import Foundation

/// 文件日志（对齐老仓库 packages/app/main/logger.js 的契约）：
///   1) `<userData>/logs/pixshell-YYYY-MM-DD.log`   —— 按天归档
///   2) `<userData>/logs/pixshell-runtime.log`      —— 运行时主日志，滚动保留最近 1000 行
/// 位置：`~/Library/Application Support/PixShell/logs/`
/// 铁律：**绝不把异常抛回调用方**（任何写失败都静默降级），日志本身不能拖垮 App。
enum Log {
    enum Level: Int { case error = 0, warn = 1, info = 2, debug = 3
        var tag: String {
            switch self { case .error: return "ERROR"; case .warn: return "WARN"; case .info: return "INFO"; case .debug: return "DEBUG" }
        }
    }

    static var minLevel: Level = .debug
    private static let maxRuntimeLines = 1000
    private static let queue = DispatchQueue(label: "com.pixshell.log")
    private static var seq = 0

    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("PixShell/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static let isoFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    static func error(_ m: @autoclosure () -> String, _ tag: String = "") { write(.error, tag, m()) }
    static func warn(_ m: @autoclosure () -> String, _ tag: String = "")  { write(.warn, tag, m()) }
    static func info(_ m: @autoclosure () -> String, _ tag: String = "")  { write(.info, tag, m()) }
    static func debug(_ m: @autoclosure () -> String, _ tag: String = "") { write(.debug, tag, m()) }

    private static func write(_ level: Level, _ tag: String, _ msg: String) {
        guard level.rawValue <= minLevel.rawValue else { return }
        let now = Date()
        let line = "\(isoFmt.string(from: now)) [\(level.tag)]\(tag.isEmpty ? "" : " [\(tag)]") \(msg)\n"
        queue.async {
            seq += 1
            let daily = dir.appendingPathComponent("pixshell-\(dayFmt.string(from: now)).log")
            append(line, to: daily)
            let runtime = dir.appendingPathComponent("pixshell-runtime.log")
            append(line, to: runtime)
            if seq % 50 == 0 { trimRuntime(runtime) }   // 每 50 行检查一次滚动，避免频繁重写
        }
    }

    private static func append(_ line: String, to url: URL) {
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 运行时日志只保留最近 N 行
    private static func trimRuntime(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        guard lines.count > maxRuntimeLines + 200 else { return }
        lines = Array(lines.suffix(maxRuntimeLines))
        try? lines.joined(separator: "\n").data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// 启动横幅：便于在日志里区分每次运行
    static func banner(_ version: String) {
        info("==== PixShell \(version) 启动 · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) ====", "app")
        info("日志目录 \(dir.path)", "app")
    }
}
