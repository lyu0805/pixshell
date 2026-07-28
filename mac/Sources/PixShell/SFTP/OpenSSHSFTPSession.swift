import Foundation
import Darwin

/// 系统 OpenSSH 回落的 SFTP 后端。
///
/// 背景：`NIOSFTPSession` 走 swift-nio-ssh，算法只有 AES-GCM；OpenWrt/Dropbear 常见
/// chacha20/aes-ctr，NIO 握手直接 EOF。即便算法能谈上，部分 Dropbear 也未注册
/// `subsystem sftp`，只提供 `/usr/libexec/sftp-server` 可执行文件。
///
/// 策略：
/// 1. 用 `/usr/bin/ssh` + 与 `OpenSSHSession` 同一套最大兼容参数/ASKPASS 认证；
/// 2. **优先** `ssh host /usr/libexec/sftp-server`（及若干常见路径）——实测 ImmortalWrt 可用；
/// 3. 再试 `ssh -s sftp` 子系统；
/// 4. 二进制 SFTP v3 帧走 stdin/stdout（**禁止 -tt**，否则会污染协议流）。
///
/// 所有 completion 切主线程，接口与 `NIOSFTPSession` 一致。
public final class OpenSSHSFTPSession: SFTPService {
    private let queue = DispatchQueue(label: "com.pixshell.sftp.openssh")
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var askPassScript: String?
    private var askPassSecret: String?
    private var nextRequestId: UInt32 = 1
    private var connected = false
    /// 读缓冲：跨包拼接
    private var rx = Data()
    private let rxLock = NSLock()

    public init() {}

    // MARK: - 连接

    public func connect(_ creds: SSHCredentials, completion: @escaping (Result<Void, Error>) -> Void) {
        let hasPassword = !(creds.password ?? "").isEmpty
        let hasKey = !(creds.keyPath ?? "").isEmpty
        guard hasPassword || hasKey else {
            finishMain(completion, .failure(SFTPError.unsupportedAuth))
            return
        }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.teardownLocked()
            let targets = Self.serverLaunchTargets()
            var lastError: Error = SFTPError.connectFailed("no sftp backend")
            for target in targets {
                do {
                    try self.spawn(creds: creds, target: target)
                    try self.handshake()
                    self.connected = true
                    Log.info("OpenSSH SFTP 已连接 via \(target.label) \(creds.username)@\(creds.host):\(creds.port)", "sftp")
                    self.finishMain(completion, .success(()))
                    return
                } catch {
                    lastError = error
                    Log.warn("OpenSSH SFTP 尝试 \(target.label) 失败: \(error.localizedDescription)", "sftp")
                    self.teardownLocked()
                }
            }
            self.finishMain(completion, .failure(lastError))
        }
    }

    /// 启动方式：远端可执行路径 或 子系统名。
    private struct LaunchTarget {
        enum Kind { case exec(String); case subsystem(String) }
        let kind: Kind
        var label: String {
            switch kind {
            case .exec(let p): return "exec \(p)"
            case .subsystem(let s): return "subsystem \(s)"
            }
        }
    }

    private static func serverLaunchTargets() -> [LaunchTarget] {
        [
            // OpenWrt/ImmortalWrt：openssh-sftp-server 包装这里，Dropbear 默认不挂 subsystem。
            .init(kind: .exec("/usr/libexec/sftp-server")),
            .init(kind: .exec("/usr/lib/sftp-server")),
            .init(kind: .exec("/usr/lib/openssh/sftp-server")),
            .init(kind: .exec("/usr/libexec/openssh/sftp-server")),
            .init(kind: .subsystem("sftp")),
        ]
    }

    private func spawn(creds: SSHCredentials, target: LaunchTarget) throws {
        // 二进制通道：绝不要伪终端（-tt 会把 MOTD/提示符灌进 SFTP 流）。
        var args = OpenSSHSession.baseSSHOptions(creds, batchIfKeyOnly: true)
        args += ["-o", "RequestTTY=no", "-T"]
        switch target.kind {
        case .subsystem(let name):
            // OpenSSH：`ssh -s user@host sftp`（-s 后 destination，子系统名当 remote command）
            args += ["-s", "\(creds.username)@\(creds.host)", name]
        case .exec(let path):
            // Dropbear 常未注册 subsystem，但 openssh-sftp-server 可当远端命令跑。
            args += ["\(creds.username)@\(creds.host)", "exec \(path)"]
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        let hin = Pipe(), hout = Pipe(), herr = Pipe()
        p.standardInput = hin
        p.standardOutput = hout
        p.standardError = herr

        var env = ProcessInfo.processInfo.environment
        if let pw = creds.password, !pw.isEmpty, let ask = OpenSSHSession.installAskPass(password: pw) {
            askPassScript = ask.script
            askPassSecret = ask.secret
            env["SSH_ASKPASS"] = ask.script
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = ":"
            env["SSH_ASKPASS_PROMPT"] = "none"
        }
        p.environment = env

        // 脱离控制终端，强制走 ASKPASS（与交互 shell 的 forkpty 路径不同）
        p.qualityOfService = .userInitiated
        do {
            try p.run()
        } catch {
            throw SFTPError.connectFailed("无法启动 /usr/bin/ssh: \(error.localizedDescription)")
        }
        // 再 setsid 不了（Process 已起）；靠无 tty + SSH_ASKPASS_REQUIRE=force。
        process = p
        stdinPipe = hin
        stdoutPipe = hout
        stderrPipe = herr
        rx = Data()
        nextRequestId = 1
        Log.info("OpenSSH SFTP 启动 \(target.label) pid=\(p.processIdentifier) args=\(args.joined(separator: " "))", "sftp")
    }

    private func handshake() throws {
        // SSH_FXP_INIT (type=1) version=3
        var payload = Data()
        payload.append(SFTP.INIT)
        payload.appendUInt32(SFTP.version)
        try writeFrame(payload)
        let (type, body) = try readPacket(timeout: 12)
        guard type == SFTP.VERSION else {
            throw SFTPError.connectFailed("期望 VERSION，收到 type=\(type)")
        }
        // body: uint32 version + extensions（忽略）
        _ = body
    }

    // MARK: - SFTPService

    public func listDirectory(_ path: String, completion: @escaping (Result<[SFTPEntry], Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.ensureConnected()
                let handle = try self.opendir(path)
                defer { try? self.closeHandle(handle) }
                var acc: [SFTPEntry] = []
                while true {
                    let names = try self.readdir(handle)
                    if names == nil { break } // EOF
                    for n in names! where n.filename != "." && n.filename != ".." {
                        acc.append(n.toEntry())
                    }
                }
                self.finishMain(completion, .success(acc))
            } catch {
                self.finishMain(completion, .failure(error))
            }
        }
    }

    public func makeDirectory(_ path: String, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.ensureConnected()
                var args = Data()
                args.appendSFTPString(path)
                args.appendUInt32(SFTP.ATTR_PERMISSIONS)
                args.appendUInt32(UInt32(0o755))
                let resp = try self.request(SFTP.MKDIR, args)
                try self.expectOK(resp)
                self.finishMain(completion, .success(()))
            } catch {
                self.finishMain(completion, .failure(error))
            }
        }
    }

    public func remove(_ path: String, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.ensureConnected()
                let isDir: Bool
                if let attrs = try? self.stat(path) {
                    isDir = attrs.isDir
                } else {
                    isDir = false
                }
                var args = Data()
                args.appendSFTPString(path)
                let resp = try self.request(isDir ? SFTP.RMDIR : SFTP.REMOVE, args)
                try self.expectOK(resp)
                self.finishMain(completion, .success(()))
            } catch {
                self.finishMain(completion, .failure(error))
            }
        }
    }

    public func rename(from: String, to: String, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.ensureConnected()
                var args = Data()
                args.appendSFTPString(from)
                args.appendSFTPString(to)
                let resp = try self.request(SFTP.RENAME, args)
                try self.expectOK(resp)
                self.finishMain(completion, .success(()))
            } catch {
                self.finishMain(completion, .failure(error))
            }
        }
    }

    public func realpath(_ path: String, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.ensureConnected()
                var args = Data()
                args.appendSFTPString(path)
                let resp = try self.request(SFTP.REALPATH, args)
                guard case .name(let names) = resp, let first = names.first else {
                    throw SFTPError.unsupportedResponse
                }
                self.finishMain(completion, .success(first.filename))
            } catch {
                self.finishMain(completion, .failure(error))
            }
        }
    }

    public func home(completion: @escaping (Result<String, Error>) -> Void) {
        realpath(".", completion: completion)
    }

    public func download(remote: String, local: String, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.ensureConnected()
                FileManager.default.createFile(atPath: local, contents: nil)
                guard let fh = FileHandle(forWritingAtPath: local) else {
                    throw SFTPError.localFileError("cannot open local file for write: \(local)")
                }
                defer { try? fh.close() }
                let handle = try self.openFile(remote, pflags: SFTP.FXF_READ)
                defer { try? self.closeHandle(handle) }
                var offset: UInt64 = 0
                readLoop: while true {
                    var args = Data()
                    args.appendSFTPBytes(handle)
                    args.appendUInt64(offset)
                    args.appendUInt32(UInt32(SFTP.chunkSize))
                    let resp = try self.request(SFTP.READ, args)
                    switch resp {
                    case .data(let bytes):
                        if bytes.isEmpty { break readLoop }
                        fh.write(Data(bytes))
                        offset += UInt64(bytes.count)
                        if bytes.count < SFTP.chunkSize { break readLoop }
                    case .status(let code, let msg):
                        if code == SFTP.FX_EOF { break readLoop }
                        throw SFTPError.status(code: code, message: msg)
                    default:
                        throw SFTPError.unsupportedResponse
                    }
                }
                self.finishMain(completion, .success(()))
            } catch {
                self.finishMain(completion, .failure(error))
            }
        }
    }

    public func upload(local: String, remote: String, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.ensureConnected()
                guard let fh = FileHandle(forReadingAtPath: local) else {
                    throw SFTPError.localFileError("cannot open local file for read: \(local)")
                }
                defer { try? fh.close() }
                let handle = try self.openFile(remote, pflags: SFTP.FXF_WRITE | SFTP.FXF_CREAT | SFTP.FXF_TRUNC)
                defer { try? self.closeHandle(handle) }
                var offset: UInt64 = 0
                while true {
                    let chunk = fh.readData(ofLength: SFTP.chunkSize)
                    if chunk.isEmpty { break }
                    var args = Data()
                    args.appendSFTPBytes(handle)
                    args.appendUInt64(offset)
                    args.appendSFTPBytes([UInt8](chunk))
                    let resp = try self.request(SFTP.WRITE, args)
                    try self.expectOK(resp)
                    offset += UInt64(chunk.count)
                }
                self.finishMain(completion, .success(()))
            } catch {
                self.finishMain(completion, .failure(error))
            }
        }
    }

    public func close() {
        queue.sync { teardownLocked() }
    }

    // MARK: - 低层 SFTP 操作

    private func ensureConnected() throws {
        guard connected, process?.isRunning == true else { throw SFTPError.notConnected }
    }

    private func opendir(_ path: String) throws -> [UInt8] {
        var args = Data()
        args.appendSFTPString(path)
        let resp = try request(SFTP.OPENDIR, args)
        guard case .handle(let h) = resp else { throw SFTPError.unsupportedResponse }
        return h
    }

    private func readdir(_ handle: [UInt8]) throws -> [SFTPName]? {
        var args = Data()
        args.appendSFTPBytes(handle)
        let resp = try request(SFTP.READDIR, args)
        switch resp {
        case .name(let names): return names
        case .status(let code, let msg):
            if code == SFTP.FX_EOF { return nil }
            throw SFTPError.status(code: code, message: msg)
        default:
            throw SFTPError.unsupportedResponse
        }
    }

    private func openFile(_ path: String, pflags: UInt32) throws -> [UInt8] {
        var args = Data()
        args.appendSFTPString(path)
        args.appendUInt32(pflags)
        args.appendUInt32(0) // ATTRS flags
        let resp = try request(SFTP.OPEN, args)
        guard case .handle(let h) = resp else { throw SFTPError.unsupportedResponse }
        return h
    }

    private func closeHandle(_ handle: [UInt8]) throws {
        var args = Data()
        args.appendSFTPBytes(handle)
        let resp = try request(SFTP.CLOSE, args)
        try? expectOK(resp)
    }

    private func stat(_ path: String) throws -> SFTPAttributes {
        var args = Data()
        args.appendSFTPString(path)
        let resp = try request(SFTP.STAT, args)
        guard case .attrs(let a) = resp else { throw SFTPError.unsupportedResponse }
        return a
    }

    private func request(_ type: UInt8, _ args: Data) throws -> SFTPRawResponse {
        let id = nextRequestId
        nextRequestId &+= 1
        var payload = Data()
        payload.append(type)
        payload.appendUInt32(id)
        payload.append(args)
        try writeFrame(payload)
        // 读到匹配 request-id 的包（忽略错序——单线程请求不会错序）
        while true {
            let (ptype, body) = try readPacket(timeout: 30)
            if ptype == SFTP.VERSION { continue }
            guard body.count >= 4 else { throw SFTPError.malformedPacket }
            // body 可能是切片：只用相对 offset / withUnsafeBytes，禁止 0-based 下标。
            let rid = body.readUInt32(at: 0)
            guard rid == id else { continue }
            // Data(dropFirst) 重新基址到 startIndex=0，后续解析安全。
            var rest = Data(body.dropFirst(4))
            return try parseResponse(type: ptype, body: &rest)
        }
    }

    private func expectOK(_ resp: SFTPRawResponse) throws {
        if case .status(let code, let msg) = resp {
            if code == SFTP.FX_OK { return }
            throw SFTPError.status(code: code, message: msg)
        }
        throw SFTPError.unsupportedResponse
    }

    private func parseResponse(type: UInt8, body: inout Data) throws -> SFTPRawResponse {
        // 统一拷成连续、startIndex=0 的 Data，避免切片/removeFirst 后下标崩溃。
        var body = Data(body)
        switch type {
        case SFTP.STATUS:
            guard body.count >= 4 else { throw SFTPError.malformedPacket }
            let code = body.readUInt32BE()
            let msg = body.readSFTPString() ?? ""
            return .status(code: code, message: msg)
        case SFTP.HANDLE:
            guard let h = body.readSFTPBytes() else { throw SFTPError.malformedPacket }
            return .handle(h)
        case SFTP.DATA:
            guard let d = body.readSFTPBytes() else { throw SFTPError.malformedPacket }
            return .data(d)
        case SFTP.NAME:
            guard body.count >= 4 else { throw SFTPError.malformedPacket }
            let count = Int(body.readUInt32BE())
            guard count >= 0 else { throw SFTPError.malformedPacket }
            var names: [SFTPName] = []
            names.reserveCapacity(count)
            for _ in 0..<count {
                guard let filename = body.readSFTPString(),
                      let longname = body.readSFTPString(),
                      let attrs = body.readSFTPAttributes() else {
                    throw SFTPError.malformedPacket
                }
                names.append(SFTPName(filename: filename, longname: longname, attrs: attrs))
            }
            return .name(names)
        case SFTP.ATTRS:
            guard let a = body.readSFTPAttributes() else { throw SFTPError.malformedPacket }
            return .attrs(a)
        default:
            throw SFTPError.unsupportedResponse
        }
    }

    // MARK: - 帧 IO

    private func writeFrame(_ inner: Data) throws {
        guard let hin = stdinPipe else { throw SFTPError.notConnected }
        var frame = Data()
        frame.appendUInt32(UInt32(inner.count))
        frame.append(inner)
        do {
            try hin.fileHandleForWriting.write(contentsOf: frame)
        } catch {
            throw SFTPError.connectFailed("写 SFTP 帧失败: \(error.localizedDescription)")
        }
    }

    private func readPacket(timeout: TimeInterval) throws -> (UInt8, Data) {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            rxLock.lock()
            if rx.count >= 4 {
                let len = Int(rx.readUInt32(at: 0))
                let total = 4 + len
                // dropFirst/prefix 相对 count，再 Data(...) 重新基址，杜绝切片下标崩溃。
                if total >= 4, rx.count >= total {
                    let packet = Data(rx.dropFirst(4).prefix(total - 4))
                    rx = Data(rx.dropFirst(total))
                    rxLock.unlock()
                    guard let type = packet.first else { throw SFTPError.malformedPacket }
                    return (type, Data(packet.dropFirst(1)))
                }
            }
            rxLock.unlock()

            if Date() > deadline {
                let err = peekStderr()
                throw SFTPError.connectFailed(err.isEmpty ? "读 SFTP 超时" : "读 SFTP 超时: \(err)")
            }
            if process?.isRunning != true {
                let err = peekStderr()
                throw SFTPError.connectFailed(err.isEmpty ? "ssh/sftp 进程已退出" : "ssh/sftp 退出: \(err)")
            }
            try readMore(timeout: min(0.5, deadline.timeIntervalSinceNow))
        }
    }

    private func readMore(timeout: TimeInterval) throws {
        guard let hout = stdoutPipe else { throw SFTPError.notConnected }
        let fd = hout.fileHandleForReading.fileDescriptor
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ms = Int32(max(timeout, 0.05) * 1000)
        let pr = poll(&pfd, 1, ms)
        if pr < 0 && errno != EINTR {
            throw SFTPError.connectFailed("poll 失败 errno=\(errno)")
        }
        if pr > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
            let chunk = hout.fileHandleForReading.availableData
            if chunk.isEmpty {
                // EOF
                return
            }
            rxLock.lock()
            rx.append(chunk)
            rxLock.unlock()
        }
    }

    private func peekStderr() -> String {
        guard let herr = stderrPipe else { return "" }
        let data = herr.fileHandleForReading.availableData
        let s = String(data: data, encoding: .utf8) ?? ""
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 240 { return String(t.suffix(240)) }
        return t
    }

    private func teardownLocked() {
        connected = false
        if let p = process, p.isRunning {
            p.terminate()
            // 不无限等
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                p.waitUntilExit()
                group.leave()
            }
            _ = group.wait(timeout: .now() + 1.5)
        }
        process = nil
        try? stdinPipe?.fileHandleForWriting.close()
        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        rx = Data()
        if let s = askPassSecret { try? FileManager.default.removeItem(atPath: s) }
        if let s = askPassScript {
            let dir = (s as NSString).deletingLastPathComponent
            try? FileManager.default.removeItem(atPath: s)
            try? FileManager.default.removeItem(atPath: dir)
        }
        askPassSecret = nil
        askPassScript = nil
    }

    private func finishMain<T>(_ completion: @escaping (Result<T, Error>) -> Void, _ result: Result<T, Error>) {
        DispatchQueue.main.async { completion(result) }
    }
}

// MARK: - Data SFTP 编解码（与 ByteBuffer 版平行，供 OpenSSH 管道用）
//
// 注意：Swift `Data` 在 `removeFirst` / 部分 `subdata` 后可能保留非 0 的 `startIndex`。
// 对切片做 `self[0]` / `subdata(in: 0..<n)` 会触发
// `Data._Representation.subscript.getter` → SIGILL/EXC_BAD_INSTRUCTION。
// 约定：
// 1. 相对 offset 读写一律走 `withUnsafeBytes`（视图从 0 起）；
// 2. 消费字节后用 `self = Data(dropFirst(n))` 重新基址到 startIndex=0；
// 3. 禁止对可能是切片的 Data 使用字面 0-based Range。

private extension Data {
    mutating func appendUInt32(_ v: UInt32) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
    mutating func appendUInt64(_ v: UInt64) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
    mutating func appendSFTPString(_ s: String) {
        let bytes = Array(s.utf8)
        appendUInt32(UInt32(bytes.count))
        append(contentsOf: bytes)
    }
    mutating func appendSFTPBytes(_ bytes: [UInt8]) {
        appendUInt32(UInt32(bytes.count))
        append(contentsOf: bytes)
    }

    /// 相对当前 Data 视图起点的 BE u32 只读；offset 从 0 计（相对 count，不是 startIndex）。
    /// 使用 withUnsafeBytes，对切片 Data 也安全。
    func readUInt32(at offset: Int) -> UInt32 {
        precondition(offset >= 0 && count >= offset + 4, "readUInt32 out of bounds")
        return withUnsafeBytes { buf -> UInt32 in
            var v: UInt32 = 0
            for i in 0..<4 { v = (v << 8) | UInt32(buf[offset + i]) }
            return v
        }
    }

    /// 相对当前 Data 视图起点的 BE u64 只读。
    func readUInt64(at offset: Int) -> UInt64 {
        precondition(offset >= 0 && count >= offset + 8, "readUInt64 out of bounds")
        return withUnsafeBytes { buf -> UInt64 in
            var v: UInt64 = 0
            for i in 0..<8 { v = (v << 8) | UInt64(buf[offset + i]) }
            return v
        }
    }

    /// 只读相对 offset 的 u32（不消费）。
    func peekUInt32(at offset: Int) -> UInt32 { readUInt32(at: offset) }

    /// 从当前开头读 big-endian u32 并消费 4 字节；消费后重新基址。
    mutating func readUInt32BE() -> UInt32 {
        precondition(count >= 4, "readUInt32BE underflow")
        let v = readUInt32(at: 0)
        self = Data(dropFirst(4))
        return v
    }

    /// 从当前开头读 big-endian u64 并消费 8 字节；消费后重新基址。
    mutating func readUInt64BE() -> UInt64 {
        precondition(count >= 8, "readUInt64BE underflow")
        let v = readUInt64(at: 0)
        self = Data(dropFirst(8))
        return v
    }

    mutating func readSFTPString() -> String? {
        guard count >= 4 else { return nil }
        let len = Int(readUInt32(at: 0))
        guard len >= 0, count >= 4 + len else { return nil }
        let slice = Data(dropFirst(4).prefix(len))
        self = Data(dropFirst(4 + len))
        return String(data: slice, encoding: .utf8) ?? String(data: slice, encoding: .isoLatin1)
    }

    mutating func readSFTPBytes() -> [UInt8]? {
        guard count >= 4 else { return nil }
        let len = Int(readUInt32(at: 0))
        guard len >= 0, count >= 4 + len else { return nil }
        let slice = Data(dropFirst(4).prefix(len))
        self = Data(dropFirst(4 + len))
        return [UInt8](slice)
    }

    mutating func readSFTPAttributes() -> SFTPAttributes? {
        guard count >= 4 else { return nil }
        let flags = readUInt32BE()
        var a = SFTPAttributes()
        if flags & SFTP.ATTR_SIZE != 0 {
            guard count >= 8 else { return nil }
            a.size = readUInt64BE()
        }
        if flags & SFTP.ATTR_UIDGID != 0 {
            guard count >= 8 else { return nil }
            a.uid = readUInt32BE()
            a.gid = readUInt32BE()
        }
        if flags & SFTP.ATTR_PERMISSIONS != 0 {
            guard count >= 4 else { return nil }
            a.permissions = readUInt32BE()
        }
        if flags & SFTP.ATTR_ACMODTIME != 0 {
            guard count >= 8 else { return nil }
            a.atime = readUInt32BE()
            a.mtime = readUInt32BE()
        }
        if flags & SFTP.ATTR_EXTENDED != 0 {
            guard count >= 4 else { return nil }
            let n = Int(readUInt32BE())
            guard n >= 0 else { return nil }
            for _ in 0..<n {
                guard readSFTPString() != nil, readSFTPString() != nil else { return nil }
            }
        }
        return a
    }
}

