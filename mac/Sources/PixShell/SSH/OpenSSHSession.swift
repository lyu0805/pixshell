import Foundation
import Darwin

/// 系统 OpenSSH 退出错误（exit≠0）。上层用它区分「假 open 后静默关掉」和真实失败。
/// `hint` 来自退出前 pty 输出摘要，用于区分认证失败 vs 网络失败（禁止一律清 Keychain）。
public struct OpenSSHExitError: Error, LocalizedError {
    public let code: Int
    public let hint: String
    /// 明确看到密码/口令提示后仍未打开 shell，才标记为认证被拒。
    /// 网络、端口、算法协商、无 hint 的退出都不得默认当成密码错误。
    public let authRejected: Bool
    public init(code: Int, hint: String = "", authRejected: Bool? = nil) {
        self.code = code
        self.hint = hint
        if let authRejected {
            self.authRejected = authRejected
        } else {
            let h = hint.lowercased()
            self.authRejected = h.contains("permission denied")
                || h.contains("authentication failed")
                || h.contains("auth failed")
        }
    }
    public var errorDescription: String? {
        let base: String
        switch code {
        case 255: base = "系统 ssh 失败（exit 255）"
        case 127: base = "无法启动 /usr/bin/ssh"
        default:  base = "系统 ssh 退出码 \(code)"
        }
        let h = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.isEmpty { return base }
        // 截一段给 UI/分类器，避免整屏 MOTD。
        let clip = h.count > 240 ? String(h.suffix(240)) : h
        return base + "：" + clip
    }
}

/// 用**系统自带的 OpenSSH**（`/usr/bin/ssh`）跑一个会话，作为算法协商失败时的回落传输。
///
/// 为什么需要它：内置的 swift-nio-ssh 实现的算法很窄 —— 主机密钥只有 ed25519/ecdsa（**没有 RSA**）、
/// 加密只有 aes-gcm、KEX 只有 curve25519/ecdh。而只提供 RSA 主机密钥 + aes-ctr + dh-group14 的老机器
/// （CentOS 7、老 OpenSSH、交换机路由器等网络设备）在市面上仍然大量存在，那些机器内置实现根本握不上手。
///
/// 设计取舍：
/// - **默认不用它**。只有当内置实现在"还没打开 shell"时就因算法协商失败挂掉，才自动回落（见
///   AppDelegate+Sessions.startSSH）。已经能连的机器行为一个字都不变。
/// - 跑在**伪终端(pty)**里。
/// - 若 App 已持有密码（Keychain / 用户刚输入），通过受控 `SSH_ASKPASS` 注入一次，避免回落后还要再敲。
///   无私钥且无密码时，交互提问仍原样出现在终端。
/// - **禁止**在 fork 后立刻宣称 shell 已打开：必须等认证迹象确认，或 exit≠0 时带错误码上抛，
///   否则 UI 会假显示「已连接」再灰字「连接已关闭」。
public final class OpenSSHSession: SSHSession {

    public weak var delegate: SSHSessionDelegate?

    /// exec 命令级总超时（秒）。远端命令不退出（tail -f / 挂起 / 网络黑洞）时 terminate 兜底收口，
    /// 避免 completion 永不回调 → HTTP 永不返回 → 后续工具调用排队超时。
    static let execTimeout: TimeInterval = 30

    private var pid: pid_t = -1
    private var masterFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var closed = false
    private var creds: SSHCredentials?
    /// 是否已向 UI 确认过「真的登录成功」（与 pty 已 fork 严格分离）。
    private var shellOpenedEmitted = false
    private var sawAuthPrompt = false
    private var pendingOpenWorkItem: DispatchWorkItem?
    /// 退出前输出摘要，供 OpenSSHExitError.hint 做 auth/network 分类。
    private var recentOutput = ""
    /// ASKPASS 临时文件，finish 时清理（不在日志里打印密码）。
    private var askPassScriptPath: String?
    private var askPassSecretPath: String?

    public init() {}

    // MARK: - 连接

    public func connectAndOpenShell(_ creds: SSHCredentials, term: String, cols: Int, rows: Int) {
        self.creds = creds

        let args = Self.buildArguments(creds, term: term)
        Log.info("回落到系统 ssh：target=\(creds.username)@\(creds.host) argc=\(args.count)", "ssh")

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
        // 已有密码 → 受控 ASKPASS 注入（不写进参数、不打日志）。
        if let pw = creds.password, !pw.isEmpty, let ask = Self.installAskPass(password: pw) {
            askPassScriptPath = ask.script
            askPassSecretPath = ask.secret
            env.append("SSH_ASKPASS=\(ask.script)")
            env.append("SSH_ASKPASS_REQUIRE=force")
            // OpenSSH 只在认为「有 display」时才走 ASKPASS；给一个占位即可。
            env.append("DISPLAY=:")
            env.append("SSH_ASKPASS_PROMPT=none")
        }
        if let proxy = creds.proxy {
            env.append("\(ProxyStdioBridge.usernameEnv)=\(proxy.username)")
            env.append("\(ProxyStdioBridge.passwordEnv)=\(proxy.password)")
        }
        var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) }
        cEnv.append(nil)

        let child = forkpty(&master, nil, nil, &win)
        if child == -1 {
            for p in cArgs where p != nil { free(p) }
            for p in cEnv where p != nil { free(p) }
            cleanupAskPass()
            finish(NSError(domain: "PixShell.openssh", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "无法分配伪终端"]))
            return
        }
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
        // 注意：这里**不**回调 didOpenShell。fork 成功 ≠ 认证成功。
        // 等读到认证后的真实输出，或 exit≠0 时带错误码关闭。
        watchExit()
    }

    /// FIDO2 硬件安全密钥检测（sk-* 密钥）：私钥 openssh-key-v1 的 public 段未加密，
    /// base64 解码后含 `sk-ssh-ed25519@openssh.com` / `sk-ecdsa-sha2-nistp256@openssh.com`
    /// 类型字符串；同名 .pub 是明文（第一段即类型），优先检查。
    static func isFIDO2Key(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let expanded = (path as NSString).expandingTildeInPath
        let skTypes = ["sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com"]
        if let pubText = try? String(contentsOfFile: expanded + ".pub", encoding: .utf8) {
            for t in skTypes where pubText.hasPrefix(t) { return true }
        }
        guard let data = FileManager.default.contents(atPath: expanded),
              let text = String(data: data, encoding: .utf8) else { return false }
        let b64 = text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        guard let decoded = Data(base64Encoded: b64) else { return false }
        let s = String(decoding: decoded, as: UTF8.self)
        return skTypes.contains(where: s.contains)
    }

    /// 组装 ssh 参数。只放"让它在 App 里行为可预期"的选项，不去替用户决定安全策略。
    private static func buildArguments(_ c: SSHCredentials, term: String) -> [String] {
        var a: [String] = []
        a += ["-tt"]                                        // 强制分配 tty（我们本来就跑在 pty 里）
        a += baseSSHOptions(c, batchIfKeyOnly: true)
        a += ["\(c.username)@\(c.host)"]
        return a
    }

    /// 非交互回落（SFTP / exec）共用的基础 ssh 选项：端口、兼容算法、认证、代理。
    /// 不含目标 `user@host`、也不含 `-tt`（SFTP 二进制通道绝不能分配 tty）。
    static func baseSSHOptions(_ c: SSHCredentials, batchIfKeyOnly: Bool) -> [String] {
        var a: [String] = []
        a += ["-p", String(c.port)]
        a += ["-o", "StrictHostKeyChecking=accept-new"]
        a += ["-o", "NumberOfPasswordPrompts=1"]
        // 限制 DNS / 代理 CONNECT / SSH 握手的初始等待时间，避免代理不可用时
        // “打开会话…”覆盖层永久停留。ProxyStdioBridge 自身也有独立握手超时。
        a += ["-o", "ConnectTimeout=15"]
        a += ["-o", "ServerAliveInterval=30"]
        a += compatibilityOptions()

        if let kp = c.keyPath, !kp.isEmpty {
            a += ["-i", (kp as NSString).expandingTildeInPath]
            a += ["-o", "IdentitiesOnly=yes"]
            // FIDO2 硬件安全密钥（sk-*）：系统 OpenSSH 需要 SecurityKeyProvider
            // 才弹出 Touch ID / 安全密钥触摸提示（macOS 12.3+，默认未启用）。
            if isFIDO2Key(kp) {
                a += ["-o", "SecurityKeyProvider=Security.framework"]
            }
            if c.password == nil || c.password?.isEmpty == true {
                a += ["-o", "PreferredAuthentications=publickey"]
                if batchIfKeyOnly {
                    a += ["-o", "BatchMode=yes"]
                }
            }
        } else if let pw = c.password, !pw.isEmpty {
            // 纯密码：禁止再扫 ~/.ssh / agent。Dropbear/OpenWrt 对无用 publickey 尝试很敏感。
            a += ["-o", "PreferredAuthentications=password,keyboard-interactive"]
            a += ["-o", "PubkeyAuthentication=no"]
            a += ["-o", "IdentitiesOnly=yes"]
            a += ["-o", "IdentityAgent=none"]
        }
        if let p = c.proxy {
            switch p.type {
            case .socks5, .socks4:
                a += ["-o", "ProxyCommand=\(proxyBridgeCommand(p))"]
            case .http:
                a += ["-o", "ProxyCommand=\(proxyBridgeCommand(p))"]
            case .sshJump:
                a += ["-J", "\(p.username.isEmpty ? "" : p.username + "@")\(p.host):\(p.port)"]
            }
        }
        return a
    }

    /// 使用应用自身作为 OpenSSH 的 ProxyCommand；代理密码只走环境变量，
    /// 不进入命令行、日志或系统进程列表。
    private static func proxyBridgeCommand(_ proxy: ProxyConfig) -> String {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return [executable, ProxyStdioBridge.flag, proxy.type.rawValue, proxy.host,
                String(proxy.port), "%h", "%p"]
            .map(shellQuote)
            .joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func applyProxyEnvironment(_ credentials: SSHCredentials, to environment: inout [String: String]) {
        guard let proxy = credentials.proxy else { return }
        environment[ProxyStdioBridge.usernameEnv] = proxy.username
        environment[ProxyStdioBridge.passwordEnv] = proxy.password
    }

    /// 回落路径的最大算法兼容参数（交互 shell / 监控 exec / SFTP 共用）。
    static func compatibilityOptions() -> [String] {
        // 最大算法兼容：新算法优先，同时显式放开老 Dropbear / OpenWrt / CentOS7 / 网络设备常用的旧套件。
        // 用绝对列表而不是仅 `+`，避免本机 ssh_config 把旧算法整类关掉后回落仍握不上手。
        var keyAlgorithms = [
            "ssh-ed25519",
            "ecdsa-sha2-nistp256",
            "ecdsa-sha2-nistp384",
            "ecdsa-sha2-nistp521",
            "rsa-sha2-512",
            "rsa-sha2-256",
            "ssh-rsa",
            // FIDO2 硬件安全密钥（sk-*）：绝对列表必须显式加入，否则被
            // PubkeyAcceptedAlgorithms 拒绝 → 安全密钥认证直接失败。
            "sk-ssh-ed25519@openssh.com",
            "sk-ecdsa-sha2-nistp256@openssh.com",
        ]
        // macOS 26 的 /usr/bin/ssh 已从二进制中完全移除 ssh-dss；把不受支持的算法
        // 放进绝对列表会让整条选项报 "Bad key types" 并在认证前退出。不要按系统版本
        // 猜测：直接查询当前 OpenSSH，旧系统仍支持时继续保留对老设备的兼容性。
        if systemSSHKeyAlgorithms.contains("ssh-dss") {
            keyAlgorithms.append("ssh-dss")
        }
        let keyList = keyAlgorithms.joined(separator: ",")
        return [
            // blowfish-cbc/cast128-cbc 已从现代 OpenSSH 编译列表移除；写进绝对列表会让整条 Ciphers 失效。
            "-o", "Ciphers=chacha20-poly1305@openssh.com,aes128-ctr,aes192-ctr,aes256-ctr,aes128-gcm@openssh.com,aes256-gcm@openssh.com,3des-cbc,aes128-cbc,aes192-cbc,aes256-cbc",
            "-o", "KexAlgorithms=sntrup761x25519-sha512@openssh.com,sntrup761x25519-sha512,curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group-exchange-sha256,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512,diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1,diffie-hellman-group1-sha1",
            "-o", "HostKeyAlgorithms=\(keyList)",
            "-o", "PubkeyAcceptedAlgorithms=\(keyList)",
            // 老 OpenSSH 仍认 PubkeyAcceptedKeyTypes；与上面并列无害。
            "-o", "PubkeyAcceptedKeyTypes=\(keyList)",
            "-o", "MACs=hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha2-256,hmac-sha2-512,hmac-sha1",
        ]
    }

    /// 当前系统 OpenSSH 实际编译进二进制的 key 算法。只查询一次，避免按 macOS
    /// 版本硬编码，也让未来系统或用户替换的 ssh 实现自动采用正确能力集合。
    private static let systemSSHKeyAlgorithms: Set<String> = {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-Q", "key"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return Set(text.split(whereSeparator: \.isNewline).map(String.init))
        } catch {
            Log.warn("无法查询系统 OpenSSH 支持的 key 算法：\(error.localizedDescription)", "ssh")
            return []
        }
    }()

    /// 写一次性 ASKPASS 脚本 + 0600 密文文件。返回路径；失败返回 nil（退回终端交互）。
    ///
    /// 注意：OpenSSH 要求 `SSH_ASKPASS` 指向**可执行**文件；仅靠 `setAttributes` 在部分
    /// 临时目录/拷贝场景下会丢 +x，这里用 `chmod` 再强制一次，并校验 `access(X_OK)`。
    static func installAskPass(password: String) -> (script: String, secret: String)? {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pixshell-askpass-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            // 目录本身也要可进（0755）；secret 仅 owner 读。
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.path)
            let secret = base.appendingPathComponent("secret")
            let script = base.appendingPathComponent("askpass.sh")
            try password.data(using: .utf8)?.write(to: secret, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
            _ = chmod(secret.path, 0o600)
            // 脚本只 cat 密文文件；不把密码写进脚本正文。用 /bin/cat 绝对路径，避免 PATH 空。
            let sh = "#!/bin/sh\nexec /bin/cat '\(secret.path)'\n"
            try sh.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            _ = chmod(script.path, 0o700)
            guard access(script.path, X_OK) == 0 else {
                Log.warn("ASKPASS 脚本不可执行：\(script.path)", "ssh")
                try? FileManager.default.removeItem(at: base)
                return nil
            }
            return (script.path, secret.path)
        } catch {
            Log.warn("ASKPASS 准备失败：\(error.localizedDescription)", "ssh")
            return nil
        }
    }

    private func cleanupAskPass() {
        if let s = askPassSecretPath { try? FileManager.default.removeItem(atPath: s) }
        if let s = askPassScriptPath {
            let dir = (s as NSString).deletingLastPathComponent
            try? FileManager.default.removeItem(atPath: s)
            try? FileManager.default.removeItem(atPath: dir)
        }
        askPassSecretPath = nil
        askPassScriptPath = nil
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
                self.considerOpen(afterReceiving: chunk)
                DispatchQueue.main.async { self.delegate?.sshSession(self, didReceive: chunk) }
            } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                if n < 0 { Log.warn("系统 ssh 读取结束 errno=\(errno)", "ssh") }
                // 读侧 EOF：真正的结果以 waitpid 的 exit code 为准，这里不抢先 finish(nil)。
                // 若进程已退，watchExit 会收口；若还在，继续等。
            }
        }
        src.resume()
        readSource = src
    }

    /// 根据输出判断是否已越过认证、可以宣称 shell 打开。
    private func considerOpen(afterReceiving chunk: [UInt8]) {
        if let raw = String(bytes: chunk, encoding: .utf8), !raw.isEmpty {
            recentOutput += raw
            if recentOutput.count > 4000 {
                recentOutput = String(recentOutput.suffix(2000))
            }
        }
        guard !shellOpenedEmitted, !closed else { return }
        let text = String(bytes: chunk, encoding: .utf8)?.lowercased() ?? ""

        // 自动探测系统 ssh / Dropbear 的密码提示框，自动将已有的密码投递进 pty 通道
        if text.contains("password:") || text.contains("'s password") || text.contains("passphrase") {
            sawAuthPrompt = true
            if let pw = creds?.password, !pw.isEmpty {
                Log.info("在 pty 捕获到密码提示符，自动投递密码至 OpenSSH 伪终端", "ssh")
                let passData = Array((pw + "\n").utf8)
                send(passData)
                pendingOpenWorkItem?.cancel()
                pendingOpenWorkItem = nil
                return
            }
        }

        // 明确失败输出：等 watchExit 带错误码，绝不假 open。
        if text.contains("permission denied")
            || text.contains("authentication failed")
            || text.contains("auth failed")
            || text.contains("connection refused")
            || text.contains("could not resolve")
            || text.contains("no route to host")
            || text.contains("operation timed out")
            || text.contains("connection timed out")
            || text.contains("host key verification failed") {
            pendingOpenWorkItem?.cancel()
            pendingOpenWorkItem = nil
            return
        }
        // 其余输出（MOTD / 提示符 / 远端数据）→ 短防抖后确认 open。
        // 刚答完密码时可能先有一小段噪声，防抖避免抢跑。
        pendingOpenWorkItem?.cancel()
        let delay: TimeInterval = sawAuthPrompt ? 0.35 : 0.12
        let work = DispatchWorkItem { [weak self] in
            self?.emitOpenIfNeeded()
        }
        pendingOpenWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func emitOpenIfNeeded() {
        guard !shellOpenedEmitted, !closed else { return }
        shellOpenedEmitted = true
        pendingOpenWorkItem = nil
        Log.info("系统 ssh shell 已确认打开", "ssh")
        delegate?.sshSessionDidOpenShell(self)
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
    /// 含命令级总超时（execTimeout）：远端命令不退出时 terminate 兜底收口，
    /// 避免 readDataToEndOfFile 无限阻塞 → HTTP 永不返回 → 后续工具调用排队超时（P0 根因）。
    public func exec(_ command: String, completion: @escaping (String) -> Void) {
        guard let c = creds else { DispatchQueue.main.async { completion("") }; return }
        DispatchQueue.global(qos: .utility).async {
            // 与交互/SFTP 回落同一套算法+认证参数；有密码时用 ASKPASS（不再死守 BatchMode 空返回）。
            var args = Self.baseSSHOptions(c, batchIfKeyOnly: true)
            args += ["-o", "ConnectTimeout=10", "-T"]
            args += ["\(c.username)@\(c.host)", command]

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            var env = ProcessInfo.processInfo.environment
            var secretPath: String?
            var scriptPath: String?
            if let pw = c.password, !pw.isEmpty, let ask = Self.installAskPass(password: pw) {
                secretPath = ask.secret
                scriptPath = ask.script
                env["SSH_ASKPASS"] = ask.script
                env["SSH_ASKPASS_REQUIRE"] = "force"
                env["DISPLAY"] = ":"
                env["SSH_ASKPASS_PROMPT"] = "none"
            }
            Self.applyProxyEnvironment(c, to: &env)
            p.environment = env

            // 命令级总超时：到期 terminate + 收口。不用 readDataToEndOfFile（会无限阻塞），
            // 改为 DispatchSource 异步读，超时由 timer 触发。
            let timeout = Self.execTimeout
            let outFH = pipe.fileHandleForReading
            var text = ""
            let bufferLock = NSLock()
            var didFinish = false
            // 子进程被 timer 或正常退出后，收集剩余数据并收口（只收一次）。
            func collectAndFinish() {
                guard !didFinish else { return }
                didFinish = true
                // 读尽剩余数据（进程已退出/被 terminate，读不会无限阻塞）。
                let rest = outFH.readDataToEndOfFile()
                if let s = String(data: rest, encoding: .utf8) { bufferLock.lock(); text += s; bufferLock.unlock() }
                if let s = secretPath { try? FileManager.default.removeItem(atPath: s) }
                if let s = scriptPath {
                    let dir = (s as NSString).deletingLastPathComponent
                    try? FileManager.default.removeItem(atPath: s)
                    try? FileManager.default.removeItem(atPath: dir)
                }
                DispatchQueue.main.async { completion(text) }
            }

            do {
                try p.run()
            } catch {
                collectAndFinish()
                return
            }
            // 异步读 stdout（不阻塞调用线程）。
            outFH.readabilityHandler = { fh in
                let d = fh.availableData
                if !d.isEmpty, let s = String(data: d, encoding: .utf8) {
                    bufferLock.lock(); text += s; bufferLock.unlock()
                } else if d.isEmpty {
                    fh.readabilityHandler = nil
                    DispatchQueue.global(qos: .utility).async { collectAndFinish() }
                }
            }
            // 超时兜底：到期 kill 子进程 → readabilityHandler 收尾 → collectAndFinish。
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak p] in
                if p?.isRunning == true {
                    Log.warn("exec 命令超时（\(Int(timeout))s）被强制终止：\(command.prefix(80))", "ssh")
                    p?.terminate()
                    // terminate 发 SIGTERM；个别命令不退，SIGKILL 兜底。
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                        if let pid = p?.processIdentifier, p?.isRunning == true {
                            kill(pid, SIGKILL)
                        }
                    }
                }
            }
            // 正常退出兜底：进程退出后补一次收口（readabilityHandler 若因无更多数据未触发）。
            DispatchQueue.global(qos: .utility).async {
                p.waitUntilExit()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { collectAndFinish() }
            }
        }
    }

    public func close() {
        guard !closed else { return }
        if pid > 0 { kill(pid, SIGHUP) }
        // 用户主动关：error=nil，上层不得当认证失败清钥匙串。
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
            Log.info("系统 ssh 退出 pid=\(p) code=\(code) opened=\(self?.shellOpenedEmitted ?? false)", "ssh")
            let hint = self?.recentOutput ?? ""
            let sawPasswordPrompt = self?.sawAuthPrompt ?? false
            let lowerHint = hint.lowercased()
            let explicitAuth = lowerHint.contains("permission denied")
                || lowerHint.contains("authentication failed")
                || lowerHint.contains("auth failed")
            let networkHint = lowerHint.contains("connection refused")
                || lowerHint.contains("connection reset")
                || lowerHint.contains("timed out")
                || lowerHint.contains("timeout")
                || lowerHint.contains("no route")
                || lowerHint.contains("could not resolve")
                || lowerHint.contains("network is unreachable")
                || lowerHint.contains("host is down")
                || lowerHint.contains("network is down")
                || lowerHint.contains("host unreachable")
                || lowerHint.contains("host key verification failed")
            // 认证提示出现过但从未打开 shell：优先视为认证拒绝；仍被网络关键词命中时交给上层 network 分类。
            let authRejected = explicitAuth || (sawPasswordPrompt && !networkHint)
            if code == 0 {
                self?.finish(nil)
            } else if self?.shellOpenedEmitted == true {
                // 曾经真的连上过再退：当正常/带码关闭，不再伪装成「认证阶段失败」。
                self?.finish(OpenSSHExitError(code: Int(code), hint: hint))
            } else {
                // 从未确认 shell → 必须带错误，禁止 finish(nil) 让上层以为「干净断开」。
                self?.finish(OpenSSHExitError(code: Int(code), hint: hint, authRejected: authRejected))
            }
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        pendingOpenWorkItem?.cancel()
        pendingOpenWorkItem = nil
        readSource?.cancel(); readSource = nil
        if masterFD >= 0 { Darwin.close(masterFD); masterFD = -1 }
        pid = -1
        cleanupAskPass()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.sshSession(self, didCloseWith: error)
        }
    }
}
