import Foundation
import Network
import Security

/// 本地回环 HTTP 控制服务器：让外部 CLI（pixshell-cli，Claude Code / Codex / OpenCode 等）
/// 驱动正在运行的 PixShell 桌面端——列出已存主机、开会话、发命令、读屏幕、传文件。
/// 对齐老 JS 仓库 `packages/app/main/agent-bridge.js` 的路径 / 语义，端口/鉴权文件不变，
/// 现有 `pixshell-cli` 无需任何修改即可继续工作。
///
/// 安全边界（纵深防御，任何一条都不能削弱）：
///   - 只绑定 127.0.0.1，绝不监听 0.0.0.0 / 局域网网卡；
///   - 每个已接受的连接都再核实一次远端地址是否回环；
///   - 每个请求都要求 token（`~/Library/Application Support/PixShell/agent_token`，0600）；
///   - 不发任何 CORS 响应头；带 `Origin` 时仅放行本机回环同源（`http://127.0.0.1:port` /
///     `http://localhost:port`），其它 Origin 一律 403（挡住跨站 CSRF，同时允许 Web SSH 页）；
///   - 请求体上限 8 MiB，超出返回 413；
///   - 绝不把 token 明文写进日志，只记录长度。
final class AgentBridge {
    /// 与老 JS 版 `DEFAULT_PORT` 保持一致。
    static let defaultPort = 8766
    /// 请求体上限（sftp 上传等）：超过即拒绝，防止本地恶意/失控客户端把内存打爆。
    static let maxBodyBytes = 8 * 1024 * 1024
    /// 请求头上限：还没找到 `\r\n\r\n` 就超过这个尺寸，判定为异常请求，直接拒绝。
    fileprivate static let maxHeaderBytes = 64 * 1024

    weak var host: BridgeHost?

    /// 监听失败（端口被占等）时回调。无头模式（--headless）用它来"端口被有头占 → 自己退出让位"；
    /// 有头保持原有"只记日志不退出"的容错行为。
    var onPortBusy: (() -> Void)?

    /// 端口被占用时的行为：有头 = 重试等无头让位（先发 /v1/app/shutdown 让它退）；无头 = 立即退出让位。
    /// 默认 false（无头行为）。
    var retryOnPortBusy = false
    private var failedRetryCount = 0

    private(set) var isRunning = false
    private(set) var port: Int
    let tokenPath: String

    private var listener: NWListener?
    private var token: String
    /// 承载 NWListener 状态回调 + 所有连接的分帧处理；App 状态访问一律转发主线程，
    /// 这条队列自身绝不触碰 host 的业务数据。
    private let queue = DispatchQueue(label: "com.pixshell.bridge")
    /// 强引用住每个还活着的连接：NWConnection 由调用方负责保活，一旦这里不存它，
    /// ARC 会在 accept() 返回后立刻释放，导致连接刚建立就被悄悄拆掉（receive 永远不回调）。
    private var connections: [ObjectIdentifier: BridgeConnection] = [:]

    /// 最近一次「鉴权通过」的外部请求时间（供状态栏三态指示：未开启/已开启/已对接）；
    /// 从未有过合法请求则为 nil。只在 token 校验成功时更新——401 不算「已对接」。
    /// 用锁保护读写：写入发生在 bridge 内部队列，读取来自 App 主线程的轮询定时器，
    /// 一个裸的 Date? 跨线程读写不保证不撕裂，这里用 NSLock 保证读到的要么是旧值要么是新值。
    private let lastClientLock = NSLock()
    private var _lastClientAt: Date?
    var lastClientAt: Date? {
        lastClientLock.lock()
        defer { lastClientLock.unlock() }
        return _lastClientAt
    }
    fileprivate func markClientAuthenticated() {
        lastClientLock.lock()
        _lastClientAt = Date()
        lastClientLock.unlock()
    }

    init(host: BridgeHost? = nil) {
        self.host = host
        if let envPort = ProcessInfo.processInfo.environment["PIXSHELL_BRIDGE_PORT"],
           let p = Int(envPort), p > 0, p < 65536 {
            self.port = p
        } else {
            self.port = AgentBridge.defaultPort
        }
        self.tokenPath = AgentBridge.computeTokenPath()
        self.token = AgentBridge.ensureToken(at: self.tokenPath)
    }

    // MARK: - Token

    private static func tokenDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("PixShell", isDirectory: true)
    }

    private static func computeTokenPath() -> String {
        tokenDir().appendingPathComponent("agent_token").path
    }

    /// 读取已有 token（不存在/太短返回 nil）。供有头接管读无头已写的 token（只读，不重建）。
    static func existingToken() -> String? {
        guard let data = FileManager.default.contents(atPath: computeTokenPath()) else { return nil }
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.count ?? 0) >= 16 ? s : nil
    }

    /// 探测 127.0.0.1:port 是否被监听：TCP 建连成功即认为在听。
    /// 不依赖 token：/v1/health 在鉴权后面（无 token 返回 401），用裸 TCP 探测比 HTTP GET 可靠。
    /// 供有头接管判断「无头是否还占着端口」。
    static func isPortOpen(_ port: Int) -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: max(0, port))) else { return false }
        let sem = DispatchSemaphore(value: 0)
        var result = false
        var done = false
        let conn = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        conn.stateUpdateHandler = { state in
            guard !done else { return }
            switch state {
            case .ready: result = true; done = true; sem.signal()
            case .failed, .cancelled: result = false; done = true; sem.signal()
            default: break
            }
        }
        conn.start(queue: DispatchQueue.global())
        _ = sem.wait(timeout: .now() + 1.5)
        conn.cancel()
        return result
    }

    /// 无头收到 reopen 后拉起有头进程（不带 --headless）。无头已 terminate，
    /// 此时 open 会真正启动新有头实例，不再复用无头。参数是 `[appPath]` 或 `["-a","PixShell"]`。
    static func spawnOpenApp(_ args: [String]) {
        openProcess(open: "/usr/bin/open", args: args)
    }

    /// 有头退出时拉起无头进程接续桥：`open <App>.app --args --headless`。
    /// 只有 bundle（.app）才有意义；debug 裸二进制（path 是目录）用名字兜底。
    static func spawnHeadlessProcess() {
        let rawPath = Bundle.main.bundlePath
        let appPath = rawPath.hasSuffix(".app") ? rawPath : ""
        if !appPath.isEmpty {
            openProcess(open: "/usr/bin/open", args: [appPath, "--args", "--headless"])
            return
        }
        openProcess(open: "/usr/bin/open", args: ["-a", "PixShell", "--args", "--headless"])
    }

    /// 异步 `open`（不阻塞主线程、无窗口）。
    private static func openProcess(open: String, args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: open)
        p.arguments = args
        try? p.run()
    }

    /// 读取已有 token；不存在/太短则用 `SecRandomCopyBytes` 生成 32 字节并写盘（权限 0600）。
    /// 铁律：绝不把 token 明文写进日志。
    private static func ensureToken(at path: String) -> String {
        let fm = FileManager.default
        let dir = tokenDir()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = fm.contents(atPath: path), let s = String(data: data, encoding: .utf8) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 16 { return trimmed }
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let hex: String
        if status == errSecSuccess {
            hex = bytes.map { String(format: "%02x", $0) }.joined()
        } else {
            // 极端兜底：系统随机源不可用时退化为拼接 UUID，长度/不可预测性仍然足够。
            hex = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        }
        if fm.createFile(atPath: path, contents: Data(hex.utf8), attributes: [.posixPermissions: 0o600]) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } else {
            Log.warn("无法写入 agent_token 文件: \(path)", "bridge")
        }
        return hex
    }

    /// 供设置面板"重置 token"预留（当前未接 UI）。
    func rotateToken() {
        queue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(atPath: self.tokenPath)
            self.token = AgentBridge.ensureToken(at: self.tokenPath)
            Log.info("agent_token 已重置（长度 \(self.token.count)）", "bridge")
        }
    }

    /// 当前 token（只读快照）。菜单打开 Web SSH 时拼进 `?token=`；绝不写日志。
    var currentToken: String { token }

    /// 拼 Web SSH 浏览器 URL（本机回环 + 当前 token + 可选 session）。
    func webSSHURL(session: Int? = nil, hostId: String? = nil) -> URL? {
        var c = URLComponents()
        c.scheme = "http"
        c.host = "127.0.0.1"
        c.port = port
        c.path = "/webssh"
        var items: [URLQueryItem] = [URLQueryItem(name: "token", value: token)]
        if let session { items.append(URLQueryItem(name: "session", value: String(session))) }
        if let hostId, !hostId.isEmpty { items.append(URLQueryItem(name: "host_id", value: hostId)) }
        c.queryItems = items
        return c.url
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in self?.startLocked() }
    }

    private func startLocked() {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: max(0, port))) else {
            Log.warn("端口号非法，本地桥不启动: \(port)", "bridge")
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = false
        // 只绑定 127.0.0.1：requiredLocalEndpoint 限定监听地址，从不监听 0.0.0.0 / 局域网网卡。
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        do {
            let l = try NWListener(using: params)
            listener = l
            l.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let actualPort = l.port.map { Int($0.rawValue) } ?? self.port
                    self.port = actualPort
                    self.isRunning = true
                    Log.info("本地桥已启动 http://127.0.0.1:\(actualPort)（token 长度 \(self.token.count)）", "bridge")
                case .failed(let err):
                    self.isRunning = false
                    Log.warn("本地桥监听失败，端口可能被占用，保持关闭不影响主程序: \(err)", "bridge")
                    self.listener?.cancel()
                    self.listener = nil
                    // 有头模式：短暂重试，等无头收到 shutdown 退出、端口释放后再 bind。
                    // 无头模式不重试：走 onPortBusy 立即退出让位。
                    if self.retryOnPortBusy, self.failedRetryCount < 10 {
                        self.failedRetryCount += 1
                        let delay = 0.3 * Double(self.failedRetryCount)
                        self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self, self.retryOnPortBusy else { return }
                            if AgentBridge.isPortOpen(self.port) { return }   // 还没释放，继续等
                            self.startLocked()
                        }
                    } else {
                        // 重试耗尽（有头 10 次 ~1.8s 仍被占）：有头默认无 onPortBusy handler，这里
                        // 必须打日志，否则桥静默失败、CLI 调用全部连不上却毫无痕迹。
                        if self.retryOnPortBusy {
                            Log.warn("端口 \(self.port) 重试 10 次仍被占用，本地桥放弃启动", "bridge")
                        }
                        self.onPortBusy?()
                    }
                case .cancelled:
                    self.isRunning = false
                default:
                    break
                }
            }
            l.start(queue: queue)
        } catch {
            Log.warn("本地桥启动异常: \(error)", "bridge")
            isRunning = false
            listener = nil
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.isRunning = false
            // 停止时一并断开所有还挂着的连接，避免残留的 CLI 长连接继续占用。
            let all = self.connections.values
            self.connections.removeAll()
            for c in all { c.cancelNow() }
            Log.info("本地桥已停止", "bridge")
        }
    }

    // MARK: - Accept

    private func accept(_ connection: NWConnection) {
        // 纵深防御：即便监听已绑定 127.0.0.1，仍逐连接核实远端地址是回环。
        if !AgentBridge.isLoopback(connection.endpoint) {
            Log.warn("拒绝非回环连接: \(connection.endpoint)", "bridge")
            connection.cancel()
            return
        }
        let conn = BridgeConnection(connection: connection, queue: queue, token: token, host: host)
        let key = ObjectIdentifier(conn)
        connections[key] = conn
        // 连接结束（正常回应完成 / 出错 / 对端提前断开）后从保活表里摘掉，交给 ARC 回收。
        conn.onFinish = { [weak self] in
            self?.queue.async { self?.connections.removeValue(forKey: key) }
        }
        // 只有 token 校验真正通过才算「外部对接」；401 不计入 lastClientAt。
        conn.onAuthenticated = { [weak self] in self?.markClientAuthenticated() }
        conn.start()
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        switch endpoint {
        case .hostPort(let h, _):
            switch h {
            case .ipv4(let addr): return addr == .loopback
            case .ipv6(let addr): return addr == .loopback
            case .name(let n, _): return n == "localhost"
            @unknown default: return false
            }
        default:
            return false
        }
    }
}

// MARK: - 单个连接的 HTTP/1.1 分帧 + 鉴权 + 路由派发

/// 只解析我们需要的最小 HTTP/1.1 子集：请求行、头部、可选 body；每个响应都
/// `Connection: close`，用完即关闭连接（不支持 keep-alive / 管线化 / chunked）。
private final class BridgeConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let token: String
    private weak var host: BridgeHost?

    private var buffer = Data()
    private var headersParsed = false
    private var responded = false

    private var method = "GET"
    private var path = "/"
    private var query: [String: String] = [:]
    private var headers: [String: String] = [:]
    private var contentLength = 0
    private var bodyBuffer = Data()
    private var finished = false
    /// 请求已经凑齐并交给 dispatch() 之后置位：防止连接上多余/尾随字节被再次误判成
    /// "又一个完整请求" 从而重复调用 BridgeRouter（比如重复执行一次 exec）。
    private var dispatched = false

    /// 连接彻底结束时回调一次（正常完成 / 出错 / 对端提前断开），供 AgentBridge 从保活表摘除。
    var onFinish: (() -> Void)?
    /// token 校验通过时回调一次（401 不触发）——供 AgentBridge 更新 lastClientAt。
    var onAuthenticated: (() -> Void)?

    init(connection: NWConnection, queue: DispatchQueue, token: String, host: BridgeHost?) {
        self.connection = connection
        self.queue = queue
        self.token = token
        self.host = host
    }

    func start() {
        connection.start(queue: queue)
        receiveMore()
    }

    /// 外部（AgentBridge.stop()）强制中断；与内部 finish() 走同一去重逻辑，绝不重复触发 onFinish。
    func cancelNow() {
        finish()
    }

    private func receiveMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.ingest(data)
            }
            // 请求已经交给 dispatch()（或已经回应完毕）：不再继续收，避免尾随字节被
            // 误当成第二个请求、触发重复的路由调用。
            if self.dispatched || self.responded { return }
            if error != nil {
                self.finish()
                return
            }
            if isComplete {
                // 对端提前关闭写侧，还没凑齐一个完整请求：直接放弃，不回应。
                self.finish()
                return
            }
            self.receiveMore()
        }
    }

    /// 统一的终结路径：取消连接 + 通知外部摘除保活引用；用 `finished` 去重，避免重复调用。
    private func finish() {
        guard !finished else { return }
        finished = true
        connection.cancel()
        onFinish?()
    }

    private func ingest(_ data: Data) {
        if !headersParsed {
            buffer.append(data)
            let sep = Data([0x0d, 0x0a, 0x0d, 0x0a]) // "\r\n\r\n"
            guard let range = buffer.range(of: sep) else {
                if buffer.count > AgentBridge.maxHeaderBytes {
                    respond(.fail(400, "header too large"))
                }
                return
            }
            let headBytes = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            let rest = buffer.subdata(in: range.upperBound..<buffer.endIndex)
            guard parseHead(headBytes) else {
                respond(.fail(400, "bad request"))
                return
            }
            headersParsed = true
            bodyBuffer = rest
        } else {
            bodyBuffer.append(data)
        }

        guard headersParsed else { return }

        if bodyBuffer.count > AgentBridge.maxBodyBytes || contentLength > AgentBridge.maxBodyBytes {
            respond(.fail(413, "request body too large"))
            return
        }
        if !dispatched, bodyBuffer.count >= contentLength {
            dispatched = true
            dispatch()
        }
    }

    /// 解析请求行 + 头部。返回 false 表示格式非法。
    private func parseHead(_ headBytes: Data) -> Bool {
        guard let text = String(data: headBytes, encoding: .utf8) else { return false }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return false }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return false }
        method = parts[0].uppercased()
        let target = String(parts[1])

        guard let comps = URLComponents(string: "http://127.0.0.1" + target) else { return false }
        var p = comps.path.isEmpty ? "/" : comps.path
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        path = p
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { q[item.name] = item.value ?? "" }
        query = q

        var hdrs: [String: String] = [:]
        for line in lines {
            guard !line.isEmpty else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let valueStart = line.index(after: colon)
            let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
            hdrs[key] = value
        }
        headers = hdrs

        if let te = hdrs["transfer-encoding"], te.lowercased().contains("chunked") {
            // 不支持 chunked（本地 CLI 客户端从不使用）；直接判非法请求。
            return false
        }
        contentLength = Int(hdrs["content-length"] ?? "") ?? 0
        return true
    }

    private func dispatch() {
        // Origin：无 CORS 头。跨站 Origin 一律拒绝；仅放行本机回环（Web SSH 页自己的 fetch）。
        if let origin = headers["origin"], !BridgeConnection.isLoopbackOrigin(origin) {
            respond(.fail(403, "origin not allowed"))
            return
        }

        // 静态资源 GET /web/*（xterm.js/css/addon）：公开前端库，无会话数据；
        // <script src> 无法带 token，对齐 Win 免鉴权。仍受回环绑定 + Origin 约束。
        let isPublicWebAsset = method == "GET" && path.hasPrefix("/web/")
        if !isPublicWebAsset {
            let got = extractToken()
            guard !got.isEmpty, BridgeConnection.constantTimeEqual(got, token) else {
                respond(.fail(401, "unauthorized"))
                return
            }
            // 鉴权通过才算「外部真正对接过」；401 绝不触发。
            onAuthenticated?()
        }

        let needsBody = method == "POST" || method == "PUT" || method == "PATCH"
        var bodyObj: [String: Any]?
        if needsBody {
            let raw = bodyBuffer.count > contentLength ? bodyBuffer.subdata(in: bodyBuffer.startIndex..<bodyBuffer.index(bodyBuffer.startIndex, offsetBy: contentLength)) : bodyBuffer
            if raw.isEmpty {
                bodyObj = [:]
            } else if let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                bodyObj = obj
            } else {
                respond(.fail(400, "invalid json"))
                return
            }
        }

        let req = BridgeRequest(method: method, path: path, query: query, body: bodyObj)
        // 铁律：碰 App 状态的处理一律在主线程；回到 bridge 队列后再写连接（避免跨线程碰同一个连接对象）。
        // 静态资源无 App 状态，可在 bridge 队列直接路由，但走同一路径更简单一致。
        DispatchQueue.main.async { [weak self] in
            BridgeRouter.route(req, host: self?.host) { response in
                self?.queue.async { self?.respond(response) }
            }
        }
    }

    /// 严格同源匹配（带端口）；`portHint` 非 nil 时要求端口一致。
    private static func isAllowedOrigin(_ origin: String, portHint: Int?) -> Bool {
        guard let comps = URLComponents(string: origin),
              let host = comps.host?.lowercased(),
              comps.scheme?.lowercased() == "http" else { return false }
        guard host == "127.0.0.1" || host == "localhost" || host == "[::1]" || host == "::1" else { return false }
        if let portHint {
            let p = comps.port ?? 80
            return p == portHint
        }
        return true
    }

    /// 是否本机回环 Origin（任意端口）——Web SSH 页从 8766 打开时 Origin 就是 `http://127.0.0.1:8766`。
    private static func isLoopbackOrigin(_ origin: String) -> Bool {
        isAllowedOrigin(origin, portHint: nil)
    }

    private func extractToken() -> String {
        if let auth = headers["authorization"] {
            let lowered = auth.lowercased()
            if lowered.hasPrefix("bearer ") {
                return String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
        }
        if let t = headers["x-pixshell-token"] { return t.trimmingCharacters(in: .whitespaces) }
        if let t = headers["x-agent-token"] { return t.trimmingCharacters(in: .whitespaces) }
        if let t = query["token"] { return t }
        return ""
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        if ab.count != bb.count { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    private func respond(_ response: BridgeResponse) {
        guard !responded else { return }
        responded = true

        let bodyData: Data
        if let raw = response.rawBody {
            bodyData = raw
        } else if let json = response.json {
            do {
                bodyData = try JSONSerialization.data(withJSONObject: json, options: [])
            } catch {
                Log.warn("响应序列化失败: \(error)", "bridge")
                bodyData = Data("{\"ok\":false,\"error\":\"internal error\"}".utf8)
            }
        } else {
            bodyData = Data()
        }

        let ct = response.contentType.isEmpty ? "application/json; charset=utf-8" : response.contentType
        // HTML 页再加一层 CSP（页面 meta 已有；响应头双保险，禁 CDN/外联）
        let csp: String
        if ct.contains("text/html") {
            csp = "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; font-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        } else {
            csp = "default-src 'none'"
        }
        let statusLine = "HTTP/1.1 \(response.status) \(BridgeConnection.reason(for: response.status))\r\n"
        let head = statusLine
            + "Content-Type: \(ct)\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "X-Content-Type-Options: nosniff\r\n"
            + "Content-Security-Policy: \(csp)\r\n"
            + "Connection: close\r\n"
            + "\r\n"

        var full = Data(head.utf8)
        full.append(bodyData)

        connection.send(content: full, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        default: return "Error"
        }
    }
}
