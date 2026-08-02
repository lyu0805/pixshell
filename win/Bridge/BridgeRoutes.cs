using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;

namespace PixShell.Bridge;

/// <summary>
/// 应用侧需要实现的最小状态接口：桥只依赖这个接口，绝不依赖 MainWindow 的具体实现，保持桥接层
/// 可独立测试/替换（对齐 mac Bridge/BridgeRoutes.swift 的 BridgeHost 协议）。
///
/// 约定：这里的 session 用整数下标表示当前打开的会话（对应 MainWindow 里 Sessions.Items 的下标），
/// 不是老 JS 版里的 "ssh_xxxx" 字符串 id——外部 CLI 从 GET /v1/app/sessions 里看到的 session 字段
/// 是什么，回传时原样带回来即可，这里负责把它解析成 int 再转交给宿主。
/// </summary>
public interface IBridgeHost
{
    /// <summary>保存的主机列表（绝不包含密码/私钥内容）。</summary>
    List<Dictionary<string, object?>> BridgeHosts();
    /// <summary>当前打开的会话列表。</summary>
    List<Dictionary<string, object?>> BridgeSessions();
    /// <summary>按 hostId 打开一个新会话；只用已保存凭据，绝不弹密码框。</summary>
    Task<Dictionary<string, object?>> BridgeConnectAsync(string hostId);
    /// <summary>把文本写进某会话的交互 shell（看得见，像手敲）。返回 false 表示会话不存在/写入失败。</summary>
    bool BridgeWrite(int session, string text);
    /// <summary>一次性执行命令并返回 stdout（独立通道，不进终端画面）。</summary>
    Task<string> BridgeExecAsync(int session, string cmd);
    /// <summary>读取某会话最近的终端输出（最多 lines 行；&lt;=0 表示使用默认值）。</summary>
    string BridgeScreen(int session, int lines);
    /// <summary>SFTP 列目录。</summary>
    Task<List<Dictionary<string, object?>>> BridgeSftpListAsync(int session, string path);
    /// <summary>SFTP 下载；返回落地的本地路径，失败抛异常。</summary>
    Task<string?> BridgeSftpDownloadAsync(int session, string remote, string local);
    /// <summary>SFTP 上传；返回远端路径，失败抛异常。</summary>
    Task<string?> BridgeSftpUploadAsync(int session, string local, string remote);
    /// <summary>关闭全部会话并释放桥（有头接管时让无头退出用）。</summary>
    void BridgeShutdown();
}

/// <summary>一次已解析的 HTTP 请求：AgentBridge 完成分帧、鉴权、Origin 校验之后，把纯业务部分交给
/// BridgeRouter 处理，二者职责严格分离（对齐 mac BridgeRequest）。</summary>
public sealed class BridgeRequest
{
    public string Method = "GET";          // 已转大写
    public string Path = "/";              // 已去掉查询串、已去掉末尾多余 "/"（根路径 "/" 除外）
    public Dictionary<string, string> Query = new();
    /// <summary>仅在需要 body 的方法（POST/PUT/PATCH）上非 null；GET 恒为 null。</summary>
    public JsonElement? Body;
}

public sealed class BridgeResponse
{
    public int Status;
    public object Json = new();
    /// <summary>非空时 AgentBridge 以 HTML/文本直接回写（Web SSH 页）；优先于 Json。</summary>
    public string? Html;
    public string? ContentType;
    public static BridgeResponse Ok(object json) => new() { Status = 200, Json = json };
    public static BridgeResponse Fail(int status, string error) => new() { Status = status, Json = new { ok = false, error } };
    public static BridgeResponse HtmlOk(string html, string contentType = "text/html; charset=utf-8") =>
        new() { Status = 200, Html = html, ContentType = contentType, Json = new { ok = true } };
}

/// <summary>
/// 路径路由：把 HTTP 请求映射到 IBridgeHost 调用，路径/别名严格对齐老仓库
/// packages/app/main/agent-bridge.js 的 /v1/app/* 语义（与 mac Bridge/BridgeRoutes.swift 逐路由对齐），
/// 保证现有 pixshell-cli 不用改。
/// </summary>
public static class BridgeRouter
{
    /// <summary>桥接协议自身的版本号（区别于 App 版本），供 CLI 诊断用。</summary>
    public const string BridgeVersion = "1.0.0-cs";

    /// <summary>会话号是否真的存在。越界必须明确报错，不能返回 ok:true + 空输出 ——
    /// 那样 agent 分不清"命令没有输出"和"会话号写错了"，只能瞎猜。</summary>
    private static bool ValidSession(IBridgeHost host, int sid) =>
        sid >= 0 && sid < host.BridgeSessions().Count;

    public static async Task<BridgeResponse> RouteAsync(BridgeRequest req, IBridgeHost? host)
    {
        var p = req.Path;
        var method = req.Method;

        if (p == "/v1/health" || p == "/health")
        {
            return BridgeResponse.Ok(new { ok = true, version = BridgeVersion, sessions = host?.BridgeSessions().Count ?? 0 });
        }

        if (host == null) return BridgeResponse.Fail(500, "bridge host not attached");

        try
        {
            switch (p)
            {
                case "/v1/app/hosts":
                case "/v1/app/host-list":
                    if (method != "GET") return BridgeResponse.Fail(405, "use GET");
                    return RouteHosts(req, host);

                case "/v1/app/hosts/connect":
                case "/v1/app/connect":
                    if (method != "POST") return BridgeResponse.Fail(405, "use POST (password must not go in query string)");
                    return await RouteConnect(req, host).ConfigureAwait(false);

                case "/v1/app/sessions":
                case "/v1/app/list":
                    if (method != "GET") return BridgeResponse.Fail(405, "use GET");
                    return BridgeResponse.Ok(new { ok = true, sessions = host.BridgeSessions() });

                case "/v1/app/shell":
                    if (method != "POST") return BridgeResponse.Fail(405, "use POST");
                    return RouteShell(req, host);

                case "/v1/app/exec":
                case "/v1/app/direct":
                    if (method != "POST") return BridgeResponse.Fail(405, "use POST");
                    return await RouteExec(req, host).ConfigureAwait(false);

                case "/v1/app/screen":
                case "/v1/app/read":
                    if (method != "GET" && method != "POST") return BridgeResponse.Fail(405, "use GET/POST");
                    return RouteScreen(req, host);

                case "/v1/app/sftp/list":
                    if (method != "GET" && method != "POST") return BridgeResponse.Fail(405, "use GET/POST");
                    return await RouteSftpList(req, host).ConfigureAwait(false);

                case "/v1/app/sftp/download":
                    if (method != "POST") return BridgeResponse.Fail(405, "use POST");
                    return await RouteSftpDownload(req, host).ConfigureAwait(false);

                case "/v1/app/sftp/upload":
                    if (method != "POST") return BridgeResponse.Fail(405, "use POST");
                    return await RouteSftpUpload(req, host).ConfigureAwait(false);

                // 有头接管：无头进程收到后关闭全部会话并退出让位（对齐 mac BridgeRoutes.swift）。
                case "/v1/app/shutdown":
                    if (method != "POST") return BridgeResponse.Fail(405, "use POST");
                    host.BridgeShutdown();
                    return BridgeResponse.Ok(new { ok = true });

                // Web SSH 页由 AgentBridge 直接处理，不走路由层。

                default:
                    return BridgeResponse.Fail(404, "not found");
            }
        }
        catch (Exception ex)
        {
            // 兜底：任何 handler 内部异常都转成 JSON 错误响应，绝不让未处理异常炸到调用方。
            return BridgeResponse.Fail(500, ex.Message);
        }
    }

    private static BridgeResponse RouteHosts(BridgeRequest req, IBridgeHost host)
    {
        var hosts = host.BridgeHosts();
        var gid = QueryField(req.Query, "group-id", "group_id", "g");
        if (!string.IsNullOrEmpty(gid))
        {
            var filtered = hosts.Where(h => (h.TryGetValue("group", out var g) ? g as string ?? "" : "") == gid).ToList();
            return BridgeResponse.Ok(new { ok = true, hosts = filtered });
        }
        return BridgeResponse.Ok(new { ok = true, hosts });
    }

    private static async Task<BridgeResponse> RouteConnect(BridgeRequest req, IBridgeHost host)
    {
        var hostId = StringField(req.Body, "host_id", "hostId", "id");
        if (string.IsNullOrEmpty(hostId)) return BridgeResponse.Fail(400, "缺少 host_id");
        try
        {
            var dict = await host.BridgeConnectAsync(hostId).ConfigureAwait(false);
            dict["ok"] = true;
            return new BridgeResponse { Status = 200, Json = dict };
        }
        catch (Exception ex)
        {
            return BridgeResponse.Fail(400, ex.Message);
        }
    }

    private static BridgeResponse RouteShell(BridgeRequest req, IBridgeHost host)
    {
        if (!TrySessionField(req, out var sid)) return BridgeResponse.Fail(400, "会话不存在或 id 不唯一");

        var cmd = StringField(req.Body, "cmd");
        var text = StringField(req.Body, "text") ?? cmd ?? "";
        var hasCmd = HasKey(req.Body, "cmd");
        var hasText = HasKey(req.Body, "text");
        var newlineField = GetField(req.Body, "newline");

        if (hasCmd && !hasText)
        {
            // shell --cmd：自动补回车
            if (!text.EndsWith('\n') && !text.EndsWith('\r')) text += "\n";
        }
        else if (IsTruthy(newlineField))
        {
            if (!text.EndsWith('\n') && !text.EndsWith('\r')) text += "\n";
        }
        else if (IsExplicitFalse(newlineField))
        {
            // 保持原样，不追加换行
        }
        else if (cmd != null)
        {
            if (!text.EndsWith('\n')) text += "\n";
        }

        if (host.BridgeWrite(sid, text))
            return BridgeResponse.Ok(new { ok = true, sessionId = sid, bytes = System.Text.Encoding.UTF8.GetByteCount(text) });
        return BridgeResponse.Fail(400, "write failed");
    }

    private static async Task<BridgeResponse> RouteExec(BridgeRequest req, IBridgeHost host)
    {
        if (!TrySessionField(req, out var sid)) return BridgeResponse.Fail(400, "会话不存在或 id 不唯一");
        var cmd = StringField(req.Body, "cmd", "command", "text");
        if (string.IsNullOrEmpty(cmd)) return BridgeResponse.Fail(400, "缺少 cmd");
        if (!ValidSession(host, sid))
        {
            Logging.Log.Warn($"exec 指定的会话不存在 session={sid}（共 {host.BridgeSessions().Count} 个）", "bridge");
            return BridgeResponse.Fail(404, $"会话 {sid} 不存在（当前共 {host.BridgeSessions().Count} 个，用 /v1/app/sessions 查）");
        }
        var stdout = await host.BridgeExecAsync(sid, cmd).ConfigureAwait(false);
        return BridgeResponse.Ok(new { ok = true, sessionId = sid, stdout, stderr = "" });
    }

    private static BridgeResponse RouteScreen(BridgeRequest req, IBridgeHost host)
    {
        if (!TrySessionField(req, out var sid)) return BridgeResponse.Fail(400, "会话不存在或 id 不唯一");
        var linesRaw = req.Query.GetValueOrDefault("lines") ?? req.Query.GetValueOrDefault("n") ?? StringField(req.Body, "lines", "n");
        var n = int.TryParse(linesRaw, out var parsed) ? parsed : 200;
        if (!ValidSession(host, sid))
        {
            Logging.Log.Warn($"screen 指定的会话不存在 session={sid}（共 {host.BridgeSessions().Count} 个）", "bridge");
            return BridgeResponse.Fail(404, $"会话 {sid} 不存在（当前共 {host.BridgeSessions().Count} 个，用 /v1/app/sessions 查）");
        }
        var text = host.BridgeScreen(sid, n);
        var lines = text.Split('\n');
        return BridgeResponse.Ok(new { ok = true, sessionId = sid, text, lines, totalLines = lines.Length });
    }

    private static async Task<BridgeResponse> RouteSftpList(BridgeRequest req, IBridgeHost host)
    {
        if (!TrySessionField(req, out var sid)) return BridgeResponse.Fail(400, "会话不存在");
        var path = StringField(req.Body, "path", "remote", "remotePath")
                   ?? req.Query.GetValueOrDefault("path") ?? req.Query.GetValueOrDefault("p") ?? "/";
        try
        {
            var entries = await host.BridgeSftpListAsync(sid, path).ConfigureAwait(false);
            return BridgeResponse.Ok(new { ok = true, path, entries });
        }
        catch (Exception ex)
        {
            return BridgeResponse.Fail(400, ex.Message);
        }
    }

    private static async Task<BridgeResponse> RouteSftpDownload(BridgeRequest req, IBridgeHost host)
    {
        if (!TrySessionField(req, out var sid)) return BridgeResponse.Fail(400, "会话不存在");
        var remote = StringField(req.Body, "remote", "remotePath", "path");
        if (string.IsNullOrEmpty(remote)) return BridgeResponse.Fail(400, "缺少 remote");
        var local = StringField(req.Body, "local", "localPath") ?? DefaultDownloadLocal(remote);
        if (!IsSafeLocalPath(local, out var safeLocal)) return BridgeResponse.Fail(403, "不允许访问此本地路径");
        try
        {
            var result = await host.BridgeSftpDownloadAsync(sid, remote, safeLocal).ConfigureAwait(false);
            return result != null ? BridgeResponse.Ok(new { ok = true, localPath = result }) : BridgeResponse.Fail(400, "download failed");
        }
        catch (Exception ex)
        {
            return BridgeResponse.Fail(400, ex.Message);
        }
    }

    private static async Task<BridgeResponse> RouteSftpUpload(BridgeRequest req, IBridgeHost host)
    {
        if (!TrySessionField(req, out var sid)) return BridgeResponse.Fail(400, "会话不存在");
        var local = StringField(req.Body, "local", "localPath");
        var remote = StringField(req.Body, "remote", "remotePath");
        if (string.IsNullOrEmpty(local) || string.IsNullOrEmpty(remote)) return BridgeResponse.Fail(400, "需要 local 与 remote");
        if (!IsSafeLocalPath(local, out var safeLocal)) return BridgeResponse.Fail(403, "不允许访问此本地路径");
        try
        {
            var result = await host.BridgeSftpUploadAsync(sid, safeLocal, remote).ConfigureAwait(false);
            return result != null ? BridgeResponse.Ok(new { ok = true, remotePath = result }) : BridgeResponse.Fail(400, "upload failed");
        }
        catch (Exception ex)
        {
            return BridgeResponse.Fail(400, ex.Message);
        }
    }

    // =====================================================================
    // 小工具
    // =====================================================================

    private static string? QueryField(Dictionary<string, string> query, params string[] keys)
    {
        foreach (var k in keys)
            if (query.TryGetValue(k, out var v) && !string.IsNullOrEmpty(v)) return v;
        return null;
    }

    private static bool HasKey(JsonElement? body, string key) =>
        body is { ValueKind: JsonValueKind.Object } b && b.TryGetProperty(key, out _);

    private static JsonElement? GetField(JsonElement? body, string key)
    {
        if (body is { ValueKind: JsonValueKind.Object } b && b.TryGetProperty(key, out var v)) return v;
        return null;
    }

    private static string? StringField(JsonElement? body, params string[] keys)
    {
        if (body is not { ValueKind: JsonValueKind.Object } b) return null;
        foreach (var k in keys)
        {
            if (!b.TryGetProperty(k, out var v)) continue;
            switch (v.ValueKind)
            {
                case JsonValueKind.String: return v.GetString();
                case JsonValueKind.Number: return v.ToString();
                case JsonValueKind.True: return "true";
                case JsonValueKind.False: return "false";
            }
        }
        return null;
    }

    private static bool IsTruthy(JsonElement? v)
    {
        if (v is not { } val) return false;
        return val.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.Number => val.TryGetInt64(out var n) && n != 0,
            JsonValueKind.String => val.GetString() is "1" or "true" or "True" or "TRUE",
            _ => false,
        };
    }

    private static bool IsExplicitFalse(JsonElement? v)
    {
        if (v is not { } val) return false;
        return val.ValueKind switch
        {
            JsonValueKind.False => true,
            JsonValueKind.String => val.GetString() is "0" or "false" or "False" or "FALSE",
            _ => false,
        };
    }

    /// <summary>session 在本机以数组下标（int）表示；接受 JSON number 或数字字符串，兼容 body 字段与
    /// query 字段两种来源（GET /v1/app/screen 等走 query）。</summary>
    private static bool TrySessionField(BridgeRequest req, out int session)
    {
        session = -1;
        if (req.Body is { ValueKind: JsonValueKind.Object } b)
        {
            foreach (var k in new[] { "session", "session_id", "sessionId" })
            {
                if (!b.TryGetProperty(k, out var v)) continue;
                if (v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var n)) { session = n; return true; }
                if (v.ValueKind == JsonValueKind.String && int.TryParse(v.GetString()?.Trim(), out var ns)) { session = ns; return true; }
            }
        }
        foreach (var k in new[] { "session", "session_id", "s" })
        {
            if (req.Query.TryGetValue(k, out var qs) && int.TryParse(qs.Trim(), out var qn)) { session = qn; return true; }
        }
        return false;
    }

    private static string DefaultDownloadLocal(string remote)
    {
        var basePart = remote.Replace('\\', '/');
        var idx = basePart.LastIndexOf('/');
        var name = idx >= 0 ? basePart[(idx + 1)..] : basePart;
        if (string.IsNullOrEmpty(name)) name = "file";
        var safe = name.Replace("/", "_").Replace("\\", "_");
        return Path.Combine(Path.GetTempPath(), "pixshell-dl-" + safe);
    }

    private static bool IsSafeLocalPath(string path, out string normalized)
    {
        normalized = string.Empty;
        if (string.IsNullOrEmpty(path) || path.Contains("..")) return false;
        try
        {
            normalized = Path.GetFullPath(path);
            var downloads = Path.GetFullPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads"));
            var temp = Path.GetFullPath(Path.GetTempPath());
            
            bool IsUnder(string root) =>
                normalized.StartsWith(root, StringComparison.OrdinalIgnoreCase) &&
                (normalized.Length == root.Length || 
                 normalized[root.Length] == Path.DirectorySeparatorChar || 
                 normalized[root.Length] == Path.AltDirectorySeparatorChar || 
                 root.EndsWith(Path.DirectorySeparatorChar.ToString()));

            return IsUnder(downloads) || IsUnder(temp);
        }
        catch
        {
            return false;
        }
    }
}
