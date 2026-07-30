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
///
/// Windows 探测顺序（真机踩坑，2026-07）：
/// 1. <c>C:\Program Files\OpenSSH\ssh-keygen.exe</c>（独立 x64 安装，PE 正常）
/// 2. <c>C:\Program Files\Git\usr\bin\ssh-keygen.exe</c>（Git for Windows）
/// 3. PATH 上的 <c>ssh-keygen</c>（需能真正拉起进程）
/// 4. 最后才 <c>%SystemRoot%\System32\OpenSSH\ssh-keygen.exe</c>
///
/// 注意：部分机器 System32 里那个文件**存在但不是有效 PE**（"不是有效的 Win32 应用程序"）。
/// 旧代码 <c>File.Exists(sys32) ? sys32 : "ssh-keygen"</c> 会永久命中坏文件。
/// 现用 MZ 头过滤非 PE；绝对路径过 MZ 即采用。PATH 裸名再试跑进程。
/// 注意：Win OpenSSH 的 <c>-V</c> 是证书 validity 不是版本，探测勿用 <c>-V</c>。
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

    /// <summary>缓存探测结果；进程生命周期内只扫一次。</summary>
    private static string? _keygenExeCached;
    private static bool _keygenProbed;

    /// <summary>ssh-keygen 可执行文件（见类注释探测顺序）。找不到时回落 "ssh-keygen" 让 PATH 再试一次。</summary>
    internal static string KeygenExe
    {
        get
        {
            if (_keygenProbed) return _keygenExeCached ?? "ssh-keygen";
            _keygenProbed = true;
            _keygenExeCached = ResolveKeygenExe();
            Log.Info($"ssh-keygen = {_keygenExeCached}", "keys");
            return _keygenExeCached;
        }
    }

    /// <summary>按优先级找一个**真能跑**的 ssh-keygen。公开给冒烟/诊断。</summary>
    public static string ResolveKeygenExe()
    {
        var pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var candidates = new[]
        {
            System.IO.Path.Combine(pf, "OpenSSH", "ssh-keygen.exe"),
            System.IO.Path.Combine(pf, "Git", "usr", "bin", "ssh-keygen.exe"),
            "ssh-keygen", // PATH
            System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH", "ssh-keygen.exe"),
        };
        foreach (var c in candidates)
        {
            if (LooksRunnable(c)) return c;
        }
        // 全灭：仍返回 PATH 名，让 Generate 的错误信息把失败原因抛给 UI
        return "ssh-keygen";
    }

    /// <summary>
    /// 绝对路径：存在 + MZ 头即通过（过滤 System32 伪 PE）。不再对绝对路径做进程试跑——
    /// 真机上部分 OpenSSH 在 Redirect 管道下对 <c>-l -f 不存在</c> 表现不稳定，会假阴性。
    /// PATH 裸名：无文件可验，只能 Start 试跑（用 <c>-l -f</c> 临时路径，勿用 <c>-V</c>）。
    /// </summary>
    private static bool LooksRunnable(string exe)
    {
        try
        {
            var isBare = exe.IndexOfAny(new[] { '/', '\\', ':' }) < 0;
            if (!isBare)
            {
                if (!File.Exists(exe)) return false;
                using (var fs = File.OpenRead(exe))
                {
                    if (fs.Length < 2) return false;
                    var b0 = fs.ReadByte();
                    var b1 = fs.ReadByte();
                    if (b0 != 'M' || b1 != 'Z')
                    {
                        Log.Warn($"跳过无效 PE 的 ssh-keygen: {exe}", "keys");
                        return false;
                    }
                }
                // 绝对路径 + 有效 PE：直接采用。CreateProcess 级失败留给 Generate 报错。
                return true;
            }

            // PATH 裸名：试跑，证明不是"找不到/不是有效 Win32 应用"
            var psi = new ProcessStartInfo(exe)
            {
                ArgumentList = { "-l", "-f", System.IO.Path.Combine(System.IO.Path.GetTempPath(), "pixshell-no-such-key") },
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using var p = Process.Start(psi);
            if (p == null) return false;
            p.StandardInput.Close();
            // 异步排空，避免管道堵死 WaitForExit
            var stdoutTask = p.StandardOutput.ReadToEndAsync();
            var stderrTask = p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit(4000))
            {
                try { p.Kill(entireProcessTree: true); } catch { }
                return false;
            }
            try { stdoutTask.Wait(500); stderrTask.Wait(500); } catch { }
            return true;
        }
        catch (Exception ex)
        {
            Log.Warn($"探测 ssh-keygen 失败 ({exe}): {ex.Message}", "keys");
            return false;
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
    /// passphrase 传空串表示不加口令（<c>-N ""</c>）。
    /// 首次 CreateProcess/执行失败会清探测缓存并重解析一次，避免 MZ 命中坏 PE 后整进程粘死。</summary>
    public static (string? path, string? error) Generate(string name, KeyType type, string comment, string passphrase)
    {
        Directory.CreateDirectory(SshDir);
        var safe = (name ?? "").Trim();
        if (safe.Length == 0 || safe.Contains('/') || safe.Contains('\\') || safe.StartsWith("."))
            return (null, "文件名不合法");
        // 拒绝 Windows 非法文件名字符，防奇怪路径/注入进 -f
        if (safe.IndexOfAny(System.IO.Path.GetInvalidFileNameChars()) >= 0)
            return (null, "文件名不合法");
        // 拒绝 Win 设备保留名与 List 会跳过的特殊文件名
        var stem = safe.Split('.')[0];
        switch (stem.ToUpperInvariant())
        {
            case "CON": case "PRN": case "AUX": case "NUL":
            case "COM1": case "COM2": case "COM3": case "COM4":
            case "COM5": case "COM6": case "COM7": case "COM8": case "COM9":
            case "LPT1": case "LPT2": case "LPT3": case "LPT4":
            case "LPT5": case "LPT6": case "LPT7": case "LPT8": case "LPT9":
                return (null, "文件名不合法");
        }
        if (safe is "known_hosts" or "known_hosts.old" or "config" or "authorized_keys")
            return (null, "文件名不合法");

        var path = System.IO.Path.Combine(SshDir, safe);
        if (File.Exists(path)) return (null, $"已存在同名密钥：{safe}");

        var args = new List<string>(TypeArgs(type)) { "-f", path, "-N", passphrase ?? "" };
        if (!string.IsNullOrWhiteSpace(comment)) { args.Add("-C"); args.Add(comment.Trim()); }

        var outText = Run(KeygenExe, args.ToArray());
        if (!File.Exists(path))
        {
            // 可能是缓存到了 MZ 但实际不可跑的路径：清缓存再试一次
            InvalidateKeygenCache();
            outText = Run(KeygenExe, args.ToArray());
        }
        if (!File.Exists(path))
            return (null, string.IsNullOrWhiteSpace(outText) ? "ssh-keygen 执行失败" : outText.Trim());

        Log.Info($"生成密钥 {safe}（{type}）", "keys");
        return (path, null);
    }

    /// <summary>清 ssh-keygen 探测缓存（Generate 失败重试 / 诊断用）。</summary>
    public static void InvalidateKeygenCache()
    {
        _keygenProbed = false;
        _keygenExeCached = null;
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
