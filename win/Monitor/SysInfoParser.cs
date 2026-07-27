using System;
using System.Collections.Generic;
using System.Globalization;

namespace PixShell.Monitor;

/// <summary>
/// 系统信息采集文本解析：纯逻辑，无 UI 依赖，字段与解析规则 1:1 对齐 mac 版
/// Monitor/SysInfoParser.swift。输入是 <see cref="PixShell.UI.SysInfoWindow.Command"/>
/// 采集回来的 `KEY=value` 文本（表格类字段用 `KEY=a\tb\tc\td\te` 重复行）。
/// 任何字段缺失/格式异常都不应崩溃：一律退化为 null / 空列表。
/// </summary>
public static class SysInfoParser
{
    /// <summary>CPU 一栏：型号 + 核数 + 频率/缓存/BogoMIPS + 占用率拆分。</summary>
    public sealed class CpuInfo
    {
        public string? Model;
        public int? Cores;
        public string? Mhz;
        public string? Cache;
        public string? Bogomips;
        public double? BusyPct;
        public double? UserPct;
        public double? SystemPct;
        public double? IdlePct;
        public double? IowaitPct;
    }

    /// <summary>网卡一行：名称 / IPv4 / MAC / 收发字节数。</summary>
    public sealed class NetRow
    {
        public string Name = "";
        public string? Ip;
        public string? Mac;
        public long? RxBytes;
        public long? TxBytes;
    }

    /// <summary>磁盘一行：挂载点 / 容量 / 已用 / 可用 / 使用率 / 文件系统。</summary>
    public sealed class DiskRow
    {
        public string Mount = "";
        public string? Size;
        public string? Used;
        public string? Avail;
        public int? Pct;
        public string? Fs;
    }

    public sealed class SysInfo
    {
        // 基本
        public string? Hostname;
        public string? Distro;
        public string? Kernel;
        public string? Arch;
        public string? Uptime;
        public string? Load;
        public string? Ip;
        // CPU
        public CpuInfo Cpu = new();
        // 内存 / 交换
        public int? MemPct;
        public int? MemUsedMb;
        public int? MemTotalMb;
        public int? SwapPct;
        public int? SwapUsedMb;
        public int? SwapTotalMb;
        // 表格
        public List<NetRow> Net = new();
        public List<DiskRow> Disks = new();
    }

    /// <summary>解析采集文本；未知/缺失/损坏的行一律跳过，永不崩溃。</summary>
    public static SysInfo Parse(string raw)
    {
        var info = new SysInfo();
        if (string.IsNullOrEmpty(raw)) return info;
        foreach (var rawLine in raw.Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.Length == 0) continue;
            var eq = line.IndexOf('=');
            if (eq < 0) continue;
            var key = line[..eq];
            var value = line[(eq + 1)..];
            Apply(key, value, info);
        }
        return info;
    }

    private static void Apply(string key, string value, SysInfo info)
    {
        switch (key)
        {
            case "hostname": info.Hostname = NonEmpty(value); break;
            case "distro": info.Distro = NonEmpty(value); break;
            case "kernel": info.Kernel = NonEmpty(value); break;
            case "arch": info.Arch = NonEmpty(value); break;
            case "uptime": info.Uptime = NonEmpty(value); break;
            case "load": info.Load = NonEmpty(value); break;
            case "ip": info.Ip = NonEmpty(value); break;
            case "cpu_model": info.Cpu.Model = NonEmpty(value); break;
            case "cpu_cores": info.Cpu.Cores = ParseInt(value); break;
            case "cpu_mhz": info.Cpu.Mhz = NonEmpty(value); break;
            case "cpu_cache": info.Cpu.Cache = NonEmpty(value); break;
            case "cpu_bogomips": info.Cpu.Bogomips = NonEmpty(value); break;
            case "cpu_busy": info.Cpu.BusyPct = ParseDouble(value); break;
            case "cpu_user": info.Cpu.UserPct = ParseDouble(value); break;
            case "cpu_system": info.Cpu.SystemPct = ParseDouble(value); break;
            case "cpu_idle": info.Cpu.IdlePct = ParseDouble(value); break;
            case "cpu_iowait": info.Cpu.IowaitPct = ParseDouble(value); break;
            case "mem_pct": info.MemPct = ParseInt(value); break;
            case "mem_used_mb": info.MemUsedMb = ParseInt(value); break;
            case "mem_total_mb": info.MemTotalMb = ParseInt(value); break;
            case "swap_pct": info.SwapPct = ParseInt(value); break;
            case "swap_used_mb": info.SwapUsedMb = ParseInt(value); break;
            case "swap_total_mb": info.SwapTotalMb = ParseInt(value); break;
            case "net_row":
            {
                var f = value.Split('\t');
                if (f.Length == 0 || f[0].Length == 0) return;
                info.Net.Add(new NetRow
                {
                    Name = f[0],
                    Ip = f.Length > 1 ? NonEmpty(f[1]) : null,
                    Mac = f.Length > 2 ? NonEmpty(f[2]) : null,
                    RxBytes = f.Length > 3 ? ParseLong(f[3]) : null,
                    TxBytes = f.Length > 4 ? ParseLong(f[4]) : null,
                });
                break;
            }
            case "disk_row":
            {
                var f = value.Split('\t');
                if (f.Length == 0 || f[0].Length == 0) return;
                var pctStr = f.Length > 4 ? f[4].Replace("%", "") : "";
                info.Disks.Add(new DiskRow
                {
                    Mount = f[0],
                    Size = f.Length > 1 ? NonEmpty(f[1]) : null,
                    Used = f.Length > 2 ? NonEmpty(f[2]) : null,
                    Avail = f.Length > 3 ? NonEmpty(f[3]) : null,
                    Pct = ParseInt(pctStr),
                    Fs = f.Length > 5 ? NonEmpty(f[5]) : null,
                });
                break;
            }
            default:
                break; // 未知 key：忽略，兼容未来新增字段
        }
    }

    private static string? NonEmpty(string s)
    {
        var t = s.Trim();
        return (t.Length == 0 || t == "-") ? null : t;
    }

    private static int? ParseInt(string s) =>
        int.TryParse(s.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : null;

    private static long? ParseLong(string s) =>
        long.TryParse(s.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : null;

    private static double? ParseDouble(string s) =>
        double.TryParse(s.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : null;

    /// <summary>字节数转人类可读（KB/MB/GB），用于网卡 rx/tx 展示。</summary>
    public static string FormatBytes(long? n)
    {
        if (n is null || n < 0) return "-";
        string[] units = { "B", "KB", "MB", "GB", "TB" };
        double v = n.Value;
        int i = 0;
        while (v >= 1024 && i < units.Length - 1) { v /= 1024; i++; }
        return i == 0 ? $"{n} B" : $"{v.ToString("0.0", CultureInfo.InvariantCulture)} {units[i]}";
    }
}
