using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using PixShell.Logging;

namespace PixShell.LSP;

/// <summary>rust-analyzer 最小 LSP 客户端（stdio JSON-RPC），对齐 mac LSPClient.swift。
/// initialize → initialized → didOpen（全量）→ didChange（全量替换）→
/// 收 publishDiagnostics → 请求 hover / completion / definition。
/// rust-analyzer 没找到/启动失败 → 优雅降级（编辑器照常工作）。</summary>
public sealed class LSPClient : IDisposable
{
    public record Diagnostic(int Start, int Length, string Message, bool IsError);

    public event Action<List<Diagnostic>>? Diagnostics;
    public event Action<bool>? ReadyChanged;

    private readonly object _lock = new();
    private readonly CancellationTokenSource _cts = new();
    private Process? _process;
    private StreamWriter? _stdin;
    private readonly MemoryStream _buffer = new();
    private int _nextId = 1;
    /// <summary>挂起请求。Msg 为 null 时（握手类）不做 -32801 重试。</summary>
    private sealed class Pending
    {
        public required Action<JsonElement?> Done;
        public Dictionary<string, object?>? Msg;
        public int Retries;
    }
    private readonly Dictionary<int, Pending> _pending = new();
    private volatile bool _ready;
    private string _documentUri = "";
    private string _documentText = "";

    /// <summary>探测 rust-analyzer：PATH + 常见位置（含 rustup 安装的 .cargo/bin）。</summary>
    public static string? Locate()
    {
        var candidates = new List<string>();
        var localApp = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        candidates.Add(Path.Combine(userProfile, ".cargo", "bin", "rust-analyzer.exe"));
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("CARGO_HOME")))
            candidates.Add(Path.Combine(Environment.GetEnvironmentVariable("CARGO_HOME")!, "bin", "rust-analyzer.exe"));
        foreach (var c in candidates.Where(File.Exists)) return c;
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in path.Split(Path.PathSeparator))
        {
            if (string.IsNullOrEmpty(dir)) continue;
            var p = Path.Combine(dir.Trim('"'), "rust-analyzer.exe");
            if (File.Exists(p)) return p;
        }
        return null;
    }

    public void Start(string rootPath, string uri, string text)
    {
        var exe = Locate();
        if (exe == null) { ReadyChanged?.Invoke(false); return; }

        var psi = new ProcessStartInfo(exe)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        // PATH 注入：rust-analyzer 需要 cargo/rustc 加载 workspace；GUI 进程 PATH 窄，
        // rustup 装在 %USERPROFILE%\.cargo\bin 时不在 PATH —— 不注入会
        // "Failed to run cargo metadata: No such file or directory"。
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var extra = new[] { Path.Combine(home, ".cargo", "bin") };
        var cur = psi.Environment["PATH"] ?? "";
        psi.Environment["PATH"] = cur + Path.PathSeparator + string.Join(Path.PathSeparator, extra.Where(Directory.Exists));

        try { _process = Process.Start(psi); }
        catch { ReadyChanged?.Invoke(false); return; }
        if (_process == null) { ReadyChanged?.Invoke(false); return; }

        _stdin = _process.StandardInput;
        _documentUri = uri;
        _documentText = text;
        _ = ReadLoopAsync(_process.StandardOutput, _cts.Token);

        Send("initialize", new Dictionary<string, object?>
        {
            ["processId"] = Environment.ProcessId,
            ["rootUri"] = "file:///" + rootPath.Replace('\\', '/'),
            ["capabilities"] = new Dictionary<string, object?>
            {
                ["textDocument"] = new Dictionary<string, object?>
                {
                    ["hover"] = new Dictionary<string, object?> { ["contentFormat"] = new[] { "plaintext", "markdown" } },
                    ["completion"] = new Dictionary<string, object?> { ["completionItem"] = new Dictionary<string, object?> { ["documentationFormat"] = new[] { "plaintext" } } },
                    ["definition"] = new Dictionary<string, object?> { ["linkSupport"] = false },
                },
            },
        }, expectResponse: true, _ =>
        {
            Send("initialized", new Dictionary<string, object?>(), expectResponse: false);
            Send("textDocument/didOpen", new Dictionary<string, object?>
            {
                ["textDocument"] = new Dictionary<string, object?> { ["uri"] = uri, ["languageId"] = "rust", ["version"] = 1, ["text"] = text },
            }, expectResponse: false);
            _ready = true;
            ReadyChanged?.Invoke(true);
        });
    }

    public void DidChange(string text)
    {
        if (!_ready || string.IsNullOrEmpty(_documentUri)) return;
        lock (_lock)
        {
            _documentText = text;
        }
        Send("textDocument/didChange", new Dictionary<string, object?>
        {
            ["textDocument"] = new Dictionary<string, object?> { ["uri"] = _documentUri, ["version"] = ++_version },
            ["contentChanges"] = new[] { new Dictionary<string, object?> { ["text"] = text } },
        }, expectResponse: false);
    }
    private int _version = 1;

    public Task HoverAsync(string uri, int line, int character, Action<string?> done)
    {
        Request("textDocument/hover", new Dictionary<string, object?>
        {
            ["textDocument"] = new Dictionary<string, object?> { ["uri"] = uri },
            ["position"] = new Dictionary<string, object?> { ["line"] = line, ["character"] = character },
        }, r => done(ParseHover(r)));
        return Task.CompletedTask;
    }

    public Task CompletionAsync(string uri, int line, int character, Action<List<(string Label, string Detail)>> done)
    {
        Request("textDocument/completion", new Dictionary<string, object?>
        {
            ["textDocument"] = new Dictionary<string, object?> { ["uri"] = uri },
            ["position"] = new Dictionary<string, object?> { ["line"] = line, ["character"] = character },
        }, r => done(ParseCompletion(r)));
        return Task.CompletedTask;
    }

    public Task DefinitionAsync(string uri, int line, int character, Action<(int Line, int Char)?> done)
    {
        Request("textDocument/definition", new Dictionary<string, object?>
        {
            ["textDocument"] = new Dictionary<string, object?> { ["uri"] = uri },
            ["position"] = new Dictionary<string, object?> { ["line"] = line, ["character"] = character },
        }, r => done(ParseDefinition(r)));
        return Task.CompletedTask;
    }

    public void Shutdown()
    {
        _ready = false;
        try
        {
            Send("shutdown", new Dictionary<string, object?>(), expectResponse: false);
            Send("exit", new Dictionary<string, object?>(), expectResponse: false);
            _stdin?.Close();
        }
        catch { }
        try { _process?.Kill(); } catch { }
        _process?.Dispose();
        _process = null;
        lock (_lock) { _pending.Clear(); }
    }

    public void Dispose() { Shutdown(); _cts.Cancel(); }

    // =====================================================================
    // 帧收发（标准 LSP：Content-Length 头 + JSON body）
    // =====================================================================

    private void Send(string method, Dictionary<string, object?> params_, bool expectResponse = true, Action<JsonElement?>? onResponse = null)
    {
        var msg = new Dictionary<string, object?> { ["jsonrpc"] = "2.0", ["method"] = method, ["params"] = params_ };
        if (expectResponse)
        {
            int id;
            lock (_lock) { id = _nextId++; if (onResponse != null) _pending[id] = new Pending { Done = onResponse }; }
            msg["id"] = id;
        }
        Write(msg);
    }

    private void Request(string method, Dictionary<string, object?> params_, Action<JsonElement?> done)
    {
        if (!_ready) { done(null); return; }
        var msg = new Dictionary<string, object?> { ["jsonrpc"] = "2.0", ["method"] = method, ["params"] = params_ };
        int id;
        lock (_lock)
        {
            id = _nextId++;
            msg["id"] = id;
            _pending[id] = new Pending { Done = done, Msg = msg };
        }
        _ = TimeoutAfterAsync(id);
        Write(msg);
    }

    /// <summary>请求超时（10s）：rust-analyzer 不响应时回调空结果，避免挂起泄漏。
    /// -32801 重试会把 pending 换新 id，旧 id 超时不会误伤新请求。</summary>
    private async Task TimeoutAfterAsync(int id)
    {
        await Task.Delay(10_000);
        Pending? entry = null;
        lock (_lock)
        {
            if (_pending.TryGetValue(id, out var e)) { _pending.Remove(id); entry = e; }
        }
        entry?.Done(null);
    }

    private void Write(Dictionary<string, object?> obj)
    {
        if (_stdin == null) return;
        try
        {
            var body = JsonSerializer.SerializeToUtf8Bytes(obj);
            var head = Encoding.UTF8.GetBytes($"Content-Length: {body.Length}\r\n\r\n");
            lock (_stdin)
            {
                _stdin.BaseStream.Write(head, 0, head.Length);
                _stdin.BaseStream.Write(body, 0, body.Length);
                _stdin.BaseStream.Flush();
            }
        }
        catch (Exception ex) { Log.Warn($"LSP 发送失败：{ex.Message}", "lsp"); }
    }

    /// <summary>读循环：accumulate 到 MemoryStream，按 Content-Length 切帧。JSON body 里的换行
    /// 必须原样保留 —— 绝不能按行切（早期按行切会读半帧）。</summary>
    private async Task ReadLoopAsync(StreamReader stdout, CancellationToken ct)
    {
        var buffer = new byte[65536];
        try
        {
            while (!ct.IsCancellationRequested)
            {
                int n = await stdout.BaseStream.ReadAsync(buffer, 0, buffer.Length, ct);
                if (n <= 0) break;
                lock (_lock)
                {
                    _buffer.Write(buffer, 0, n);
                    DrainFrames();
                }
            }
        }
        catch (Exception ex) { Log.Warn($"LSP 读取循环退出：{ex.Message}", "lsp"); }
    }

    private void DrainFrames()
    {
        _buffer.Position = 0;
        var all = _buffer.ToArray();
        int pos = 0;
        while (pos < all.Length)
        {
            // 找 header 结束
            int headerEnd = IndexOf(all, pos, "\r\n\r\n");
            if (headerEnd < 0) break;
            var header = Encoding.UTF8.GetString(all, pos, headerEnd - pos);
            int? len = null;
            foreach (var line in header.Split("\r\n"))
            {
                if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
                {
                    if (int.TryParse(line.Split(':')[1].Trim(), out var l)) len = l;
                }
            }
            if (len == null) { pos = headerEnd + 4; continue; }
            int bodyStart = headerEnd + 4;
            if (all.Length - bodyStart < len.Value) break; // 帧不完整
            var body = all[bodyStart..(bodyStart + len.Value)];
            pos = bodyStart + len.Value;
            HandleFrame(body);
        }
        _buffer.SetLength(0);
        if (pos < all.Length) _buffer.Write(all, pos, all.Length - pos);
    }

    private static int IndexOf(byte[] haystack, int start, string needle)
    {
        var nb = Encoding.UTF8.GetBytes(needle);
        for (int i = start; i <= haystack.Length - nb.Length; i++)
        {
            bool match = true;
            for (int j = 0; j < nb.Length; j++)
                if (haystack[i + j] != nb[j]) { match = false; break; }
            if (match) return i;
        }
        return -1;
    }

    private void HandleFrame(byte[] body)
    {
        JsonElement? root = null;
        try { root = JsonSerializer.Deserialize<JsonElement>(body); } catch { return; }
        if (!root.HasValue) return;

        if (root.Value.TryGetProperty("id", out var idProp) && idProp.TryGetInt32(out var id))
        {
            Pending? entry;
            lock (_lock) { _pending.Remove(id, out entry); }
            if (entry != null)
            {
                // -32801 ContentModified：rust-analyzer 冷启动首轮分析/文档更新窗口会拒绝
                // 位置请求（VS Code 等客户端同样自动重试）。重发（新 id），最多 3 次。
                if (entry.Msg != null && entry.Retries < 3 &&
                    root.Value.TryGetProperty("error", out var err) && err.ValueKind == JsonValueKind.Object &&
                    err.TryGetProperty("code", out var codeProp) && codeProp.TryGetInt32(out var code) && code == -32801)
                {
                    int newId;
                    lock (_lock)
                    {
                        newId = _nextId++;
                        entry.Msg["id"] = newId;
                        entry.Retries++;
                        _pending[newId] = entry;
                    }
                    _ = Task.Run(async () => { await Task.Delay(250); Write(entry.Msg); });
                    return;
                }
                JsonElement? result = null;
                if (root.Value.TryGetProperty("result", out var r) && r.ValueKind != JsonValueKind.Null)
                    result = r;
                entry.Done(result);
                return;
            }
        }
        if (root.Value.TryGetProperty("method", out var m) && m.GetString() == "textDocument/publishDiagnostics")
        {
            var items = new List<Diagnostic>();
            string text;
            lock (_lock) { text = _documentText; }
            if (root.Value.TryGetProperty("params", out var p) &&
                p.TryGetProperty("diagnostics", out var diags) && diags.ValueKind == JsonValueKind.Array)
            {
                foreach (var d in diags.EnumerateArray())
                {
                    if (!d.TryGetProperty("range", out var range) ||
                        !range.TryGetProperty("start", out var start) ||
                        !start.TryGetProperty("line", out var sl) ||
                        !start.TryGetProperty("character", out var sc) ||
                        !range.TryGetProperty("end", out var end) ||
                        !end.TryGetProperty("line", out var el) ||
                        !end.TryGetProperty("character", out var ec) ||
                        !d.TryGetProperty("message", out var msg)) continue;
                    int severity = 2;
                    if (d.TryGetProperty("severity", out var sev) && sev.TryGetInt32(out var s)) severity = s;
                    var loc = Utf16Offset(sl.GetInt32(), sc.GetInt32(), text);
                    var endLoc = Utf16Offset(el.GetInt32(), ec.GetInt32(), text);
                    if (loc < 0 || endLoc < loc || endLoc > text.Length) continue;
                    items.Add(new Diagnostic(loc, endLoc - loc, msg.GetString() ?? "", severity <= 1));
                }
            }
            Diagnostics?.Invoke(items);
        }
    }

    /// <summary>LSP 行/列（UTF-16 code unit）→ string 偏移。</summary>
    private static int Utf16Offset(int line, int character, string text)
    {
        int offset = 0;
        for (int l = 0; l < line && offset < text.Length; l++)
        {
            int nl = text.IndexOf('\n', offset);
            if (nl < 0) return -1;
            offset = nl + 1;
        }
        if (offset > text.Length) return -1;
        return Math.Min(offset + character, text.Length);
    }

    // =====================================================================
    // 响应解析
    // =====================================================================

    private static string? ParseHover(JsonElement? r)
    {
        if (!r.HasValue) return null;
        if (r.Value.TryGetProperty("contents", out var c))
        {
            if (c.ValueKind == JsonValueKind.String) return c.GetString();
            if (c.ValueKind == JsonValueKind.Object && c.TryGetProperty("value", out var v)) return v.GetString();
            if (c.ValueKind == JsonValueKind.Array)
            {
                var parts = new List<string>();
                foreach (var item in c.EnumerateArray())
                {
                    if (item.ValueKind == JsonValueKind.String) parts.Add(item.GetString() ?? "");
                    else if (item.ValueKind == JsonValueKind.Object && item.TryGetProperty("value", out var v2)) parts.Add(v2.GetString() ?? "");
                }
                return parts.Count > 0 ? string.Join("\n\n", parts) : null;
            }
        }
        return null;
    }

    private static List<(string Label, string Detail)> ParseCompletion(JsonElement? r)
    {
        var result = new List<(string, string)>();
        if (!r.HasValue) return result;
        JsonElement items = default;
        if (r.Value.ValueKind == JsonValueKind.Object && r.Value.TryGetProperty("items", out var arr)) items = arr;
        else if (r.Value.ValueKind == JsonValueKind.Array) items = r.Value;
        else return result;
        foreach (var item in items.EnumerateArray().Take(50))
        {
            var label = item.TryGetProperty("label", out var l) ? l.GetString() ?? "" : "";
            var detail = item.TryGetProperty("detail", out var d2) ? d2.GetString() ?? "" : "";
            result.Add((label, detail));
        }
        return result;
    }

    private static (int Line, int Char)? ParseDefinition(JsonElement? r)
    {
        if (!r.HasValue) return null;
        // 新版：Location[] 裸数组
        if (r.Value.ValueKind == JsonValueKind.Array && r.Value.GetArrayLength() > 0)
        {
            var first = r.Value[0];
            if (first.TryGetProperty("range", out var rg) && rg.TryGetProperty("start", out var st) &&
                st.TryGetProperty("line", out var l) && st.TryGetProperty("character", out var c))
                return (l.GetInt32(), c.GetInt32());
            return null;
        }
        // 单条 Location
        if (r.Value.ValueKind == JsonValueKind.Object && r.Value.TryGetProperty("range", out var range) &&
            range.TryGetProperty("start", out var start) &&
            start.TryGetProperty("line", out var line) && start.TryGetProperty("character", out var ch))
            return (line.GetInt32(), ch.GetInt32());
        return null;
    }
}
