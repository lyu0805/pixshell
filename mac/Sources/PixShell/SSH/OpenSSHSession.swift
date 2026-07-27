import Foundation
import Darwin

/// 用**系统自带的 OpenSSH**（`/usr/bin/ssh`）跑一个会话，作为算法协商失败时的回落传输。
///
/// 为什么需要它：内置的 swift-nio-ssh 实现的算法很窄 —— 主机密钥只有 ed25519/ecdsa（**没有 RSA**）、
/// 加密只有 aes-gcm、KEX 只有 curve25519/ecdh。而只提供 RSA 主机密钥 + aes-ctr + dh-group14 的老机器
/// （CentOS 7、老 OpenSSH、交换机路由器等网络设备）在市面上仍然大量存在，那些机器内置实现根本握不上手。
/// 那个库的密钥类型是 `internal enum`，模块外无法扩展，只补一样也没用（RSA/ctr/dh-group 得同时补齐），
/// 等于把 OpenSSH 已经做好的事重写一遍 —— 所以直接复用系统 OpenSSH。
///
/// 设计取舍：
/// - **默认不用它**。只有当内置实现在"还没打开 shell"时就因算法协商失败挂掉，才自动回落（见
///   AppDelegate+Sessions.startSSH）。已经能连的机器行为一个字都不变。
/// - 跑在**伪终端(pty)**里，所以 ssh 自己的任何交互式提问（口令、一次性验证码、首次连接确认）
///   都会原样出现在终端里由用户自己回答。这里**不做任何自动应答**，也不借 SSH_ASKPASS/sshpass 之类
///   的手段去塞凭据 —— 用户在终端里敲，和他平时用 ssh 一模一样。
/// - 顺带白拿了 OpenSSH 的全部能力：~/.ssh/config、ProxyJump、证书登录、ssh-agent、全部算法。
public final class OpenSSHSession: SSHSession {

    public weak var delegate: SSHSessionDelegate?

    private var pid: pid_t = -1
    private var masterFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var closed = false
    private var creds: SSHCredentials?

    public init() {}

    // MARK: - 连接

    public func connectAndOpenShell(_ creds: SSHCredentials, term: String, cols: Int, rows: Int) {
        self.creds = creds

        let args = Self.buildArguments(creds, term: term)
        Log.info("回落到系统 ssh：/usr/bin/ssh \(args.joined(separator: " "))", "ssh")

        // 必须用 forkpty，不能用 posix_spawn +POSIX_SPAWN_SETSID +dup2(slave)：
        // 后者只是把从端接到了 0/1/2，**并没有把它设成子进程的控制终端**（缺 TIOCSCTTY）。
        // 没有控制终端的 ssh 无法交互提问，会直接打印 "Permission denied" 退出 —— 实测踩过。
        // forkpty 内部做了 setsid + TIOCSCTTY，正是这里需要的语义。
        var master: Int32 = 0
        var win = winsize(ws_row: UInt16(max(rows, 1)), ws_col: UInt16(max(cols, 1)), ws_xpixel: 0, ws_ypixel: 0)

        let argv: [String] = ["ssh"] + args
        // fork 之后只能调 async-signal-safe 的东西，所以字符串在 fork 前就转成 C 数组备好。
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)
        var env: [String] = ["TERM=\(term)"]   // TERM 要传对，否则远端 shell 的颜色/光标行为会退化
        for k in ["HOME", "PATH", "LANG", "SSH_AUTH_SOCK", "USER"] {
            if let v = ProcessInfo.processInfo.environment[k] { env.append("\(k)=\(v)") }
        }
        var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) }
        cEnv.append(nil)

        let child = forkpty(&master, nil, nil, &win)
        if child == -1 {
            for p in cArgs where p != nil { free(p) }
            for p in cEnv where p != nil { free(p) }
            finish(NSError(domain: "PixShell.openssh", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "无法分配伪终端"]))
            return
        }
        Log.info("系统 ssh 启动 pid 待定，cwd=\(FileManager.default.currentDirectoryPath)", "ssh")
        if child == 0 {
            // 子进程：直接 exec，失败就硬退出（这里不能再碰 Swift 运行时）。
            execve("/usr/bin/ssh", &cArgs, &cEnv)
            _exit(127)
        }

        for p in cArgs where p != nil { free(p) }
        for p in cEnv where p != nil { free(p) }
        masterFD = master
        pid = child
        Log.info("系统 ssh 已启动 pid=\(child) fd=\(master) \(creds.username)@\(creds.host):\(creds.port)", "ssh")
        startReading()
        // pty 一建好就能收发了；shell 是否真的登录成功由用户在终端里看到的内容决定。
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.sshSessionDidOpenShell(self)
        }
        watchExit()
    }

    /// 组装 ssh 参数。只放"让它在 App 里行为可预期"的选项，不去替用户决定安全策略。
    private static func buildArguments(_ c: SSHCredentials, term: String) -> [String] {
        var a: [String] = []
        a += ["-tt"]                                        // 强制分配 tty（我们本来就跑在 pty 里）
        a += ["-p", String(c.port)]
        a += ["-o", "StrictHostKeyChecking=accept-new"]     // 首次连接自动记 known_hosts，但变更仍会拦
        a += ["-o", "NumberOfPasswordPrompts=1"]            // 别反复追问，失败就干净退出
        a += ["-o", "ServerAliveInterval=30"]
        if let kp = c.keyPath, !kp.isEmpty {
            a += ["-i", (kp as NSString).expandingTildeInPath]
            a += ["-o", "IdentitiesOnly=yes"]               // 指定了私钥就只用它，别把 agent 里的全试一遍
        }
        // 代理：SOCKS/HTTP 交给 ssh 自己的 ProxyCommand（用 nc），跳板机用 ProxyJump。
        if let p = c.proxy {
            switch p.type {
            case .socks5, .socks4:
                a += ["-o", "ProxyCommand=/usr/bin/nc -x \(p.host):\(p.port) -X \(p.type == .socks5 ? "5" : "4") %h %p"]
            case .http:
                a += ["-o", "ProxyCommand=/usr/bin/nc -x \(p.host):\(p.port) -X connect %h %p"]
            case .sshJump:
                a += ["-J", "\(p.username.isEmpty ? "" : p.username + "@")\(p.host):\(p.port)"]
            }
        }
        a += ["\(c.username)@\(c.host)"]
        return a
    }

    // MARK: - IO

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
                if n < 0 { Log.warn("系统 ssh 读取结束 errno=\(errno)", "ssh") }
                self.finish(nil)
            }
        }
        src.resume()
        readSource = src
    }

    public func send(_ data: [UInt8]) {
        guard masterFD >= 0, !data.isEmpty else { return }
        var d = data
        _ = write(masterFD, &d, d.count)
    }

    public func resize(cols: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        var w = winsize(ws_row: UInt16(max(rows, 1)), ws_col: UInt16(max(cols, 1)), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &w)
        if pid > 0 { kill(pid, SIGWINCH) }
    }

    /// 一次性命令（监控采集用）：另起一个非交互 ssh 进程收 stdout。
    /// 走 BatchMode，绝不弹交互提示 —— 后台采集不该阻塞在提问上。
    public func exec(_ command: String, completion: @escaping (String) -> Void) {
        guard let c = creds else { DispatchQueue.main.async { completion("") }; return }
        DispatchQueue.global(qos: .utility).async {
            var args = ["-p", String(c.port),
                        "-o", "BatchMode=yes",
                        "-o", "StrictHostKeyChecking=accept-new",
                        "-o", "ConnectTimeout=10"]
            if let kp = c.keyPath, !kp.isEmpty {
                args += ["-i", (kp as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
            }
            args += ["\(c.username)@\(c.host)", command]

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
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

    // MARK: - 收尾

    private func watchExit() {
        guard pid > 0 else { return }
        let p = pid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            waitpid(p, &status, 0)
            // 退出码是排查"连不上但没报错"的关键线索：255=ssh 自身失败，1=远端命令失败
            let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f)
            Log.info("系统 ssh 退出 pid=\(p) code=\(code)", "ssh")
            self?.finish(nil)
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
