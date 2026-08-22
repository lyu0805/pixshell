import Foundation

/// SCP + shell exec 文件后端（对齐 win 端 ScpBackend/ScpAdapter）。
/// 面向**没有 openssh-sftp-server** 的目标（Dropbear / OpenWrt / 部分网络设备）：
/// SFTP 子系统不可用时，列表走 `ls -la` 解析，上传/下载走 `/usr/bin/scp` 进程，
/// 增删改走 shell 命令。每个操作独立起 ssh/scp 进程，无常驻连接（`connect` 只是探活）。
///
/// 能力降级（相对 SFTP）：mtime 一律 1970、perms 一律 0（ls 文本位不换算）、
/// 软链按 ls 显示名处理；上传下载无进度回调。够文件管理面板用。
public final class SCPSession: SFTPService {
    private var creds: SSHCredentials?
    private var connectedFlag = false
    private let queue = DispatchQueue(label: "pixshell.scp", qos: .utility)

    private func done<T>(_ r: Result<T, Error>, _ completion: @escaping (Result<T, Error>) -> Void) {
        DispatchQueue.main.async { completion(r) }
    }

    public init() {}

    // MARK: - SFTPService

    public func connect(_ creds: SSHCredentials, completion: @escaping (Result<Void, Error>) -> Void) {
        self.creds = creds
        runSSH("echo __pix_scp_ok__", timeout: 15) { [weak self] out, code in
            guard let self = self else { return }
            if code == 0, out.contains("__pix_scp_ok__") {
                self.connectedFlag = true
                self.done(.success(()), completion)
            } else {
                self.connectedFlag = false
                self.done(.failure(SFTPError.connectFailed("SCP 探活失败：exit \(code) \(out.suffix(200))")), completion)
            }
        }
    }

    public func listDirectory(_ path: String, completion: @escaping (Result<[SFTPEntry], Error>) -> Void) {
        runSSH("ls -la \(Self.escape(path)) 2>&1", timeout: 30) { [weak self] out, _ in
            guard let self = self else { return }
            self.done(Result { try Self.parseLs(out) }, completion)
        }
    }

    public func download(remote: String, local: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let c = creds else { return done(.failure(SFTPError.notConnected), completion) }
        var args = Self.scpOptions(c)
        args += ["\(Self.target(c)):\(Self.remoteArg(remote, for: c))", local]
        runProcess("/usr/bin/scp", args, timeout: 900, envAskPassFor: c, completion: { [weak self] _, errOut, code in
            guard let self = self else { return }
            if code == 0 { self.done(.success(()), completion) }
            else { self.done(.failure(SFTPError.localFileError("scp 下载失败 exit \(code): \(errOut.suffix(300))")), completion) }
        })
    }

    public func upload(local: String, remote: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let c = creds else { return done(.failure(SFTPError.notConnected), completion) }
        var args = Self.scpOptions(c)
        args += [local, "\(Self.target(c)):\(Self.remoteArg(remote, for: c))"]
        runProcess("/usr/bin/scp", args, timeout: 900, envAskPassFor: c, completion: { [weak self] _, errOut, code in
            guard let self = self else { return }
            if code == 0 { self.done(.success(()), completion) }
            else { self.done(.failure(SFTPError.localFileError("scp 上传失败 exit \(code): \(errOut.suffix(300))")), completion) }
        })
    }

    public func makeDirectory(_ path: String, completion: @escaping (Result<Void, Error>) -> Void) {
        runSSH("mkdir -p \(Self.escape(path)) && echo OK", timeout: 30) { [weak self] out, code in
            guard let self = self else { return }
            if code == 0 { self.done(.success(()), completion) }
            else { self.done(.failure(SFTPError.status(code: UInt32(code), message: "mkdir 失败")), completion) }
        }
    }

    public func remove(_ path: String, completion: @escaping (Result<Void, Error>) -> Void) {
        // rm -rf 同时覆盖文件与目录（协议语义：目录自动 RMDIR 的超集）。
        runSSH("rm -rf \(Self.escape(path)) && echo OK", timeout: 60) { [weak self] out, code in
            guard let self = self else { return }
            if code == 0 { self.done(.success(()), completion) }
            else { self.done(.failure(SFTPError.status(code: UInt32(code), message: "删除失败")), completion) }
        }
    }

    public func rename(from: String, to: String, completion: @escaping (Result<Void, Error>) -> Void) {
        runSSH("mv \(Self.escape(from)) \(Self.escape(to)) && echo OK", timeout: 30) { [weak self] out, code in
            guard let self = self else { return }
            if code == 0 { self.done(.success(()), completion) }
            else { self.done(.failure(SFTPError.status(code: UInt32(code), message: "重命名失败")), completion) }
        }
    }

    public func realpath(_ path: String, completion: @escaping (Result<String, Error>) -> Void) {
        runSSH("cd -P \(Self.escape(path)) && pwd", timeout: 30) { [weak self] out, code in
            guard let self = self else { return }
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if code == 0, !trimmed.isEmpty, !trimmed.contains("\n") {
                self.done(.success(trimmed), completion)
            } else {
                self.done(.failure(SFTPError.status(code: UInt32(code), message: "路径不存在")), completion)
            }
        }
    }

    public func home(completion: @escaping (Result<String, Error>) -> Void) {
        runSSH("echo $HOME", timeout: 30) { [weak self] out, code in
            guard let self = self else { return }
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if code == 0, !trimmed.isEmpty { self.done(.success(trimmed), completion) }
            else { self.done(.failure(SFTPError.status(code: UInt32(code), message: "无法取家目录")), completion) }
        }
    }

    public func close() {
        connectedFlag = false
        creds = nil
    }

    // MARK: - 进程执行

    /// 起一条一次性 `ssh` 命令（兼容算法/认证/代理全部沿用 OpenSSH 回落同款参数）。
    private func runSSH(_ command: String, timeout: TimeInterval, completion: @escaping (String, Int32) -> Void) {
        guard let c = creds else { completion("", -1); return }
        var args = OpenSSHSession.baseSSHOptions(c, batchIfKeyOnly: true)
        args += ["-o", "ConnectTimeout=10", "-T"]
        args += ["\(c.username)@\(c.host)", command]
        runProcess("/usr/bin/ssh", args, timeout: timeout, envAskPassFor: c) { out, err, code in
            completion(out.isEmpty ? err : out, code)
        }
    }

    /// 起一个进程收 stdout/stderr + 超时兜底（对齐 OpenSSHSession.exec 的收口方式）。
    private func runProcess(_ path: String, _ args: [String], timeout: TimeInterval,
                            envAskPassFor c: SSHCredentials? = nil,
                            completion: @escaping (String, String, Int32) -> Void) {
        queue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let outPipe = Pipe(), errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            p.standardInput = FileHandle.nullDevice
            var env = ProcessInfo.processInfo.environment
            var secretPath: String?
            var scriptPath: String?
            if let pw = c?.password, !pw.isEmpty, let ask = OpenSSHSession.installAskPass(password: pw) {
                secretPath = ask.secret
                scriptPath = ask.script
                env["SSH_ASKPASS"] = ask.script
                env["SSH_ASKPASS_REQUIRE"] = "force"
                env["DISPLAY"] = ":"
                env["SSH_ASKPASS_PROMPT"] = "none"
            }
            p.environment = env
            let lock = NSLock()
            var outText = "", errText = "", finished = false
            func finish(_ code: Int32) {
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                let o = outText, e = errText
                lock.unlock()
                if let s = secretPath { try? FileManager.default.removeItem(atPath: s) }
                if let s = scriptPath {
                    let dir = (s as NSString).deletingLastPathComponent
                    try? FileManager.default.removeItem(atPath: s)
                    try? FileManager.default.removeItem(atPath: dir)
                }
                completion(o, e, code)
            }
            outPipe.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                if d.isEmpty { fh.readabilityHandler = nil }
                else if let s = String(data: d, encoding: .utf8) { lock.lock(); outText += s; lock.unlock() }
            }
            errPipe.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                if d.isEmpty { fh.readabilityHandler = nil }
                else if let s = String(data: d, encoding: .utf8) { lock.lock(); errText += s; lock.unlock() }
            }
            do {
                try p.run()
            } catch {
                finish(-1)
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak p] in
                if p?.isRunning == true {
                    if let pid = p?.processIdentifier { kill(pid, SIGKILL) }
                }
            }
            DispatchQueue.global(qos: .utility).async {
                p.waitUntilExit()
                finish(p.terminationStatus)
            }
        }
    }

    // MARK: - 参数与解析

    /// scp 的端口是 `-P`（大写）；其余 -o/-i/ProxyCommand 与 ssh 同义透传。
    private static func scpOptions(_ c: SSHCredentials) -> [String] {
        var a = OpenSSHSession.baseSSHOptions(c, batchIfKeyOnly: true)
        if a.count >= 2, a[0] == "-p" { a.removeFirst(2) }   // 去掉 ssh 的 -p <port>
        return ["-P", String(c.port)] + a
    }

    private static func target(_ c: SSHCredentials) -> String { "\(c.username)@\(c.host)" }

    /// 远端路径侧的 shell 引用：scp 的 remote 侧会再经远端 shell 展开，单引号包裹。
    private static func remoteArg(_ path: String, for c: SSHCredentials) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// shell 命令参数引用（与 win ScpBackend.EscapeArg 同口径）。
    private static func escape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 解析 `ls -la`（对齐 win ScpBackend.ListDirectory：total/./.. 跳过、软链剥 " -> "）。
    static func parseLs(_ raw: String) throws -> [SFTPEntry] {
        var entries: [SFTPEntry] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("total ") { continue }
            let parts = l.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 9 else { continue }
            let perms = parts[0]
            let isDir = perms.hasPrefix("d")
            let isLink = perms.hasPrefix("l")
            var name = parts[parts.count - 1]
            if name == "." || name == ".." { continue }
            if isLink, let range = name.range(of: " -> "), range.lowerBound > name.startIndex {
                name = String(name[..<range.lowerBound])
            }
            let size = UInt64(parts[parts.count - 4]) ?? 0
            entries.append(SFTPEntry(name: name, isDir: isDir, size: size,
                                     mtime: Date(timeIntervalSince1970: 0), perms: 0))
        }
        return entries
    }
}

/// SFTP 后端三层回落工厂（对齐 win：SftpAdapter → ProcAdapter → ScpAdapter）。
/// NIO 子系统握手失败（无 sftp-server 的 Dropbear 等）→ 系统 ssh sftp → SCP+shell。
/// `skipNIO`：私钥是 NIO 加载不了的类型（RSA/加密等）时置 true，直接从系统 ssh 开始。
enum SFTPBackend {
    static func label(of svc: SFTPService) -> String {
        switch svc {
        case is NIOSFTPSession: return "NIO"
        case is OpenSSHSFTPSession: return "OpenSSH"
        case is SCPSession: return "SCP"
        default: return "SFTP"
        }
    }

    static func connect(creds: SSHCredentials, skipNIO: Bool = false,
                        completion: @escaping (Result<SFTPService, Error>) -> Void) {
        if skipNIO {
            connectViaOpenSSH(creds, completion: completion)
            return
        }
        let nio = NIOSFTPSession()
        nio.connect(creds) { result in
            switch result {
            case .success: completion(.success(nio))
            case .failure(let e1):
                Log.warn("SFTP(NIO) 连接失败，尝试系统 ssh sftp 回落：\(e1.localizedDescription)", "sftp")
                connectViaOpenSSH(creds, completion: completion)
            }
        }
    }

    private static func connectViaOpenSSH(_ creds: SSHCredentials,
                                          completion: @escaping (Result<SFTPService, Error>) -> Void) {
        let open = OpenSSHSFTPSession()
        open.connect(creds) { result in
            switch result {
            case .success: completion(.success(open))
            case .failure(let e2):
                Log.warn("系统 ssh sftp 回落失败，尝试 SCP 后端：\(e2.localizedDescription)", "sftp")
                let scp = SCPSession()
                scp.connect(creds) { result in
                    switch result {
                    case .success:
                        Log.info("SFTP 三层回落到 SCP+shell（目标无 sftp-server 也能管理文件）", "sftp")
                        completion(.success(scp))
                    case .failure(let e3):
                        completion(.failure(e3))
                    }
                }
            }
        }
    }
}
