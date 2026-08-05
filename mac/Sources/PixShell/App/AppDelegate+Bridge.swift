import AppKit

// 本地 CLI/AI-Agent 桥的宿主实现（对齐老仓库 agent-bridge.js 的能力面）。
// 桥只监听 127.0.0.1 且强制 token 鉴权；这里只负责把请求映射到会话/主机操作。
extension AppDelegate: BridgeHost {

    /// 启动本地桥（失败不影响 App）。无头模式（--headless）用自建会话的 HeadlessBridgeHost；
    /// 有头用 AppDelegate 自己（复用已打开 Tab 的会话）。
    func startAgentBridge() {
        if isHeadless {
            startHeadlessBridge()
            return
        }
        // 有头接管：若已有无头在听 8766，先让它退出，等端口释放后再自己 bind。
        // 轮询最多 5s（无头退出是秒级），超时也不阻塞启动——AgentBridge 本身有"端口被占只记日志"兜底。
        waitForHeadlessToYield()
        let b = AgentBridge(host: self)
        // 有头 bind 与无头退出是异步竞态：失败先重试等端口释放，而不是直接放弃。
        b.retryOnPortBusy = true
        agentBridge = b
        b.start()
        AgentCLI.install(port: b.port)   // 写出 pixshell 命令，供本机 agent 直接操作本 App
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

    /// 有头启动前：探测 8766，若有无头在听 → 发 /v1/app/shutdown → 轮询直到端口释放
    /// （无头退出）。最多等 5s，超时也继续启动——AgentBridge 的 retryOnPortBusy
    /// 会继续等端口释放后再 bind，最终一定接管。
    private func waitForHeadlessToYield() {
        let port = AgentBridge.configuredPort
        // 探测用裸 TCP 建连：/v1/health 在鉴权后面（无 token 返回 401），HTTP GET 判断不了在听。
        guard AgentBridge.isPortOpen(port), let token = AgentBridge.existingToken() else { return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/app/shutdown")!)
        req.httpMethod = "POST"
        req.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { _, _, _ in
            // 发完请求后轮询端口释放（AgentBridge retryOnPortBusy 也兜底等待）
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if !AgentBridge.isPortOpen(port) { return }   // 无头已退出，端口释放
                usleep(250_000)
            }
            Log.warn("等待无头退出超时，靠 retryOnPortBusy 继续等", "bridge")
        }.resume()
    }

    /// 无头模式启动桥：自建 HeadlessBridgeHost；端口被占（=有头已在）→ 立即退出让位。
    /// 注意：这里强捕获 self（不用 [weak self]）——无头进程是短命"让位即退出"的，不存在引用循环，
    /// 而且 ifAppDelegate 意外释放会让 onShutdown 里的 NSApp.terminate 不触发、进程挂起等死。
    private func startHeadlessBridge() {
        let host = HeadlessBridgeHost()
        headlessHost = host
        host.onShutdown = {
            self.agentBridge?.stop()
            NSApp.terminate(nil)
        }
        let b = AgentBridge(host: host)
        // 端口已被有头占用 → 退出（有头接管了桥，无头让位；CLI 会再用到有头）。
        // onPortBusy 在 bridge 内部队列回调，切主线程再触发关闭+退出。
        b.onPortBusy = {
            DispatchQueue.main.async {
                Log.info("本地桥端口被占用（有头已在），无头进程退出让位", "bridge")
                self.headlessHost?.closeAll()
            }
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
