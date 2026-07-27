using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace PixShell.Store;

// 命令框纯逻辑（1:1 移植 mac Store/CommandBox.swift，本质是老仓库
// packages/sftp-panel/src/sync.js + packages/command-box/src/history.js + params.js）：
//   CommandSync    → 终端 cwd ↔ SFTP 路径同步
//   CommandHistory → 历史 push/导航/过滤 + 持久化
//   CommandParams  → ${x} 参数模板
// 无 UI 依赖，便于复用/单测。

/// <summary>终端 cd ↔ SFTP 目录同步。</summary>
public static class CommandSync
{
    /// <summary>规整远端路径：压缩重复 `/`、去尾部 `/`；空/`~` 归一为 `.`</summary>
    public static string NormalizeRemotePath(string? p)
    {
        if (string.IsNullOrEmpty(p) || p == "~") return ".";
        var s = Regex.Replace(p, "/+", "/");
        if (s.Length > 1 && s.EndsWith("/")) s = s[..^1];
        return s.Length == 0 ? "." : s;
    }

    /// <summary>拼接远端路径，处理 `.`、`..`、绝对路径。</summary>
    public static string JoinRemote(string @base, string name)
    {
        if (string.IsNullOrEmpty(name) || name == ".") return NormalizeRemotePath(@base);
        if (name == "..")
        {
            var b = NormalizeRemotePath(@base);
            if (b == "." || b == "/") return ".";
            var parts = b.Split('/', StringSplitOptions.RemoveEmptyEntries).ToList();
            if (parts.Count > 0) parts.RemoveAt(parts.Count - 1);
            return parts.Count == 0 ? (@base.StartsWith("/") ? "/" : ".") : "/" + string.Join("/", parts);
        }
        if (name.StartsWith("/")) return NormalizeRemotePath(name);
        var baseNorm = NormalizeRemotePath(@base);
        if (baseNorm == ".") return name;
        if (baseNorm == "/") return "/" + name;
        return baseNorm + "/" + name;
    }

    /// <summary>命令是否是 `cd …`。</summary>
    public static bool ShouldSyncCd(string command) => Regex.IsMatch(command, @"^\s*cd\s+");

    /// <summary>取出 `cd` 的目标（去引号）；`cd` 无参数视为 `~`。</summary>
    public static string? ParseCdTarget(string command)
    {
        var m = Regex.Match(command, @"^\s*cd\s*(.*)$");
        if (!m.Success) return null;
        var t = m.Groups[1].Value.Trim();
        if (t.Length == 0) return "~";
        t = Regex.Replace(t, "^['\"]|['\"]$", "");
        return t;
    }

    /// <summary>把一条命令作用到当前路径上，得到新的 SFTP 路径（非 cd 命令原样返回）。</summary>
    public static string ApplyCd(string currentPath, string command)
    {
        if (!ShouldSyncCd(command)) return currentPath;
        var target = ParseCdTarget(command);
        if (target == null) return currentPath;
        if (target == "~" || target.Length == 0) return ".";
        if (target.StartsWith("/")) return NormalizeRemotePath(target);
        return JoinRemote(string.IsNullOrEmpty(currentPath) ? "." : currentPath, target);
    }
}

/// <summary>命令历史（持久化到 `%APPDATA%\PixShell\cmd-history.json`）。</summary>
public sealed class CommandHistory
{
    private List<string> _items = new();
    private int _index = -1; // -1 表示"未在浏览历史"（即草稿态）
    private string _draft = "";
    private const int Limit = 500;
    private readonly string _path;

    public IReadOnlyList<string> Items => _items;

    public CommandHistory()
    {
        _path = Path.Combine(HostStore.AppDir, "cmd-history.json");
        try
        {
            if (File.Exists(_path))
            {
                var a = JsonSerializer.Deserialize<List<string>>(File.ReadAllText(_path));
                if (a != null) _items = a;
            }
        }
        catch { /* 读取失败保留空历史 */ }
    }

    /// <summary>新命令置顶去重（对齐 mac push）。</summary>
    public void Push(string cmd)
    {
        var c = Regex.Replace(cmd, "\n+$", "");
        if (string.IsNullOrWhiteSpace(c)) return;
        _items = new List<string> { c }.Concat(_items.Where(x => x != c)).ToList();
        if (_items.Count > Limit) _items = _items.Take(Limit).ToList();
        Save();
        ResetCursor();
    }

    public void ResetCursor() { _index = -1; _draft = ""; }

    /// <summary>↑ 更旧；current 为当前输入框内容（首次上翻时记为草稿）。</summary>
    public string Older(string current)
    {
        if (_index < 0) _draft = current;
        if (_items.Count == 0) return current;
        var ni = Math.Min(_items.Count - 1, _index + 1);
        _index = ni;
        return _items[ni];
    }

    /// <summary>↓ 更新；回到草稿。</summary>
    public string Newer()
    {
        if (_index <= 0) { _index = -1; return _draft; }
        _index -= 1;
        return _items[_index];
    }

    /// <summary>前缀/包含过滤（历史弹出用）。</summary>
    public List<string> Filter(string prefix, int limit = 20) =>
        _items.Where(x => prefix.Length == 0 || x.StartsWith(prefix) || x.Contains(prefix)).Take(limit).ToList();

    private void Save()
    {
        try { File.WriteAllText(_path, JsonSerializer.Serialize(_items)); } catch { /* 静默降级 */ }
    }
    
    public void Remove(string cmd)
    {
        _items.RemoveAll(x => x == cmd);
        ResetCursor();
        Save();
    }
    
    public void Clear()
    {
        _items.Clear();
        ResetCursor();
        Save();
    }
}

/// <summary>自定义命令参数模板 `${name}`。</summary>
public static class CommandParams
{
    private static readonly Regex ParamRegex = new(@"\$\{([a-zA-Z0-9_]+)\}", RegexOptions.Compiled);

    /// <summary>取出模板里的参数名（去重、保序）。</summary>
    public static List<string> Parse(string template)
    {
        var names = new List<string>();
        foreach (Match m in ParamRegex.Matches(template))
        {
            var n = m.Groups[1].Value;
            if (!names.Contains(n)) names.Add(n);
        }
        return names;
    }

    /// <summary>用取值渲染模板；缺失的占位符原样保留。</summary>
    public static string Render(string template, IReadOnlyDictionary<string, string> values) =>
        ParamRegex.Replace(template, m => values.TryGetValue(m.Groups[1].Value, out var v) ? v : m.Value);

    public static bool HasUnresolved(string template) => Parse(template).Count > 0;
}
