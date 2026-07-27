import Foundation

// 命令框纯逻辑（1:1 移植老仓库）：
//   packages/sftp-panel/src/sync.js      → CommandSync（终端 cwd ↔ SFTP 路径同步）
//   packages/command-box/src/history.js  → CommandHistory（历史 push/导航/过滤）
//   packages/command-box/src/params.js   → CommandParams（${x} 参数模板）
// 无 UI 依赖，便于单测与复用。

// MARK: - 终端 cd ↔ SFTP 目录同步

enum CommandSync {
    /// 规整远端路径：压缩重复 `/`、去尾部 `/`；空/`~` 归一为 `.`
    static func normalizeRemotePath(_ p: String?) -> String {
        guard let p = p, !p.isEmpty, p != "~" else { return "." }
        var s = p.replacingOccurrences(of: "/+", with: "/", options: .regularExpression)
        if s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? "." : s
    }

    /// 拼接远端路径，处理 `.`、`..`、绝对路径
    static func joinRemote(_ base: String, _ name: String) -> String {
        if name.isEmpty || name == "." { return normalizeRemotePath(base) }
        if name == ".." {
            let b = normalizeRemotePath(base)
            if b == "." || b == "/" { return "." }
            var parts = b.split(separator: "/").map(String.init)
            parts.removeLast()
            return parts.isEmpty ? (base.hasPrefix("/") ? "/" : ".") : "/" + parts.joined(separator: "/")
        }
        if name.hasPrefix("/") { return normalizeRemotePath(name) }
        let b = normalizeRemotePath(base)
        if b == "." { return name }
        if b == "/" { return "/" + name }
        return b + "/" + name
    }

    /// 命令是否是 `cd …`
    static func shouldSyncCd(_ command: String) -> Bool {
        command.range(of: "^\\s*cd\\s+", options: .regularExpression) != nil
    }

    /// 取出 `cd` 的目标（去引号）；`cd` 无参数视为 `~`
    static func parseCdTarget(_ command: String) -> String? {
        guard let r = command.range(of: "^\\s*cd\\s*(.*)$", options: .regularExpression) else { return nil }
        var t = String(command[r]).replacingOccurrences(of: "^\\s*cd\\s*", with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "~" }
        t = t.replacingOccurrences(of: "^['\"]|['\"]$", with: "", options: .regularExpression)
        return t
    }

    /// 把一条命令作用到当前路径上，得到新的 SFTP 路径（非 cd 命令原样返回）
    static func applyCd(_ currentPath: String, _ command: String) -> String {
        guard shouldSyncCd(command), let target = parseCdTarget(command) else { return currentPath }
        if target == "~" || target.isEmpty { return "." }
        if target.hasPrefix("/") { return normalizeRemotePath(target) }
        return joinRemote(currentPath.isEmpty ? "." : currentPath, target)
    }
}

// MARK: - 命令历史（持久化到 Application Support）

final class CommandHistory {
    private(set) var items: [String] = []
    private var index: Int = -1        // -1 表示"未在浏览历史"（即草稿态）
    private var draft: String = ""
    private let limit = 500
    private let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("PixShell", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("cmd-history.json")
        if let d = try? Data(contentsOf: url), let a = try? JSONDecoder().decode([String].self, from: d) { items = a }
    }

    /// 新命令置顶去重（对齐老仓库 pushHistory）
    func push(_ cmd: String) {
        let c = cmd.replacingOccurrences(of: "\n+$", with: "", options: .regularExpression)
        guard !c.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        items = [c] + items.filter { $0 != c }
        if items.count > limit { items = Array(items.prefix(limit)) }
        save()
        resetCursor()
    }

    func resetCursor() { index = -1; draft = "" }

    /// ↑ 更旧；current 为当前输入框内容（首次上翻时记为草稿）
    func older(current: String) -> String {
        if index < 0 { draft = current }
        guard !items.isEmpty else { return current }
        let ni = min(items.count - 1, index + 1)
        index = ni
        return items[ni]
    }

    /// ↓ 更新；回到草稿
    func newer() -> String {
        if index <= 0 { index = -1; return draft }
        index -= 1
        return items[index]
    }

    /// 前缀/包含过滤（历史弹出用）
    func filter(prefix: String, limit: Int = 20) -> [String] {
        let p = prefix
        return items.filter { p.isEmpty || $0.hasPrefix(p) || $0.contains(p) }.prefix(limit).map { $0 }
    }

    /// 删除特定索引的历史
    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        save()
        resetCursor()
    }

    /// 根据内容删除特定历史
    func remove(item: String) {
        if let idx = items.firstIndex(of: item) {
            remove(at: idx)
        }
    }

    /// 清空所有历史记录
    func clear() {
        items.removeAll()
        save()
        resetCursor()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: url, options: .atomic) }
    }
}

// MARK: - 自定义命令参数模板 `${name}`

enum CommandParams {
    /// 取出模板里的参数名（去重、保序）
    static func parse(_ template: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "\\$\\{([a-zA-Z0-9_]+)\\}") else { return [] }
        let ns = template as NSString
        var names: [String] = []
        for m in re.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            let n = ns.substring(with: m.range(at: 1))
            if !names.contains(n) { names.append(n) }
        }
        return names
    }

    /// 用取值渲染模板；缺失的占位符原样保留
    static func render(_ template: String, values: [String: String]) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\$\\{([a-zA-Z0-9_]+)\\}") else { return template }
        let ns = template as NSString
        var out = ""
        var idx = 0
        for m in re.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: idx, length: m.range.location - idx))
            let key = ns.substring(with: m.range(at: 1))
            out += values[key] ?? ns.substring(with: m.range)
            idx = m.range.location + m.range.length
        }
        if idx < ns.length { out += ns.substring(from: idx) }
        return out
    }

    static func hasUnresolved(_ template: String) -> Bool { !parse(template).isEmpty }
}
