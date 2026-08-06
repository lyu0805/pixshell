import Foundation

/// 主机列表持久化：JSON 存 ~/Library/Application Support/PixShell/hosts.json。
/// 另存"最近连接历史"(recents)：一串主机 id，供快速连接落地页展示。
final class HostStore {
    private(set) var hosts: [Host] = []
    var onChange: (() -> Void)?
    private(set) var recents: [String] = []   // 最近连接的主机 id（最新在前）
    private let url: URL
    private let recentsURL: URL

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
        if let data = try? JSONEncoder().encode(recents) { try? data.write(to: recentsURL, options: .atomic) }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(hosts) {
            try? data.write(to: url, options: .atomic)
            onChange?()
        }
    }

    func replaceAll(_ newHosts: [Host]) {
        hosts = newHosts
        let valid = Set(hosts.map(\.id))
        recents.removeAll { !valid.contains($0) }
        saveRecents(); save()
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

    /// 分组顺序由 hosts.json 中该组首次出现的位置决定。
    func moveGroup(_ source: String, before target: String) {
        guard source != target else { return }
        let groupName: (Host) -> String = { $0.group.isEmpty ? "默认" : $0.group }
        var names: [String] = []
        for h in hosts where !names.contains(groupName(h)) { names.append(groupName(h)) }
        guard let from = names.firstIndex(of: source), let targetIndex = names.firstIndex(of: target) else { return }
        names.remove(at: from)
        // 拖到目标行：向上放到目标前，向下放到目标后。
        // 旧实现向下拖到相邻行时会插回原位，看起来像拖动完全无效。
        names.insert(source, at: from < targetIndex ? targetIndex : targetIndex)
        let rank = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, $0.offset) })
        hosts = hosts.enumerated().sorted {
            let left = rank[groupName($0.element)] ?? Int.max
            let right = rank[groupName($1.element)] ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
        save()
    }

    /// 仅允许在同一分组内拖动主机，手动顺序直接持久化。
    func moveHost(_ source: String, before target: String) {
        guard source != target,
              let from = hosts.firstIndex(where: { $0.id == source }),
              let to = hosts.firstIndex(where: { $0.id == target }) else { return }
        let sourceGroup = hosts[from].group.isEmpty ? "默认" : hosts[from].group
        let targetGroup = hosts[to].group.isEmpty ? "默认" : hosts[to].group
        guard sourceGroup == targetGroup else { return }
        let movingDown = from < to
        let item = hosts.remove(at: from)
        let targetAfterRemoval = hosts.firstIndex(where: { $0.id == target }) ?? hosts.endIndex
        let insertion = movingDown ? min(targetAfterRemoval + 1, hosts.endIndex) : targetAfterRemoval
        hosts.insert(item, at: insertion)
        save()
    }
}
