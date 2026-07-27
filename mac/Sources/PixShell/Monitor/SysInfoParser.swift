import Foundation

/// 系统信息采集文本解析：纯逻辑，无 AppKit 依赖，方便单测。
/// 输入是 `SysInfoPanel.command` 采集回来的 `KEY=value` 文本（表格类字段用 `KEY=a\tb\tc` 重复行）。
/// 任何字段缺失/格式异常都不应崩溃：一律退化为 nil / 空数组。
enum SysInfoParser {

    /// CPU 一栏：型号 + 核数 + 频率/缓存/BogoMIPS + 占用率拆分。
    struct CPUInfo {
        var model: String?
        var cores: Int?
        var mhz: String?
        var cache: String?
        var bogomips: String?
        var busyPct: Double?
        var userPct: Double?
        var systemPct: Double?
        var idlePct: Double?
        var iowaitPct: Double?
    }

    /// 网卡一行：名称 / IPv4 / MAC / 收发字节数。
    struct NetRow {
        var name: String
        var ip: String?
        var mac: String?
        var rxBytes: Int64?
        var txBytes: Int64?
    }

    /// 磁盘一行：挂载点 / 容量 / 已用 / 可用 / 使用率 / 文件系统。
    struct DiskRow {
        var mount: String
        var size: String?
        var used: String?
        var avail: String?
        var pct: Int?
        var fs: String?
    }

    struct SysInfo {
        // 基本
        var hostname: String?
        var distro: String?
        var kernel: String?
        var arch: String?
        var uptime: String?
        var load: String?
        var ip: String?
        // CPU
        var cpu = CPUInfo()
        // 内存 / 交换
        var memPct: Int?
        var memUsedMB: Int?
        var memTotalMB: Int?
        var swapPct: Int?
        var swapUsedMB: Int?
        var swapTotalMB: Int?
        // 表格
        var net: [NetRow] = []
        var disks: [DiskRow] = []
    }

    /// 解析采集文本；未知/缺失/损坏的行一律跳过，永不崩溃。
    static func parse(_ raw: String) -> SysInfo {
        var info = SysInfo()
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            let value = String(line[line.index(after: eq)...])
            apply(key: key, value: value, into: &info)
        }
        return info
    }

    private static func apply(key: String, value: String, into info: inout SysInfo) {
        switch key {
        case "hostname": info.hostname = nonEmpty(value)
        case "distro": info.distro = nonEmpty(value)
        case "kernel": info.kernel = nonEmpty(value)
        case "arch": info.arch = nonEmpty(value)
        case "uptime": info.uptime = nonEmpty(value)
        case "load": info.load = nonEmpty(value)
        case "ip": info.ip = nonEmpty(value)
        case "cpu_model": info.cpu.model = nonEmpty(value)
        case "cpu_cores": info.cpu.cores = Int(value.trimmingCharacters(in: .whitespaces))
        case "cpu_mhz": info.cpu.mhz = nonEmpty(value)
        case "cpu_cache": info.cpu.cache = nonEmpty(value)
        case "cpu_bogomips": info.cpu.bogomips = nonEmpty(value)
        case "cpu_busy": info.cpu.busyPct = Double(value)
        case "cpu_user": info.cpu.userPct = Double(value)
        case "cpu_system": info.cpu.systemPct = Double(value)
        case "cpu_idle": info.cpu.idlePct = Double(value)
        case "cpu_iowait": info.cpu.iowaitPct = Double(value)
        case "mem_pct": info.memPct = Int(value)
        case "mem_used_mb": info.memUsedMB = Int(value)
        case "mem_total_mb": info.memTotalMB = Int(value)
        case "swap_pct": info.swapPct = Int(value)
        case "swap_used_mb": info.swapUsedMB = Int(value)
        case "swap_total_mb": info.swapTotalMB = Int(value)
        case "net_row":
            let f = value.components(separatedBy: "\t")
            guard let name = f.first, !name.isEmpty else { return }
            let row = NetRow(
                name: name,
                ip: f.count > 1 ? nonEmpty(f[1]) : nil,
                mac: f.count > 2 ? nonEmpty(f[2]) : nil,
                rxBytes: f.count > 3 ? Int64(f[3]) : nil,
                txBytes: f.count > 4 ? Int64(f[4]) : nil
            )
            info.net.append(row)
        case "disk_row":
            let f = value.components(separatedBy: "\t")
            guard let mount = f.first, !mount.isEmpty else { return }
            let pctStr = f.count > 4 ? f[4].replacingOccurrences(of: "%", with: "") : ""
            let row = DiskRow(
                mount: mount,
                size: f.count > 1 ? nonEmpty(f[1]) : nil,
                used: f.count > 2 ? nonEmpty(f[2]) : nil,
                avail: f.count > 3 ? nonEmpty(f[3]) : nil,
                pct: Int(pctStr),
                fs: f.count > 5 ? nonEmpty(f[5]) : nil
            )
            info.disks.append(row)
        default:
            break // 未知 key：忽略，兼容未来新增字段
        }
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return (t.isEmpty || t == "-") ? nil : t
    }

    /// 字节数转人类可读（KB/MB/GB），用于网卡 rx/tx 展示。
    static func formatBytes(_ n: Int64?) -> String {
        guard let n = n, n >= 0 else { return "-" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(n)
        var i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(n) B" : String(format: "%.1f %@", v, units[i])
    }
}
