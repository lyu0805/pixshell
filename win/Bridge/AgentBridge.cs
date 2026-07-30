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
///   - 不发任何 CORS 响应头；跨站 Origin 一律拒绝。仅放行同源
///     http://127.0.0.1:&lt;port&gt; / localhost，供本机 Web SSH 页 fetch API；
///   - GET /webssh、/v1/app/webssh 提供浏览器 xterm 页；GET /web/* 提供静态资源；
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

    /// <summary>当前鉴权 token（只给本机 UI 拼 Web SSH URL 用；绝不写日志）。</summary>
    public string Token => _token;

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
        try { _cts?.Dispose(); } catch { }
        _listener = null;
        _cts = null;
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

            // Origin 策略：默认拒绝跨站 Origin（无 CORS）。
            // 仅放行同源 http://127.0.0.1:<port> / http://localhost:<port>，供本机 Web SSH 页 fetch API。
            var origin = request.Headers["Origin"];
            if (!string.IsNullOrEmpty(origin) && !IsSameOriginLoopback(origin, Port))
            {
                await WriteJsonAsync(response, 403, new { ok = false, error = "origin not allowed" }).ConfigureAwait(false);
                return;
            }

            var method = (request.HttpMethod ?? "GET").ToUpperInvariant();
            var path = NormalizePath(request.Url?.AbsolutePath ?? "/");

            // Web SSH 静态资源：xterm.js / css / addon，无需 token（只含公开前端库，无会话数据）。
            if (method == "GET" && path.StartsWith("/web/", StringComparison.Ordinal))
            {
                await WriteStaticWebAsync(response, path["/web/".Length..]).ConfigureAwait(false);
                return;
            }

            // Web SSH 页面本身也要求 token（query / header），与 API 同权；HTML 直接内嵌，不走 JSON 路由。
            if (method == "GET" && (path == "/webssh" || path == "/v1/app/webssh"))
            {
                var gotPage = ExtractToken(request);
                if (string.IsNullOrEmpty(gotPage) || !ConstantTimeEquals(gotPage, _token))
                {
                    // 仍返回 HTML 壳，由前端 gate 提示粘贴 token（也支持无 token 打开后手填）。
                    // 若带了错误 token，明确 401 JSON，避免误以为页面坏了。
                    if (!string.IsNullOrEmpty(gotPage))
                    {
                        await WriteJsonAsync(response, 401, new { ok = false, error = "unauthorized" }).ConfigureAwait(false);
                        return;
                    }
                }
                else
                {
                    MarkClientAuthenticated();
                }
                await WriteWebSshPageAsync(response).ConfigureAwait(false);
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
                Path = path,
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

            // 路由层也可直接吐 HTML（/v1/app/webssh 备用路径若走到 Router）。
            if (!string.IsNullOrEmpty(bresp.Html))
            {
                await WriteBytesAsync(response, bresp.Status, bresp.ContentType ?? "text/html; charset=utf-8",
                    Encoding.UTF8.GetBytes(bresp.Html)).ConfigureAwait(false);
                return;
            }

            await WriteJsonAsync(response, bresp.Status, bresp.Json).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            Log.Warn($"桥请求处理失败: {ex.Message}", "bridge");
            try { response.Close(); } catch { /* 忽略 */ }
        }
    }

    /// <summary>仅允许本机回环且端口匹配的 Origin（Web SSH 页 fetch 会带 Origin）。</summary>
    private static bool IsSameOriginLoopback(string origin, int port)
    {
        if (!Uri.TryCreate(origin, UriKind.Absolute, out var u)) return false;
        if (!string.Equals(u.Scheme, "http", StringComparison.OrdinalIgnoreCase)) return false;
        var host = u.Host;
        if (!(host is "127.0.0.1" or "localhost" or "::1")) return false;
        var p = u.IsDefaultPort ? 80 : u.Port;
        return p == port;
    }

    /// <summary>web/ 目录：优先输出目录旁的 web\，再退回 AppBase。</summary>
    private static string? ResolveWebRoot()
    {
        var baseDir = AppDomain.CurrentDomain.BaseDirectory;
        var candidates = new[]
        {
            Path.Combine(baseDir, "web"),
            Path.GetFullPath(Path.Combine(baseDir, "..", "..", "..", "web")),
        };
        foreach (var c in candidates)
        {
            if (Directory.Exists(c)) return c;
        }
        return null;
    }

    private static async Task WriteWebSshPageAsync(HttpListenerResponse response)
    {
        var root = ResolveWebRoot();
        string html;
        if (root != null)
        {
            var path = Path.Combine(root, "webssh.html");
            if (File.Exists(path))
            {
                html = await File.ReadAllTextAsync(path).ConfigureAwait(false);
                await WriteBytesAsync(response, 200, "text/html; charset=utf-8", Encoding.UTF8.GetBytes(html)).ConfigureAwait(false);
                return;
            }
        }
        // 兜底：文件缺失时给最小提示页，避免 500 空响应。
        html = "<!DOCTYPE html><meta charset=utf-8><title>PixShell Web SSH</title>" +
               "<body style='background:#0e1116;color:#c9d1d9;font:14px sans-serif;padding:24px'>" +
               "<h1>Web SSH</h1><p>缺少 web/webssh.html，请重新安装/构建 PixShell。</p></body>";
        await WriteBytesAsync(response, 200, "text/html; charset=utf-8", Encoding.UTF8.GetBytes(html)).ConfigureAwait(false);
    }

    private static readonly HashSet<string> WebAssetAllowlist = new(StringComparer.OrdinalIgnoreCase)
    {
        "xterm.js", "xterm.css", "addon-fit.js",
    };

    private static async Task WriteStaticWebAsync(HttpListenerResponse response, string relative)
    {
        // 防路径穿越 + 白名单（对齐 Mac：仅公开 xterm 三件套；webssh.html 走已鉴权 /webssh）
        var name = relative.Replace('\\', '/');
        if (name.Contains("..", StringComparison.Ordinal) || name.Contains('/') || string.IsNullOrWhiteSpace(name)
            || !WebAssetAllowlist.Contains(name))
        {
            await WriteJsonAsync(response, 404, new { ok = false, error = "not found" }).ConfigureAwait(false);
            return;
        }
        var root = ResolveWebRoot();
        if (root == null)
        {
            await WriteJsonAsync(response, 404, new { ok = false, error = "web root missing" }).ConfigureAwait(false);
            return;
        }
        var full = Path.Combine(root, name);
        if (!File.Exists(full))
        {
            await WriteJsonAsync(response, 404, new { ok = false, error = "not found" }).ConfigureAwait(false);
            return;
        }
        var ext = Path.GetExtension(full).ToLowerInvariant();
        var ctype = ext switch
        {
            ".js" => "application/javascript; charset=utf-8",
            ".css" => "text/css; charset=utf-8",
            _ => "application/octet-stream",
        };
        var bytes = await File.ReadAllBytesAsync(full).ConfigureAwait(false);
        await WriteBytesAsync(response, 200, ctype, bytes).ConfigureAwait(false);
    }

    /// <summary>拼 Web SSH 浏览器 URL（含 token + 可选 session）。</summary>
    public string BuildWebSshUrl(int? session = null, string? hostId = null)
    {
        var q = new List<string> { "token=" + Uri.EscapeDataString(_token) };
        if (session is >= 0) q.Add("session=" + session.Value);
        if (!string.IsNullOrEmpty(hostId)) q.Add("host_id=" + Uri.EscapeDataString(hostId));
        return $"http://127.0.0.1:{Port}/webssh?{string.Join("&", q)}";
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
        var bodyBytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(json));
        await WriteBytesAsync(response, status, "application/json; charset=utf-8", bodyBytes).ConfigureAwait(false);
    }

    private static async Task WriteBytesAsync(HttpListenerResponse response, int status, string contentType, byte[] bodyBytes)
    {
        try
        {
            response.StatusCode = status;
            response.ContentType = contentType;
            response.Headers["Cache-Control"] = "no-store";
            response.Headers["X-Content-Type-Options"] = "nosniff";
            // HTML 响应头 CSP 双保险（页面 meta 已有）；禁 CDN/外联，仅 self + 内联。
            if (contentType.Contains("text/html", StringComparison.OrdinalIgnoreCase))
            {
                response.Headers["Content-Security-Policy"] =
                    "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; " +
                    "connect-src 'self'; img-src 'self' data:; font-src 'self' data:; " +
                    "base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
            }
            // 同源 Web SSH 页不需要 CORS 头；跨站仍被 Origin 校验挡掉。
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
