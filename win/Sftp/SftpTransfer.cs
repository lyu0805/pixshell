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

    /// <summary>构造远端打包命令：逐项 `-C 父目录 basename`；末尾回传 <c>__PIXSHELL_RC:&lt;code&gt;</c>
    /// （ssh.exec 只回 stdout 文本，不带 exit code；对齐 mac packCommand）。</summary>
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
        return $"tar -czf {Quote(archive)} {string.Join(" ", parts)} 2>&1; echo __PIXSHELL_RC:$?";
    }

    /// <summary>远端解压命令：解压后删临时包，并回传 tar 真实退出码（rm 不影响 RC；对齐 mac extractCommand）。</summary>
    public static string ExtractCommand(string archive, string remoteDir)
    {
        var arc = Quote(archive);
        var dst = Quote(remoteDir);
        return $"tar -xzf {arc} -C {dst} 2>&1; rc=$?; rm -f {arc}; echo __PIXSHELL_RC:$rc";
    }

    /// <summary>解析 ssh.exec 输出里的 <c>__PIXSHELL_RC:N</c>。
    /// 打包/解压路径<strong>必须</strong>有标记：空输出或无标记一律失败（旧「空=成功」会把未执行的 extract 当绿）。
    /// 兼容：非空无标记 → code=1 + 原文。</summary>
    public static (int code, string message) ParseRemoteRC(string output)
    {
        var trimmed = (output ?? "").Trim();
        var marker = "__PIXSHELL_RC:";
        var idx = trimmed.LastIndexOf(marker, StringComparison.Ordinal);
        if (idx >= 0)
        {
            var after = trimmed[(idx + marker.Length)..].Trim();
            var end = 0;
            if (after.Length > 0 && after[0] == '-') end = 1;
            while (end < after.Length && char.IsDigit(after[end])) end++;
            var numStr = after[..end];
            var msg = trimmed[..idx].Trim();
            if (int.TryParse(numStr, out var code)) return (code, msg);
            return (1, msg.Length == 0 ? trimmed : msg);
        }
        // 无标记：空（exec 失败/超时/未连接）与有文本都当失败，堵住假绿
        return (1, trimmed.Length == 0 ? "远端无 __PIXSHELL_RC 回执（命令未执行或通道失败）" : trimmed);
    }

    /// <summary>本地解压到目标目录。返回错误描述，null 表示成功。</summary>
    public static string? ExtractLocal(string archive, string intoDir) =>
        Run("tar", new[] { "-xzf", archive, "-C", intoDir });

    /// <summary>本地打包（多项 → 一个 .tar.gz）。逐项 <c>-C 父目录 basename</c>，支持跨目录多选（对齐 mac packLocal）。</summary>
    public static string? PackLocal(string archive, IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return "无文件";
        var args = new List<string> { "-czf", archive };
        foreach (var raw in paths)
        {
            var p = raw.TrimEnd('\\', '/');
            var parent = Path.GetDirectoryName(p);
            var baseName = Path.GetFileName(p);
            if (string.IsNullOrEmpty(baseName)) return "无法确定文件名: " + raw;
            // Windows 根路径 GetDirectoryName 可能 null；回落盘符根或 .
            if (string.IsNullOrEmpty(parent)) parent = Path.GetPathRoot(p) is { Length: > 0 } root ? root.TrimEnd('\\', '/') : ".";
            args.Add("-C");
            args.Add(parent);
            args.Add(baseName);
        }
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
