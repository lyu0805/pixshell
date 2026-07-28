import Foundation
import Darwin

/// 本机交互式 shell（应用内终端标签），不弹外部 Terminal.app。
/// 复用 SSHSession 协议：forkpty + login shell，IO 经 master FD 桥到 SwiftTerm。
public final class LocalSession: SSHSession {

    public weak var delegate: SSHSessionDelegate?

    private var pid: pid_t = -1
    private var masterFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var closed = false
    private var shellOpenedEmitted = false

    public init() {}

    public func connectAndOpenShell(_ creds: SSHCredentials, term: String, cols: Int, rows: Int) {
        // creds 对本地 shell 无意义；保留协议签名。
        _ = creds
        var master: Int32 = 0
        var win = winsize(
            ws_row: UInt16(max(rows, 1)),
            ws_col: UInt16(max(cols, 1)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        let shellPath = Self.preferredShell()
        let shellName = (shellPath as NSString).lastPathComponent
        // login shell：argv[0] 以 `-` 开头，走完整 profile。
        let argv0 = "-" + shellName
        var cArgs: [UnsafeMutablePointer<CChar>?] = [strdup(argv0), nil]

        var env: [String] = [
            "TERM=\(term.isEmpty ? "xterm-256color" : term)",
            "COLORTERM=truecolor",
            "PIXSHELL_LOCAL=1",
        ]
        for k in ["HOME", "PATH", "LANG", "LC_ALL", "LC_CTYPE", "USER", "LOGNAME",
                  "SHELL", "TMPDIR", "SSH_AUTH_SOCK", "XPC_FLAGS", "XPC_SERVICE_NAME"] {
            if let v = ProcessInfo.processInfo.environment[k], !v.isEmpty {
                env.append("\(k)=\(v)")
            }
        }
        if ProcessInfo.processInfo.environment["HOME"] == nil {
            env.append("HOME=\(NSHomeDirectory())")
        }
        if ProcessInfo.processInfo.environment["USER"] == nil {
            env.append("USER=\(NSUserName())")
        }
        if ProcessInfo.processInfo.environment["SHELL"] == nil {
            env.append("SHELL=\(shellPath)")
        }
        var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) }
        cEnv.append(nil)

        let child = forkpty(&master, nil, nil, &win)
        if child == -1 {
            for p in cArgs where p != nil { free(p) }
            for p in cEnv where p != nil { free(p) }
            finish(NSError(domain: "PixShell.local", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "无法分配本地伪终端"]))
            return
        }
        if child == 0 {
            // 子进程：切到用户主目录再 exec login shell。
            let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
            _ = home.withCString { chdir($0) }
            execve(shellPath, &cArgs, &cEnv)
            // 兜底 /bin/zsh、/bin/bash
            for fallback in ["/bin/zsh", "/bin/bash", "/bin/sh"] {
                execve(fallback, &cArgs, &cEnv)
            }
            _exit(127)
        }

        for p in cArgs where p != nil { free(p) }
        for p in cEnv where p != nil { free(p) }
        masterFD = master
        pid = child
        Log.info("本地 shell 已启动 pid=\(child) fd=\(master) \(shellPath)", "local")
        startReading()
        watchExit()
        // 本地 fork 成功即可开 shell（无需认证握手）。
        emitOpenIfNeeded()
    }

    private static func preferredShell() -> String {
        if let s = ProcessInfo.processInfo.environment["SHELL"], !s.isEmpty,
           FileManager.default.isExecutableFile(atPath: s) {
            return s
        }
        for p in ["/bin/zsh", "/bin/bash", "/bin/sh"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "/bin/zsh"
    }

    private func startReading() {
        let src = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .global(qos: .userInitiated))
        src.setEventHandler { [weak self] in
            guard let self = self, self.masterFD >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(self.masterFD, &buf, buf.count)
            if n > 0 {
                let chunk = Array(buf[0..<n])
                DispatchQueue.main.async { self.delegate?.sshSession(self, didReceive: chunk) }
            } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                // EOF / 致命读错：等 waitpid 收口
            }
        }
        src.resume()
        readSource = src
    }

    private func emitOpenIfNeeded() {
        guard !shellOpenedEmitted, !closed else { return }
        shellOpenedEmitted = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.sshSessionDidOpenShell(self)
        }
    }

    public func send(_ data: [UInt8]) {
        guard masterFD >= 0, !data.isEmpty else { return }
        var d = data
        _ = write(masterFD, &d, d.count)
    }

    public func resize(cols: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        var w = winsize(
            ws_row: UInt16(max(rows, 1)),
            ws_col: UInt16(max(cols, 1)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(masterFD, TIOCSWINSZ, &w)
        if pid > 0 { kill(pid, SIGWINCH) }
    }

    /// 本地一次性命令：另起 Process 收 stdout（监控侧栏等；本地会话一般不采远端指标）。
    public func exec(_ command: String, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            var text = ""
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                text = String(data: data, encoding: .utf8) ?? ""
            } catch {
                text = ""
            }
            DispatchQueue.main.async { completion(text) }
        }
    }

    public func close() {
        guard !closed else { return }
        if pid > 0 { kill(pid, SIGHUP) }
        finish(nil)
    }

    private func watchExit() {
        guard pid > 0 else { return }
        let p = pid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            waitpid(p, &status, 0)
            let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f)
            Log.info("本地 shell 退出 pid=\(p) code=\(code)", "local")
            if code == 0 {
                self?.finish(nil)
            } else {
                self?.finish(NSError(domain: "PixShell.local", code: Int(code),
                                     userInfo: [NSLocalizedDescriptionKey: "本地 shell 退出码 \(code)"]))
            }
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        readSource?.cancel(); readSource = nil
        if masterFD >= 0 { Darwin.close(masterFD); masterFD = -1 }
        pid = -1
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.sshSession(self, didCloseWith: error)
        }
    }
}
