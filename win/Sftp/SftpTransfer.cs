using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace PixShell.Sftp;

/// <summary>
/// 智能打包传输（对齐 mac 版 SFTP/SFTPTransfer.swift，移植自老仓库 native-102）。
/// 阈值：8MB。触发条件：多项 / 目录 / 单个文件 ≥ 阈值。
/// 下载：远端 `tar -czf`（逐项 `-C 父目录 basename`，避免绝对路径进包）→ 下载压缩包 → 本地解压 → 两端清理临时包。
/// 上传：本地 `tar -czf` → 上传压缩包 → 远端 `tar -xzf` + 删包。
/// 本地打包/解包用 Windows 10 1803+ 自带的 bsdtar（`tar.exe`，System32 内置，支持 -c/-x/-z/-f/-C，与远端 GNU tar 参数兼容）。
/// </summary>
public static class SftpTransfer
{
    /// <summary>老仓库 TRANSFER_PACK_BYTES，与 mac 版 packThreshold 一致。</summary>
    public const long PackThreshold = 8 * 1024 * 1024;

    /// <summary>shell 单引号转义（与老仓库 shellQuote / mac quote(_:) 等价）。</summary>
    public static string Quote(string s) => "'" + s.Replace("'", "'\\''") + "'";

    /// <summary>是否需要打包：多项 / 含目录 / 单文件超阈值（对齐 mac shouldPack）。</summary>
    public static bool ShouldPack(int count, bool singleIsDir, long singleSize) =>
        count > 1 || (count == 1 && (singleIsDir || singleSize >= PackThreshold));

    /// <summary>构造远端打包命令：逐项 `-C 父目录 basename`（对齐 mac packCommand，POSIX 路径处理）。</summary>
    public static string PackCommand(string archive, IEnumerable<string> remotePaths)
    {
        var parts = remotePaths.Select(rp =>
        {
            var norm = rp.TrimEnd('/');
            var path = norm.Length == 0 ? "/" : norm;
            var slash = path.LastIndexOf('/');
            string baseName = slash >= 0 ? path[(slash + 1)..] : path;
            string parent = slash > 0 ? path[..slash] : "/";
            return $"-C {Quote(parent)} {Quote(baseName.Length == 0 ? path : baseName)}";
        });
        return $"tar -czf {Quote(archive)} {string.Join(" ", parts)} 2>&1";
    }

    /// <summary>本地解压到目标目录。返回错误描述，null 表示成功。</summary>
    public static string? ExtractLocal(string archive, string intoDir) =>
        Run("tar", new[] { "-xzf", archive, "-C", intoDir });

    /// <summary>本地打包（多项 → 一个 .tar.gz）。</summary>
    public static string? PackLocal(string archive, IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return "无文件";
        var parent = Path.GetDirectoryName(paths[0].TrimEnd('\\', '/'));
        if (string.IsNullOrEmpty(parent)) return "无法确定父目录";
        var args = new List<string> { "-czf", archive, "-C", parent };
        foreach (var p in paths) args.Add(Path.GetFileName(p.TrimEnd('\\', '/')));
        return Run("tar", args.ToArray());
    }

    private static string? Run(string exe, string[] args)
    {
        try
        {
            var psi = new ProcessStartInfo(exe)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            foreach (var a in args) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi);
            if (p == null) return "无法启动 tar";
            var err = p.StandardError.ReadToEnd();
            var outp = p.StandardOutput.ReadToEnd();
            p.WaitForExit();
            if (p.ExitCode == 0) return null;
            var msg = (err + outp).Trim();
            return msg.Length == 0 ? $"tar 退出码 {p.ExitCode}" : msg;
        }
        catch (Exception ex) { return ex.Message; }
    }

    /// <summary>生成唯一临时包名（毫秒时间戳，与 mac stamp() 等价可读）。</summary>
    public static string Stamp() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString();
}
