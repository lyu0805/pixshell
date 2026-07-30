import Foundation

/// 主机模型。字段与 Windows 端 + Electron 版对齐：id/name/host/port/username/group/osId。
/// 密码不进 JSON —— 存 Keychain（见 Keychain.swift），按 id 关联。
struct Host: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var host: String
    var port: Int
    var username: String
    var group: String
    var osId: String
    /// 私钥文件路径（可含 ~，登录时展开）。留空表示走密码登录。不进 Keychain，直接存 JSON——
    /// 私钥本身仍在磁盘原路径，这里只记路径，不拷贝/不加密存储。
    var keyPath: String = ""
    /// 出站代理引用：对应 ProxyConfig.id（见 Proxy/ProxyConfig.swift）。留空 = 直连，不经代理。
    var proxyId: String = ""
    /// 连接类型：100 = SSH（默认），200 = RDP（Windows 远程桌面），
    /// 300 = 本机终端（应用内本地 shell），400 = Web（新建连接可选；连接时开应用内 Web 标签）。
    /// RDP 类型不走 SSH，连接时直接拉起系统 RDP 客户端（见 openSession(to:)）。
    /// 本机终端走 LocalSession（forkpty），不弹外部 Terminal.app。
    /// Web 两种形态（**禁止**外开系统浏览器；主入口「新建连接 → 类型 Web → 连接」）：
    ///   1) `webUrl` 非空（或 host 本身是 http(s) URL）→ 应用内直接打开该页（noVNC / 面板 / 任意 Web 控制台）
    ///   2) 否则 → 本地桥 `/webssh?host_id=`，底层仍是 SSH PTY（原 Web SSH 终端）
    var connectionType: Int = 100
    /// Web 外部页 URL（http/https）。空 = 走本地桥 WebSSH；有值 = 应用内 WKWebView 直接 Navigate。
    /// 也兼容把完整 URL 写在 `host` 字段（保存时会规范化进 webUrl）。
    var webUrl: String = ""

    init(id: String = UUID().uuidString, name: String = "", host: String = "",
         port: Int = 22, username: String = "root", group: String = "", osId: String = "",
         keyPath: String = "", proxyId: String = "", connectionType: Int = 100,
         webUrl: String = "") {
        self.id = id; self.name = name; self.host = host; self.port = port
        self.username = username; self.group = group; self.osId = osId
        self.keyPath = keyPath; self.proxyId = proxyId; self.connectionType = connectionType
        self.webUrl = webUrl
    }

    // 自定义 init(from:)：新字段用 decodeIfPresent 兜底，老 hosts.json 仍可解码。
    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, group, osId, keyPath, proxyId, connectionType, webUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        group = try c.decode(String.self, forKey: .group)
        osId = try c.decode(String.self, forKey: .osId)
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath) ?? ""
        proxyId = try c.decodeIfPresent(String.self, forKey: .proxyId) ?? ""
        connectionType = try c.decodeIfPresent(Int.self, forKey: .connectionType) ?? 100
        webUrl = try c.decodeIfPresent(String.self, forKey: .webUrl) ?? ""
    }

    /// RDP 主机（Windows 远程桌面），连接时拉起系统 RDP 客户端而非建 SSH 会话。
    var isRdp: Bool { connectionType == 200 }
    /// 本机终端会话（应用内本地 shell，不经 SSH）。
    var isLocal: Bool { connectionType == 300 }
    /// Web 连接（应用内 WKWebView：外部 URL 或本地桥 /webssh）。
    var isWebSSH: Bool { connectionType == 400 }

    /// 解析后的外部 Web URL（优先 webUrl，其次 host 字段里的 http(s)）。
    var resolvedWebURL: URL? {
        for raw in [webUrl, host] {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if let u = URL(string: t), let scheme = u.scheme?.lowercased(),
               (scheme == "http" || scheme == "https"), u.host != nil {
                return u
            }
        }
        return nil
    }

    /// Web 是否走外部页（noVNC 等），而非本地桥 SSH 终端。
    var isExternalWeb: Bool { isWebSSH && resolvedWebURL != nil }

    var display: String {
        if !name.isEmpty { return name }
        if let u = resolvedWebURL { return u.host ?? u.absoluteString }
        return host
    }
    var subtitle: String {
        if isLocal { return username.isEmpty ? "local" : "\(username)@local" }
        if isWebSSH {
            if let u = resolvedWebURL {
                // 外部 Web/VNC：副标题给可辨识的 host + path 摘要
                let path = u.path
                if path.count > 1 { return "web · \(u.host ?? "")\(path)" }
                return "web · \(u.absoluteString)"
            }
            if host.isEmpty || host == "127.0.0.1" { return "web · 127.0.0.1" }
            return "web · \(username)@\(host):\(port)"
        }
        return "\(username)@\(host):\(port)"
    }

    /// 快速连接 logo 打开的本机终端主机（不进 hosts.json）。
    static func localTerminal() -> Host {
        Host(id: "local-\(UUID().uuidString)",
             name: "本机终端",
             host: "localhost",
             port: 0,
             username: NSUserName(),
             group: "",
             osId: "macos",
             connectionType: 300)
    }

    /// 应用内 Web 终端主机（不进 hosts.json；仅作标签元数据）。
    static func webSSHTerminal(sessionIndex: Int?) -> Host {
        let suffix = sessionIndex.map { " · 会话 \($0 + 1)" } ?? ""
        return Host(id: "webssh-\(UUID().uuidString)",
                    name: "Web 终端\(suffix)",
                    host: "127.0.0.1",
                    port: 0,
                    username: "web",
                    group: "",
                    osId: "web",
                    connectionType: 400)
    }
}
