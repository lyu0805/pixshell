import Foundation

/// 应用侧需要实现的最小状态接口：AgentBridge 只依赖这个协议，绝不 import AppDelegate，
/// 保持桥接层可独立测试、可替换（对齐老仓库 agent-bridge.js 里 opts.engine 的角色）。
///
/// 约定：这里的 `session` 用整数下标/内部编号表示当前打开的会话（对应 App 里的
/// `sessions: [TermSession]`），不是老 JS 版里的 `"ssh_xxxx"` 字符串 id——由外部 CLI
/// 看到的 `GET /v1/app/sessions` 里的 `id` 字段是什么，回传时原样带回来即可，本文件负责
/// 把它解析成 Int 再转交给这里的方法。
protocol BridgeHost: AnyObject {
    /// 保存的主机列表（绝不包含密码 / 私钥内容）。
    func bridgeHosts() -> [[String: Any]]
    /// 当前打开的会话列表。
    func bridgeSessions() -> [[String: Any]]
    /// 按 hostId 打开一个新会话；completion 在主线程回调。
    func bridgeConnect(hostId: String, completion: @escaping (Result<[String: Any], Error>) -> Void)
    /// 把文本写进某会话的交互 shell（看得见，像手敲）。返回 false 表示会话不存在/写入失败。
    func bridgeWrite(session: Int, text: String) -> Bool
    /// 一次性执行命令并返回 stdout（独立通道，不进终端画面）。
    func bridgeExec(session: Int, cmd: String, completion: @escaping (String) -> Void)
    /// 读取某会话最近的终端输出（最多 lines 行；<=0 表示使用默认值）。
    func bridgeScreen(session: Int, lines: Int) -> String
    /// SFTP 列目录。
    func bridgeSFTPList(session: Int, path: String, completion: @escaping (Result<[[String: Any]], Error>) -> Void)
    /// SFTP 下载；成功回落地的本地路径，失败回具体错误。
    /// （原先用 `String?` 表示"路径或 nil"，与实现里"nil 表示成功"的写法撞了语义，
    ///   造成上传成功却报 upload failed —— 改成 Result 后不可能再误读。）
    func bridgeSFTPDownload(session: Int, remote: String, local: String, completion: @escaping (Result<String, Error>) -> Void)
    /// SFTP 上传；成功回远端路径，失败回具体错误。
    func bridgeSFTPUpload(session: Int, local: String, remote: String, completion: @escaping (Result<String, Error>) -> Void)
}

/// 一次已解析的 HTTP 请求：AgentBridge 完成分帧、鉴权、Origin 校验之后，把纯业务部分
/// 交给 `BridgeRouter` 处理，二者职责严格分离。
struct BridgeRequest {
    var method: String          // 已转大写："GET" / "POST" / ...
    var path: String            // 已去掉查询串、已去掉末尾多余 "/"（根路径 "/" 除外）
    var query: [String: String]
    var body: [String: Any]?    // 仅在需要 body 的方法上非 nil；GET 恒为 nil
}

struct BridgeResponse {
    var status: Int
    var json: [String: Any]

    static func ok(_ json: [String: Any]) -> BridgeResponse { BridgeResponse(status: 200, json: json) }
    static func fail(_ status: Int, _ error: String) -> BridgeResponse {
        BridgeResponse(status: status, json: ["ok": false, "error": error])
    }
}

/// 路径路由：把 HTTP 请求映射到 `BridgeHost` 调用，路径/别名严格对齐老仓库
/// `packages/app/main/agent-bridge.js` 的 `/v1/app/*` 语义，保证现有 pixshell-cli 不用改。
enum BridgeRouter {
    /// 桥接协议自身的版本号（区别于 App 版本），供 CLI 诊断用。
    static let bridgeVersion = "1.0.0-swift"

    /// 会话号是否真的存在。越界必须明确报错，不能返回 ok:true + 空输出 ——
    /// 那样 agent 分不清"命令没有输出"和"会话号写错了"，只能瞎猜。
    private static func validSession(_ host: BridgeHost, _ sid: Int) -> Bool {
        sid >= 0 && sid < host.bridgeSessions().count
    }

    static func route(_ req: BridgeRequest, host: BridgeHost?, completion: @escaping (BridgeResponse) -> Void) {
        let p = req.path
        let method = req.method

        if p == "/v1/health" || p == "/health" {
            completion(.ok([
                "ok": true,
                "version": bridgeVersion,
                "sessions": host?.bridgeSessions().count ?? 0,
            ]))
            return
        }

        guard let host = host else {
            completion(.fail(500, "bridge host not attached"))
            return
        }

        switch (p, method) {
        case ("/v1/app/hosts", "GET"), ("/v1/app/host-list", "GET"):
            let hosts = host.bridgeHosts()
            if let gid = req.query["group-id"] ?? req.query["group_id"] ?? req.query["g"], !gid.isEmpty {
                let filtered = hosts.filter { (($0["group"] as? String) ?? "") == gid }
                completion(.ok(["ok": true, "hosts": filtered]))
            } else {
                completion(.ok(["ok": true, "hosts": hosts]))
            }

        case ("/v1/app/hosts/connect", _), ("/v1/app/connect", _):
            guard method == "POST" else {
                completion(.fail(405, "use POST (password must not go in query string)"))
                return
            }
            guard let hostId = stringField(req.body, ["host_id", "hostId", "id"]), !hostId.isEmpty else {
                completion(.fail(400, "缺少 host_id"))
                return
            }
            host.bridgeConnect(hostId: hostId) { result in
                switch result {
                case .success(let dict):
                    var out = dict
                    out["ok"] = true
                    completion(BridgeResponse(status: 200, json: out))
                case .failure(let err):
                    completion(.fail(400, describeError(err)))
                }
            }

        case ("/v1/app/sessions", "GET"), ("/v1/app/list", "GET"):
            completion(.ok(["ok": true, "sessions": host.bridgeSessions()]))

        case ("/v1/app/shell", _):
            guard method == "POST" else { completion(.fail(405, "use POST")); return }
            guard let sid = sessionField(req.body, req.query) else {
                completion(.fail(400, "会话不存在或 id 不唯一"))
                return
            }
            let cmd = stringField(req.body, ["cmd"])
            var text = stringField(req.body, ["text"]) ?? cmd ?? ""
            if req.body?["cmd"] != nil, req.body?["text"] == nil {
                // shell --cmd：自动补回车
                if !text.hasSuffix("\n"), !text.hasSuffix("\r") { text += "\n" }
            } else if isTruthy(req.body?["newline"]) {
                if !text.hasSuffix("\n"), !text.hasSuffix("\r") { text += "\n" }
            } else if isExplicitFalse(req.body?["newline"]) {
                // 保持原样，不追加换行
            } else if cmd != nil {
                if !text.hasSuffix("\n") { text += "\n" }
            }
            if host.bridgeWrite(session: sid, text: text) {
                completion(.ok(["ok": true, "sessionId": sid, "bytes": text.utf8.count]))
            } else {
                completion(.fail(400, "write failed"))
            }

        case ("/v1/app/exec", _), ("/v1/app/direct", _):
            guard method == "POST" else { completion(.fail(405, "use POST")); return }
            guard let sid = sessionField(req.body, req.query) else {
                completion(.fail(400, "会话不存在或 id 不唯一"))
                return
            }
            guard let cmd = stringField(req.body, ["cmd", "command", "text"]), !cmd.isEmpty else {
                completion(.fail(400, "缺少 cmd"))
                return
            }
            guard validSession(host, sid) else {
                Log.warn("exec 指定的会话不存在 session=\(sid)（共 \(host.bridgeSessions().count) 个）", "bridge")
                completion(.fail(404, "会话 \(sid) 不存在（当前共 \(host.bridgeSessions().count) 个，用 /v1/app/sessions 查）"))
                return
            }
            host.bridgeExec(session: sid, cmd: cmd) { stdout in
                completion(.ok(["ok": true, "sessionId": sid, "stdout": stdout, "stderr": ""]))
            }

        case ("/v1/app/screen", _), ("/v1/app/read", _):
            guard method == "GET" || method == "POST" else { completion(.fail(405, "use GET/POST")); return }
            guard let sid = sessionField(req.body, req.query) else {
                completion(.fail(400, "会话不存在或 id 不唯一"))
                return
            }
            guard validSession(host, sid) else {
                Log.warn("screen 指定的会话不存在 session=\(sid)（共 \(host.bridgeSessions().count) 个）", "bridge")
                completion(.fail(404, "会话 \(sid) 不存在（当前共 \(host.bridgeSessions().count) 个，用 /v1/app/sessions 查）"))
                return
            }
            let linesRaw = req.query["lines"] ?? req.query["n"] ?? stringField(req.body, ["lines", "n"])
            let n = linesRaw.flatMap { Int($0) } ?? 200
            let text = host.bridgeScreen(session: sid, lines: n)
            let lines = text.components(separatedBy: "\n")
            completion(.ok([
                "ok": true, "sessionId": sid, "text": text, "lines": lines, "totalLines": lines.count,
            ]))

        case ("/v1/app/sftp/list", _):
            guard method == "GET" || method == "POST" else { completion(.fail(405, "use GET/POST")); return }
            guard let sid = sessionField(req.body, req.query) else {
                completion(.fail(400, "会话不存在"))
                return
            }
            let path = stringField(req.body, ["path", "remote", "remotePath"]) ?? req.query["path"] ?? req.query["p"] ?? "/"
            host.bridgeSFTPList(session: sid, path: path) { result in
                switch result {
                case .success(let entries):
                    // entries = 历史字段；items = 任务验收/新 CLI 约定，两者同内容。
                    completion(.ok(["ok": true, "path": path, "entries": entries, "items": entries]))
                case .failure(let err):
                    completion(.fail(400, describeError(err)))
                }
            }

        case ("/v1/app/sftp/download", "POST"):
            guard let sid = sessionField(req.body, req.query) else {
                completion(.fail(400, "会话不存在"))
                return
            }
            guard let remote = stringField(req.body, ["remote", "remotePath", "path"]), !remote.isEmpty else {
                completion(.fail(400, "缺少 remote"))
                return
            }
            let local = stringField(req.body, ["local", "localPath"]) ?? defaultDownloadLocal(remote: remote)
            host.bridgeSFTPDownload(session: sid, remote: remote, local: local) { r in
                switch r {
                case .success(let path): completion(.ok(["ok": true, "localPath": path]))
                case .failure(let e):    completion(.fail(400, "download failed: \(e.localizedDescription)"))
                }
            }

        case ("/v1/app/sftp/upload", "POST"):
            guard let sid = sessionField(req.body, req.query) else {
                completion(.fail(400, "会话不存在"))
                return
            }
            guard let local = stringField(req.body, ["local", "localPath"]),
                  let remote = stringField(req.body, ["remote", "remotePath"]),
                  !local.isEmpty, !remote.isEmpty else {
                completion(.fail(400, "需要 local 与 remote"))
                return
            }
            host.bridgeSFTPUpload(session: sid, local: local, remote: remote) { r in
                switch r {
                case .success(let path): completion(.ok(["ok": true, "remotePath": path]))
                case .failure(let e):    completion(.fail(400, "upload failed: \(e.localizedDescription)"))
                }
            }

        default:
            completion(.fail(404, "not found"))
        }
    }

    // MARK: - 小工具

    private static func describeError(_ err: Error) -> String {
        (err as NSError).localizedDescription
    }

    private static func stringField(_ body: [String: Any]?, _ keys: [String]) -> String? {
        guard let body = body else { return nil }
        for k in keys {
            if let v = body[k] {
                if let s = v as? String { return s }
                if let n = v as? NSNumber { return n.stringValue }
            }
        }
        return nil
    }

    private static func isTruthy(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return s == "1" || s.lowercased() == "true" }
        return false
    }

    private static func isExplicitFalse(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b == false }
        if let s = v as? String { return s == "0" || s.lowercased() == "false" }
        return false
    }

    /// `session` 在本机以数组下标（Int）表示；接受 JSON number 或数字字符串，
    /// 兼容 body 字段与 query 字段两种来源（GET /v1/app/screen 等走 query）。
    private static func sessionField(_ body: [String: Any]?, _ query: [String: String]) -> Int? {
        if let body = body {
            for k in ["session", "session_id", "sessionId"] {
                if let v = body[k] {
                    if let n = v as? NSNumber { return n.intValue }
                    if let s = v as? String, let i = Int(s.trimmingCharacters(in: .whitespaces)) { return i }
                }
            }
        }
        for k in ["session", "session_id", "s"] {
            if let s = query[k], let i = Int(s.trimmingCharacters(in: .whitespaces)) { return i }
        }
        return nil
    }

    private static func defaultDownloadLocal(remote: String) -> String {
        let base = (remote as NSString).lastPathComponent
        let safe = base.isEmpty ? "file" : base.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("pixshell-dl-\(safe)")
    }
}
