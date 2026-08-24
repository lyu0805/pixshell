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

    /// 事件回调投递线程开关：true（默认，UI 会话）走主线程供 SwiftTerm 直接用；
    /// false（无头/桥会话）直接在 IO 线程回调，让 `connected` 翻转与后台 poll 脱离主线程/
    /// GUI 卡顿。桥的 delegate（HeadlessSession）内部自带锁，IO 线程回调安全。
    public var deliversOnMainThread: Bool = true

    /// 回调/防抖投递队列：UI 会话用主线程（供 SwiftTerm/AppKit 直接用）；无头/桥会话用专用
    /// 串行队列，让 open 防抖与 didReceive/didOpen/didClose 回调彻底脱离主线程 —— 否则 GUI
    /// 卡顿会拖住 `pendingOpenWorkItem`（原调度到 main queue），`connected` 翻转随之延迟，
    /// 表现为「重连无响应」。每次按当前开关返回，不用 lazy 以免依赖 delegate/开关的设置时序。
    private let ioCallbackQueue = DispatchQueue(label: "pixshell.openssh.callback")
    private var callbackQueue: DispatchQueue { deliversOnMainThread ? .main : ioCallbackQueue }

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

    /// 这些字段被四类线程并发触碰：读泵（global userInitiated）、watchExit（global
    /// utility）、close()/send()/resize()（任意调用线程）、callbackQueue（emitOpen）。
    /// 无锁时 `finish` 可双重进入 → 同一 fd 被 close 两次（fd 号被新连接复用时会拆错连接），
    /// 密码也可能在 fd 关闭与写回之间写进无关 fd。所有访问走短临界区；send/resize 在
    /// 锁内只取 fd 快照、write/ioctl/kill 留在锁外（阻塞操作持锁会拖死 finish）。
    private let stateLock = NSLock()

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
        a += ["-o", "ServerAliveInterval=30"]
        // 连接多路复用：同一条 user@host:port 只在**首个**进程做完整认证，之后 10 分钟内
        // 所有 exec/SFTP/SCP/监控进程全部复用这条已认证连接（零重新认证）。防的是
        // 「每条命令一个新 ssh 进程 + 每进程一次密码验证」被 fail2ban/防火墙当爆破封禁。
        // ControlPersist 让 master 在最后一个客户端退出后仍存活 10 分钟，空闲自动收尾。
        //
        // **路径长度铁律**：OpenSSH 对 ControlPath 的 unix socket 有 `sun_path` 104 字节
        // 硬上限。macOS 临时目录是 /var/folders/<xx>/<32hex>/T/（约 49 字节），加前缀目录、
        // 加 `%C`(user+host+port 完整 SHA 哈希) 展开后**必超 104**——日志实锤：
        // `ControlPath too long ('.../cm-392593213a4f...' >= 104 bytes)`，整条命令 exit 255、
        // SFTP/exec 静默失败（今天事故直接根因）。因此这里：
        //  1) 用 `%h-%p`(host:port,~30 字符) 代替 `%C`(完整哈希,~40 字符) 缩短；
        //  2) 完整拼接后仍超上限 → **放弃 ControlMaster 复用**（退回每次独立认证，
        //     仅极少数超长 host 路径才发生，避免整条命令因超限而 255。
        // socket 文件名里的 host 成分必须净化：host 可能是 IPv6（含冒号、% 符号）、
        // 或含 / 等路径分隔符——直接拼进 ControlPath 会破坏 socket 路径。统一替换成安全字符。
        let hostPart = c.host
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "%", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let base = "\(controlSocketDir)/cm-\(hostPart)-\(c.port)"
        if base.utf8.count <= 90 {
            // 留 14 字节余量：`%h-%p` 已展开，但加上前缀/目录分隔符仍可能略涨。
            a += ["-o", "ControlMaster=auto"]
            a += ["-o", "ControlPath=\(base)"]
            a += ["-o", "ControlPersist=10m"]
        } else {
            Log.warn("ControlPath 超长（\(base.utf8.count) 字节），已放弃 ControlMaster 复用：\(c.host)", "ssh")
        }
        a += compatibilityOptions()

        if let kp = c.keyPath, !kp.isEmpty {
            let expandedKey = (kp as NSString).expandingTildeInPath
            tightenKeyPermissions(expandedKey)
            a += ["-i", expandedKey]
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
                a += ["-o", "ProxyCommand=/usr/bin/nc -x \(p.host):\(p.port) -X \(p.type == .socks5 ? "5" : "4") %h %p"]
            case .http:
                a += ["-o", "ProxyCommand=/usr/bin/nc -x \(p.host):\(p.port) -X connect %h %p"]
            case .sshJump:
                a += ["-J", "\(p.username.isEmpty ? "" : p.username + "@")\(p.host):\(p.port)"]
            }
        }
        return a
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

    /// 私钥权限收紧到 0600：权限过宽时系统 ssh 直接拒用（"Permissions ... are too open"），
    /// 表现为这台主机的回落路径全体静默失败——SFTP 连不上、exec 全空、右键下载"不生效"
    /// （真实案例：日志里 sftp-server 五种启动方式全败于 too open）。只收紧、绝不放宽。
    static func tightenKeyPermissions(_ path: String) {
        var st = stat()
        guard stat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return }
        if st.st_mode & 0o077 != 0 {
            chmod(path, 0o600)
            Log.warn("私钥权限过宽，已收紧为 0600：\(path)", "ssh")
        }
    }

    /// ControlMaster 复用 socket 的目录（懒创建，0700）。
    /// 必须放在**无空格**路径：ssh 的 -o ControlPath 值按配置行解析，含空格会报
    /// "extra arguments at end of line" 直接拒启（Application Support 就踩这个坑）。
    /// 临时目录随系统清理无妨——master 本来就只活 ControlPersist 的 10 分钟。
    static let controlSocketDir: String = {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pixshell-cm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        chmod(dir.path, 0o700)
        return dir.path
    }()

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
            guard let self = self else { return }
            self.stateLock.lock()
            let fd = self.masterFD
            self.stateLock.unlock()
            guard fd >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                let chunk = Array(buf[0..<n])
                self.considerOpen(afterReceiving: chunk)
                self.callbackQueue.async { self.delegate?.sshSession(self, didReceive: chunk) }
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
    /// 只在读泵线程串行进入，但读写的 `recentOutput/shellOpenedEmitted/...` 与
    /// watchExit/finish/emitOpen 并发，状态访问全部锁内；密码投递在锁外 send。
    private func considerOpen(afterReceiving chunk: [UInt8]) {
        var deliverPassword: [UInt8]?
        var openWork: DispatchWorkItem?
        var openDelay: TimeInterval = 0.12
        stateLock.lock()
        if let raw = String(bytes: chunk, encoding: .utf8), !raw.isEmpty {
            recentOutput += raw
            if recentOutput.count > 4000 {
                recentOutput = String(recentOutput.suffix(2000))
            }
        }
        if !shellOpenedEmitted && !closed {
            let text = String(bytes: chunk, encoding: .utf8)?.lowercased() ?? ""
            if text.contains("password:") || text.contains("'s password") || text.contains("passphrase") {
                sawAuthPrompt = true
                if let pw = creds?.password, !pw.isEmpty {
                    // 已有密码：自动投递，本轮不调度 open 确认（等答完后的真实输出）。
                    deliverPassword = Array((pw + "\n").utf8)
                    pendingOpenWorkItem?.cancel()
                    pendingOpenWorkItem = nil
                } else {
                    // 没存密码：GUI 里提示留给用户在终端交互作答，继续走 open 防抖；
                    // 无头桥里无人应答——不 emitOpen，让 ensureConnected 的 poll 如实
                    // 超时失败（否则假 ready 后 agent 会把命令喂给口令提示）。
                    if deliversOnMainThread {
                        scheduleOpenConfirm(delay: sawAuthPrompt ? 0.35 : 0.12)
                    }
                }
            } else if text.contains("permission denied")
                || text.contains("authentication failed")
                || text.contains("auth failed")
                || text.contains("connection refused")
                || text.contains("could not resolve")
                || text.contains("no route to host")
                || text.contains("operation timed out")
                || text.contains("connection timed out")
                || text.contains("host key verification failed") {
                // 明确失败输出：等 watchExit 带错误码，绝不假 open。
                pendingOpenWorkItem?.cancel()
                pendingOpenWorkItem = nil
            } else {
                // 其余输出（MOTD / 提示符 / 远端数据）→ 短防抖后确认 open。
                // 刚答完密码时可能先有一小段噪声，防抖避免抢跑。
                scheduleOpenConfirm(delay: sawAuthPrompt ? 0.35 : 0.12)
            }
            openWork = pendingOpenWorkItem
            if openWork != nil { openDelay = pendingOpenDelay }
        }
        stateLock.unlock()
        if let deliverPassword {
            Log.info("在 pty 捕获到密码提示符，自动投递密码至 OpenSSH 伪终端", "ssh")
            send(deliverPassword)
        }
        if let openWork {
            callbackQueue.asyncAfter(deadline: .now() + openDelay, execute: openWork)
        }
    }

    /// 锁内调用：安排一次「防抖后确认 open」。延迟存入 `pendingOpenDelay` 供锁外调度。
    private func scheduleOpenConfirm(delay: TimeInterval) {
        pendingOpenWorkItem?.cancel()
        pendingOpenDelay = delay
        pendingOpenWorkItem = DispatchWorkItem { [weak self] in
            self?.emitOpenIfNeeded()
        }
    }
    private var pendingOpenDelay: TimeInterval = 0.12

    private func emitOpenIfNeeded() {
        stateLock.lock()
        guard !shellOpenedEmitted, !closed else { stateLock.unlock(); return }
        shellOpenedEmitted = true
        pendingOpenWorkItem = nil
        stateLock.unlock()
        Log.info("系统 ssh shell 已确认打开", "ssh")
        delegate?.sshSessionDidOpenShell(self)
    }

    public func send(_ data: [UInt8]) {
        stateLock.lock()
        let fd = masterFD
        stateLock.unlock()
        guard fd >= 0, !data.isEmpty else { return }
        var d = data
        _ = write(fd, &d, d.count)
    }

    public func resize(cols: Int, rows: Int) {
        stateLock.lock()
        let fd = masterFD
        let p = pid
        stateLock.unlock()
        guard fd >= 0 else { return }
        var w = winsize(ws_row: UInt16(max(rows, 1)), ws_col: UInt16(max(cols, 1)), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, TIOCSWINSZ, &w)
        if p > 0 { kill(p, SIGWINCH) }
    }

    /// 一次性命令（监控采集用）：另起一个非交互 ssh 进程收 stdout。
    /// 走 BatchMode，绝不弹交互提示 —— 后台采集不该阻塞在提问上。
    /// 含命令级总超时（execTimeout）：远端命令不退出时 terminate 兜底收口，
    /// 避免 readDataToEndOfFile 无限阻塞 → HTTP 永不返回 → 后续工具调用排队超时（P0 根因）。
    public func exec(_ command: String, completion: @escaping (String) -> Void) {
        exec(command, timeout: Self.execTimeout, maxBytes: 0) { out, _ in completion(out) }
    }

    public func exec(_ command: String, timeout: TimeInterval, maxBytes: Int,
                     completion: @escaping (String, Bool) -> Void) {
        guard let c = creds else { callbackQueue.async { completion("", false) }; return }
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
            p.environment = env

            // 命令级总超时：到期 terminate + 收口。不用 readDataToEndOfFile（会无限阻塞），
            // 改为 DispatchSource 异步读，超时由 timer 触发。
            let outFH = pipe.fileHandleForReading
            var text = ""
            let bufferLock = NSLock()
            var didFinish = false
            var timedOutFlag = false
            // 子进程被 timer 或正常退出后，收集剩余数据并收口（只收一次）。
            // 完成门在 bufferLock 内 check-then-set：EOF / 输出上限 / waitUntilExit 三条
            // 收口路径跑在不同 GCD 线程、可能并发到达，裸 bool 的 guard 挡不住双进入 →
            // completion 双回调 → 桥侧 next() 多弹破坏 4 并发记账。
            func collectAndFinish(timedOut: Bool = false) {
                bufferLock.lock()
                guard !didFinish else { bufferLock.unlock(); return }
                didFinish = true
                // 用 OR 合并：超时兜底线程已置 true 后，EOF/退出兜底以默认 false 进来
                // 不能把它盖回去（否则强杀的命令会被上报成正常完成）。
                timedOutFlag = timedOutFlag || timedOut
                bufferLock.unlock()
                // 读尽剩余数据（进程已退出/被 terminate，读不会无限阻塞）。
                let rest = outFH.readDataToEndOfFile()
                if let s = String(data: rest, encoding: .utf8) { bufferLock.lock(); text += s; bufferLock.unlock() }
                if let s = secretPath { try? FileManager.default.removeItem(atPath: s) }
                if let s = scriptPath {
                    let dir = (s as NSString).deletingLastPathComponent
                    try? FileManager.default.removeItem(atPath: s)
                    try? FileManager.default.removeItem(atPath: dir)
                }
                // completion 需要的快照在锁内取：readabilityHandler 末次 append 可能仍在进行。
                bufferLock.lock()
                let outSnapshot = text
                let timedSnapshot = timedOutFlag
                bufferLock.unlock()
                self.callbackQueue.async { completion(outSnapshot, timedSnapshot) }
            }

            do {
                try p.run()
            } catch {
                collectAndFinish()
                return
            }
            // 异步读 stdout（不阻塞调用线程）+ 输出上限（防大输出 OOM）。
            outFH.readabilityHandler = { fh in
                let d = fh.availableData
                if !d.isEmpty, let s = String(data: d, encoding: .utf8) {
                    bufferLock.lock(); text += s
                    let capped = maxBytes > 0 && text.count >= maxBytes
                    bufferLock.unlock()
                    if capped {
                        fh.readabilityHandler = nil
                        p.terminate()  // 到输出上限：杀掉子进程收口
                        DispatchQueue.global(qos: .utility).async { collectAndFinish() }
                    }
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
                    // 标记超时（即使收口时子进程已退出，也如实上报）。
                    bufferLock.lock(); timedOutFlag = true; bufferLock.unlock()
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
        stateLock.lock()
        let p = pid
        stateLock.unlock()
        if p > 0 { kill(p, SIGHUP) }
        // 用户主动关：error=nil，上层不得当认证失败清钥匙串。
        finish(nil)
    }

    /// watchExit 分类用的只读快照（锁内取，避免与读泵/finish 撕裂读）。
    private func exitHintSnapshot() -> (hint: String, opened: Bool, sawPrompt: Bool) {
        stateLock.lock(); defer { stateLock.unlock() }
        return (recentOutput, shellOpenedEmitted, sawAuthPrompt)
    }

    // MARK: - 收尾

    private func watchExit() {
        stateLock.lock()
        let p = pid
        stateLock.unlock()
        guard p > 0 else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            waitpid(p, &status, 0)
            // 退出码是排查"连不上但没报错"的关键线索：255=ssh 自身失败，1=远端命令失败
            let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f)
            let snap = self?.exitHintSnapshot() ?? (hint: "", opened: false, sawPrompt: false)
            Log.info("系统 ssh 退出 pid=\(p) code=\(code) opened=\(snap.opened)", "ssh")
            let hint = snap.hint
            let sawPasswordPrompt = snap.sawPrompt
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
            } else if snap.opened {
                // 曾经真的连上过再退：当正常/带码关闭，不再伪装成「认证阶段失败」。
                self?.finish(OpenSSHExitError(code: Int(code), hint: hint))
            } else {
                // 从未确认 shell → 必须带错误，禁止 finish(nil) 让上层以为「干净断开」。
                self?.finish(OpenSSHExitError(code: Int(code), hint: hint, authRejected: authRejected))
            }
        }
    }

    private func finish(_ error: Error?) {
        // closed 的 check-then-set 在锁内：close()（任意线程）与 watchExit（utility 队列）
        // 同时到达时只有一方能进入，杜绝同一 masterFD 被 Darwin.close 两次（fd 号被
        // 新连接复用时会拆错连接）和 delegate.didCloseWith 双投递。
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        let fd = masterFD
        masterFD = -1
        let work = pendingOpenWorkItem
        pendingOpenWorkItem = nil
        let src = readSource
        readSource = nil
        pid = -1
        stateLock.unlock()
        work?.cancel()
        src?.cancel()
        if fd >= 0 { Darwin.close(fd) }
        cleanupAskPass()
        callbackQueue.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.sshSession(self, didCloseWith: error)
        }
    }
}
