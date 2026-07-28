using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using PixShell.Logging;

namespace PixShell.Bridge;

/// <summary>
/// 把 PixShell 注册为 Claude Code / Codex / OpenCode 等 AI 工具的默认交互式 SSH 入口。
///
/// 做法（Windows）：
///  1. 确保 <see cref="AgentCLI"/> 的 bin 脚本已写出（pixshell.cmd / pixshell.py）；
///  2. 在 <c>%APPDATA%\PixShell\bin</c> 写 <c>ssh.cmd</c> 包装器（优先走本机桥，失败回落系统 OpenSSH）；
///  3. 把该 bin 目录前置写入**用户级** PATH，让 GUI / 终端里的 AI 工具先命中我们的 ssh。
///
/// 取消注册只清我们自己写的 ssh.cmd 与 PATH 条目，绝不删用户其它文件，也不动系统 OpenSSH。
/// </summary>
public static class AiSshRegister
{
    public const string Marker = "PIXSHELL_AI_SSH_WRAPPER";
    public const string MarkerLine = "REM " + Marker + " v1 — 由 PixShell 自动生成，取消注册时删除。";

    public static string BinDir => AgentCLI.BinDir;
    public static string SshCmdPath => Path.Combine(BinDir, "ssh.cmd");
    public static string StatePath => Path.Combine(HostStore.AppDir, "ai_ssh_registered");

    /// <summary>本机可探测的 AI / 编码工具。新增只改这张表。</summary>
    public static readonly AiToolSpec[] KnownTools =
    {
        new("claude", "Claude Code", "claude"),
        new("codex", "Codex", "codex"),
        new("grok", "Grok CLI", "grok"),
        new("opencode", "OpenCode", "opencode"),
        new("cursor", "Cursor", "cursor"),
        new("windsurf", "Windsurf", "windsurf"),
        new("ollama", "Ollama", "ollama"),
    };

    public sealed record AiToolSpec(string Key, string Display, string Exe);
    public sealed record AiToolHit(string Key, string Display, string Path);

    public sealed record RegisterResult(bool Ok, string Message);
    public sealed record StatusSnapshot(
        bool Registered,
        string BinDir,
        string SshCmdPath,
        bool SshCmdPresent,
        bool PathContainsBin,
        IReadOnlyList<AiToolHit> DetectedTools);

    /// <summary>当前注册状态 + 本机 AI 工具探测结果。</summary>
    public static StatusSnapshot Snapshot(int? bridgePort = null)
    {
        // 探测不依赖桥是否在跑；注册状态以我们写的文件 + PATH 为准。
        _ = bridgePort;
        var detected = DetectTools();
        var pathHit = UserPathContains(BinDir);
        var cmdOk = IsOurSshCmd(SshCmdPath);
        var registered = File.Exists(StatePath) || (cmdOk && pathHit);
        return new StatusSnapshot(registered, BinDir, SshCmdPath, cmdOk, pathHit, detected);
    }

    public static IReadOnlyList<AiToolHit> DetectTools()
    {
        var hits = new List<AiToolHit>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var t in KnownTools)
        {
            var p = Which(t.Exe);
            if (p != null)
            {
                hits.Add(new AiToolHit(t.Key, t.Display, p));
                seen.Add(t.Key);
            }
        }
        // CLI 不在 PATH 时，用常见配置/安装目录兜底（对齐 mac AiSshBridge.detectTools extras）。
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var localApp = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var extras = new (string Key, string Display, string[] Paths)[]
        {
            ("claude", "Claude Code", new[]
            {
                Path.Combine(home, ".claude"),
                Path.Combine(appData, "Claude"),
                Path.Combine(localApp, "Programs", "Claude"),
            }),
            ("codex", "Codex", new[]
            {
                Path.Combine(home, ".codex"),
                Path.Combine(appData, "Codex"),
                Path.Combine(appData, "openai-codex"),
            }),
            ("grok", "Grok CLI", new[]
            {
                Path.Combine(home, ".grok"),
                Path.Combine(home, ".grok", "bin"),
            }),
            ("opencode", "OpenCode", new[]
            {
                Path.Combine(home, ".opencode"),
                Path.Combine(appData, "opencode"),
            }),
            ("cursor", "Cursor", new[]
            {
                Path.Combine(home, ".cursor"),
                Path.Combine(localApp, "Programs", "cursor"),
                Path.Combine(localApp, "Programs", "Cursor"),
            }),
            ("windsurf", "Windsurf", new[]
            {
                Path.Combine(home, ".windsurf"),
                Path.Combine(localApp, "Programs", "Windsurf"),
            }),
            ("ollama", "Ollama", new[]
            {
                Path.Combine(localApp, "Programs", "Ollama"),
                Path.Combine(appData, "Ollama"),
            }),
        };
        foreach (var e in extras)
        {
            if (seen.Contains(e.Key)) continue;
            foreach (var path in e.Paths)
            {
                try
                {
                    if (Directory.Exists(path) || File.Exists(path))
                    {
                        hits.Add(new AiToolHit(e.Key, e.Display, path));
                        seen.Add(e.Key);
                        break;
                    }
                }
                catch { /* ignore */ }
            }
        }
        return hits;
    }

    /// <summary>一键注册：写 ssh.cmd + 前置用户 PATH + 状态文件。会顺带刷新 AgentCLI 脚本。</summary>
    public static RegisterResult Register(int bridgePort)
    {
        try
        {
            Directory.CreateDirectory(BinDir);
            AgentCLI.Install(bridgePort);

            var body = BuildSshCmd();
            File.WriteAllText(SshCmdPath, body, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));

            if (!PrependUserPath(BinDir, out var pathMsg))
                return new RegisterResult(false, "写 ssh.cmd 成功，但改用户 PATH 失败：" + pathMsg);

            File.WriteAllText(StatePath, DateTime.UtcNow.ToString("o") + "\n" + BinDir + "\n", Encoding.UTF8);
            Log.Info($"AI SSH 已注册：{SshCmdPath}；PATH 已前置 {BinDir}", "bridge");
            var tools = DetectTools();
            var toolNote = tools.Count == 0
                ? "本机未探测到 Claude/Codex/Grok/OpenCode 等，但仍已注册（装好后即可用）。"
                : "已检测到：" + string.Join("、", tools.Select(t => t.Display)) + "。";
            return new RegisterResult(true,
                "已注册为 AI 默认 SSH 工具。\n" +
                $"包装器：{SshCmdPath}\n" +
                $"已把 {BinDir} 前置到用户 PATH。\n" +
                toolNote + "\n" +
                "新开的终端 / AI 工具进程会吃到新 PATH；已开的进程需重启。");
        }
        catch (Exception ex)
        {
            Log.Warn("AI SSH 注册失败：" + ex.Message, "bridge");
            return new RegisterResult(false, "注册失败：" + ex.Message);
        }
    }

    /// <summary>一键取消：删我们的 ssh.cmd / 状态文件，并从用户 PATH 去掉 bin。</summary>
    public static RegisterResult Unregister()
    {
        try
        {
            if (File.Exists(SshCmdPath))
            {
                if (IsOurSshCmd(SshCmdPath) || File.Exists(StatePath))
                    File.Delete(SshCmdPath);
                else
                    Log.Warn($"跳过删除 {SshCmdPath}：不是我们的包装器", "bridge");
            }

            if (File.Exists(StatePath))
            {
                try { File.Delete(StatePath); } catch { /* ignore */ }
            }

            if (!RemoveFromUserPath(BinDir, out var pathMsg))
                return new RegisterResult(false, "清理包装器完成，但改用户 PATH 失败：" + pathMsg);

            Log.Info("AI SSH 已取消注册", "bridge");
            return new RegisterResult(true,
                "已取消注册。\n" +
                "已删除 ssh.cmd 包装器，并从用户 PATH 移除 PixShell\\bin。\n" +
                "新开的终端会恢复系统 OpenSSH；已开的进程需重启。");
        }
        catch (Exception ex)
        {
            Log.Warn("AI SSH 取消注册失败：" + ex.Message, "bridge");
            return new RegisterResult(false, "取消注册失败：" + ex.Message);
        }
    }

    // ---------------------------------------------------------------------
    // ssh.cmd：优先走 pixshell 桥（交互/已连会话），否则绝对路径回落系统 OpenSSH
    // ---------------------------------------------------------------------
    private static string BuildSshCmd()
    {
        // 关键：PATH 前置本 bin 后，AI 工具调用的 `ssh` 会先命中本包装器。
        // 包装器必须行为兼容 OpenSSH（Claude/Codex 会直接 ssh user@host）。
        // 用 System32 绝对路径启动真实 ssh，避免 PATH 递归命中自己；
        // 同时导出 PIXSHELL_* 环境变量，方便同会话里的 agent 发现 CLI 桥。
        var lines = new List<string>
        {
            "@echo off",
            MarkerLine,
            "REM 将 PixShell bin 暴露给 AI 工具：ssh 仍走系统 OpenSSH（绝对路径，防递归），",
            "REM 同目录 pixshell.cmd / pixshell.py 作为交互式会话桥入口。",
            "setlocal EnableExtensions",
            "chcp 65001 >nul 2>&1",
            "set \"PIXSHELL_SSH_WRAPPER=1\"",
            "set \"PIXSHELL_BIN=%~dp0\"",
            "set \"PIXSHELL_CLI=%~dp0pixshell.cmd\"",
            "",
            "set \"REAL_SSH=\"",
            "if exist \"%SystemRoot%\\System32\\OpenSSH\\ssh.exe\" set \"REAL_SSH=%SystemRoot%\\System32\\OpenSSH\\ssh.exe\"",
            "if not defined REAL_SSH if exist \"%ProgramFiles%\\OpenSSH\\ssh.exe\" set \"REAL_SSH=%ProgramFiles%\\OpenSSH\\ssh.exe\"",
            "if not defined REAL_SSH if exist \"%ProgramFiles(x86)%\\OpenSSH\\ssh.exe\" set \"REAL_SSH=%ProgramFiles(x86)%\\OpenSSH\\ssh.exe\"",
            "if not defined REAL_SSH (",
            "  echo [PixShell] 找不到系统 OpenSSH（ssh.exe）。请安装「OpenSSH 客户端」可选功能。 1>&2",
            "  exit /b 1",
            ")",
            "",
            "\"%REAL_SSH%\" %*",
            "exit /b %ERRORLEVEL%",
        };
        return string.Join("\r\n", lines) + "\r\n";
    }

    private static bool IsOurSshCmd(string path)
    {
        try
        {
            if (!File.Exists(path)) return false;
            var text = File.ReadAllText(path);
            return text.Contains(Marker, StringComparison.Ordinal);
        }
        catch { return false; }
    }

    // ---------------------------------------------------------------------
    // 用户级 PATH 读写（不碰 Machine，不需要管理员）
    // ---------------------------------------------------------------------
    private static bool UserPathContains(string dir)
    {
        var path = Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.User) ?? "";
        var target = NormalizeDir(dir);
        return path.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries)
            .Any(p => string.Equals(NormalizeDir(p), target, StringComparison.OrdinalIgnoreCase));
    }

    private static bool PrependUserPath(string dir, out string error)
    {
        error = "";
        try
        {
            var current = Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.User) ?? "";
            var parts = current.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries).ToList();
            var target = NormalizeDir(dir);
            parts.RemoveAll(p => string.Equals(NormalizeDir(p), target, StringComparison.OrdinalIgnoreCase));
            parts.Insert(0, dir.TrimEnd('\\', '/'));
            var next = string.Join(";", parts);
            Environment.SetEnvironmentVariable("PATH", next, EnvironmentVariableTarget.User);
            // 当前进程也立刻可见，方便本会话内再探测
            var proc = Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.Process) ?? "";
            if (!proc.Split(';').Any(p => string.Equals(NormalizeDir(p), target, StringComparison.OrdinalIgnoreCase)))
                Environment.SetEnvironmentVariable("PATH", dir.TrimEnd('\\', '/') + ";" + proc, EnvironmentVariableTarget.Process);
            return true;
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return false;
        }
    }

    private static bool RemoveFromUserPath(string dir, out string error)
    {
        error = "";
        try
        {
            var current = Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.User) ?? "";
            var target = NormalizeDir(dir);
            var parts = current.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries)
                .Where(p => !string.Equals(NormalizeDir(p), target, StringComparison.OrdinalIgnoreCase))
                .ToList();
            Environment.SetEnvironmentVariable("PATH", string.Join(";", parts), EnvironmentVariableTarget.User);
            return true;
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return false;
        }
    }

    private static string NormalizeDir(string p)
    {
        try { return Path.GetFullPath(p.Trim().TrimEnd('\\', '/')); }
        catch { return (p ?? "").Trim().TrimEnd('\\', '/').ToLowerInvariant(); }
    }

    /// <summary>在 PATH（含常见用户目录）里找可执行文件。GUI PATH 比登录 shell 窄，补几处。</summary>
    public static string? Which(string name)
    {
        var exts = new[] { ".cmd", ".exe", ".bat", "" };
        var dirs = (Environment.GetEnvironmentVariable("PATH") ?? "")
            .Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries)
            .ToList();
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var localApp = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        dirs.Add(Path.Combine(home, ".local", "bin"));
        dirs.Add(Path.Combine(home, "bin"));
        dirs.Add(Path.Combine(home, ".grok", "bin"));
        dirs.Add(Path.Combine(appData, "npm"));
        dirs.Add(Path.Combine(localApp, "Programs"));
        dirs.Add(Path.Combine(localApp, "Microsoft", "WindowsApps"));
        // Cursor / Windsurf / Ollama 常见安装位
        dirs.Add(Path.Combine(localApp, "Programs", "cursor"));
        dirs.Add(Path.Combine(localApp, "Programs", "Cursor"));
        dirs.Add(Path.Combine(localApp, "Programs", "Windsurf"));
        dirs.Add(Path.Combine(localApp, "Programs", "Ollama"));
        foreach (var d in dirs.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            foreach (var ext in exts)
            {
                try
                {
                    var candidate = Path.Combine(d, name + ext);
                    if (File.Exists(candidate)) return candidate;
                }
                catch { /* ignore bad path segment */ }
            }
        }
        return null;
    }
}
