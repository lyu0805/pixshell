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

    /// 构造远端打包命令：逐项 `-C 父目录 basename`；末尾回传 `__PIXSHELL_RC:<code>` 供调用方判定成败
    /// （`ssh.exec` 只回 stdout 文本，不带 exit code）。
    static func packCommand(archive: String, remotePaths: [String]) -> String {
        let parts = remotePaths.map { rp -> String in
            let norm = rp.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            let path = norm.isEmpty ? "/" : norm
            let base = (path as NSString).lastPathComponent
            var parent = (path as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == "." { parent = "/" }
            return "-C \(quote(parent)) \(quote(base.isEmpty ? path : base))"
        }.joined(separator: " ")
        return "tar -czf \(quote(archive)) \(parts) 2>&1; echo __PIXSHELL_RC:$?"
    }

    /// 远端解压命令：解压后删临时包，并回传 tar 的真实退出码（rm 不影响 RC）
    static func extractCommand(archive: String, into remoteDir: String) -> String {
        let arc = quote(archive)
        let dst = quote(remoteDir)
        return "tar -xzf \(arc) -C \(dst) 2>&1; rc=$?; rm -f \(arc); echo __PIXSHELL_RC:$rc"
    }

    /// 解析 `ssh.exec` 输出里的 `__PIXSHELL_RC:N`。
    /// 打包/解压**必须**有标记：空输出或无标记一律失败（旧「空=成功」会把未执行的 extract 当绿）。
    static func parseRemoteRC(_ out: String) -> (code: Int, message: String) {
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: #"__PIXSHELL_RC:(-?\d+)\s*$"#, options: .regularExpression) {
            let tail = String(trimmed[range])
            let msg = trimmed[..<range.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let num = tail.replacingOccurrences(of: "__PIXSHELL_RC:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (Int(num) ?? 1, String(msg))
        }
        // 无标记：空（exec 失败/超时）与有文本都当失败
        if trimmed.isEmpty {
            return (1, "远端无 __PIXSHELL_RC 回执（命令未执行或通道失败）")
        }
        return (1, trimmed)
    }

    /// 本地解压到目标目录（返回错误描述，nil 表示成功）
    static func extractLocal(archive: String, into dir: String) -> String? {
        run("/usr/bin/tar", ["-xzf", archive, "-C", dir])
    }
    /// 本地打包（多项 → 一个 .tar.gz）。逐项 `-C 父目录 basename`，支持跨目录多选。
    static func packLocal(archive: String, files: [URL]) -> String? {
        guard !files.isEmpty else { return "无文件" }
        var args = ["-czf", archive]
        for u in files {
            let parent = u.deletingLastPathComponent().path
            let base = u.lastPathComponent
            args.append(contentsOf: ["-C", parent.isEmpty ? "/" : parent, base])
        }
        return run("/usr/bin/tar", args)
    }

    @discardableResult
    private static func run(_ launch: String, _ args: [String]) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: launch); p.arguments = args
        let pipe = Pipe(); p.standardError = pipe; p.standardOutput = pipe
        do { try p.run() } catch { return error.localizedDescription }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus == 0 { return nil }
        let out = String(data: output, encoding: .utf8) ?? ""
        return out.isEmpty ? "tar 退出码 \(p.terminationStatus)" : out
    }

    /// 生成唯一临时包名（不用 Date().timeIntervalSince1970 之外的随机源，保证可读）
    static func stamp() -> String {
        String(Int(Date().timeIntervalSince1970 * 1000))
    }
}
