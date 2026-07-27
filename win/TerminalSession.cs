using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using PixShell.Logging;
using PixShell.Proxy;
using PixShell.Terminal;
using Renci.SshNet;

namespace PixShell;

/// <summary>
/// 一个终端会话 = 一个独立 WebView2(内嵌 xterm) + 一条独立 SSH.NET ShellStream。
///
/// 多会话 tab 的实现方式：MainWindow 为每个 tab 实例化一份本类，各自持有独立的
/// WebView2 与 SSH 连接。SSH↔xterm 的桥逻辑（P1 单会话时写好）在这里原样复用，
/// 只是从「窗口单例」变成「每会话一份」，因此无需任何会话路由字段。
///
/// 消息协议（与单会话一致，另加 title）：
///   JS → C#:  {"t":"in","d":...} | {"t":"resize","cols","rows"} | {"t":"title","d":...} | {"t":"ready"}
///   C# → JS:  {"t":"out","d":"<base64(UTF-8)>"} | {"t":"status","d":...}
/// </summary>
public sealed class TerminalSession : IDisposable
{
    /// <summary>本会话独占的 WebView2 控件，放进对应 TabItem 的内容区。</summary>
    public WebView2 View { get; } = new WebView2();

    /// <summary>tab 头显示的标题：默认主机名，收到远端 OSC 标题后跟随。</summary>
    public string Title { get; private set; }

    public bool Connected => _connected;

    /// <summary>标题变化（远端 OSC 标题）→ 通知 MainWindow 更新 tab 头。</summary>
    public event Action<TerminalSession>? TitleChanged;

    /// <summary>状态变化 → 若为当前活动 tab，MainWindow 显示到状态栏。</summary>
    public event Action<TerminalSession, string>? StatusChanged;

    private readonly string _htmlPath;

    // ---- 以下为单会话桥逻辑的实例化字段（与 P1 完全一致，仅从窗口移入会话）----
    private SshClient? _ssh;
    private ShellStream? _shell;
    private Thread? _readThread;
    private uint _cols = 80;
    private uint _rows = 24;
    private object? _channel;
    private MethodInfo? _windowChange;
    private volatile bool _connected;

    /// <summary>终端语义高亮开关（对齐 mac AppDelegate.highlightEnabled）。默认开。</summary>
    public static bool HighlightEnabled { get; set; } = true;

    // 记录本会话的连接凭据，供 SFTP 面板复用同一主机+密码（另建独立连接）。
    private string _host = "";
    private int _port = 22;
    private string _user = "";
    private string _pass = "";
    private string? _keyPath;
    private ProxyConfig? _proxy;

    // ---------------------------------------------------------------------
    // 会话输出缓冲：供本地 CLI/Agent 桥 GET /v1/app/screen 读取"最近屏幕"（对齐 mac
    // sessions[].outputBuffer）。只做简单的滚动字符窗口，不逐字节还原终端渲染语义
    // （复杂转义序列/alt-screen 不特殊处理），够"看最近输出"够用即可。
    // ---------------------------------------------------------------------
    private readonly object _outputBufLock = new();
    private readonly StringBuilder _outputBuffer = new();
    private const int OutputBufferCap = 500_000; // ~500KB

    // JS 页 ready 前 C#→JS 消息会丢（PostWebMessage 无人听）。
    // 队列暂存 payload，ready 后按序冲刷；theme 另有 _pendingSchemeJson 兜底。
    private volatile bool _jsReady;
    private volatile bool _pendingFocus;
    private readonly object _pendingMsgLock = new();
    private readonly List<string> _pendingMsgs = new();
    private const int PendingMsgCap = 500;

    private void AppendOutputBuffer(string text)
    {
        lock (_outputBufLock)
        {
            _outputBuffer.Append(text);
            if (_outputBuffer.Length > OutputBufferCap)
                _outputBuffer.Remove(0, _outputBuffer.Length - OutputBufferCap);
        }
    }

    /// <summary>桥接 /v1/app/screen 用：读取最近 N 行输出（&lt;=0 使用默认 200）。</summary>
    public string GetRecentOutput(int lines)
    {
        string snapshot;
        lock (_outputBufLock) snapshot = _outputBuffer.ToString();
        var n = lines > 0 ? lines : 200;
        var rows = snapshot.Split('\n');
        var start = Math.Max(0, rows.Length - n);
        return string.Join("\n", rows[start..]);
    }

    /// <summary>会话主机名（SFTP 面板显示用）。</summary>
    public string HostName => _host;

    /// <summary>发起本会话连接时使用的主机条目（供自定义加速/重连/监控 IP 复用）。</summary>
    public HostEntry? SourceHost { get; set; }

    /// <summary>本会话连接密码（重连时复用；不做其它用途）。</summary>
    public string? Password => _pass;

    public TerminalSession(string label, string htmlPath)
    {
        Title = label;
        _htmlPath = htmlPath;
    }

    /// <summary>初始化 WebView2 并加载本地 xterm 页面（连接前调用一次）。</summary>
    public async Task InitAsync()
    {
        await View.EnsureCoreWebView2Async();
        View.CoreWebView2.WebMessageReceived += OnWebMessageReceived;
        // 关掉 WebView2 自带的浏览器右键菜单（刷新/查看源码等），改用下面的自绘终端右键菜单
        // （复制/粘贴/全选/清屏 + 设置背景，对齐 mac 版终端右键菜单）。
        View.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
        View.CoreWebView2.ContextMenuRequested += OnContextMenuRequested;
        View.CoreWebView2.Navigate(new Uri(_htmlPath).AbsoluteUri);
    }

    // ---------------------------------------------------------------------
    // 终端右键菜单：复制/粘贴/全选/清屏 + 设置背景(12 预设+恢复默认)
    // 对齐 mac App/AppDelegate+TermMenu.swift。
    // ---------------------------------------------------------------------

    /// <summary>老仓库 TERM_BG_PRESETS（12 个预设，值 1:1 照搬 mac Self.termBgPresets）。</summary>
    public static readonly (string Id, string Name, string Color)[] TermBgPresets =
    {
        ("deep", "深灰", "#0f1419"), ("default", "默认", "#1e1f29"),
        ("night", "Night", "#1a1b26"), ("dracula", "Dracula", "#282a36"),
        ("solar", "Solarized", "#002b36"), ("cat", "Catppuccin", "#1e1e2e"),
        ("github", "GitHub", "#0d1117"), ("nord", "Nord", "#2e3440"),
        ("rose", "Rosé", "#191724"), ("tokyo", "Tokyo", "#16161e"),
        ("gray", "黑灰", "#1c1c1c"), ("black", "纯黑", "#000000"),
    };

    private void OnContextMenuRequested(object? sender, CoreWebView2ContextMenuRequestedEventArgs e)
    {
        e.Handled = true;
        var menu = new System.Windows.Controls.ContextMenu { PlacementTarget = View };
        void Add(string header, Action action)
        {
            var mi = new System.Windows.Controls.MenuItem { Header = header };
            mi.Click += (_, _) => action();
            menu.Items.Add(mi);
        }

        Add("复制", () => _ = CopySelectionToClipboardAsync());
        Add("粘贴", PasteFromClipboard);
        Add("全选", () => { try { _ = View.CoreWebView2?.ExecuteScriptAsync("term.selectAll();"); } catch { } });
        menu.Items.Add(new System.Windows.Controls.Separator());
        Add("清屏", ClearScreen);
        menu.Items.Add(new System.Windows.Controls.Separator());

        var bgItem = new System.Windows.Controls.MenuItem { Header = "设置背景" };
        var overrideHex = Terminal.TermBackgroundStore.Override;
        foreach (var p in TermBgPresets)
        {
            var isActive = string.Equals(p.Color, overrideHex, StringComparison.OrdinalIgnoreCase);
            var mi = new System.Windows.Controls.MenuItem
            {
                Header = isActive ? p.Name + "  ✓" : p.Name,
                FontWeight = isActive ? System.Windows.FontWeights.Bold : System.Windows.FontWeights.Normal,
                Icon = new System.Windows.Shapes.Rectangle
                {
                    Width = 12, Height = 12,
                    Fill = new System.Windows.Media.SolidColorBrush(
                        (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(p.Color)!),
                },
            };
            var color = p.Color;
            mi.Click += (_, _) => { Log.Info($"终端背景 → {color}", "ui"); Terminal.TermBackgroundStore.Set(color); };
            bgItem.Items.Add(mi);
        }
        bgItem.Items.Add(new System.Windows.Controls.Separator());
        var reset = new System.Windows.Controls.MenuItem { Header = "恢复配色默认" };
        reset.Click += (_, _) => { Log.Info("终端背景 → 恢复配色默认", "ui"); Terminal.TermBackgroundStore.Reset(); };
        bgItem.Items.Add(reset);
        menu.Items.Add(bgItem);

        menu.Items.Add(new System.Windows.Controls.Separator());
        Add("放大字号", () => { _ = View.CoreWebView2?.ExecuteScriptAsync("window.pixSetFontSize && window.pixSetFontSize((window.termFontSize || 14) + 1);"); });
        Add("缩小字号", () => { _ = View.CoreWebView2?.ExecuteScriptAsync("window.pixSetFontSize && window.pixSetFontSize(Math.max(8, (window.termFontSize || 14) - 1));"); });

        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint;
        menu.IsOpen = true;
    }

    private async Task CopySelectionToClipboardAsync()
    {
        var text = await GetSelectionAsync();
        if (!string.IsNullOrEmpty(text))
        {
            try { System.Windows.Clipboard.SetText(text); } catch { /* 剪贴板偶发占用，忽略 */ }
        }
    }

    private void PasteFromClipboard()
    {
        try
        {
            var text = System.Windows.Clipboard.GetText();
            if (!string.IsNullOrEmpty(text)) SendText(text);
        }
        catch { /* 剪贴板为空/占用，忽略 */ }
    }

    /// <summary>建立 SSH 交互式 shell。异常向上抛给 MainWindow 显示。
    /// <paramref name="keyPath"/> 非空时优先尝试私钥认证，失败/未配置则回退密码（对齐 mac NIOSSHSession）。
    /// <paramref name="proxy"/> 非空时经代理拨号（SOCKS5/SOCKS4/HTTP，SSH.NET 内置支持）。</summary>
    public async Task ConnectAsync(string host, int port, string user, string pass, string? keyPath = null, ProxyConfig? proxy = null)
    {
        if (_connected) Disconnect();
        _host = host; _port = port; _user = user; _pass = pass; _keyPath = keyPath; _proxy = proxy;   // 存凭据给 SFTP 复用
        Log.Info($"SSH 连接中 {user}@{host}:{port}", "ssh");
        SetStatus($"连接 {user}@{host}:{port} …");
        try
        {
            await Task.Run(() => Connect(host, port, user, pass, keyPath, proxy));
        }
        catch (Exception ex)
        {
            Log.Error($"SSH 认证/握手失败 {user}@{host}:{port}: {ex.Message}", "ssh");
            throw;
        }
        _connected = true;
        Log.Info($"SSH 握手完成，已连接 {user}@{host}:{port}", "ssh");
        SetStatus($"已连接 {user}@{host}");
        SendToTerm("status", "connected");
        FocusWhenReady();
    }

    // 后台线程：建立 SSH 会话 + 交互式 shell + 启动读线程。
    private void Connect(string host, int port, string user, string pass, string? keyPath, ProxyConfig? proxy)
    {
        var info = BuildConnectionInfo(host, port, user, pass, keyPath, proxy);

        var ssh = new SshClient(info);
        ssh.Connect();

        var shell = ssh.CreateShellStream("xterm-256color", _cols, _rows, 0, 0, 4096);

        _ssh = ssh;
        _shell = shell;

        CacheChannelReflection(shell);

        _readThread = new Thread(ReadPump) { IsBackground = true, Name = "ssh-read-pump" };
        _readThread.Start();
    }

    // 后台读线程主体。ShellStream.Read 阻塞直到有数据；返回 0 表示通道关闭。
    private void ReadPump()
    {
        var shell = _shell;
        if (shell == null) return;
        var buf = new byte[4096];
        // 跨 read 块保持多字节 UTF-8 状态，避免中文/emoji 被截断成 U+FFFD。
        var decoder = Encoding.UTF8.GetDecoder();
        var chars = new char[Encoding.UTF8.GetMaxCharCount(buf.Length)];
        try
        {
            while (true)
            {
                int n = shell.Read(buf, 0, buf.Length);
                if (n <= 0) break;
                int c = decoder.GetChars(buf, 0, n, chars, 0, flush: false);
                var text = c > 0 ? new string(chars, 0, c) : "";
                if (text.Length > 0)
                    AppendOutputBuffer(text);
                // 语义高亮：给纯文本段注入 truecolor SGR，已有的 ANSI 转义原样保留。
                // 关掉开关就走原始字节，一个字节都不改。
                string b64;
                if (HighlightEnabled)
                {
                    // 高亮必须用状态解码后的完整字符；本块若只有未完成序列则跳过本轮 out。
                    if (c == 0) continue;
                    b64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(
                        Highlight.SemanticHighlight.Decorate(text, ThemeManager.IsDark)));
                }
                else
                {
                    b64 = Convert.ToBase64String(buf, 0, n);
                }
                // 回到 UI 线程调用 WebView2（有线程亲和性）。
                View.Dispatcher.BeginInvoke(new Action(() => SendToTerm("out", b64)));
            }
        }
        catch
        {
            // 断开时 Read 会抛异常，属正常收尾。
        }
        finally
        {
            View.Dispatcher.BeginInvoke(new Action(() =>
            {
                if (_connected)
                {
                    _connected = false;
                    Log.Info($"SSH 连接关闭 {_user}@{_host}:{_port}", "ssh");
                    SetStatus("连接已关闭");
                    SendToTerm("status", "session closed");
                }
            }));
        }
    }

    private void CacheChannelReflection(ShellStream shell)
    {
        try
        {
            var f = typeof(ShellStream).GetField("_channel",
                BindingFlags.NonPublic | BindingFlags.Instance);
            _channel = f?.GetValue(shell);
            _windowChange = _channel?.GetType().GetMethod("SendWindowChangeRequest",
                new[] { typeof(uint), typeof(uint), typeof(uint), typeof(uint) });
        }
        catch
        {
            _channel = null;
            _windowChange = null;
        }
    }

    // ---------------------------------------------------------------------
    // JS → C#
    // ---------------------------------------------------------------------
    private void OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        string json;
        try { json = e.TryGetWebMessageAsString(); }
        catch { return; }
        if (string.IsNullOrEmpty(json)) return;

        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var t = root.TryGetProperty("t", out var tv) ? tv.GetString() : null;
            switch (t)
            {
                case "in":
                    if (root.TryGetProperty("d", out var dv))
                    {
                        var data = dv.GetString();
                        if (!string.IsNullOrEmpty(data)) WriteInput(data);
                    }
                    break;

                case "resize":
                    var cols = root.TryGetProperty("cols", out var cv) ? cv.GetUInt32() : _cols;
                    var rows = root.TryGetProperty("rows", out var rv) ? rv.GetUInt32() : _rows;
                    ApplyResize(cols, rows);
                    break;

                case "title":
                    if (root.TryGetProperty("d", out var tt))
                    {
                        var title = tt.GetString();
                        if (!string.IsNullOrWhiteSpace(title))
                        {
                            Title = title!;
                            TitleChanged?.Invoke(this);
                        }
                    }
                    break;

                case "ready":
                    // 页面 listener 已挂上：冲刷 ready 前积压的 out/status，并兜底重发 theme。
                    FlushPendingMessages();
                    if (_pendingSchemeJson != null) SendRawToTerm("{\"t\":\"theme\",\"theme\":" + _pendingSchemeJson + "}");
                    if (_pendingFocus) FocusWhenReady();
                    break;
            }
        }
        catch
        {
            // 非法消息忽略。
        }
    }

    private void WriteInput(string data)
    {
        var shell = _shell;
        if (shell == null || !_connected) return;
        try
        {
            var bytes = Encoding.UTF8.GetBytes(data);
            shell.Write(bytes, 0, bytes.Length);
            shell.Flush();
        }
        catch { /* 断开时忽略 */ }
    }

    /// <summary>命令板用：把一段文本发送到当前 shell（外部调用）。</summary>
    public void SendText(string data) => WriteInput(data);

    /// <summary>
    /// 一次性远端命令执行（独立通道，不干扰交互式 PTY shell）：工具面板/监控侧栏/系统信息用。
    /// 对齐 mac SSHSession.exec —— 新建一条 SshCommand 通道，跑完拿全部输出即关闭。
    /// </summary>
    public async Task<string> ExecAsync(string command)
    {
        if (_ssh is not { IsConnected: true }) return "";
        try
        {
            return await Task.Run(() =>
            {
                using var cmd = _ssh.CreateCommand(command);
                cmd.CommandTimeout = TimeSpan.FromSeconds(20);
                var result = cmd.Execute();
                return string.IsNullOrEmpty(result) ? (cmd.Error ?? "") : result;
            });
        }
        catch (Exception ex)
        {
            return "执行失败: " + ex.Message;
        }
    }

    /// <summary>清屏（本地 xterm，不经过远端）：对齐 mac termClear 只清本地终端视图。</summary>
    public void ClearScreen()
    {
        try { _ = View.CoreWebView2?.ExecuteScriptAsync("term.clear();"); } catch { }
    }

    // ---------------------------------------------------------------------
    // 终端配色方案（Terminal/TermSchemes.cs）+ 背景覆盖色（Terminal/TermBackgroundStore.cs）
    // ---------------------------------------------------------------------
    private string? _pendingSchemeJson;
    private TermScheme? _lastScheme;

    /// <summary>把配色方案应用到本会话的 xterm.js（对齐 mac 版 TermScheme → NSColor 生效路径）。
    /// 页面可能尚未加载完成（EnsureCoreWebView2Async 之后 Navigate 是异步的），
    /// 这里立即尝试发送一次，同时把 JSON 存起来，等 JS 端 "ready" 消息到达后兜底重发一次，
    /// 保证无论时序如何最终都会生效。若已设置终端背景覆盖色，这里一并带上（只换背景，前景/ANSI 不变）。</summary>
    public void ApplyTermScheme(TermScheme scheme)
    {
        _lastScheme = scheme;
        SendThemeWithBackground(scheme, Terminal.TermBackgroundStore.Override);
    }

    /// <summary>只改背景色覆盖（对齐 mac applyTermBackground）：留前景/ANSI 不动，用最近一次的配色方案打底。
    /// <paramref name="hex"/> 为空字符串表示清除覆盖，恢复方案自带背景。</summary>
    public void ApplyBackgroundOverride(string hex)
    {
        var scheme = _lastScheme ?? Terminal.TermSchemeStore.Current;
        SendThemeWithBackground(scheme, hex);
    }

    private void SendThemeWithBackground(TermScheme scheme, string? bgOverride)
    {
        var theme = new
        {
            background = string.IsNullOrEmpty(bgOverride) ? scheme.Background : bgOverride,
            foreground = scheme.Foreground,
            cursor = scheme.Cursor,
            // xterm.js 的 theme 字段不接受 null（会在内部解析颜色时报错），没有选区色时退回前景色。
            selectionBackground = scheme.Selection ?? scheme.Foreground,
            black = scheme.Ansi[0], red = scheme.Ansi[1], green = scheme.Ansi[2], yellow = scheme.Ansi[3],
            blue = scheme.Ansi[4], magenta = scheme.Ansi[5], cyan = scheme.Ansi[6], white = scheme.Ansi[7],
            brightBlack = scheme.Ansi[8], brightRed = scheme.Ansi[9], brightGreen = scheme.Ansi[10], brightYellow = scheme.Ansi[11],
            brightBlue = scheme.Ansi[12], brightMagenta = scheme.Ansi[13], brightCyan = scheme.Ansi[14], brightWhite = scheme.Ansi[15],
        };
        var themeJson = JsonSerializer.Serialize(theme);
        _pendingSchemeJson = themeJson;
        SendRawToTerm("{\"t\":\"theme\",\"theme\":" + themeJson + "}");
    }

    /// <summary>取 xterm 当前选区文本（用于「复制」菜单项写入系统剪贴板）。</summary>
    public async Task<string> GetSelectionAsync()
    {
        if (View.CoreWebView2 == null) return "";
        try
        {
            var raw = await View.CoreWebView2.ExecuteScriptAsync("term.getSelection()");
            return JsonSerializer.Deserialize<string>(raw) ?? "";
        }
        catch { return ""; }
    }

    /// <summary>
    /// SFTP 面板用：用与终端相同的主机+凭据新建并连接一个独立的 SftpClient。
    /// SftpClient 与 ShellStream 是两条独立连接，可并存。调用方负责 Dispose。
    /// </summary>
    public SftpClient CreateSftpClient()
    {
        if (!_connected) throw new InvalidOperationException("会话未连接");
        var info = BuildConnectionInfo(_host, _port, _user, _pass, _keyPath, _proxy);
        info.Timeout = TimeSpan.FromSeconds(30);
        var sftp = new SftpClient(info)
        {
            OperationTimeout = TimeSpan.FromSeconds(30)
        };
        sftp.Connect();
        return sftp;
    }

    /// <summary>
    /// 构造认证方式列表：私钥优先（配置了 keyPath 且能成功加载时），密码兜底——两种方式各只提交一次，
    /// 被拒即干净失败，不重试，避免反复尝试触发服务器端账号锁定（对齐 mac SSHUserAuthDelegate）。
    /// 私钥文件不存在/格式不受支持/已加密等任何加载失败：记日志并跳过，绝不抛异常、绝不阻塞密码路径。
    /// </summary>
    private static ConnectionInfo BuildConnectionInfo(string host, int port, string user, string pass, string? keyPath, ProxyConfig? proxy)
    {
        var methods = new List<Renci.SshNet.AuthenticationMethod>();
        if (!string.IsNullOrWhiteSpace(keyPath))
        {
            var expanded = Environment.ExpandEnvironmentVariables(keyPath);
            try
            {
                if (!File.Exists(expanded))
                {
                    Log.Warn($"私钥文件不存在或不可读: {expanded}", "ssh");
                }
                else
                {
                    var keyFile = new PrivateKeyFile(expanded);
                    methods.Add(new PrivateKeyAuthenticationMethod(user, keyFile));
                    Log.Info($"已加载私钥: {expanded}", "ssh");
                }
            }
            catch (Exception ex)
            {
                Log.Warn($"私钥加载失败(可能是不支持的格式/已加密)，跳过公钥认证 {expanded}: {ex.Message}", "ssh");
            }
        }
        if (!string.IsNullOrEmpty(pass)) methods.Add(new PasswordAuthenticationMethod(user, pass));

        // keyboard-interactive：相当多的服务器把 PasswordAuthentication 关了、只留 KbdInteractive
        // （以及各种 PAM/一次性口令场景）。不挂这条会直接"认证失败"，明明密码是对的。
        // 这里只自动回答"看起来是问密码"的 prompt（含 password/口令 字样且非回显），
        // 其余 prompt 一律留空——不去猜 2FA 验证码之类的东西。
        if (!string.IsNullOrEmpty(pass))
        {
            var kbd = new KeyboardInteractiveAuthenticationMethod(user);
            kbd.AuthenticationPrompt += (_, e) =>
            {
                foreach (var p in e.Prompts)
                {
                    var q = (p.Request ?? "").ToLowerInvariant();
                    if (!p.IsEchoed && (q.Contains("password") || q.Contains("口令") || q.Contains("密码")))
                        p.Response = pass;
                }
            };
            methods.Add(kbd);
        }

        if (methods.Count == 0) methods.Add(new PasswordAuthenticationMethod(user, pass ?? ""));

        // 代理：SshJump（跳板机）本版本未实现真正逻辑——退化为直连，只记一条日志，绝不假装能走通导致连接卡死
        // （对齐 mac NIOSSHSession.connectAndOpenShell 里对 .sshJump 的处理）。
        if (proxy != null && proxy.Type == ProxyType.SshJump)
        {
            Log.Warn($"代理「{proxy.Name}」类型为 ssh-jump(跳板机)，当前版本未实现，跳过代理直接连接 {host}:{port}", "proxy");
            proxy = null;
        }

        if (proxy != null && !string.IsNullOrEmpty(proxy.Host))
        {
            var proxyType = proxy.Type switch
            {
                ProxyType.Socks5 => Renci.SshNet.ProxyTypes.Socks5,
                ProxyType.Socks4 => Renci.SshNet.ProxyTypes.Socks4,
                ProxyType.Http => Renci.SshNet.ProxyTypes.Http,
                _ => Renci.SshNet.ProxyTypes.None,
            };
            Log.Info($"经代理 {proxy.Type} {proxy.Host}:{proxy.Port} 连接 {host}:{port}", "proxy");
            return new ConnectionInfo(host, port, user, proxyType, proxy.Host, proxy.Port,
                proxy.Username ?? "", proxy.Password ?? "", methods.ToArray())
            { Timeout = TimeSpan.FromSeconds(15) };
        }

        return new ConnectionInfo(host, port, user, methods.ToArray()) { Timeout = TimeSpan.FromSeconds(15) };
    }

    private void ApplyResize(uint cols, uint rows)
    {
        if (cols == 0 || rows == 0) return;
        _cols = cols;
        _rows = rows;
        if (!_connected || _windowChange == null || _channel == null) return;
        try
        {
            _windowChange.Invoke(_channel, new object[] { cols, rows, 0u, 0u });
        }
        catch { /* PTY resize 失败不致命 */ }
    }

    // ---------------------------------------------------------------------
    // C# → JS
    // ---------------------------------------------------------------------
    private void SendToTerm(string type, string data)
    {
        var payload = "{\"t\":\"" + type + "\",\"d\":\"" + JsonEncode(data) + "\"}";
        EnqueueOrPost(payload);
    }

    /// <summary>JS ready 前入队，ready 后直接 Post；避免 MOTD/banner/status 在 listener 挂上前丢失。</summary>
    private void EnqueueOrPost(string payload)
    {
        lock (_pendingMsgLock)
        {
            if (!_jsReady)
            {
                if (_pendingMsgs.Count >= PendingMsgCap)
                    _pendingMsgs.RemoveAt(0);
                _pendingMsgs.Add(payload);
                return;
            }
        }
        PostWebMessage(payload);
    }

    private void FlushPendingMessages()
    {
        List<string> batch;
        lock (_pendingMsgLock)
        {
            _jsReady = true;
            batch = new List<string>(_pendingMsgs);
            _pendingMsgs.Clear();
        }
        foreach (var payload in batch)
            PostWebMessage(payload);
    }

    private void PostWebMessage(string payload)
    {
        var core = View.CoreWebView2;
        if (core == null) return;
        try { core.PostWebMessageAsString(payload); }
        catch { /* 页面销毁/导航中忽略 */ }
    }


    private void FocusWhenReady()
    {
        if (!_jsReady)
        {
            _pendingFocus = true;
            return;
        }
        _pendingFocus = false;
        try { _ = View.CoreWebView2?.ExecuteScriptAsync("window.pixFocus && window.pixFocus();"); }
        catch { /* 页面销毁/导航中忽略 */ }
    }

    private static string JsonEncode(string s)
    {
        var sb = new StringBuilder(s.Length + 8);
        foreach (var c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                    else sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    /// <summary>直接发一段已构造好的 JSON 消息（用于 theme 这种"值本身是对象"的消息，
    /// 不能套用 SendToTerm 的字符串转义包装）。</summary>
    private void SendRawToTerm(string json)
    {
        // theme 等对象消息：ready 前也入队，避免与 out 一样在 listener 前丢失。
        EnqueueOrPost(json);
    }

    private void SetStatus(string s) => StatusChanged?.Invoke(this, s);

    // ---------------------------------------------------------------------
    // 生命周期收尾
    // ---------------------------------------------------------------------
    public void Disconnect()
    {
        if (_connected) Log.Info($"主动断开 {_user}@{_host}:{_port}", "ssh");
        _connected = false;
        try { _shell?.Dispose(); } catch { }
        try { _ssh?.Disconnect(); } catch { }
        try { _ssh?.Dispose(); } catch { }
        _shell = null;
        _ssh = null;
        _channel = null;
        _windowChange = null;
    }

    /// <summary>关闭 tab 时调用：断开 SSH 并释放 WebView2。</summary>
    public void Dispose()
    {
        Disconnect();
        try { View.Dispose(); } catch { }
    }
}
