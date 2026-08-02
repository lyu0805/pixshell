import Foundation

/// 快捷命令模型（对齐老仓库 packages/quick-commands + core 的 QuickCommand）
struct QuickParam: Codable, Equatable {
    var name: String
    var defaultValue: String?
    var required: Bool?
}

struct QuickCommand: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var group: String
    var command: String
    var params: [QuickParam]?

    init(id: String = UUID().uuidString, name: String, group: String = "默认",
         command: String, params: [QuickParam]? = nil) {
        self.id = id; self.name = name; self.group = group; self.command = command; self.params = params
    }
}

/// 快捷命令持久化 + 分组/渲染逻辑（移植老仓库 QuickCommandPanel）
final class QuickCommandStore {
    private(set) var commands: [QuickCommand] = []
    /// 显式分组表。**必须单独存**：分组光靠命令的 group 字段派生的话，
    /// 新建一个还没放命令的空分组会立刻消失。这里记住用户建过的空分组。
    private(set) var emptyGroups: [String] = []
    private let url: URL
    private let groupsURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("PixShell", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("quick-commands.json")
        groupsURL = dir.appendingPathComponent("quick-command-groups.json")
        load()
    }

    private func load() {
        if FileManager.default.fileExists(atPath: url.path) {
            if let d = try? Data(contentsOf: url), let a = try? JSONDecoder().decode([QuickCommand].self, from: d) {
                commands = a
            }
        } else {
            commands = Self.defaults
            save()
        }
        if let d = try? Data(contentsOf: groupsURL), let a = try? JSONDecoder().decode([String].self, from: d) {
            emptyGroups = a
        }
    }
    func save() {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(commands) { try? d.write(to: url, options: .atomic) }
    }
    private func saveGroups() {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted]
        if let d = try? e.encode(emptyGroups) { try? d.write(to: groupsURL, options: .atomic) }
    }

    /// 分组 = 显式建过的 ∪ 命令里出现过的（都按首次出现保序）
    func groups() -> [String] {
        var seen = Set<String>(), out: [String] = []
        for g in emptyGroups where !seen.contains(g) { seen.insert(g); out.append(g) }
        for c in commands {
            let g = c.group.isEmpty ? "默认" : c.group
            if !seen.contains(g) { seen.insert(g); out.append(g) }
        }
        return out
    }

    /// 新建分组。已存在返回 false（调用方据此提示）。
    @discardableResult
    func addGroup(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !groups().contains(n) else { return false }
        emptyGroups.append(n); saveGroups()
        return true
    }

    /// 删除分组：里面的命令一并挪回「默认」，**不连带删命令**（需单独执行删除命令）。
    func removeGroup(_ name: String) {
        emptyGroups.removeAll { $0 == name }
        for i in commands.indices where (commands[i].group.isEmpty ? "默认" : commands[i].group) == name {
            commands[i].group = "默认"
        }
        saveGroups(); save()
    }

    /// 重命名分组：分组名就存在每条命令里，所以要逐条改。
    func renameGroup(_ old: String, to new: String) {
        let n = new.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != old, !groups().contains(n) else { return }
        if let i = emptyGroups.firstIndex(of: old) { emptyGroups[i] = n }
        for i in commands.indices where (commands[i].group.isEmpty ? "默认" : commands[i].group) == old {
            commands[i].group = n
        }
        saveGroups(); save()
    }

    /// 把一条命令移到某个分组
    func move(_ id: String, to group: String) {
        guard let i = commands.firstIndex(where: { $0.id == id }) else { return }
        commands[i].group = group.isEmpty ? "默认" : group
        save()
    }

    func list(group: String?) -> [QuickCommand] {
        guard let g = group, !g.isEmpty else { return commands }
        return commands.filter { ($0.group.isEmpty ? "默认" : $0.group) == g }
    }
    func upsert(_ c: QuickCommand) {
        if let i = commands.firstIndex(where: { $0.id == c.id }) { commands[i] = c } else { commands.append(c) }
        save()
    }
    func delete(_ id: String) { commands.removeAll { $0.id == id }; save() }

    /// 用给定取值 + 参数默认值渲染模板（老仓库 render）
    func render(_ c: QuickCommand, params: [String: String] = [:]) -> String {
        var out = c.command
        for (k, v) in params { out = out.replacingOccurrences(of: "${\(k)}", with: v) }
        for p in c.params ?? [] {
            if let dv = p.defaultValue, out.contains("${\(p.name)}") {
                out = out.replacingOccurrences(of: "${\(p.name)}", with: dv)
            }
        }
        return out
    }

    /// 老仓库 DEMO_QUICK_COMMANDS 同款默认集
    static let defaults: [QuickCommand] = [
        .init(id: "qc1", name: "磁盘", group: "系统", command: "df -h"),
        .init(id: "qc2", name: "内存", group: "系统", command: "free -m"),
        .init(id: "qc3", name: "进程TOP", group: "系统", command: "ps aux --sort=-%cpu | head -20"),
        .init(id: "qc7", name: "端口监听", group: "系统", command: "ss -tulnp"),
        .init(id: "qc4", name: "Nginx 重载", group: "服务", command: "sudo systemctl reload nginx"),
        .init(id: "qc5", name: "看日志", group: "服务",
              command: "sudo tail -n ${lines} -f ${file}",
              params: [.init(name: "lines", defaultValue: "100", required: false),
                       .init(name: "file", defaultValue: "/var/log/nginx/error.log", required: true)]),
        .init(id: "qc6", name: "Docker PS", group: "容器",
              command: "docker ps --format \"table {{.Names}}\\t{{.Status}}\\t{{.Ports}}\""),
        // Rust 工具链：远端跑 cargo 的常用动作。输出会被语义高亮认出来
        // （error[E0382] / --> src/x.rs:12:9 / Compiling / test result: 见 SemanticHighlight）。
        .init(id: "rs1", name: "cargo build", group: "Rust", command: "cargo build ${flags}",
              params: [.init(name: "flags", defaultValue: "--release", required: false)]),
        .init(id: "rs2", name: "cargo test", group: "Rust", command: "cargo test ${args}",
              params: [.init(name: "args", defaultValue: "", required: false)]),
        .init(id: "rs3", name: "cargo clippy", group: "Rust",
              command: "cargo clippy --all-targets -- -D warnings"),
        .init(id: "rs4", name: "cargo fmt 检查", group: "Rust", command: "cargo fmt --all -- --check"),
        .init(id: "rs5", name: "cargo run", group: "Rust", command: "cargo run ${args}",
              params: [.init(name: "args", defaultValue: "", required: false)]),
        .init(id: "rs6", name: "工具链版本", group: "Rust",
              command: "rustc -Vv; cargo -V; rustup show active-toolchain 2>/dev/null"),
    ]
}

/// 发送目标（老仓库 #cmdTarget）
enum SendTarget: Equatable {
    case current
    case allConnected
    case session(Int)   // 会话下标
}
