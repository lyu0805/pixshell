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
    /// 连接类型：100 = SSH（默认），200 = RDP（Windows 远程桌面），300 = 本机终端（应用内本地 shell）。
    /// RDP 类型不走 SSH，连接时直接拉起系统 RDP 客户端（见 openSession(to:)）。
    /// 本机终端走 LocalSession（forkpty），不弹外部 Terminal.app。
    var connectionType: Int = 100

    init(id: String = UUID().uuidString, name: String = "", host: String = "",
         port: Int = 22, username: String = "root", group: String = "", osId: String = "",
         keyPath: String = "", proxyId: String = "", connectionType: Int = 100) {
        self.id = id; self.name = name; self.host = host; self.port = port
        self.username = username; self.group = group; self.osId = osId
        self.keyPath = keyPath; self.proxyId = proxyId; self.connectionType = connectionType
    }

    // 自定义 init(from:)：keyPath/proxyId/connectionType 用 decodeIfPresent 兜底，保证老版本 hosts.json
    // （没有这些字段）仍能正常解码，不会因为多了新字段就整条记录解析失败。encode(to:) 沿用编译器合成的实现。
    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, group, osId, keyPath, proxyId, connectionType
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
    }

    /// RDP 主机（Windows 远程桌面），连接时拉起系统 RDP 客户端而非建 SSH 会话。
    var isRdp: Bool { connectionType == 200 }
    /// 本机终端会话（应用内本地 shell，不经 SSH）。
    var isLocal: Bool { connectionType == 300 }

    var display: String { name.isEmpty ? host : name }
    var subtitle: String {
        if isLocal { return username.isEmpty ? "local" : "\(username)@local" }
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
}
