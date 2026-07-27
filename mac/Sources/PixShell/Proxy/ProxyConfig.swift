import Foundation

/// 代理类型。字段/归一化规则对齐老仓库 packages/proxy/src/index.js (createProxy/normalizeProxyType)。
///
/// 关于 `sshJump`：老仓库还有一种"跳板机"代理(通过另一台 SSH 主机中转)。真正实现跳板逻辑
/// (在跳板机上再开一个 forward channel)不在本次范围内。这里仍保留该 case——纯粹是为了让
/// **老配置文件**(type 是字符串 "ssh-jump" 或历史数字码 200)解码时不失败、不丢数据；
/// 拨号时(见 NIOSSHSession.connectAndOpenShell)一旦遇到 `.sshJump` 一律当作"未配置代理"处理：
/// 记一条 Log.warn 后直接走原来的直连路径，绝不假装成 SOCKS 去连一个跳板机地址(那样只会挂住/报错)。
/// 管理面板(ProxyPanel)新建/编辑时也只暴露 socks5/socks4/http 三种可选类型。
public enum ProxyType: String, Codable, Sendable {
    case socks5
    case socks4
    case http
    case sshJump = "ssh-jump"
}

/// 代理配置模型。默认值/端口规则与 JS createProxy/defaultPort 1:1 对齐。
/// 显式 Sendable：挂在 `SSHCredentials`(public, Sendable) 上，字段又全是值类型，理应可以安全跨线程传递。
public struct ProxyConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var type: ProxyType
    public var host: String
    public var port: Int
    public var username: String
    public var password: String

    public init(id: String = ProxyConfig.newId(), name: String = "proxy", type: ProxyType = .socks5,
                host: String = "", port: Int = 0, username: String = "", password: String = "") {
        self.id = id
        self.name = name.isEmpty ? "proxy" : name
        self.type = type
        self.host = host
        self.port = port > 0 ? port : ProxyConfig.defaultPort(for: type)
        self.username = username
        self.password = password
    }

    enum CodingKeys: String, CodingKey { case id, name, type, host, port, username, password }

    // 自定义解码：容错优先——任何字段缺失/类型对不上都不应让整条代理记录解析失败(顶多退化成默认值)。
    // 尤其是 `type`：老配置里可能是字符串("socks5"/"http"/"ssh-jump")，也可能是历史数字码(100/200)。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ProxyConfig.newId()
        let rawName = (try? c.decode(String.self, forKey: .name)) ?? "proxy"
        name = rawName.isEmpty ? "proxy" : rawName
        let normalizedType = ProxyConfig.normalizeProxyType(ProxyConfig.decodeRawType(c))
        type = normalizedType
        host = (try? c.decode(String.self, forKey: .host)) ?? ""
        let rawPort = (try? c.decode(Int.self, forKey: .port)) ?? 0
        port = rawPort > 0 ? rawPort : ProxyConfig.defaultPort(for: normalizedType)
        username = (try? c.decode(String.self, forKey: .username)) ?? ""
        password = (try? c.decode(String.self, forKey: .password)) ?? ""
    }

    /// type 字段可能是 String 也可能是 Int(老历史数字码)，两种都试一遍，都不行就空串
    /// (交给 normalizeProxyType 兜底成 socks5)。
    private static func decodeRawType(_ c: KeyedDecodingContainer<CodingKeys>) -> String {
        if let s = try? c.decode(String.self, forKey: .type) { return s }
        if let n = try? c.decode(Int.self, forKey: .type) { return String(n) }
        return ""
    }

    /// 对齐 JS normalizeProxyType：100→socks5、200→ssh-jump(历史数字码)，
    /// 合法字符串原样识别，其余一律回落 socks5。
    static func normalizeProxyType(_ raw: String) -> ProxyType {
        switch raw {
        case "100": return .socks5
        case "200": return .sshJump
        case "socks4": return .socks4
        case "socks5": return .socks5
        case "http": return .http
        case "ssh-jump": return .sshJump
        default: return .socks5
        }
    }

    /// 对齐 JS defaultPort。
    static func defaultPort(for type: ProxyType) -> Int {
        switch type {
        case .http: return 8080
        case .sshJump: return 22
        case .socks4, .socks5: return 1080
        }
    }

    /// 对齐 JS `'px_' + Date.now().toString(36)`。公开：作为 public init 的默认参数值必须可见。
    public static func newId() -> String {
        "px_" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
    }
}

/// 代理列表持久化：`~/Library/Application Support/PixShell/proxies.json`。
/// 风格照抄 Store/QuickCommands.swift 的 QuickCommandStore。容错加载：
/// 文件不存在/整体解析失败 → 退回空列表，绝不因为一份坏文件崩溃或丢已有配置。
final class ProxyStore {
    private(set) var proxies: [ProxyConfig] = []
    private let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("PixShell", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("proxies.json")
        load()
    }

    private func load() {
        guard let d = try? Data(contentsOf: url) else { proxies = []; return }
        guard let a = try? JSONDecoder().decode([ProxyConfig].self, from: d) else {
            Log.warn("代理配置解析失败，使用空列表: \(url.path)", "proxy")
            proxies = []
            return
        }
        proxies = a
    }

    func save() {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(proxies) { try? d.write(to: url, options: .atomic) }
    }

    func list() -> [ProxyConfig] { proxies }

    /// 对齐 JS findProxyById：空 id 或 "0" 视为"不使用代理"。
    func find(_ id: String) -> ProxyConfig? {
        guard !id.isEmpty, id != "0" else { return nil }
        return proxies.first { $0.id == id }
    }

    func upsert(_ p: ProxyConfig) {
        if let i = proxies.firstIndex(where: { $0.id == p.id }) { proxies[i] = p } else { proxies.append(p) }
        save()
    }

    func delete(_ id: String) { proxies.removeAll { $0.id == id }; save() }
}
