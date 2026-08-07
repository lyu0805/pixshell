import AppKit

// 本地 CLI/AI-Agent 桥的宿主实现（对齐老仓库 agent-bridge.js 的能力面）。
// 桥只监听 127.0.0.1 且强制 token 鉴权；这里只负责把请求映射到会话/主机操作。
extension AppDelegate: BridgeHost {

    /// 启动本地桥（失败不影响 App）。
    ///
    /// **有头/无头端口分工（绝不打架）**：
    ///   - 无头进程（--headless）：监听 `AgentBridge.defaultPort`（47866）——agent 专属。
    ///   - 有头 GUI：监听 `AgentBridge.guiPort`（47867）——只服务 GUI 自己的功能
    ///     （Web SSH 镜像页等），**不碰 agent 端口**，也**不再赶走无头进程**。
    /// 两端各自独立监听，互不占端口、互不让位。agent 请求永远连 47866 的无头进程。
    ///
    /// 有头模式 agent 请求也走**独立** HeadlessBridgeHost 实例（agentHeadlessHost）——
    /// 绝不在 UI 里开标签、不抢控制器。
    func startAgentBridge() {
        if isHeadless {
            startHeadlessBridge()
            return
        }
        // agent 专用隔离池：connect 建的是无 UI 会话，绝不开 UI 标签、不碰用户控制器。
        if agentHeadlessHost == nil {
            let host = HeadlessBridgeHost()
            // 有头模式不因 shutdown 退出；空回调即可。
            host.onShutdown = {}
            agentHeadlessHost = host
        }
        // 有头用 GUI 专用端口（47867），与无头 agent 端口（47866）完全隔离。
        let b = AgentBridge(host: agentHeadlessHost, port: AgentBridge.guiPort)
        // 有头 GUI 端口被占 → 池避让试下一端口（高位段），绝无头/有头抢同一端口。
        b.usePortPool = true
        // 有头 GUI 桥不写 agent_port：CLI/MCP 发现的是无头进程的 47866。
        b.writesAgentPort = false
        agentBridge = b
        b.start()
        AgentCLI.install(port: AgentBridge.defaultPort)   // CLI 永远连 agent 端口（无头进程）
        // start()/监听就绪都是异步的，且状态栏可能被整窗重建替换 —— 用定时器周期性对齐真实状态，
        // 同时让「已对接」能随时间自然回落到「已开启」。
        bridgeTimer?.invalidate()
        bridgeTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self, weak b] _ in
            guard let self = self, let b = b else { return }
            // lastClientAt 只在「鉴权通过」时更新（401 不算），据此判定「已对接」
            let idle = b.lastClientAt.map { Date().timeIntervalSince($0) }
            self.bridgeStatus = (running: b.isRunning, port: b.port, clientIdle: idle)
            self.updateCliStatus()
        }
        bridgeTimer?.fire()
    }

    /// 无头模式启动桥：自建 HeadlessBridgeHost，监听 agent 端口（47866）。
    /// **不再因有头存在而让位**——有头用独立 GUI 端口，两端各自监听，永不打架。
    /// 注意：这里强捕获 self（不用 [weak self]）——无头进程生命周期随进程，
    /// 而且 ifAppDelegate 意外释放会让 onShutdown 里的 NSApp.terminate 不触发、进程挂起等死。
    private func startHeadlessBridge() {
        let host = HeadlessBridgeHost()
        headlessHost = host
        host.onShutdown = {
            self.agentBridge?.stop()
            NSApp.terminate(nil)
        }
        let b = AgentBridge(host: host, port: AgentBridge.defaultPort)
        // 无头端口被占（已有桥在服务）→ 立即退出让位（去重）。
        // 之前没设这个：端口被占时无头静默僵尸（不退出也不服务），CLI/MCP 竞态多拉时
        // 出现"旧桥死了但僵尸占位/僵尸永远不接管"的静默期 —— 通道死掉的隐藏来源。
        b.onPortBusy = {
            self.agentBridge?.stop()
            NSApp.terminate(nil)
        }
        agentBridge = b
        b.start()
        AgentCLI.install(port: b.port)
    }

    /// 桥收到一次鉴权通过的外部请求 → 状态栏转「已对接」
    func noteBridgeClient() {
        bridgeStatus.clientIdle = 0
        updateCliStatus()
    }

    // MARK: - BridgeHost

    func bridgeHosts() -> [[String: Any]] {
        store.hosts.map { h in
            ["id": h.id, "name": h.display, "host": h.host,
             "port": h.port, "username": h.username, "group": h.group]
        }
    }

    func bridgeSessions() -> [[String: Any]] {
        sessions.enumerated().map { (i, s) in
            ["session": i, "title": s.title, "host": s.host.host,
             "username": s.host.username, "connected": s.connected, "active": i == current]
        }
    }

    func bridgeConnect(hostId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let h = store.hosts.first(where: { $0.id == hostId }) else {
            completion(.failure(NSError(domain: "PixShell", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "未找到主机 \(hostId)"]))); return
        }
        // 只用已保存的密码/私钥；桥不弹密码框（无人值守场景不该阻塞）
        let pw = Keychain.password(for: h.id) ?? ""
        guard !pw.isEmpty || !h.keyPath.isEmpty else {
            completion(.failure(NSError(domain: "PixShell", code: 401,
                userInfo: [NSLocalizedDescriptionKey: "该主机没有保存的密码或私钥，请先在界面里连接一次"]))); return
        }
        // Web 主机（type 400）底层仍走 SSH PTY；剥掉 Web 标记，避免 SSH 标签被当成 Web 视图。
        var connectHost = h
        if connectHost.isWebSSH { connectHost.connectionType = 100 }
        if connectHost.isRdp || connectHost.isLocal {
            completion(.failure(NSError(domain: "PixShell", code: 400,
                userInfo: [NSLocalizedDescriptionKey: "RDP/本机终端不能经 Web 桥连接"]))); return
        }
        beginSession(to: connectHost, password: pw)
        let idx = sessions.count - 1
        // 等 shell 真正打开再回，最多 20s
        var waited = 0.0
        func poll() {
            if sessions.indices.contains(idx), sessions[idx].connected {
                completion(.success(["session": idx, "title": sessions[idx].title])); return
            }
            waited += 0.25
            if waited > 20 {
                completion(.failure(NSError(domain: "PixShell", code: 504,
                    userInfo: [NSLocalizedDescriptionKey: "连接超时"]))); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
        }
        poll()
    }

    func bridgeWrite(session: Int, text: String) -> Bool {
        guard sessions.indices.contains(session), let ssh = sessions[session].ssh else { return false }
        ssh.send(Array(text.utf8))
        return true
    }

    func bridgeExec(session: Int, cmd: String, completion: @escaping (String) -> Void) {
        guard sessions.indices.contains(session), let ssh = sessions[session].ssh else { completion(""); return }
        ssh.exec(cmd) { completion($0) }
    }

    func bridgeScreen(session: Int, lines: Int) -> String {
        guard sessions.indices.contains(session) else { return "" }
        let buf = sessions[session].outputBuffer
        let n = lines > 0 ? lines : 200
        let rows = buf.split(separator: "\n", omittingEmptySubsequences: false)
        return rows.suffix(n).joined(separator: "\n")
    }

    func bridgeSFTPList(session: Int, path: String, completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
        // 复用当前 SFTP 面板的连接；桥不另开会话
        guard sessions.indices.contains(session), let sp = sftpPanel else {
            completion(.failure(NSError(domain: "PixShell", code: 400,
                userInfo: [NSLocalizedDescriptionKey: "会话不存在"]))); return
        }
        sp.connectIfNeeded(host: sessions[session].host, password: sessions[session].password)
        sp.listForBridge(path) { r in
            switch r {
            case .failure(let e): completion(.failure(e))
            case .success(let entries):
                completion(.success(entries.map { e in
                    ["name": e.name, "isDir": e.isDir, "size": e.size,
                     "mtime": ISO8601DateFormatter().string(from: e.mtime)]
                }))
            }
        }
    }

    func bridgeSFTPDownload(session: Int, remote: String, local: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard sessions.indices.contains(session), let sp = sftpPanel else {
            completion(.failure(Self.bridgeErr("会话不存在"))); return
        }
        sp.connectIfNeeded(host: sessions[session].host, password: sessions[session].password)
        sp.downloadForBridge(remote: remote, local: local) { err in
            if let e = err { completion(.failure(Self.bridgeErr(e))) } else { completion(.success(local)) }
        }
    }

    func bridgeSFTPUpload(session: Int, local: String, remote: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard sessions.indices.contains(session), let sp = sftpPanel else {
            completion(.failure(Self.bridgeErr("会话不存在"))); return
        }
        sp.connectIfNeeded(host: sessions[session].host, password: sessions[session].password)
        sp.uploadForBridge(local: local, remote: remote) { err in
            if let e = err { completion(.failure(Self.bridgeErr(e))) } else { completion(.success(remote)) }
        }
    }

    private static func bridgeErr(_ msg: String) -> Error {
        NSError(domain: "PixShell.bridge", code: 400, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
