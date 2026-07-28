using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PixShell;

/// <summary>
/// 单个主机条目。字段对齐 BLUEPRINT：id/name/host/port/username/group/osId。
/// 注意：这里绝不放明文密码，密码由 <see cref="CredentialStore"/> 用 DPAPI 单独加密存储。
/// </summary>
public class HostEntry
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "";
    public string Host { get; set; } = "";
    public int Port { get; set; } = 22;
    public string Username { get; set; } = "";
    public string Group { get; set; } = "默认";
    public string OsId { get; set; } = "";

    /// <summary>私钥文件路径（可含环境变量，登录时展开）。留空表示走密码登录。
    /// 不进 DPAPI 凭据库——私钥本身仍在磁盘原路径，这里只记路径，不拷贝/不加密存储。
    /// 对齐 mac Host.keyPath。旧 hosts.json 没有这个字段时，JSON 反序列化按默认值 "" 处理，不影响解析。</summary>
    public string KeyPath { get; set; } = "";

    /// <summary>出站代理引用：对应 ProxyConfig.Id（见 Proxy/ProxyConfig.cs）。留空 = 直连，不经代理。
    /// 对齐 mac Host.proxyId。</summary>
    public string ProxyId { get; set; } = "";

    /// <summary>连接类型：100 = SSH（默认），200 = RDP，300 = 本机终端（应用内本地 shell）。
    /// 对齐 mac Host.connectionType。RDP 拉 mstsc；本机终端走 TerminalSession.ConnectLocalAsync，不弹 wt/cmd。</summary>
    public int ConnectionType { get; set; } = 100;

    /// <summary>RDP 主机（Windows 远程桌面）。</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public bool IsRdp => ConnectionType == 200;

    /// <summary>本机终端会话（应用内本地 shell，不经 SSH）。</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public bool IsLocal => ConnectionType == 300;

    public override string ToString() =>
        string.IsNullOrWhiteSpace(Name) ? $"{Username}@{Host}" : Name;

    /// <summary>卡片标题：优先显示名称，否则 user@host（对齐 mac Host.display）。</summary>
    public string Display => string.IsNullOrWhiteSpace(Name) ? $"{Username}@{Host}" : Name;

    /// <summary>卡片副标题：user@host:port；本机终端显示 user@local。</summary>
    public string Subtitle => IsLocal
        ? (string.IsNullOrWhiteSpace(Username) ? "local" : $"{Username}@local")
        : $"{Username}@{Host}:{Port}";

    /// <summary>快速连接 logo 打开的本机终端主机（不进 hosts.json）。</summary>
    public static HostEntry LocalTerminal() => new()
    {
        Id = "local-" + Guid.NewGuid().ToString("N"),
        Name = "本机终端",
        Host = "localhost",
        Port = 0,
        Username = Environment.UserName,
        Group = "",
        OsId = "windows",
        ConnectionType = 300,
    };
}

/// <summary>
/// 主机清单持久化：明文 JSON 存 %APPDATA%\PixShell\hosts.json（不含密码）。
/// </summary>
public static class HostStore
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public static string AppDir
    {
        get
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "PixShell");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    private static string HostsPath => Path.Combine(AppDir, "hosts.json");

    public static List<HostEntry> Load()
    {
        try
        {
            if (!File.Exists(HostsPath)) return new List<HostEntry>();
            var json = File.ReadAllText(HostsPath, Encoding.UTF8);
            return JsonSerializer.Deserialize<List<HostEntry>>(json, JsonOpts)
                   ?? new List<HostEntry>();
        }
        catch
        {
            return new List<HostEntry>();
        }
    }

    public static void Save(List<HostEntry> hosts)
    {
        var json = JsonSerializer.Serialize(hosts, JsonOpts);
        File.WriteAllText(HostsPath, json, Encoding.UTF8);
    }

    /// <summary>按 id 合并写入（导入主机 JSON 用）：已存在则整体覆盖，否则追加。</summary>
    public static void Upsert(HostEntry entry)
    {
        var list = Load();
        var i = list.FindIndex(h => h.Id == entry.Id);
        if (i >= 0) list[i] = entry; else list.Add(entry);
        Save(list);
    }
}

/// <summary>
/// 快速连接「历史」记录：只存主机 id 的有序列表（最近的在前），存
/// %APPDATA%\PixShell\recents.json。首次运行时以当前 hosts.json 播种，
/// 对齐 mac 版 HostStore.recentHosts/noteRecent/clearRecents。
/// </summary>
public static class RecentsStore
{
    private static string RecentsPath => Path.Combine(HostStore.AppDir, "recents.json");
    private const int MaxRecents = 30;

    public static List<string> LoadIds()
    {
        try
        {
            if (!File.Exists(RecentsPath))
            {
                // 首运行：用已存主机列表播种（顺序即历史顺序）。
                var seeded = HostStore.Load().ConvertAll(h => h.Id);
                SaveIds(seeded);
                return seeded;
            }
            var json = File.ReadAllText(RecentsPath, Encoding.UTF8);
            return JsonSerializer.Deserialize<List<string>>(json) ?? new List<string>();
        }
        catch
        {
            return new List<string>();
        }
    }

    private static void SaveIds(List<string> ids)
    {
        var json = JsonSerializer.Serialize(ids);
        File.WriteAllText(RecentsPath, json, Encoding.UTF8);
    }

    /// <summary>记一次连接：置顶该主机 id，去重，截断长度。</summary>
    public static void NoteRecent(string hostId)
    {
        var ids = LoadIds();
        ids.RemoveAll(id => id == hostId);
        ids.Insert(0, hostId);
        if (ids.Count > MaxRecents) ids.RemoveRange(MaxRecents, ids.Count - MaxRecents);
        SaveIds(ids);
    }

    public static void ClearRecents() => SaveIds(new List<string>());

    /// <summary>把历史 id 列表解析成主机对象（按历史顺序；已被删除的主机自动跳过）。</summary>
    public static List<HostEntry> RecentHosts(IEnumerable<HostEntry> allHosts)
    {
        var byId = new Dictionary<string, HostEntry>();
        foreach (var h in allHosts) byId[h.Id] = h;
        var result = new List<HostEntry>();
        foreach (var id in LoadIds())
            if (byId.TryGetValue(id, out var h)) result.Add(h);
        return result;
    }
}

/// <summary>
/// 密码存储：用 Windows DPAPI（<see cref="ProtectedData"/>，scope=CurrentUser）加密后
/// 存 %APPDATA%\PixShell\creds.dat，按 host id 关联。密文只能被当前 Windows 用户解出，
/// 不落明文。文件格式：JSON 字典 { host-id: base64(密文) }。
/// </summary>
public static class CredentialStore
{
    // 附加熵：与 DPAPI 主密钥一起参与加解密，提升一点点强度（应用固定值即可）。
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("PixShell.v1.creds");

    private static string CredsPath => Path.Combine(HostStore.AppDir, "creds.dat");

    private static Dictionary<string, string> LoadMap()
    {
        try
        {
            if (!File.Exists(CredsPath)) return new Dictionary<string, string>();
            var json = File.ReadAllText(CredsPath, Encoding.UTF8);
            return JsonSerializer.Deserialize<Dictionary<string, string>>(json)
                   ?? new Dictionary<string, string>();
        }
        catch
        {
            return new Dictionary<string, string>();
        }
    }

    private static void SaveMap(Dictionary<string, string> map)
    {
        var json = JsonSerializer.Serialize(map);
        File.WriteAllText(CredsPath, json, Encoding.UTF8);
    }

    /// <summary>保存/更新某主机的密码（DPAPI 加密）。空密码表示清除。</summary>
    public static void SetPassword(string hostId, string? password)
    {
        var map = LoadMap();
        if (string.IsNullOrEmpty(password))
        {
            map.Remove(hostId);
        }
        else
        {
            var cipher = ProtectedData.Protect(
                Encoding.UTF8.GetBytes(password), Entropy, DataProtectionScope.CurrentUser);
            map[hostId] = Convert.ToBase64String(cipher);
        }
        SaveMap(map);
    }

    /// <summary>取回明文密码；不存在或解密失败返回 null。</summary>
    public static string? GetPassword(string hostId)
    {
        var map = LoadMap();
        if (!map.TryGetValue(hostId, out var b64) || string.IsNullOrEmpty(b64))
            return null;
        try
        {
            var plain = ProtectedData.Unprotect(
                Convert.FromBase64String(b64), Entropy, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plain);
        }
        catch
        {
            return null;
        }
    }

    public static void Remove(string hostId)
    {
        var map = LoadMap();
        if (map.Remove(hostId)) SaveMap(map);
    }
}

public class UiPrefs
{
    public double SidebarWidth { get; set; } = 240;
    /// <summary>底部文件/命令坞高度（对齐 mac pixshell.bottomHeight）。</summary>
    public double BottomHeight { get; set; } = 230;
}

public static class UiStore
{
    private static string PrefsPath => Path.Combine(HostStore.AppDir, "ui_prefs.json");
    public static UiPrefs Load()
    {
        try { return JsonSerializer.Deserialize<UiPrefs>(File.ReadAllText(PrefsPath)) ?? new UiPrefs(); }
        catch { return new UiPrefs(); }
    }
    public static void Save(UiPrefs prefs) => File.WriteAllText(PrefsPath, JsonSerializer.Serialize(prefs));
}
