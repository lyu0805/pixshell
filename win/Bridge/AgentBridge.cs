using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using PixShell.Logging;

namespace PixShell.Bridge;

/// <summary>
/// 本地回环 HTTP 控制服务器：让外部 CLI（pixshell-cli，Claude Code / Codex / OpenCode 等）驱动正在
/// 运行的 PixShell 桌面端——列出已存主机、开会话、发命令、读屏幕、传文件。对齐老 JS 仓库
/// packages/app/main/agent-bridge.js 与 mac Bridge/AgentBridge.swift 的路径/语义、端口/鉴权文件不变，
/// 现有 pixshell-cli 无需任何修改即可继续工作。
///
/// 安全边界（纵深防御，任何一条都不能削弱）：
///   - 只绑定 127.0.0.1，绝不监听 0.0.0.0 / 局域网网卡（HttpListener 前缀直接写字面量 IP，
///     绝不用 "+"/"*"/机器名——那样既会暴露到局域网，也需要管理员权限做 URL-ACL 预留）；
///   - 每个已接受的请求都再核实一次远端地址是否回环；
///   - 每个请求都要求 token（%APPDATA%\PixShell\agent_token，仅当前用户可读写）；
///   - 不发任何 CORS 响应头，且只要请求带 Origin 头一律拒绝（挡住浏览器页面发起的 CSRF）；
///   - 请求体上限 8 MiB，超出返回 413；
///   - 绝不把 token 明文写进日志，只记录长度。
/// </summary>
public sealed class AgentBridge
{
    /// <summary>与老 JS 版 DEFAULT_PORT / mac AgentBridge.defaultPort 保持一致。</summary>
    public const int DefaultPort = 8766;
    /// <summary>请求体上限（sftp 上传等）：超过即拒绝，防止本地恶意/失控客户端把内存打爆。</summary>
    public const int MaxBodyBytes = 8 * 1024 * 1024;

    /// <summary>业务宿主（MainWindow 实现）。可为 null（桥已监听但 App 还没挂上宿主）。</summary>
    public IBridgeHost? Host { get; set; }

    public bool IsRunning { get; private set; }
    public int Port { get; private set; }
    public string TokenPath { get; }

    private HttpListener? _listener;
    private CancellationTokenSource? _cts;
    private string _token;

    /// <summary>最近一次"鉴权通过"的外部请求时间（供状态栏三态指示：未开启/已开启/已对接）；
    /// 从未有过合法请求则为 null。只在 token 校验成功时更新——401 不算"已对接"。
    /// 用锁保护读写：写入发生在请求处理线程，读取来自 UI 线程的轮询定时器。</summary>
    private readonly object _lastClientLock = new();
    private DateTime? _lastClientAt;
    public DateTime? LastClientAt
    {
        get { lock (_lastClientLock) return _lastClientAt; }
    }
    private void MarkClientAuthenticated()
    {
        lock (_lastClientLock) _lastClientAt = DateTime.UtcNow;
    }

    public AgentBridge(IBridgeHost? host = null)
    {
        Host = host;
        var envPort = Environment.GetEnvironmentVariable("PIXSHELL_BRIDGE_PORT");
        Port = (int.TryParse(envPort, out var p) && p > 0 && p < 65536) ? p : DefaultPort;
        TokenPath = ComputeTokenPath();
        _token = EnsureToken(TokenPath);
    }

    // =====================================================================
    // Token
    // =====================================================================

    private static string TokenDir()
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PixShell");
        Directory.CreateDirectory(dir);
        return dir;
    }

    private static string ComputeTokenPath() => Path.Combine(TokenDir(), "agent_token");

    /// <summary>读取已有 token；不存在/太短则用 RandomNumberGenerator 生成 32 字节并写盘（ACL 收紧到
    /// 当前用户）。铁律：绝不把 token 明文写进日志。</summary>
    private static string EnsureToken(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                var s = File.ReadAllText(path).Trim();
                if (s.Length >= 16) return s;
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"读取 agent_token 失败，将重新生成: {ex.Message}", "bridge");
        }

        var hex = Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
        try
        {
            File.WriteAllText(path, hex);
            RestrictToCurrentUser(path);
        }
        catch (Exception ex)
        {
            Log.Warn($"无法写入 agent_token 文件: {path} ({ex.Message})", "bridge");
        }
        return hex;
    }

    /// <summary>把 token 文件 ACL 收紧到"仅当前用户"（凭据文件，绝不能继承目录权限对所有用户可读）。
    /// 用 icacls（Windows 自带，无需额外 NuGet 包）：清继承 + 只授予当前用户完全控制。</summary>
    private static void RestrictToCurrentUser(string path)
    {
        try
        {
            var user = $"{Environment.UserDomainName}\\{Environment.UserName}";
            var psi = new ProcessStartInfo
            {
                FileName = "icacls.exe",
                Arguments = $"\"{path}\" /inheritance:r /grant:r \"{user}:F\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            using var proc = Process.Start(psi);
            proc?.WaitForExit(5000);
        }
        catch (Exception ex)
        {
            Log.Warn($"设置 agent_token ACL 失败: {ex.Message}", "bridge");
        }
    }

    /// <summary>供设置面板"重置 token"预留（当前未接 UI，对齐 mac rotateToken）。</summary>
    public void RotateToken()
    {
        try { File.Delete(TokenPath); } catch { /* 忽略 */ }
        _token = EnsureToken(TokenPath);
        Log.Info($"agent_token 已重置（长度 {_token.Length}）", "bridge");
    }

    // =====================================================================
    // Lifecycle
    // =====================================================================

    public void Start()
    {
        if (_listener != null) return;
        try
        {
            var listener = new HttpListener();
            // 只字面量绑定 127.0.0.1：绝不用 "+"/"*"/机器名，那样会监听所有网卡且需要管理员 URL-ACL。
            listener.Prefixes.Add($"http://127.0.0.1:{Port}/");
            listener.Start();
            _listener = listener;
            _cts = new CancellationTokenSource();
            IsRunning = true;
            Log.Info($"本地桥已启动 http://127.0.0.1:{Port}（token 长度 {_token.Length}）", "bridge");
            _ = AcceptLoopAsync(listener, _cts.Token);
        }
        catch (Exception ex)
        {
            IsRunning = false;
            _listener = null;
            Log.Warn($"本地桥启动异常，端口可能被占用，保持关闭不影响主程序: {ex.Message}", "bridge");
        }
    }

    public void Stop()
    {
        try
        {
            _cts?.Cancel();
            _listener?.Stop();
            _listener?.Close();
        }
        catch { /* 忽略收尾异常 */ }
        _listener = null;
        IsRunning = false;
        Log.Info("本地桥已停止", "bridge");
    }

    private async Task AcceptLoopAsync(HttpListener listener, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && listener.IsListening)
        {
            HttpListenerContext ctx;
            try
            {
                ctx = await listener.GetContextAsync().ConfigureAwait(false);
            }
            catch
            {
                break; // listener 已 Stop()/Close()，正常退出循环
            }
            _ = HandleAsync(ctx); // 每个请求独立处理，不阻塞下一个 accept
        }
    }

    // =====================================================================
    // 单请求处理：回环校验 → Origin 拒绝 → 读 body(带上限) → token 鉴权 → 路由 → 回应
    // =====================================================================

    private async Task HandleAsync(HttpListenerContext ctx)
    {
        var request = ctx.Request;
        var response = ctx.Response;
        response.KeepAlive = false;

        try
        {
            // 纵深防御：即便监听前缀已限定 127.0.0.1，仍逐请求核实远端地址是回环。
            var remote = request.RemoteEndPoint?.Address;
            if (remote == null || !IPAddress.IsLoopback(remote))
            {
                Log.Warn($"拒绝非回环请求: {remote}", "bridge");
                await WriteJsonAsync(response, 403, new { ok = false, error = "forbidden" }).ConfigureAwait(false);
                return;
            }

            // 无 CORS：只要带 Origin 头，一律拒绝（挡住浏览器页面发起的跨站请求）。
            if (!string.IsNullOrEmpty(request.Headers["Origin"]))
            {
                await WriteJsonAsync(response, 403, new { ok = false, error = "origin not allowed" }).ConfigureAwait(false);
                return;
            }

            if (request.ContentLength64 > MaxBodyBytes)
            {
                await WriteJsonAsync(response, 413, new { ok = false, error = "request body too large" }).ConfigureAwait(false);
                return;
            }

            var (bodyOk, bodyText) = await TryReadBodyAsync(request, response).ConfigureAwait(false);
            if (!bodyOk) return; // 413 已写回，请求结束

            var got = ExtractToken(request);
            if (string.IsNullOrEmpty(got) || !ConstantTimeEquals(got, _token))
            {
                await WriteJsonAsync(response, 401, new { ok = false, error = "unauthorized" }).ConfigureAwait(false);
                return;
            }
            MarkClientAuthenticated(); // 鉴权通过才算"外部真正对接过"；401 绝不触发

            var method = (request.HttpMethod ?? "GET").ToUpperInvariant();
            JsonElement? bodyObj = null;
            if (method is "POST" or "PUT" or "PATCH")
            {
                if (string.IsNullOrWhiteSpace(bodyText))
                {
                    bodyObj = JsonDocument.Parse("{}").RootElement;
                }
                else
                {
                    try { bodyObj = JsonDocument.Parse(bodyText).RootElement; }
                    catch
                    {
                        await WriteJsonAsync(response, 400, new { ok = false, error = "invalid json" }).ConfigureAwait(false);
                        return;
                    }
                }
            }

            var breq = new BridgeRequest
            {
                Method = method,
                Path = NormalizePath(request.Url?.AbsolutePath ?? "/"),
                Query = ParseQuery(request.Url?.Query),
                Body = bodyObj,
            };

            BridgeResponse bresp;
            try
            {
                // 铁律：碰 App 状态（会话/主机）的处理一律在 WPF 主线程完成。
                var op = Application.Current.Dispatcher.InvokeAsync(() => BridgeRouter.RouteAsync(breq, Host));
                var inner = await op.Task.ConfigureAwait(false);
                bresp = await inner.ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                Log.Warn($"桥路由处理异常: {ex.Message}", "bridge");
                bresp = BridgeResponse.Fail(500, "internal error");
            }

            await WriteJsonAsync(response, bresp.Status, bresp.Json).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            Log.Warn($"桥请求处理失败: {ex.Message}", "bridge");
            try { response.Close(); } catch { /* 忽略 */ }
        }
    }

    /// <summary>边读边限制大小地读取请求体；返回 (是否可继续, 已读到的文本)。超限时已直接写回 413。</summary>
    private async Task<(bool ok, string text)> TryReadBodyAsync(HttpListenerRequest request, HttpListenerResponse response)
    {
        if (!request.HasEntityBody) return (true, "");
        using var ms = new MemoryStream();
        var buf = new byte[8192];
        var total = 0;
        int n;
        while ((n = await request.InputStream.ReadAsync(buf.AsMemory(0, buf.Length)).ConfigureAwait(false)) > 0)
        {
            total += n;
            if (total > MaxBodyBytes)
            {
                await WriteJsonAsync(response, 413, new { ok = false, error = "request body too large" }).ConfigureAwait(false);
                return (false, "");
            }
            ms.Write(buf, 0, n);
        }
        return (true, Encoding.UTF8.GetString(ms.ToArray()));
    }

    private static string ExtractToken(HttpListenerRequest request)
    {
        var auth = request.Headers["Authorization"];
        if (!string.IsNullOrEmpty(auth) && auth.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            return auth[7..].Trim();
        var t1 = request.Headers["X-PixShell-Token"];
        if (!string.IsNullOrEmpty(t1)) return t1.Trim();
        var t2 = request.Headers["X-Agent-Token"];
        if (!string.IsNullOrEmpty(t2)) return t2.Trim();
        var query = ParseQuery(request.Url?.Query);
        return query.GetValueOrDefault("token", "");
    }

    private static bool ConstantTimeEquals(string a, string b)
    {
        var ab = Encoding.UTF8.GetBytes(a);
        var bb = Encoding.UTF8.GetBytes(b);
        if (ab.Length != bb.Length) return false;
        return CryptographicOperations.FixedTimeEquals(ab, bb);
    }

    private static string NormalizePath(string path)
    {
        var p = string.IsNullOrEmpty(path) ? "/" : path;
        if (p.Length > 1 && p.EndsWith('/')) p = p.TrimEnd('/');
        return p.Length == 0 ? "/" : p;
    }

    /// <summary>手写查询串解析（不依赖 System.Web，避免引入额外包引用）。</summary>
    private static Dictionary<string, string> ParseQuery(string? query)
    {
        var dict = new Dictionary<string, string>();
        if (string.IsNullOrEmpty(query)) return dict;
        var q = query.TrimStart('?');
        foreach (var pair in q.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var idx = pair.IndexOf('=');
            var key = idx >= 0 ? pair[..idx] : pair;
            var val = idx >= 0 ? pair[(idx + 1)..] : "";
            try
            {
                key = Uri.UnescapeDataString(key.Replace('+', ' '));
                val = Uri.UnescapeDataString(val.Replace('+', ' '));
            }
            catch { /* 非法编码原样保留 */ }
            dict[key] = val;
        }
        return dict;
    }

    private static async Task WriteJsonAsync(HttpListenerResponse response, int status, object json)
    {
        try
        {
            var bodyBytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(json));
            response.StatusCode = status;
            response.ContentType = "application/json; charset=utf-8";
            response.Headers["Cache-Control"] = "no-store";
            response.ContentLength64 = bodyBytes.Length;
            await response.OutputStream.WriteAsync(bodyBytes).ConfigureAwait(false);
        }
        catch { /* 客户端可能已断开，忽略 */ }
        finally
        {
            try { response.OutputStream.Close(); } catch { /* 忽略 */ }
            try { response.Close(); } catch { /* 忽略 */ }
        }
    }
}
