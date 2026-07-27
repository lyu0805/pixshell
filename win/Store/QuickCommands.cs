using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using PixShell.Logging;

namespace PixShell.Store;

/// <summary>快捷命令参数（对齐 mac Store/QuickCommands.swift 的 QuickParam）。</summary>
public class QuickCommandParam
{
    public string Name { get; set; } = "";
    public string? DefaultValue { get; set; }
    public bool? Required { get; set; }
}

/// <summary>快捷命令（对齐 mac QuickCommand：id/name/group/command/params）。</summary>
public class QuickCommand
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "";
    public string Group { get; set; } = "默认";
    public string Command { get; set; } = "";
    public List<QuickCommandParam>? Params { get; set; }
}

/// <summary>
/// 快捷命令持久化 + 分组/渲染逻辑（1:1 移植 mac Store/QuickCommands.swift 的 QuickCommandStore）：
/// 存 `%APPDATA%\PixShell\quick-commands.json`；首次运行（文件不存在/为空）用与 mac 完全一致的
/// 默认集播种（老仓库 DEMO_QUICK_COMMANDS）。
/// </summary>
public sealed class QuickCommandStore
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private readonly string _path;
    private readonly string _groupsPath;

    public List<QuickCommand> Commands { get; private set; } = new();

    /// <summary>显式分组表。**必须单独存**：分组光靠命令的 Group 字段派生的话，
    /// 新建一个还没放命令的空分组会立刻消失。这里记住用户建过的空分组
    /// （对齐 mac QuickCommandStore.emptyGroups / quick-command-groups.json）。</summary>
    public List<string> EmptyGroups { get; private set; } = new();

    public QuickCommandStore()
    {
        _path = Path.Combine(HostStore.AppDir, "quick-commands.json");
        _groupsPath = Path.Combine(HostStore.AppDir, "quick-command-groups.json");
        Load();
    }

    private void Load()
    {
        LoadGroups();
        try
        {
            if (File.Exists(_path))
            {
                var json = File.ReadAllText(_path);
                var list = JsonSerializer.Deserialize<List<QuickCommand>>(json, JsonOpts);
                if (list is { Count: > 0 })
                {
                    Commands = list;
                    return;
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"读取 quick-commands.json 失败，使用默认集: {ex.Message}", "quickcmd");
        }
        Commands = Defaults();
        Save();
    }

    private void LoadGroups()
    {
        try
        {
            if (File.Exists(_groupsPath))
            {
                var list = JsonSerializer.Deserialize<List<string>>(File.ReadAllText(_groupsPath), JsonOpts);
                if (list != null) EmptyGroups = list;
            }
        }
        catch (Exception ex) { Log.Warn($"读取 quick-command-groups.json 失败: {ex.Message}", "quickcmd"); }
    }

    public void Save()
    {
        try { File.WriteAllText(_path, JsonSerializer.Serialize(Commands, JsonOpts)); }
        catch (Exception ex) { Log.Warn($"写入 quick-commands.json 失败: {ex.Message}", "quickcmd"); }
    }

    private void SaveGroups()
    {
        try { File.WriteAllText(_groupsPath, JsonSerializer.Serialize(EmptyGroups, JsonOpts)); }
        catch (Exception ex) { Log.Warn($"写入 quick-command-groups.json 失败: {ex.Message}", "quickcmd"); }
    }

    /// <summary>分组 = 显式建过的 ∪ 命令里出现过的（都按首次出现保序，对齐 mac groups()）。</summary>
    public List<string> Groups()
    {
        var seen = new HashSet<string>();
        var outp = new List<string>();
        foreach (var g in EmptyGroups)
            if (seen.Add(g)) outp.Add(g);
        foreach (var c in Commands)
        {
            var g = string.IsNullOrEmpty(c.Group) ? "默认" : c.Group;
            if (seen.Add(g)) outp.Add(g);
        }
        return outp;
    }

    /// <summary>新建分组。已存在返回 false（调用方据此提示）。</summary>
    public bool AddGroup(string name)
    {
        var n = name.Trim();
        if (n.Length == 0 || Groups().Contains(n)) return false;
        EmptyGroups.Add(n);
        SaveGroups();
        return true;
    }

    /// <summary>删除分组：里面的命令一并挪回「默认」，**不连带删命令**（对齐 mac removeGroup）。</summary>
    public void RemoveGroup(string name)
    {
        EmptyGroups.RemoveAll(g => g == name);
        foreach (var c in Commands)
            if ((string.IsNullOrEmpty(c.Group) ? "默认" : c.Group) == name) c.Group = "默认";
        SaveGroups();
        Save();
    }

    /// <summary>重命名分组：分组名存在每条命令里，故逐条改（对齐 mac renameGroup）。</summary>
    public void RenameGroup(string oldName, string newName)
    {
        var n = newName.Trim();
        if (n.Length == 0 || n == oldName || Groups().Contains(n)) return;
        var i = EmptyGroups.IndexOf(oldName);
        if (i >= 0) EmptyGroups[i] = n;
        foreach (var c in Commands)
            if ((string.IsNullOrEmpty(c.Group) ? "默认" : c.Group) == oldName) c.Group = n;
        SaveGroups();
        Save();
    }

    /// <summary>把一条命令移到某个分组（对齐 mac move）。</summary>
    public void Move(string id, string group)
    {
        var c = Commands.FirstOrDefault(x => x.Id == id);
        if (c == null) return;
        c.Group = string.IsNullOrEmpty(group) ? "默认" : group;
        Save();
    }

    public List<QuickCommand> List(string? group) =>
        string.IsNullOrEmpty(group)
            ? Commands
            : Commands.Where(c => (string.IsNullOrEmpty(c.Group) ? "默认" : c.Group) == group).ToList();

    public void Upsert(QuickCommand c)
    {
        var i = Commands.FindIndex(x => x.Id == c.Id);
        if (i >= 0) Commands[i] = c; else Commands.Add(c);
        Save();
    }

    public void Delete(string id)
    {
        Commands.RemoveAll(c => c.Id == id);
        Save();
    }

    /// <summary>用给定取值 + 参数默认值渲染模板（对齐 mac render）。</summary>
    public string Render(QuickCommand c, IReadOnlyDictionary<string, string>? paramValues = null)
    {
        var outp = c.Command;
        if (paramValues != null)
            foreach (var kv in paramValues) outp = outp.Replace("${" + kv.Key + "}", kv.Value);
        foreach (var p in c.Params ?? new List<QuickCommandParam>())
        {
            if (p.DefaultValue != null && outp.Contains("${" + p.Name + "}"))
                outp = outp.Replace("${" + p.Name + "}", p.DefaultValue);
        }
        return outp;
    }

    /// <summary>老仓库 DEMO_QUICK_COMMANDS 同款默认集（与 mac QuickCommandStore.defaults 逐条对齐）。</summary>
    public static List<QuickCommand> Defaults() => new()
    {
        new QuickCommand { Id = "qc1", Name = "磁盘", Group = "系统", Command = "df -h" },
        new QuickCommand { Id = "qc2", Name = "内存", Group = "系统", Command = "free -m" },
        new QuickCommand { Id = "qc3", Name = "进程TOP", Group = "系统", Command = "ps aux --sort=-%cpu | head -20" },
        new QuickCommand { Id = "qc7", Name = "端口监听", Group = "系统", Command = "ss -tulnp" },
        new QuickCommand { Id = "qc4", Name = "Nginx 重载", Group = "服务", Command = "sudo systemctl reload nginx" },
        new QuickCommand
        {
            Id = "qc5", Name = "看日志", Group = "服务", Command = "sudo tail -n ${lines} -f ${file}",
            Params = new List<QuickCommandParam>
            {
                new QuickCommandParam { Name = "lines", DefaultValue = "100", Required = false },
                new QuickCommandParam { Name = "file", DefaultValue = "/var/log/nginx/error.log", Required = true },
            }
        },
        new QuickCommand
        {
            Id = "qc6", Name = "Docker PS", Group = "容器",
            Command = "docker ps --format \"table {{.Names}}\\t{{.Status}}\\t{{.Ports}}\""
        },
        // Rust 工具链：远端跑 cargo 的常用动作（与 mac QuickCommandStore.defaults 对齐）。
        new QuickCommand
        {
            Id = "rs1", Name = "cargo build", Group = "Rust", Command = "cargo build ${flags}",
            Params = new List<QuickCommandParam>
            {
                new QuickCommandParam { Name = "flags", DefaultValue = "--release", Required = false },
            }
        },
        new QuickCommand
        {
            Id = "rs2", Name = "cargo test", Group = "Rust", Command = "cargo test ${args}",
            Params = new List<QuickCommandParam>
            {
                new QuickCommandParam { Name = "args", DefaultValue = "", Required = false },
            }
        },
        new QuickCommand { Id = "rs3", Name = "cargo clippy", Group = "Rust", Command = "cargo clippy --all-targets -- -D warnings" },
        new QuickCommand { Id = "rs4", Name = "cargo fmt 检查", Group = "Rust", Command = "cargo fmt --all -- --check" },
        new QuickCommand
        {
            Id = "rs5", Name = "cargo run", Group = "Rust", Command = "cargo run ${args}",
            Params = new List<QuickCommandParam>
            {
                new QuickCommandParam { Name = "args", DefaultValue = "", Required = false },
            }
        },
        new QuickCommand { Id = "rs6", Name = "工具链版本", Group = "Rust", Command = "rustc -Vv; cargo -V; rustup show active-toolchain 2>/dev/null" },
    };
}

/// <summary>发送目标（对齐 mac SendTarget：当前会话 / 所有已连接会话 / 指定会话下标）。</summary>
public enum SendTargetKind { Current, AllConnected, Session }

public readonly struct SendTarget
{
    public SendTargetKind Kind { get; }
    public int SessionIndex { get; }

    private SendTarget(SendTargetKind kind, int sessionIndex)
    {
        Kind = kind;
        SessionIndex = sessionIndex;
    }

    public static SendTarget Current { get; } = new(SendTargetKind.Current, -1);
    public static SendTarget AllConnected { get; } = new(SendTargetKind.AllConnected, -1);
    public static SendTarget Session(int index) => new(SendTargetKind.Session, index);
}
