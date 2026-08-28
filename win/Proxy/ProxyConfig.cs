using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PixShell.Proxy;

/// <summary>
/// 代理类型。字段/归一化规则对齐老仓库 packages/proxy/src/index.js（createProxy/normalizeProxyType），
/// 与 mac 版 Proxy/ProxyConfig.swift 的 ProxyType 1:1 对应。
///
/// 关于 SshJump（跳板机）：真正实现跳板逻辑（在跳板机上再开一个 forward channel）不在本次范围内。
/// 这个枚举值只是为了让老配置文件（type 是字符串 "ssh-jump" 或历史数字码 200）解码时不失败、不丢数据；
/// 拨号时一旦遇到 SshJump 一律当作"未配置代理"处理：记一条 Log.Warn 后直接走原来的直连路径。
/// 管理面板（ProxyWindow）新建/编辑时也只暴露 Socks5/Socks4/Http 三种可选类型。
/// </summary>
public enum ProxyType
{
    Socks5,
    Socks4,
    Http,
    SshJump,
}

/// <summary>
/// 代理配置模型。默认值/端口规则与 JS createProxy/defaultPort、mac ProxyConfig 1:1 对齐。
/// </summary>
public class ProxyConfig
{
    public string Id { get; set; } = NewId();
    public string Name { get; set; } = "proxy";
    public ProxyType Type { get; set; } = ProxyType.Socks5;
    public string Host { get; set; } = "";
    public int Port { get; set; } = DefaultPort(ProxyType.Socks5);
    public string Username { get; set; } = "";
    public string Password { get; set; } = "";

    /// <summary>对齐 JS `'px_' + Date.now().toString(36)`。</summary>
    public static string NewId() => "px_" + ToBase36(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());

    private static string ToBase36(long value)
    {
        const string digits = "0123456789abcdefghijklmnopqrstuvwxyz";
        var chars = new char[13];
        var index = chars.Length;
        do
        {
            chars[--index] = digits[(int)(value % 36)];
            value /= 36;
        } while (value > 0);
        return new string(chars, index, chars.Length - index);
    }

    /// <summary>对齐 JS defaultPort / mac ProxyConfig.defaultPort。</summary>
    public static int DefaultPort(ProxyType type) => type switch
    {
        ProxyType.Http => 8080,
        ProxyType.SshJump => 22,
        _ => 1080, // socks4/socks5
    };

    /// <summary>对齐 JS normalizeProxyType：历史数字码 100→socks5、200→ssh-jump，合法字符串原样识别，其余回落 socks5。</summary>
    public static ProxyType NormalizeType(string raw) => raw switch
    {
        "100" => ProxyType.Socks5,
        "200" => ProxyType.SshJump,
        "socks4" => ProxyType.Socks4,
        "socks5" => ProxyType.Socks5,
        "http" => ProxyType.Http,
        "ssh-jump" => ProxyType.SshJump,
        _ => ProxyType.Socks5,
    };

    public string DisplayName => Type switch
    {
        ProxyType.Socks5 => "SOCKS5",
        ProxyType.Socks4 => "SOCKS4",
        ProxyType.Http => "HTTP",
        ProxyType.SshJump => "SSH跳板(暂不支持)",
        _ => Type.ToString(),
    };
}

/// <summary>
/// 代理列表持久化：`%APPDATA%\PixShell\proxies.json`。风格照抄 Storage.cs 的 HostStore。
/// 容错加载：文件不存在/整体解析失败 → 退回空列表，绝不因为一份坏文件崩溃或丢已有配置。
/// JSON 里的 "type" 字段可能是字符串（新格式）也可能是历史数字码（老配置），用自定义转换器兼容两种。
/// </summary>
public static class ProxyStore
{
    private static string CredentialId(string id) => "proxy-password-" + id;
    private static string FilePath => Path.Combine(HostStore.AppDir, "proxies.json");

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        Converters = { new ProxyTypeJsonConverter() },
    };

    public static List<ProxyConfig> Load()
    {
        try
        {
            if (!File.Exists(FilePath)) return new List<ProxyConfig>();
            var json = File.ReadAllText(FilePath);
            var list = JsonSerializer.Deserialize<List<ProxyConfig>>(json, JsonOpts) ?? new List<ProxyConfig>();
            var migrated = false;
            var migrationFailed = false;
            foreach (var proxy in list)
            {
                if (!string.IsNullOrEmpty(proxy.Password))
                {
                    var legacyPassword = proxy.Password;
                    var thisMigrationFailed = false;
                    try
                    {
                        CredentialStore.SetPassword(CredentialId(proxy.Id), legacyPassword);
                        if (CredentialStore.GetPassword(CredentialId(proxy.Id)) == legacyPassword)
                            migrated = true;
                        else
                            thisMigrationFailed = true;
                    }
                    catch
                    {
                        thisMigrationFailed = true;
                    }
                    if (thisMigrationFailed)
                    {
                        migrationFailed = true;
                        Logging.Log.Warn($"代理 {proxy.Id} 的明文凭据迁移失败，保留原配置", "proxy");
                        continue;
                    }
                }
                proxy.Password = CredentialStore.GetPassword(CredentialId(proxy.Id)) ?? "";
            }
            if (migrated && !migrationFailed) SaveConfig(list);
            return list;
        }
        catch (Exception ex)
        {
            Logging.Log.Warn($"代理配置解析失败，使用空列表: {ex.Message}", "proxy");
            return new List<ProxyConfig>();
        }
    }

    private static void SaveConfig(List<ProxyConfig> list)
    {
        try
        {
            var safe = list.Select(proxy => new ProxyConfig
            {
                Id = proxy.Id, Name = proxy.Name, Type = proxy.Type, Host = proxy.Host,
                Port = proxy.Port, Username = proxy.Username, Password = "",
            }).ToList();
            File.WriteAllText(FilePath, JsonSerializer.Serialize(safe, JsonOpts));
        }
        catch (Exception ex) { Logging.Log.Warn($"代理配置保存失败: {ex.Message}", "proxy"); }
    }

    public static List<ProxyConfig> List() => Load();

    /// <summary>对齐 JS findProxyById：空 id 或 "0" 视为"不使用代理"。</summary>
    public static ProxyConfig? Find(string? id)
    {
        if (string.IsNullOrEmpty(id) || id == "0") return null;
        return Load().FirstOrDefault(p => p.Id == id);
    }

    public static void Upsert(ProxyConfig p)
    {
        var list = Load();
        var i = list.FindIndex(x => x.Id == p.Id);
        if (i >= 0) list[i] = p; else list.Add(p);
        try
        {
            foreach (var proxy in list)
            {
                if (string.IsNullOrEmpty(proxy.Password) && proxy.Id != p.Id) continue;
                CredentialStore.SetPassword(CredentialId(proxy.Id), proxy.Password);
                var stored = CredentialStore.GetPassword(CredentialId(proxy.Id));
                if ((!string.IsNullOrEmpty(proxy.Password) && stored != proxy.Password)
                    || (string.IsNullOrEmpty(proxy.Password) && stored != null))
                    throw new InvalidOperationException("凭据写入后校验失败");
            }
            if (list.Any(proxy => !string.IsNullOrEmpty(proxy.Password)
                && CredentialStore.GetPassword(CredentialId(proxy.Id)) != proxy.Password))
                throw new InvalidOperationException("凭据写入后校验失败");
        }
        catch (Exception ex)
        {
            Logging.Log.Warn($"代理凭据保存失败，跳过代理配置写盘: {ex.Message}", "proxy");
            return;
        }
        SaveConfig(list);
    }

    public static void Delete(string id)
    {
        var list = Load();
        list.RemoveAll(x => x.Id == id);
        CredentialStore.Remove(CredentialId(id));
        SaveConfig(list);
    }
}

/// <summary>type 字段可能是字符串也可能是数字（老历史数字码），两种都能读；写回时总是写字符串。</summary>
internal sealed class ProxyTypeJsonConverter : JsonConverter<ProxyType>
{
    public override ProxyType Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.Number)
            return ProxyConfig.NormalizeType(reader.GetInt32().ToString());
        var s = reader.GetString() ?? "";
        return ProxyConfig.NormalizeType(s);
    }

    public override void Write(Utf8JsonWriter writer, ProxyType value, JsonSerializerOptions options)
    {
        var s = value switch
        {
            ProxyType.Socks5 => "socks5",
            ProxyType.Socks4 => "socks4",
            ProxyType.Http => "http",
            ProxyType.SshJump => "ssh-jump",
            _ => "socks5",
        };
        writer.WriteStringValue(s);
    }
}
