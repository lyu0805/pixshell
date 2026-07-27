import Foundation

/// 智能打包传输（1:1 移植老仓库 native-102 的 downloadSmart / upload autoPack）。
/// 触发条件：多项、目录、或单文件 ≥ 8MB。
/// 下载：远端 `tar -czf`（逐项 `-C parent base`，避免绝对路径进包）→ 下载压缩包 → 本地解压 → 两端删临时包。
/// 上传：本地 `tar -czf` → 上传 → 远端 `tar -xzf` + 删包。
enum SFTPTransfer {
    /// 老仓库 TRANSFER_PACK_BYTES
    static let packThreshold: UInt64 = 8 * 1024 * 1024

    /// shell 单引号转义（与老仓库 shellQuote 等价）
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 是否需要打包：多项 / 含目录 / 单文件超阈值
    static func shouldPack(_ items: [SFTPEntry]) -> Bool {
        if items.count > 1 { return true }
        guard let one = items.first else { return false }
        return one.isDir || one.size >= packThreshold
    }

    /// 构造远端打包命令：逐项 `-C 父目录 basename`
    static func packCommand(archive: String, remotePaths: [String]) -> String {
        let parts = remotePaths.map { rp -> String in
            let norm = rp.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            let path = norm.isEmpty ? "/" : norm
            let base = (path as NSString).lastPathComponent
            var parent = (path as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == "." { parent = "/" }
            return "-C \(quote(parent)) \(quote(base.isEmpty ? path : base))"
        }.joined(separator: " ")
        return "tar -czf \(quote(archive)) \(parts) 2>&1"
    }

    /// 本地解压到目标目录（返回错误描述，nil 表示成功）
    static func extractLocal(archive: String, into dir: String) -> String? {
        run("/usr/bin/tar", ["-xzf", archive, "-C", dir])
    }
    /// 本地打包（多项 → 一个 .tar.gz）
    static func packLocal(archive: String, files: [URL]) -> String? {
        guard let first = files.first else { return "无文件" }
        let parent = first.deletingLastPathComponent().path
        var args = ["-czf", archive, "-C", parent]
        args.append(contentsOf: files.map { $0.lastPathComponent })
        return run("/usr/bin/tar", args)
    }

    @discardableResult
    private static func run(_ launch: String, _ args: [String]) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: launch); p.arguments = args
        let pipe = Pipe(); p.standardError = pipe; p.standardOutput = pipe
        do { try p.run() } catch { return error.localizedDescription }
        p.waitUntilExit()
        if p.terminationStatus == 0 { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.isEmpty ? "tar 退出码 \(p.terminationStatus)" : out
    }

    /// 生成唯一临时包名（不用 Date().timeIntervalSince1970 之外的随机源，保证可读）
    static func stamp() -> String {
        String(Int(Date().timeIntervalSince1970 * 1000))
    }
}
