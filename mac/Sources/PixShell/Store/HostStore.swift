import Foundation

/// 主机列表持久化：JSON 存 ~/Library/Application Support/PixShell/hosts.json。
/// 另存"最近连接历史"(recents)：一串主机 id，供快速连接落地页展示。
final class HostStore {
    private(set) var hosts: [Host] = []
    private(set) var recents: [String] = []   // 最近连接的主机 id（最新在前）
    private let url: URL
    private let recentsURL: URL
    /// 串行后台写盘队列：save() 不在主线程做磁盘 IO（文件大/磁盘忙时会卡 UI）。
    private let ioQueue = DispatchQueue(label: "com.pixshell.hoststore.io", qos: .utility)

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("PixShell", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("hosts.json")
        recentsURL = dir.appendingPathComponent("recents.json")
        load()
    }

    func load() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Host].self, from: data) {
            hosts = decoded
        } else { hosts = [] }
        if let data = try? Data(contentsOf: recentsURL),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            recents = ids
        } else { recents = [] }
        // 首次运行：把已保存的主机作为初始历史，避免落地页空白。
        if recents.isEmpty, !hosts.isEmpty { recents = hosts.map { $0.id }; saveRecents() }
        // 清理已删除主机的历史残留。
        let valid = Set(hosts.map { $0.id })
        recents.removeAll { !valid.contains($0) }
    }

    // 快速连接落地页的卡片来源：按历史顺序映射到现存主机。
    var recentHosts: [Host] {
        recents.compactMap { id in hosts.first { $0.id == id } }
    }

    func noteRecent(_ id: String) {
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        saveRecents()
    }
    func clearRecents() { recents = []; saveRecents() }
    private func saveRecents() {
        let data = try? JSONEncoder().encode(recents)
        let u = recentsURL
        ioQueue.async { if let data { try? data.write(to: u, options: .atomic) } }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try? encoder.encode(hosts)
        let u = url
        ioQueue.async { if let data { try? data.write(to: u, options: .atomic) } }
    }

    func upsert(_ h: Host) {
        if let i = hosts.firstIndex(where: { $0.id == h.id }) { hosts[i] = h }
        else { hosts.append(h) }
        save()
    }

    func delete(_ id: String) {
        hosts.removeAll { $0.id == id }
        recents.removeAll { $0 == id }; saveRecents()
        save()
    }
}
