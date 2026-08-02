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
        let ssh: SSHSession
        let password: String
        /// 交互 shell 的最近输出（exec 是独立通道不进这里；screen 读它）。
        private var output = ""
        private let lock = NSLock()
        var connected = false

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
                 "username": s.host.username, "connected": s.connected, "active": i == currentIndex]
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
            sessions[session].ssh.send(Array(text.utf8))
            return true
        }
    }

    func bridgeExec(session: Int, cmd: String, completion: @escaping (String) -> Void) {
        withLock {
            guard sessions.indices.contains(session) else { completion(""); return }
            sessions[session].ssh.exec(cmd) { completion($0) }
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
            let creds = SSHCredentials(host: s.host.host, port: s.host.port, username: s.host.username,
                                       password: s.password, keyPath: s.host.keyPath.isEmpty ? nil : s.host.keyPath)
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
        // 不做清理：桥层通过 bridgeSessions 感知；closeAll 统一 close。
    }
    func sshSessionDidOpenShell(_ s: SSHSession) {
        connected = true
    }
}
