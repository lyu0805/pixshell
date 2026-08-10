import Foundation

/// 无头模式（--headless）的桥宿主：**自己建 SSH/SFTP 会话**，不依赖任何 UI。
///
/// 与有头版（AppDelegate 实现 BridgeHost）的区别：有头复用已打开 Tab 的 TermSession，
/// 无头进程没有窗口，这里直接用零 UI 的 `SSHSession` / `SFTPService` 层
/// （NIOSSHSession / OpenSSHSession / NIOSFTPSession / OpenSSHSFTPSession 均无 UI 依赖，
/// 见 SSH/SSHSession.swift、SFTP/SFTPService.swift），每条会话自管一个输出缓冲，
/// 供 exec / screen 读。凭据路径与有头一致：HostStore.hosts + Keychain.password(for:)。
///
/// 会话生命周期随本进程：CLI 通过 /v1/app/connect 建会话 → exec/screen/sftp 操作 →
/// 进程退出（有头接管发 /v1/app/shutdown 或自然退出）时 close 全部。
final class HeadlessBridgeHost: BridgeHost {

    /// 无头会话：逻辑 SSH 会话 + 自管输出缓冲 + 凭据快照。
    /// 非 private：文件底部 extension 里当自己的 SSHSessionDelegate。
    final class HeadlessSession {
        let title: String
        let host: Host
        /// 内部 SSH 会话：断开后可原地重建（自动重连），下标永不变。
        private(set) var ssh: SSHSession
        let password: String
        /// 正在自动重连（防并发 exec/type 各拉一条连接）。
        var reconnecting = false
        /// 交互 shell 的最近输出（exec 是独立通道不进这里；screen 读它）。
        private var output = ""
        private let lock = NSLock()
        private var connectedState = false

        var connected: Bool {
            get { lock.lock(); defer { lock.unlock() }; return connectedState }
            set { lock.lock(); defer { lock.unlock() }; connectedState = newValue }
        }

        init(title: String, host: Host, ssh: SSHSession, password: String) {
            self.title = title
            self.host = host
            self.ssh = ssh
            self.password = password
        }

        func appendOutput(_ text: String) {
            lock.lock(); defer { lock.unlock() }
            output += text
            // 防无限增长：只保留最近 512 KiB
            if output.count > 512 * 1024 {
                output = String(output.dropFirst(output.count - 512 * 1024))
            }
        }

        func recentOutput(lines: Int) -> String {
            lock.lock(); defer { lock.unlock() }
            let n = lines > 0 ? lines : 200
            let rows = output.split(separator: "\n", omittingEmptySubsequences: false)
            return rows.suffix(n).joined(separator: "\n")
        }

        /// 原地重连（自动）：换新 ssh、复用下标，等 shell 打开。
        /// - Parameters:
        ///   - onReady: 重连结果。成功 true；失败 false（网络真断，不再重试）。
        func reconnect(creds: SSHCredentials, keyNeedsOpenSSH: Bool,
                       onReady: @escaping (Bool) -> Void) {
            if connected { onReady(true); return }
            if reconnecting { onReady(false); return }   // 已有重连在跑，别重复拉
            reconnecting = true
            // 关掉旧的（异步，不阻塞），换新的
            let old = ssh
            connected = false
            let newSsh: SSHSession = keyNeedsOpenSSH ? OpenSSHSession() : NIOSSHSession()
            ssh = newSsh
            newSsh.delegate = self
            old.close()
            newSsh.connectAndOpenShell(creds, term: "xterm-256color", cols: 100, rows: 30)
            // 等 shell 打开，最多 20s（与 bridgeConnect 一致）
            var waited = 0.0
            func poll() {
                if connected {
                    reconnecting = false
                    onReady(true); return
                }
                waited += 0.25
                if waited > 20 {
                    reconnecting = false
                    newSsh.close()
                    onReady(false); return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
            }
            poll()
        }
    }

    private var sessions: [HeadlessSession] = []
    private var currentIndex: Int = -1
    /// 主线程互斥：桥请求在主线程路由，会话操作也在主线程完成。
    private let lock = NSLock()

    /// 无头进程退出回调：全部会话 close 后调用（App 退出）。由 AppDelegate 设置。
    var onShutdown: (() -> Void)?

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    // MARK: - BridgeHost

    func bridgeHosts() -> [[String: Any]] {
        HostStore().hosts.map { h in
            ["id": h.id, "name": h.display, "host": h.host,
             "port": h.port, "username": h.username, "group": h.group]
        }
    }

    func bridgeSessions() -> [[String: Any]] {
        withLock {
            sessions.enumerated().map { (i, s) in
                ["session": i, "title": s.title, "host": s.host.host,
                 "username": s.host.username, "connected": s.connected,
                 // active 必须是「当前会话且仍连接」——死会话不得再报 active，
                 // 否则 agent 拿到 active:true disconnected:false 的误导状态反复重连。
                 "active": i == currentIndex && s.connected]
            }
        }
    }

    func bridgeConnect(hostId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let h = HostStore().hosts.first(where: { $0.id == hostId }) else {
            completion(.failure(NSError(domain: "PixShell", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "未找到主机 \(hostId)"]))); return
        }
        guard !h.isRdp && !h.isLocal else {
            completion(.failure(NSError(domain: "PixShell", code: 400,
                userInfo: [NSLocalizedDescriptionKey: "RDP/本机终端不能经桥连接"]))); return
        }
        // 复用：同主机已有活跃会话 → 直接返回，不重复建连/不重认证（持久化交互关键）。
        if let idx = withLock({ sessions.firstIndex { $0.host.id == hostId && $0.connected } }) {
            withLock { currentIndex = idx }
            completion(.success(["session": idx, "title": sessions[idx].title])); return
        }
        // 同主机已有**死**会话 → 原地重连（复用下标，不新增堆积）。
        // 否则每次 connect 都 append 新会话，死会话永不清理 → 数组无限膨胀
        // （用户实测 26 个会话 25 个 disconnected，agent 拿到 stale 下标反复 410）。
        if let idx = withLock({ sessions.firstIndex { $0.host.id == hostId } }) {
            let s = sessions[idx]
            withLock { currentIndex = idx }
            reconnectIfNeeded(session: idx, s: s) { ok in
                if ok {
                    completion(.success(["session": idx, "title": s.title]))
                } else {
                    // 重连失败：**保留死会话**（标 connected=false），不删除。
                    // 网络抖动期（TCP 间歇超时）一次失败就把会话删掉，后续
                    // bridgeExec 对死会话的自动重连路径就永远触不到了（数组里
                    // 没有它），agent 只能反复 410/建新会话 → 恶性循环。
                    // 保留后，下一次 exec/connect 仍能走 reconnectIfNeeded 再试。
                    completion(.failure(NSError(domain: "PixShell", code: 504,
                        userInfo: [NSLocalizedDescriptionKey: "会话 \(idx) 重连失败（保留死会话待下次重试）"])))
                }
            }
            return
        }
        let pw = Keychain.password(for: h.id) ?? ""
        guard !pw.isEmpty || !h.keyPath.isEmpty else {
            completion(.failure(NSError(domain: "PixShell", code: 401,
                userInfo: [NSLocalizedDescriptionKey: "该主机没有保存的密码或私钥，请先在有头界面连接一次"]))); return
        }
        // 代理：主机配置 proxyId → ProxyStore 匹配（与 startSSH 一致）。
        let proxy = h.proxyId.isEmpty ? nil : ProxyStore().list().first { $0.id == h.proxyId }
        let creds = SSHCredentials(host: h.host, port: h.port, username: h.username,
                                   password: pw, keyPath: h.keyPath.isEmpty ? nil : h.keyPath,
                                   proxy: proxy)
        // NIO 无法加载 RSA/DSA/加密私钥 → 预检失败直接用系统 OpenSSH（与有头一致）。
        let keyNeedsOpenSSH = !h.keyPath.isEmpty && SSHPrivateKeyLoader.load(path: h.keyPath) == nil
        let sess = HeadlessSession(title: h.display, host: h, ssh: keyNeedsOpenSSH ? OpenSSHSession() : NIOSSHSession(), password: pw)
        withLock {
            sessions.append(sess)
            currentIndex = sessions.count - 1
        }
        let idx = sessions.count - 1
        sess.ssh.delegate = sess
        sess.ssh.connectAndOpenShell(creds, term: "xterm-256color", cols: 100, rows: 30)
        // 等 shell 打开再回（与有头 bridgeConnect 的 poll 语义一致，最多 20s）。
        var waited = 0.0
        func poll() {
            if sess.connected {
                completion(.success(["session": idx, "title": sess.title])); return
            }
            waited += 0.25
            if waited > 20 {
                sess.ssh.close()
                withLock { if sessions.indices.contains(idx) { sessions.remove(at: idx) } }
                completion(.failure(NSError(domain: "PixShell", code: 504,
                    userInfo: [NSLocalizedDescriptionKey: "连接超时"]))); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
        }
        poll()
    }

    func bridgeWrite(session: Int, text: String) -> Bool {
        withLock {
            guard sessions.indices.contains(session) else { return false }
            let s = sessions[session]
            // 死会话：先原地重连再发送（type_text 自愈，不再静默吞掉）。
            if !s.connected {
                reconnectIfNeeded(session: session, s: s) { _ in }
                return false   // 本次请求走重连，不误报成功；调用方重试即命中重连后的会话
            }
            s.ssh.send(Array(text.utf8))
            return true
        }
    }

    /// 死会话原地重连（复用下标，agent 的 session 号永不变）。重连成功回调 true。
    private func reconnectIfNeeded(session: Int, s: HeadlessSession, done: @escaping (Bool) -> Void) {
        let h = s.host
        let pw = s.password.isEmpty ? (Keychain.password(for: h.id) ?? "") : s.password
        guard !pw.isEmpty || !h.keyPath.isEmpty else {
            done(false); return
        }
        let proxy = h.proxyId.isEmpty ? nil : ProxyStore().list().first { $0.id == h.proxyId }
        let creds = SSHCredentials(host: h.host, port: h.port, username: h.username,
                                   password: pw, keyPath: h.keyPath.isEmpty ? nil : h.keyPath,
                                   proxy: proxy)
        let keyNeedsOpenSSH = !h.keyPath.isEmpty && SSHPrivateKeyLoader.load(path: h.keyPath) == nil
        s.reconnect(creds: creds, keyNeedsOpenSSH: keyNeedsOpenSSH, onReady: done)
    }

    func bridgeExec(session: Int, cmd: String, completion: @escaping (String) -> Void) {
        bridgeExec(session: session, cmd: cmd, timeout: 30, maxBytes: 0) { out, _ in completion(out) }
    }

    func bridgeExec(session: Int, cmd: String, timeout: Double, maxBytes: Int,
                    completion: @escaping (String, Bool) -> Void) {
        withLock {
            guard sessions.indices.contains(session) else { completion("", false); return }
            let s = sessions[session]
            guard s.connected else {
                // 死会话：自动重连后再执行（根治「exec 遇断线不生效」）。
                // 重连期间其他 exec/type 会因 reconnecting 去重，等这一条完成。
                reconnectIfNeeded(session: session, s: s) { ok in
                    if ok {
                        // 重连成功：再执行命令（重连是异步的，此时已在锁外，需显式 self）
                        guard let ss = self.withLock({ self.sessions.indices.contains(session) ? self.sessions[session] : nil }) else {
                            completion("", false); return
                        }
                        ss.ssh.exec(cmd, timeout: timeout, maxBytes: maxBytes) { out, timedOut in
                            completion(out, timedOut)
                        }
                    } else {
                        // 重连失败（网络真断）→ 明确报错，不静默空
                        completion("", false)
                    }
                }
                return
            }
            s.ssh.exec(cmd, timeout: timeout, maxBytes: maxBytes) { out, timedOut in
                completion(out, timedOut)
            }
        }
    }

    func bridgeScreen(session: Int, lines: Int) -> String {
        withLock {
            guard sessions.indices.contains(session) else { return "" }
            return sessions[session].recentOutput(lines: lines)
        }
    }

    // MARK: - SFTP（独立 SFTP 连接，复用 SFTPService 零 UI 层）

    private func sftp(for session: Int, completion: @escaping (Result<(SFTPService, String), Error>) -> Void) {
        withLock {
            guard sessions.indices.contains(session) else {
                completion(.failure(NSError(domain: "PixShell", code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "会话不存在"]))); return
            }
            let s = sessions[session]
            let proxy = s.host.proxyId.isEmpty ? nil : ProxyStore().find(s.host.proxyId)
            let creds = SSHCredentials(host: s.host.host, port: s.host.port, username: s.host.username,
                                       password: s.password, keyPath: s.host.keyPath.isEmpty ? nil : s.host.keyPath,
                                       proxy: proxy)
            let svc: SFTPService = s.host.keyPath.isEmpty ? NIOSFTPSession() : OpenSSHSFTPSession()
            svc.connect(creds) { r in
                switch r {
                case .failure(let e): completion(.failure(e))
                case .success: completion(.success((svc, s.password)))
                }
            }
        }
    }

    func bridgeSFTPList(session: Int, path: String, completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
        sftp(for: session) { r in
            switch r {
            case .failure(let e): completion(.failure(e))
            case .success(let pair):
                let svc = pair.0
                svc.listDirectory(path) { lr in
                    switch lr {
                    case .failure(let e): completion(.failure(e)); svc.close()
                    case .success(let entries):
                        completion(.success(entries.map { e in
                            ["name": e.name, "isDir": e.isDir, "size": Int(e.size),
                             "mtime": ISO8601DateFormatter().string(from: e.mtime)]
                        }))
                        svc.close()
                    }
                }
            }
        }
    }

    func bridgeSFTPDownload(session: Int, remote: String, local: String, completion: @escaping (Result<String, Error>) -> Void) {
        sftp(for: session) { r in
            switch r {
            case .failure(let e): completion(.failure(e))
            case .success(let pair):
                let svc = pair.0
                svc.download(remote: remote, local: local) { dr in
                    switch dr {
                    case .failure(let e): completion(.failure(e))
                    case .success: completion(.success(local))
                    }
                    svc.close()
                }
            }
        }
    }

    func bridgeSFTPUpload(session: Int, local: String, remote: String, completion: @escaping (Result<String, Error>) -> Void) {
        sftp(for: session) { r in
            switch r {
            case .failure(let e): completion(.failure(e))
            case .success(let pair):
                let svc = pair.0
                svc.upload(local: local, remote: remote) { ur in
                    switch ur {
                    case .failure(let e): completion(.failure(e))
                    case .success: completion(.success(remote))
                    }
                    svc.close()
                }
            }
        }
    }

    // MARK: - 关闭

    /// 有头接管：`POST /v1/app/shutdown` 到达时关闭全部会话并退出让位。
    func bridgeShutdown() {
        closeAll()
    }

    /// 关闭全部会话并触发退出回调（有头接管 / 无头自然退出用）。
    func closeAll() {
        let all = withLock { () -> [SSHSession] in
            let list = sessions.map { $0.ssh }
            sessions.removeAll()
            currentIndex = -1
            return list
        }
        for s in all { s.close() }
        onShutdown?()
    }
}

/// 让 HeadlessSession 直接当自己的 SSHSessionDelegate：收字节进缓冲、记录打开/关闭。
extension HeadlessBridgeHost.HeadlessSession: SSHSessionDelegate {
    func sshSession(_ s: SSHSession, didReceive data: [UInt8]) {
        if let text = String(bytes: data, encoding: .utf8) {
            appendOutput(text)
        }
    }
    func sshSession(_ s: SSHSession, didCloseWith error: Error?) {
        connected = false
        // 断开后清残留输出：screen 不该读旧画面（会误导 agent 以为还活着）
        lock.lock(); output = ""; lock.unlock()
    }
    func sshSessionDidOpenShell(_ s: SSHSession) {
        connected = true
    }
}
