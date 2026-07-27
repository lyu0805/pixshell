using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using PixShell.Logging;

namespace PixShell;

/// <summary>
/// SSH 密钥管理（对应老仓库 config.json 的 <c>secret_key_list</c>，对齐 mac Store/SSHKeys.swift）。
///
/// 生成/读指纹一律调用系统 <c>ssh-keygen</c>，不自己实现密钥生成 ——
/// 那是安全关键代码，标准工具产出的格式（OpenSSH 新格式 + .pub）兼容性也最好。
/// Windows 10/11 自带 OpenSSH 客户端；PATH 里找不到就回落到 System32\OpenSSH 的绝对路径。
/// </summary>
public static class SshKeys
{
    public sealed class KeyInfo
    {
        public string Path { get; init; } = "";          // 私钥路径
        public string Name { get; init; } = "";          // 文件名
        public string Type { get; init; } = "-";         // ED25519 / RSA / ECDSA…
        public string Bits { get; init; } = "-";         // 位数（ssh-keygen 报告）
        public string Fingerprint { get; init; } = "-";  // SHA256:…
        public string Comment { get; init; } = "";
        public bool HasPublic { get; init; }             // 是否存在同名 .pub
        public bool Encrypted { get; init; }             // 私钥是否带口令
    }

    public enum KeyType { Ed25519, Rsa4096, Ecdsa256 }

    public static string Display(KeyType t) => t switch
    {
        KeyType.Ed25519 => "Ed25519（推荐，短快现代）",
        KeyType.Rsa4096 => "RSA 4096（兼容性最好，老服务器用）",
        _ => "ECDSA P-256",
    };

    private static string[] TypeArgs(KeyType t) => t switch
    {
        KeyType.Ed25519 => new[] { "-t", "ed25519" },
        KeyType.Rsa4096 => new[] { "-t", "rsa", "-b", "4096" },
        _ => new[] { "-t", "ecdsa", "-b", "256" },
    };

    public static string SshDir => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh");

    /// <summary>ssh-keygen 可执行文件：优先 PATH，其次 Windows 自带 OpenSSH 的固定位置。</summary>
    private static string KeygenExe
    {
        get
        {
            var sys32 = System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH", "ssh-keygen.exe");
            return File.Exists(sys32) ? sys32 : "ssh-keygen";
        }
    }

    /// <summary>扫描 ~/.ssh 下的私钥。判定：有同名 .pub，或文件头含 PRIVATE KEY 标记。</summary>
    public static List<KeyInfo> List()
    {
        var result = new List<KeyInfo>();
        if (!Directory.Exists(SshDir)) return result;

        foreach (var p in Directory.GetFiles(SshDir).OrderBy(x => x))
        {
            var name = System.IO.Path.GetFileName(p);
            if (name.EndsWith(".pub", StringComparison.OrdinalIgnoreCase)) continue;
            if (name is "known_hosts" or "known_hosts.old" or "config" or "authorized_keys") continue;
            if (name.StartsWith(".")) continue;

            var hasPub = File.Exists(p + ".pub");
            string head;
            try { head = ReadHead(p, 200); } catch { continue; }
            if (!hasPub && !head.Contains("PRIVATE KEY")) continue;

            result.Add(Inspect(p, hasPub, head));
        }
        return result;
    }

    private static string ReadHead(string path, int chars)
    {
        using var r = new StreamReader(path);
        var buf = new char[chars];
        var n = r.Read(buf, 0, chars);
        return new string(buf, 0, Math.Max(n, 0));
    }

    /// <summary>用 <c>ssh-keygen -l</c> 读指纹/类型/位数；失败也要给一条能显示的记录。</summary>
    private static KeyInfo Inspect(string path, bool hasPublic, string head)
    {
        // OpenSSH 新格式的加密私钥里没有 "ENCRYPTED" 字样，靠 -y 试探代价太大，
        // 这里用两个常见标记做保守判断，仅用于界面提示。
        var encrypted = head.Contains("ENCRYPTED") || head.Contains("bcrypt");
        // -l 优先读 .pub（不会要口令）；没有 .pub 再读私钥。
        var target = hasPublic ? path + ".pub" : path;
        var outText = Run(KeygenExe, new[] { "-l", "-f", target });

        string bits = "-", fp = "-", comment = "", type = "-";
        // 形如：256 SHA256:xxxx comment (ED25519)
        var parts = outText.Trim().Split(' ', 3, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length >= 3)
        {
            bits = parts[0];
            fp = parts[1];
            var rest = parts[2].Trim();
            var open = rest.LastIndexOf('(');
            var close = rest.LastIndexOf(')');
            if (open >= 0 && close > open)
            {
                type = rest.Substring(open + 1, close - open - 1);
                comment = rest[..open].Trim();
            }
            else comment = rest;
        }

        return new KeyInfo
        {
            Path = path,
            Name = System.IO.Path.GetFileName(path),
            Type = type, Bits = bits, Fingerprint = fp, Comment = comment,
            HasPublic = hasPublic, Encrypted = encrypted,
        };
    }

    /// <summary>生成新密钥。成功返回 (path, null)，失败返回 (null, 错误信息)。
    /// passphrase 传空串表示不加口令（<c>-N ""</c>）。</summary>
    public static (string? path, string? error) Generate(string name, KeyType type, string comment, string passphrase)
    {
        Directory.CreateDirectory(SshDir);
        var safe = (name ?? "").Trim();
        if (safe.Length == 0 || safe.Contains('/') || safe.Contains('\\') || safe.StartsWith("."))
            return (null, "文件名不合法");

        var path = System.IO.Path.Combine(SshDir, safe);
        if (File.Exists(path)) return (null, $"已存在同名密钥：{safe}");

        var args = new List<string>(TypeArgs(type)) { "-f", path, "-N", passphrase ?? "" };
        if (!string.IsNullOrWhiteSpace(comment)) { args.Add("-C"); args.Add(comment.Trim()); }

        var outText = Run(KeygenExe, args.ToArray());
        if (!File.Exists(path))
            return (null, string.IsNullOrWhiteSpace(outText) ? "ssh-keygen 执行失败" : outText.Trim());

        Log.Info($"生成密钥 {safe}（{type}）", "keys");
        return (path, null);
    }

    /// <summary>读公钥内容（用于"复制公钥"，粘到服务器 authorized_keys）。</summary>
    public static string? PublicKeyText(KeyInfo info)
    {
        var pub = info.Path + ".pub";
        if (File.Exists(pub))
        {
            try { return File.ReadAllText(pub).Trim(); } catch { }
        }
        // 没有 .pub 就从私钥派生（私钥带口令时会失败，返回 null 交给调用方提示）
        var t = Run(KeygenExe, new[] { "-y", "-f", info.Path }).Trim();
        return (t.StartsWith("ssh-") || t.StartsWith("ecdsa-")) ? t : null;
    }

    /// <summary>删除私钥 + 对应 .pub。</summary>
    public static void Delete(KeyInfo info)
    {
        try { File.Delete(info.Path); } catch { }
        try { File.Delete(info.Path + ".pub"); } catch { }
        Log.Info($"删除密钥 {info.Name}", "keys");
    }

    /// <summary>跑一次外部命令收 stdout+stderr。
    /// stdin 显式重定向且立刻关闭 —— ssh-keygen 需要口令时会去读输入，不这么做会**永久卡住**。</summary>
    private static string Run(string exe, string[] args)
    {
        try
        {
            var psi = new ProcessStartInfo(exe)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            foreach (var a in args) psi.ArgumentList.Add(a);

            using var p = Process.Start(psi);
            if (p == null) return "";
            p.StandardInput.Close();
            var outText = p.StandardOutput.ReadToEnd();
            var errText = p.StandardError.ReadToEnd();
            p.WaitForExit(20000);
            return string.IsNullOrWhiteSpace(outText) ? errText : outText;
        }
        catch (Exception ex)
        {
            Log.Warn($"执行 {exe} 失败: {ex.Message}", "keys");
            return "";
        }
    }
}
