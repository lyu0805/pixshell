using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using PixShell.Logging;

namespace PixShell.Store;

/// <summary>
/// 备份包 v1（格式对齐 mac Store/BackupBundle.swift / 老仓库 sync/index.js）：
/// {Version:1, ExportedAt, Hosts(不含密码), Settings, QuickCommands}。
/// 密码从不进包——HostEntry 本身就不带密码字段（密码单独在 CredentialStore/DPAPI），天然满足"不含密码"。
/// QuickCommand/QuickCommandParam 模型定义在 Store/QuickCommands.cs（真实可编辑/持久化的快捷命令板），
/// 这里直接复用，导出的是用户实际存储的快捷命令，而非内置占位列表。
/// </summary>
public class BackupBundle
{
    public int Version { get; set; } = 1;
    public string ExportedAt { get; set; } = "";
    public List<HostEntry> Hosts { get; set; } = new();
    public Dictionary<string, string> Settings { get; set; } = new();
    public List<QuickCommand> QuickCommands { get; set; } = new();

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
    };

    public static BackupBundle Make(List<HostEntry> hosts, List<QuickCommand> quick, Dictionary<string, string> settings) => new()
    {
        Version = 1,
        ExportedAt = DateTime.UtcNow.ToString("o"),
        Hosts = hosts,
        Settings = settings,
        QuickCommands = quick,
    };

    public string Encode() => JsonSerializer.Serialize(this, JsonOpts);

    /// <summary>解析备份包 JSON；版本不是 1 则抛异常（调用方按"不是备份包"处理并尝试旧的纯数组格式）。</summary>
    public static BackupBundle Decode(string json)
    {
        var b = JsonSerializer.Deserialize<BackupBundle>(json, JsonOpts) ?? throw new Exception("空备份包");
        if (b.Version != 1) throw new Exception($"不支持的备份包版本 {b.Version}");
        return b;
    }
}

/// <summary>
/// WebDAV 备份（坚果云等）：PUT/GET 一个 JSON 文件，Basic 认证。对齐 mac WebDAVBackup。
/// 配置（URL/用户名/应用密码）持久化在 `%APPDATA%\PixShell\webdav.json`。
/// </summary>
public static class WebDavBackup
{
    private const string CredentialId = "webdav-backup-password";
    public class Config
    {
        public string Url { get; set; } = "";      // 形如 https://dav.jianguoyun.com/dav/pixshell/backup.json
        public string Username { get; set; } = "";
        public string Password { get; set; } = "";  // 应用密码
    }

    private static string FilePath => Path.Combine(HostStore.AppDir, "webdav.json");

    public static Config? Load()
    {
        try
        {
            if (!File.Exists(FilePath)) return null;
            var config = JsonSerializer.Deserialize<Config>(File.ReadAllText(FilePath), new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true,
            });
            if (config == null) return null;
            if (!string.IsNullOrEmpty(config.Password))
            {
                var legacyPassword = config.Password;
                CredentialStore.SetPassword(CredentialId, legacyPassword);
                if (CredentialStore.GetPassword(CredentialId) == legacyPassword)
                    Save(config);
                else
                    return config;
            }
            config.Password = CredentialStore.GetPassword(CredentialId) ?? "";
            return config;
        }
        catch { return null; }
    }

    public static void Save(Config c)
    {
        try
        {
            CredentialStore.SetPassword(CredentialId, c.Password);
            var stored = CredentialStore.GetPassword(CredentialId);
            if ((!string.IsNullOrEmpty(c.Password) && stored != c.Password)
                || (string.IsNullOrEmpty(c.Password) && stored != null))
                throw new InvalidOperationException("WebDAV 凭据写入后校验失败");
            var safe = new Config { Url = c.Url, Username = c.Username, Password = "" };
            File.WriteAllText(FilePath, JsonSerializer.Serialize(safe, new JsonSerializerOptions
            {
                WriteIndented = true,
                PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            }));
        }
        catch (Exception ex) { Log.Warn($"WebDAV 配置保存失败: {ex.Message}", "backup"); }
    }

    private static HttpRequestMessage? BuildRequest(Config c, HttpMethod method, string? body)
    {
        if (string.IsNullOrWhiteSpace(c.Url) || !Uri.TryCreate(c.Url, UriKind.Absolute, out var uri)) return null;
        var req = new HttpRequestMessage(method, uri);
        var token = Convert.ToBase64String(Encoding.UTF8.GetBytes($"{c.Username}:{c.Password}"));
        req.Headers.Authorization = new AuthenticationHeaderValue("Basic", token);
        if (body != null) req.Content = new StringContent(body, Encoding.UTF8, "application/json");
        return req;
    }

    /// <summary>上传备份包；返回 null 表示成功，否则返回错误描述。</summary>
    public static async Task<string?> Push(Config c, BackupBundle bundle)
    {
        var body = bundle.Encode();
        var req = BuildRequest(c, HttpMethod.Put, body);
        if (req == null) return "URL 无效";
        Log.Info($"WebDAV 上传 {c.Url}（{body.Length} 字节）", "backup");
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
            var resp = await http.SendAsync(req);
            if (resp.IsSuccessStatusCode) { Log.Info($"WebDAV 上传成功 {(int)resp.StatusCode}", "backup"); return null; }
            Log.Error($"WebDAV 上传 HTTP {(int)resp.StatusCode}", "backup");
            return $"HTTP {(int)resp.StatusCode}";
        }
        catch (Exception ex)
        {
            Log.Error($"WebDAV 上传失败: {ex.Message}", "backup");
            return ex.Message;
        }
    }

    /// <summary>下载备份包。</summary>
    public static async Task<(BackupBundle? bundle, string? error)> Pull(Config c)
    {
        var req = BuildRequest(c, HttpMethod.Get, null);
        if (req == null) return (null, "URL 无效");
        Log.Info($"WebDAV 下载 {c.Url}", "backup");
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
            var resp = await http.SendAsync(req);
            if (!resp.IsSuccessStatusCode)
            {
                Log.Error($"WebDAV 下载 HTTP {(int)resp.StatusCode}", "backup");
                return (null, $"HTTP {(int)resp.StatusCode}");
            }
            var text = await resp.Content.ReadAsStringAsync();
            var bundle = BackupBundle.Decode(text);
            return (bundle, null);
        }
        catch (Exception ex)
        {
            Log.Error($"WebDAV 下载失败/备份包解析失败: {ex.Message}", "backup");
            return (null, ex.Message);
        }
    }
}
