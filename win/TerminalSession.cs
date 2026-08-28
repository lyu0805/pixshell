using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using PixShell.Logging;
using PixShell.Proxy;
using PixShell.Terminal;
using PixShell.Transports;
using Renci.SshNet;

namespace PixShell;

/// <summary>
/// 一个终端会话 = 一个独立 WebView2(内嵌 xterm) + 一条独立底层传输层。
///
/// 多会话 tab 的实现方式：MainWindow 为每个 tab 实例化一份本类，各自持有独立的
/// WebView2 与底层连接。
///
/// 消息协议：
///   JS → C#:  {"t":"in","d":...} | {"t":"resize","cols","rows"} | {"t":"title","d":...} | {"t":"ready"}
///   C# → JS:  {"t":"out","d":"<base64(UTF-8)>"} | {"t":"status","d":...}
/// </summary>
public sealed class TerminalSession : IDisposable
{
    /// <summary>本会话独占的 WebView2 控件，放进对应 TabItem 的内容区。
    /// DefaultBackgroundColor 跟配色方案走，避免页面未铺满时露出系统黑底（半截黑屏）。</summary>
    public WebView2 View { get; } = CreateView();

    private static WebView2 CreateView()
    {
        var v = new WebView2
        {
            HorizontalAlignment = System.Windows.HorizontalAlignment.Stretch,
            VerticalAlignment = System.Windows.VerticalAlignment.Stretch,
            DefaultBackgroundColor = HexToDrawingColor("#002945"),
        };
        return v;
    }

    private void WireTerminalView()
    {
        View.SizeChanged -= OnViewSizeChanged;
        View.SizeChanged += OnViewSizeChanged;
    }

    private void OnViewSizeChanged(object sender, SizeChangedEventArgs e) => SchedulePixFit();

    /// <summary>WebView2 SizeChanged 防抖 fit：合并 80ms 内多次，拖坞期间全跳（MainWindow.SuppressTerminalFit）。</summary>
    private void SchedulePixFit()
    {
        if (System.Windows.Application.Current.MainWindow is MainWindow mw && mw.SuppressTerminalFit) return;
        if (View?.CoreWebView2 == null) return;
        _fitTimer ??= new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(80) };
        _fitTimer.Tick -= FitTimer_Tick;
        _fitTimer.Tick += FitTimer_Tick;
        _fitTimer.Stop();
        _fitTimer.Start();
    }

    private void FitTimer_Tick(object? sender, EventArgs e)
    {
        _fitTimer?.Stop();
        if (System.Windows.Application.Current.MainWindow is MainWindow mw && mw.SuppressTerminalFit) return;
        try
        {
            _ = View.CoreWebView2?.ExecuteScriptAsync("try{window.pixFit&&window.pixFit()}catch(e){}");
        }
        catch { /* ignore */ }
    }

    private static System.Drawing.Color HexToDrawingColor(string hex)
    {
        try
        {
            var s = (hex ?? "").Trim();
            if (s.StartsWith("#")) s = s[1..];
            if (s.Length < 6) return System.Drawing.Color.FromArgb(255, 0x00, 0x29, 0x45);
            var n = Convert.ToInt32(s[..6], 16);
            return System.Drawing.Color.FromArgb(255, (n >> 16) & 255, (n >> 8) & 255, n & 255);
        }
        catch
        {
            return System.Drawing.Color.FromArgb(255, 0x00, 0x29, 0x45);
        }
    }

    /// <summary>
    /// 远端 OSC 标题（shell 报的 <c>root@ubuntu24: ~</c>）。
    /// 只给 tooltip / 独立窗标题用，**绝不**写到标签头。
    /// </summary>
    public string Title { get; private set; }

    /// <summary>
    /// 标签栏显示名：用户在连接管理器设的名字（<see cref="HostEntry.Display"/>）。
    /// 对齐 mac <c>TermSession.tabTitle</c> —— 远端 OSC 再怎么改也不许盖掉用户命名。
    /// </summary>
    public string TabTitle
    {
        get
        {
            var name = SourceHost?.Display?.Trim();
            if (!string.IsNullOrEmpty(name)) return name!;
            var t = Title ?? "";
            var at = t.IndexOf('@');
            if (at >= 0 && at + 1 < t.Length) t = t[(at + 1)..];
            var colon = t.IndexOf(':');
            if (colon >= 0) t = t[..colon];
            t = t.Trim();
            return string.IsNullOrEmpty(t) ? (Title ?? "会话") : t;
        }
    }

    public bool Connected => _connected;
    public string SessionId { get; } = Guid.NewGuid().ToString("N");

    /// <summary>远端 OSC 标题变化。标签头**不**订阅此事件（用 TabTitle）。</summary>
    public event Action<TerminalSession>? TitleChanged;

    /// <summary>状态变化 → 若为当前 activity tab，MainWindow 显示到状态栏。</summary>
    public event Action<TerminalSession, string>? StatusChanged;

    /// <summary>连接状态变化（连上/断开）→ MainWindow 清 SFTP/系统信息等侧栏。</summary>
    public event Action<TerminalSession, bool>? ConnectedChanged;

    private readonly string _htmlPath;

    private ITerminalTransport? _transport;
    private readonly object _transportLock = new();
    private long _transportGeneration;
    private DispatcherTimer? _fitTimer;
    private uint _cols = 80;
    private uint _rows = 24;
    private volatile bool _connected;
    private volatile bool _isLocal;
    private volatile bool _isOpenSSH;

    /// <summary>终端语义高亮开关（对齐 mac AppDelegate.highlightEnabled）。默认开。</summary>
    public static bool HighlightEnabled { get; set; } = true;

    private string _host = "";
    private int _port = 22;
    private string _user = "";
    private string _pass = "";
    private string? _keyPath;
    private ProxyConfig? _proxy;

    private readonly object _outputBufLock = new();
    private readonly StringBuilder _outputBuffer = new();
    private const int OutputBufferCap = 500_000; // ~500KB

    private volatile bool _jsReady;
    private volatile bool _pendingFocus;
    private readonly object _pendingMsgLock = new();
    private readonly List<string> _pendingMsgs = new();
    private const int PendingMsgCap = 500;
    private TaskCompletionSource<bool>? _readyTcs;
    private const int ReadyTimeoutMs = 10_000;

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
    /// <summary>会话端口。</summary>
    public int HostPort() => _port;
    /// <summary>会话用户名。</summary>
    public string HostUser() => _user;
    /// <summary>会话私钥路径。</summary>
    public string? HostKeyPath() => _keyPath;

    /// <summary>发起本会话连接时使用的主机条目（供自定义加速/重连/监控 IP 复用）。</summary>
    public HostEntry? SourceHost { get; set; }

    /// <summary>本会话连接密码（重连时复用；不做其它用途）。</summary>
    public string? Password => _pass;

    /// <summary>应用内 Web 终端标签：仅 InitWebSshAsync 置位。
    /// 主机 ConnectionType==400 只表示「连接时走 Web 入口」；
    /// 桥 Connect 为 Web 主机拉起的底层 SSH 标签不应被当成 Web 标签。</summary>
    public bool IsWebSsh => _isWebSsh;

    private bool _isWebSsh;
    private string? _webSshUrl;

    public TerminalSession(string label, string htmlPath)
    {
        View = CreateView();
        View.Visibility = System.Windows.Visibility.Collapsed;
        WireTerminalView();
        Title = label;
        _htmlPath = htmlPath;
    }

    private static CoreWebView2Environment? _sharedEnv;
    private static readonly SemaphoreSlim EnvLock = new(1, 1);

    private static async Task<CoreWebView2Environment> GetSharedEnvironmentAsync()
    {
        if (_sharedEnv != null) return _sharedEnv;
        await EnvLock.WaitAsync().ConfigureAwait(true);
        try
        {
            if (_sharedEnv != null) return _sharedEnv;
            var dataDir = Path.Combine(HostStore.AppDir, "webview2");
            Directory.CreateDirectory(dataDir);
            var opts = new CoreWebView2EnvironmentOptions
            {
                AdditionalBrowserArguments = "--disable-features=CalculateNativeWinOcclusion,RendererCodeIntegrity",
            };
            _sharedEnv = await CoreWebView2Environment.CreateAsync(
                browserExecutableFolder: null,
                userDataFolder: dataDir,
                options: opts).ConfigureAwait(true);
            Log.Info($"WebView2 env ready: {dataDir}", "webview");
            return _sharedEnv;
        }
        finally { EnvLock.Release(); }
    }

    /// <summary>初始化 WebView2 并加载本地 xterm 页面（连接前调用一次）。</summary>
    public async Task InitAsync()
    {
        if (string.IsNullOrWhiteSpace(_htmlPath) || !File.Exists(_htmlPath))
            throw new FileNotFoundException(
                "终端页面缺失，无法打开会话。请确认安装目录下存在 web/terminal.html。",
                _htmlPath);

        _readyTcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _jsReady = false;

        try
        {
            var env = await GetSharedEnvironmentAsync().ConfigureAwait(true);
            for (var attempt = 1; ; attempt++)
            {
                try
                {
                    var init = View.EnsureCoreWebView2Async(env);
                    var winner = await Task.WhenAny(init, Task.Delay(25_000)).ConfigureAwait(true);
                    if (winner != init)
                        throw new TimeoutException("EnsureCoreWebView2Async 超过 25s（0x800705B4 同类超时）");
                    await init.ConfigureAwait(true);
                    break;
                }
                catch (Exception ex) when (attempt < 2 && IsWebView2InitTimeout(ex))
                {
                    Log.Warn($"WebView2 初始化超时，清 profile 锁后重试: {ex.Message}", "webview");
                    TryClearWebView2Locks();
                    await Task.Delay(400).ConfigureAwait(true);
                }
            }
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException(
                "WebView2 初始化失败（请安装 Microsoft Edge WebView2 Runtime，或关掉残留的 msedgewebview2 后重试）：" + ex.Message, ex);
        }

        View.CoreWebView2.WebMessageReceived -= OnWebMessageReceived;
        View.CoreWebView2.WebMessageReceived += OnWebMessageReceived;
        View.CoreWebView2.Settings.AreDefaultContextMenusEnabled = true;
        View.CoreWebView2.Settings.IsStatusBarEnabled = false;
        View.CoreWebView2.Settings.AreBrowserAcceleratorKeysEnabled = false;
        try
        {
            View.CoreWebView2.Profile.PreferredColorScheme = ThemeManager.IsDark
                ? CoreWebView2PreferredColorScheme.Dark
                : CoreWebView2PreferredColorScheme.Light;
        }
        catch { }
        View.CoreWebView2.ContextMenuRequested -= OnContextMenuRequested;
        View.CoreWebView2.ContextMenuRequested += OnContextMenuRequested;

        var navFailed = (string?)null;
        void OnNav(object? sender, CoreWebView2NavigationCompletedEventArgs e)
        {
            View.CoreWebView2.NavigationCompleted -= OnNav;
            if (!e.IsSuccess)
            {
                navFailed = $"终端页面导航失败 (WebErrorStatus={e.WebErrorStatus})";
                _readyTcs?.TrySetResult(false);
            }
        }
        View.CoreWebView2.NavigationCompleted += OnNav;
        View.CoreWebView2.Navigate(new Uri(_htmlPath).AbsoluteUri);

        var completed = await Task.WhenAny(_readyTcs.Task, Task.Delay(ReadyTimeoutMs));
        if (completed != _readyTcs.Task)
            throw new TimeoutException("终端页面加载超时（xterm 未就绪）。请检查 web/terminal.html 与依赖资源。");

        if (!await _readyTcs.Task)
            throw new InvalidOperationException(navFailed ?? "终端页面未能就绪。");
    }

    private static bool IsWebView2InitTimeout(Exception ex)
    {
        for (var e = ex; e != null; e = e.InnerException!)
        {
            var m = e.Message ?? "";
            if (m.Contains("0x800705B4", StringComparison.OrdinalIgnoreCase)) return true;
            if (m.Contains("超时", StringComparison.Ordinal)) return true;
            if (m.Contains("timed out", StringComparison.OrdinalIgnoreCase)) return true;
            if (m.Contains("timeout", StringComparison.OrdinalIgnoreCase)) return true;
            if (e is TimeoutException) return true;
            if (e is OperationCanceledException) return true;
        }
        return false;
    }

    private static void TryClearWebView2Locks()
    {
        try
        {
            var dataDir = Path.Combine(HostStore.AppDir, "webview2");
            if (!Directory.Exists(dataDir)) return;
            foreach (var name in new[] { "lockfile", "SingletonLock", "SingletonCookie", "SingletonSocket" })
            {
                foreach (var f in Directory.EnumerateFiles(dataDir, name, SearchOption.AllDirectories))
                {
                    try { File.Delete(f); } catch { }
                }
            }
        }
        catch { }
    }

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
        var env = View.CoreWebView2?.Environment;
        if (env == null) return;

        var items = e.MenuItems;
        items.Clear();

        void AddCmd(string label, Action action)
        {
            var mi = env.CreateContextMenuItem(label, null, CoreWebView2ContextMenuItemKind.Command);
            mi.CustomItemSelected += (_, _) =>
            {
                try { View.Dispatcher.BeginInvoke(action); } catch { }
            };
            items.Add(mi);
        }

        void AddSep()
        {
            items.Add(env.CreateContextMenuItem("", null, CoreWebView2ContextMenuItemKind.Separator));
        }

        AddCmd("复制", () => _ = CopySelectionToClipboardAsync());
        AddCmd("粘贴", PasteFromClipboard);
        AddCmd("全选", () => { try { _ = View.CoreWebView2?.ExecuteScriptAsync("term.selectAll();"); } catch { } });
        AddSep();
        AddCmd("清屏", ClearScreen);
        AddSep();

        var bgRoot = env.CreateContextMenuItem("设置背景", null, CoreWebView2ContextMenuItemKind.Submenu);
        var overrideHex = Terminal.TermBackgroundStore.Override;
        foreach (var p in TermBgPresets)
        {
            var isActive = string.Equals(p.Color, overrideHex, StringComparison.OrdinalIgnoreCase);
            var label = isActive ? p.Name + "  ✓" : p.Name;
            var mi = env.CreateContextMenuItem(label, null, CoreWebView2ContextMenuItemKind.Command);
            var color = p.Color;
            mi.CustomItemSelected += (_, _) =>
            {
                try
                {
                    View.Dispatcher.BeginInvoke(new Action(() =>
                    {
                        Log.Info($"终端背景 → {color}", "ui");
                        Terminal.TermBackgroundStore.Set(color);
                    }));
                }
                catch { }
            };
            bgRoot.Children.Add(mi);
        }
        bgRoot.Children.Add(env.CreateContextMenuItem("", null, CoreWebView2ContextMenuItemKind.Separator));
        var reset = env.CreateContextMenuItem("恢复配色默认", null, CoreWebView2ContextMenuItemKind.Command);
        reset.CustomItemSelected += (_, _) =>
        {
            try
            {
                View.Dispatcher.BeginInvoke(new Action(() =>
                {
                    Log.Info("终端背景 → 恢复配色默认", "ui");
                    Terminal.TermBackgroundStore.Reset();
                }));
            }
            catch { }
        };
        bgRoot.Children.Add(reset);
        items.Add(bgRoot);

        AddSep();
        AddCmd("放大字号", () => { _ = View.CoreWebView2?.ExecuteScriptAsync("window.pixSetFontSize && window.pixSetFontSize((window.termFontSize || 14) + 1);"); });
        AddCmd("缩小字号", () => { _ = View.CoreWebView2?.ExecuteScriptAsync("window.pixSetFontSize && window.pixSetFontSize(Math.max(8, (window.termFontSize || 14) - 1));"); });
    }

    private async Task CopySelectionToClipboardAsync()
    {
        var text = await GetSelectionAsync();
        if (!string.IsNullOrEmpty(text))
        {
            try { System.Windows.Clipboard.SetText(text); } catch { }
        }
    }

    private void PasteFromClipboard()
    {
        try
        {
            var text = System.Windows.Clipboard.GetText();
            if (!string.IsNullOrEmpty(text)) SendText(text);
        }
        catch { }
    }

    /// <summary>建立 SSH 交互式 shell。异常向上抛给 MainWindow 显示。</summary>
    public async Task ConnectAsync(string host, int port, string user, string pass, string? keyPath = null, ProxyConfig? proxy = null)
    {
        Disconnect();
        ClearScreen();
        _isLocal = false;
        _host = host; _port = port; _user = user; _pass = pass; _keyPath = keyPath; _proxy = proxy;
        Log.Info($"SSH 连接中 {user}@{host}:{port}", "ssh");
        SetStatus($"连接 {user}@{host}:{port} …");

        ITerminalTransport? transport = null;
        long generation = 0;
        try
        {
            var expandedKey = keyPath != null ? ExpandKeyPath(keyPath) : null;
            transport = expandedKey != null && IsFIDO2Key(expandedKey)
                ? new OpenSshProcessTransport(host, port, user, expandedKey, _cols, _rows)
                : new SshNetTransport(host, port, user, pass, keyPath, proxy, _cols, _rows);
            _isOpenSSH = transport is OpenSshProcessTransport;
            generation = AttachTransport(transport);
            WireTransportEvents(transport, generation);
            await transport.ConnectAsync();
        }
        catch (Exception ex)
        {
            if (transport != null) DisposeTransportIfCurrent(transport, generation);
            Log.Error($"SSH 认证/握手失败 {user}@{host}:{port}: {ex.Message}", "ssh");
            throw;
        }

        if (!SetCurrentTransportConnected(transport!, generation, true))
        {
            DisposeTransportIfCurrent(transport!, generation);
            throw new IOException("SSH 会话在建立时关闭。");
        }
        Log.Info($"SSH 握手完成，已连接 {user}@{host}:{port}", "ssh");
        SetStatus($"已连接 {user}@{host}");
        try { ConnectedChanged?.Invoke(this, true); } catch { }
        FocusWhenReady();
    }

    /// <summary>应用内本机终端：启动 cmd.exe / powershell 并把 stdout/stderr 接到 xterm。</summary>
    public async Task ConnectLocalAsync()
    {
        Disconnect();
        ClearScreen();
        _isLocal = true;
        _isOpenSSH = false;
        _host = "localhost";
        _port = 0;
        _user = Environment.UserName;
        _pass = "";
        _keyPath = null;
        _proxy = null;
        Log.Info("启动本机 shell …", "local");
        SetStatus("启动本机终端 …");

        ITerminalTransport? transport = null;
        long generation = 0;
        try
        {
            transport = new LocalProcessTransport(_cols, _rows);
            generation = AttachTransport(transport);
            WireTransportEvents(transport, generation);
            await transport.ConnectAsync();
        }
        catch (Exception ex)
        {
            if (transport != null) DisposeTransportIfCurrent(transport, generation);
            Log.Error($"本机 shell 启动失败: {ex.Message}", "local");
            throw;
        }

        if (!SetCurrentTransportConnected(transport!, generation, true))
        {
            DisposeTransportIfCurrent(transport!, generation);
            throw new IOException("本机 shell 在启动时关闭。");
        }
        Log.Info("本机 shell 已就绪", "local");
        SetStatus("本机终端");
        try { ConnectedChanged?.Invoke(this, true); } catch { }
        FocusWhenReady();
    }

    private long AttachTransport(ITerminalTransport transport)
    {
        lock (_transportLock)
        {
            _transportGeneration++;
            _transport = transport;
            return _transportGeneration;
        }
    }

    private bool IsCurrentTransport(ITerminalTransport transport, long generation)
    {
        lock (_transportLock)
            return _transportGeneration == generation && ReferenceEquals(_transport, transport);
    }

    public bool TryGetConnectedTransportGeneration(out long generation)
    {
        lock (_transportLock)
        {
            generation = _transportGeneration;
            return _connected && _transport != null;
        }
    }

    public bool IsCurrentConnectedTransportGeneration(long generation)
    {
        lock (_transportLock)
            return _connected && _transport != null && _transportGeneration == generation;
    }

    private bool SetCurrentTransportConnected(ITerminalTransport transport, long generation, bool connected)
    {
        lock (_transportLock)
        {
            if (_transportGeneration != generation || !ReferenceEquals(_transport, transport)) return false;
            if (connected && !transport.Connected) return false;
            if (_connected == connected) return false;
            _connected = connected;
            return true;
        }
    }

    private void DisposeTransportIfCurrent(ITerminalTransport transport, long generation)
    {
        lock (_transportLock)
        {
            if (_transportGeneration == generation && ReferenceEquals(_transport, transport))
            {
                _transportGeneration++;
                _transport = null;
                _connected = false;
            }
        }
        try { transport.Disconnect(); } catch { }
        try { transport.Dispose(); } catch { }
    }

    private void AppendOutputBufferForCurrentTransport(ITerminalTransport transport, long generation, string text)
    {
        lock (_transportLock)
        {
            if (_transportGeneration != generation || !ReferenceEquals(_transport, transport)) return;
            AppendOutputBuffer(text);
        }
    }

    private void WireTransportEvents(ITerminalTransport transport, long generation)
    {
        transport.Base64DataReceived += (b64) =>
        {
            if (!IsCurrentTransport(transport, generation)) return;
            try
            {
                View.Dispatcher.BeginInvoke(new Action(() =>
                {
                    if (IsCurrentTransport(transport, generation)) SendToTerm("out", b64);
                }));
            }
            catch { }
        };

        transport.TextReceived += (text) =>
        {
            AppendOutputBufferForCurrentTransport(transport, generation, text);
        };

        transport.StatusChanged += (status) =>
        {
            try
            {
                View.Dispatcher.BeginInvoke(new Action(() =>
                {
                    if (IsCurrentTransport(transport, generation)) SetStatus(status);
                }));
            }
            catch { }
        };

        transport.ConnectedChanged += (connected) =>
        {
            try
            {
                View.Dispatcher.BeginInvoke(new Action(() =>
                {
                    if (SetCurrentTransportConnected(transport, generation, connected))
                        ConnectedChanged?.Invoke(this, connected);
                }));
            }
            catch { }
        };
    }

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
                    FlushPendingMessages();
                    if (_pendingSchemeJson != null) SendRawToTerm("{\"t\":\"theme\",\"theme\":" + _pendingSchemeJson + "}");
                    if (_pendingFocus) FocusWhenReady();
                    _readyTcs?.TrySetResult(true);
                    break;
            }
        }
        catch
        {
            // 非法消息忽略
        }
    }

    private void WriteInput(string data)
    {
        if (!_connected || string.IsNullOrEmpty(data)) return;
        try
        {
            var bytes = Encoding.UTF8.GetBytes(data);
            _transport?.Write(bytes);
        }
        catch { }
    }

    /// <summary>命令板用：把一段文本发送到当前 shell（外部调用）。</summary>
    public void SendText(string data) => WriteInput(data);

    public bool SendTextForTransportGeneration(string data, long generation)
    {
        if (string.IsNullOrEmpty(data)) return false;
        ITerminalTransport? transport;
        lock (_transportLock)
        {
            if (!_connected || _transportGeneration != generation || _transport == null) return false;
            transport = _transport;
        }
        try
        {
            transport.Write(Encoding.UTF8.GetBytes(data));
            return true;
        }
        catch { return false; }
    }

    /// <summary>
    /// 一次性远端命令执行（独立通道，不干扰交互式 PTY shell）：工具面板/监控侧栏/系统信息用。
    /// </summary>
    public async Task<string> ExecAsync(string command)
    {
        ITerminalTransport? transport;
        long generation;
        lock (_transportLock)
        {
            if (!_connected || _transport == null) return "";
            transport = _transport;
            generation = _transportGeneration;
        }
        var output = await transport.ExecAsync(command);
        return IsCurrentTransport(transport, generation) && _connected ? output : "";
    }

    /// <summary>清屏（本地 xterm，不经过远端）：对齐 mac termClear 只清本地终端视图。</summary>
    public void ClearScreen()
    {
        try { _ = View.CoreWebView2?.ExecuteScriptAsync("term.clear();"); } catch { }
    }

    private string? _pendingSchemeJson;
    private TermScheme? _lastScheme;

    /// <summary>把配色方案应用到本会话的 xterm.js。</summary>
    public void ApplyTermScheme(TermScheme scheme)
    {
        _lastScheme = scheme;
        SendThemeWithBackground(scheme, Terminal.TermBackgroundStore.Override);
    }

    /// <summary>只改背景色覆盖。</summary>
    public void ApplyBackgroundOverride(string hex)
    {
        var scheme = _lastScheme ?? Terminal.TermSchemeStore.Current;
        SendThemeWithBackground(scheme, string.IsNullOrEmpty(hex) ? null : hex);
        try
        {
            _ = View.CoreWebView2?.ExecuteScriptAsync(
                "try{if(window.term&&window.term.options){window.term.refresh(0,window.term.rows-1)}window.pixFit&&window.pixFit()}catch(e){}");
        }
        catch { }
    }

    private void SendThemeWithBackground(TermScheme scheme, string? bgOverride)
    {
        var bg = string.IsNullOrEmpty(bgOverride) ? scheme.Background : bgOverride;
        var theme = new
        {
            background = bg,
            foreground = scheme.Foreground,
            cursor = scheme.Cursor,
            selectionBackground = scheme.Selection ?? scheme.Foreground,
            black = scheme.Ansi[0], red = scheme.Ansi[1], green = scheme.Ansi[2], yellow = scheme.Ansi[3],
            blue = scheme.Ansi[4], magenta = scheme.Ansi[5], cyan = scheme.Ansi[6], white = scheme.Ansi[7],
            brightBlack = scheme.Ansi[8], brightRed = scheme.Ansi[9], brightGreen = scheme.Ansi[10], brightYellow = scheme.Ansi[11],
            brightBlue = scheme.Ansi[12], brightMagenta = scheme.Ansi[13], brightCyan = scheme.Ansi[14], brightWhite = scheme.Ansi[15],
        };
        var themeJson = JsonSerializer.Serialize(theme);
        _pendingSchemeJson = themeJson;
        try
        {
            if (!string.IsNullOrEmpty(bg))
                View.DefaultBackgroundColor = HexToDrawingColor(bg);
        }
        catch { }
        SendRawToTerm("{\"t\":\"theme\",\"theme\":" + themeJson + "}");
        try { _ = View.CoreWebView2?.ExecuteScriptAsync("try{window.pixFit&&window.pixFit()}catch(e){}"); } catch { }
    }

    /// <summary>取 xterm 当前选区文本。</summary>
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
    /// </summary>
    public SftpClient CreateSftpClient()
    {
        if (!_connected) throw new InvalidOperationException("会话未连接");
        if (_isLocal) throw new InvalidOperationException("本机终端无远端 SFTP");
        if (_isOpenSSH)
            throw new InvalidOperationException(
                "FIDO2 硬件密钥会话暂不支持 SFTP 面板（SSH.NET 无 sk-* 算法支持）。" +
                "文件传输请改用密码或普通密钥登录，或直接使用 scp/sftp 命令。");
        var info = BuildConnectionInfo(_host, _port, _user, _pass, _keyPath, _proxy);
        info.Timeout = TimeSpan.FromSeconds(30);
        var sftp = new SftpClient(info)
        {
            OperationTimeout = TimeSpan.FromSeconds(30)
        };
        sftp.Connect();
        return sftp;
    }

    /// <summary>SCP 客户端。</summary>
    public ScpClient CreateScpClient()
    {
        if (!_connected) throw new InvalidOperationException("会话未连接");
        if (_isLocal) throw new InvalidOperationException("本机终端无远端 SCP");
        if (_isOpenSSH)
            throw new InvalidOperationException(
                "FIDO2 硬件密钥会话暂不支持 SCP 面板（SSH.NET 无 sk-* 算法支持）。" +
                "文件传输请改用密码或普通密钥登录，或直接使用 scp/sftp 命令。");
        var info = BuildConnectionInfo(_host, _port, _user, _pass, _keyPath, _proxy);
        info.Timeout = TimeSpan.FromSeconds(30);
        return new ScpClient(info);
    }

    /// <summary>展开 ~ 与环境变量，供私钥路径存在性检查与加载共用。</summary>
    internal static string ExpandKeyPath(string path)
    {
        path = path.Trim();
        if (path == "~")
            return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (path.StartsWith("~/") || path.StartsWith("~\\"))
            path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), path[2..]);
        return Environment.ExpandEnvironmentVariables(path);
    }

    /// <summary>
    /// FIDO2 硬件安全密钥检测：
    /// 私钥 openssh-key-v1 的 public 段未加密，base64 解码后含
    /// `sk-ssh-ed25519@openssh.com` / `sk-ecdsa-sha2-nistp256@openssh.com` 类型字符串；
    /// 同名 .pub 是明文（第一段即类型），优先检查。
    /// </summary>
    internal static bool IsFIDO2Key(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return false;
        var expanded = ExpandKeyPath(path);
        var skTypes = new[] { "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com" };
        try
        {
            var pub = File.ReadAllText(expanded + ".pub");
            foreach (var t in skTypes)
                if (pub.StartsWith(t, StringComparison.Ordinal)) return true;
        }
        catch { }
        string text;
        try { text = File.ReadAllText(expanded); }
        catch { return false; }
        var b64 = string.Concat(text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
            .Where(l => !l.StartsWith("-----", StringComparison.Ordinal)));
        byte[] decoded;
        try { decoded = Convert.FromBase64String(b64); }
        catch { return false; }
        var s = System.Text.Encoding.UTF8.GetString(decoded);
        return skTypes.Any(s.Contains);
    }

    /// <summary>定位系统 OpenSSH 客户端。</summary>
    internal static string? LocateOpenSSH()
    {
        try
        {
            var sys = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "System32", "OpenSSH", "ssh.exe");
            if (File.Exists(sys)) return sys;
        }
        catch { }
        var path = Environment.GetEnvironmentVariable("PATH");
        if (!string.IsNullOrEmpty(path))
        {
            foreach (var dir in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            {
                try
                {
                    var f = Path.Combine(dir.Trim(), "ssh.exe");
                    if (File.Exists(f)) return f;
                }
                catch { }
            }
        }
        return null;
    }

    /// <summary>
    /// 构造认证方式列表：私钥优先，密码兜底。
    /// </summary>
    internal static ConnectionInfo BuildConnectionInfo(string host, int port, string user, string pass, string? keyPath, ProxyConfig? proxy)
    {
        var methods = new List<Renci.SshNet.AuthenticationMethod>();
        if (!string.IsNullOrWhiteSpace(keyPath))
        {
            var expanded = ExpandKeyPath(keyPath);
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

        if (proxy != null && proxy.Type == ProxyType.SshJump)
        {
            Log.Warn($"代理「{proxy.Name}」类型为 ssh-jump(跳板机)，当前版本未实现，跳过代理直接连接 {host}:{port}", "proxy");
            proxy = null;
        }

        ConnectionInfo info;
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
            info = new ConnectionInfo(host, port, user, proxyType, proxy.Host, proxy.Port,
                proxy.Username ?? "", proxy.Password ?? "", methods.ToArray())
            { Timeout = TimeSpan.FromSeconds(8) };
        }
        else
        {
            info = new ConnectionInfo(host, port, user, methods.ToArray()) { Timeout = TimeSpan.FromSeconds(5) };
        }

        PreferCompatibleAlgorithms(info);
        return info;
    }

    /// <summary>
    /// 保留 SSH.NET 全部已注册算法，仅按兼容优先序重排客户端提议列表。
    /// </summary>
    internal static void PreferCompatibleAlgorithms(ConnectionInfo info)
    {
        PreferOrder(info.Encryptions, new[]
        {
            "chacha20-poly1305@openssh.com",
            "aes128-ctr", "aes192-ctr", "aes256-ctr",
            "aes128-gcm@openssh.com", "aes256-gcm@openssh.com",
            "3des-cbc",
            "aes128-cbc", "aes192-cbc", "aes256-cbc",
        });
        PreferOrder(info.KeyExchangeAlgorithms, new[]
        {
            "curve25519-sha256",
            "curve25519-sha256@libssh.org",
            "ecdh-sha2-nistp256",
            "ecdh-sha2-nistp384",
            "ecdh-sha2-nistp521",
            "diffie-hellman-group-exchange-sha256",
            "diffie-hellman-group14-sha256",
            "diffie-hellman-group16-sha512",
            "diffie-hellman-group14-sha1",
            "diffie-hellman-group-exchange-sha1",
            "diffie-hellman-group1-sha1",
        });
        PreferOrder(info.HostKeyAlgorithms, new[]
        {
            "ssh-ed25519",
            "ecdsa-sha2-nistp256",
            "ecdsa-sha2-nistp384",
            "ecdsa-sha2-nistp521",
            "rsa-sha2-512",
            "rsa-sha2-256",
            "ssh-rsa",
            "ssh-dss",
            "ssh-ed25519-cert-v01@openssh.com",
            "ecdsa-sha2-nistp256-cert-v01@openssh.com",
            "ecdsa-sha2-nistp384-cert-v01@openssh.com",
            "ecdsa-sha2-nistp521-cert-v01@openssh.com",
            "rsa-sha2-512-cert-v01@openssh.com",
            "rsa-sha2-256-cert-v01@openssh.com",
            "ssh-rsa-cert-v01@openssh.com",
            "ssh-dss-cert-v01@openssh.com",
        });
        PreferOrder(info.HmacAlgorithms, new[]
        {
            "hmac-sha2-256-etm@openssh.com",
            "hmac-sha2-512-etm@openssh.com",
            "hmac-sha2-256",
            "hmac-sha2-512",
            "hmac-sha1",
            "hmac-sha1-etm@openssh.com",
        });
    }

    private static void PreferOrder<T>(IDictionary<string, T> map, IReadOnlyList<string> preferred)
    {
        if (map == null || map.Count == 0) return;
        var remaining = new Dictionary<string, T>(map, StringComparer.Ordinal);
        map.Clear();
        foreach (var name in preferred)
        {
            if (remaining.TryGetValue(name, out var value))
            {
                map[name] = value;
                remaining.Remove(name);
            }
        }
        foreach (var kv in remaining)
            map[kv.Key] = kv.Value;
    }

    private void ApplyResize(uint cols, uint rows)
    {
        if (cols == 0 || rows == 0) return;
        _cols = cols;
        _rows = rows;
        ITerminalTransport? transport;
        lock (_transportLock)
        {
            if (!_connected) return;
            transport = _transport;
        }
        transport?.Resize(cols, rows);
    }

    private void SendToTerm(string type, string data)
    {
        var payload = "{\"t\":\"" + type + "\",\"d\":\"" + JsonEncode(data) + "\"}";
        EnqueueOrPost(payload);
    }

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
        catch { }
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
        catch { }
    }

    /// <summary>把键盘焦点交回终端（命令框 Esc / 发送后等场景，对齐 mac 回终端）。</summary>
    public void FocusTerminal()
    {
        try { View.Focus(); } catch { }
        FocusWhenReady();
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

    private void SendRawToTerm(string json)
    {
        EnqueueOrPost(json);
    }

    private void SetStatus(string s) => StatusChanged?.Invoke(this, s);

    public void Disconnect()
    {
        ITerminalTransport? transport;
        bool was;
        lock (_transportLock)
        {
            was = _connected;
            _connected = false;
            _transportGeneration++;
            transport = _transport;
            _transport = null;
        }

        if (was)
        {
            if (_isLocal) Log.Info("主动关闭本机终端", "local");
            else Log.Info($"主动断开 {_user}@{_host}:{_port}", "ssh");
        }
        if (transport != null)
        {
            try { transport.Disconnect(); } catch { }
            try { transport.Dispose(); } catch { }
        }

        _isLocal = false;
        _isOpenSSH = false;
        if (was)
        {
            try { ConnectedChanged?.Invoke(this, false); } catch { }
        }
        _fitTimer?.Stop();
    }

    private bool _webAllowExternal;
    private string? _webAllowedHost;

    /// <summary>
    /// 应用内 Web 页：初始化 WebView2 后 Navigate。
    /// </summary>
    public async Task InitWebSshAsync(string url, bool allowExternalHosts = false)
    {
        if (string.IsNullOrWhiteSpace(url))
            throw new ArgumentException("Web 页面 URL 为空", nameof(url));
        _isWebSsh = true;
        _webSshUrl = url;
        _isLocal = false;
        _webAllowExternal = allowExternalHosts;
        _webAllowedHost = null;
        if (Uri.TryCreate(url, UriKind.Absolute, out var startUri) && !string.IsNullOrEmpty(startUri.Host))
            _webAllowedHost = startUri.Host;

        try
        {
            var env = await GetSharedEnvironmentAsync().ConfigureAwait(true);
            for (var attempt = 1; ; attempt++)
            {
                try
                {
                    var init = View.EnsureCoreWebView2Async(env);
                    var winner = await Task.WhenAny(init, Task.Delay(25_000)).ConfigureAwait(true);
                    if (winner != init)
                        throw new TimeoutException("EnsureCoreWebView2Async 超过 25s（0x800705B4 同类超时）");
                    await init.ConfigureAwait(true);
                    break;
                }
                catch (Exception ex) when (attempt < 2 && IsWebView2InitTimeout(ex))
                {
                    Log.Warn($"WebView2 初始化超时(WebSSH)，清 profile 锁后重试: {ex.Message}", "webview");
                    TryClearWebView2Locks();
                    await Task.Delay(400).ConfigureAwait(true);
                }
            }
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException(
                "WebView2 初始化失败（请安装 Microsoft Edge WebView2 Runtime）：" + ex.Message, ex);
        }

        View.CoreWebView2.Settings.AreDefaultContextMenusEnabled = true;
        View.CoreWebView2.Settings.IsStatusBarEnabled = false;
        View.CoreWebView2.Settings.AreBrowserAcceleratorKeysEnabled = false;
        try
        {
            View.CoreWebView2.Profile.PreferredColorScheme = ThemeManager.IsDark
                ? CoreWebView2PreferredColorScheme.Dark
                : CoreWebView2PreferredColorScheme.Light;
        }
        catch { }

        View.CoreWebView2.NavigationStarting -= OnWebSshNavStarting;
        View.CoreWebView2.NavigationStarting += OnWebSshNavStarting;
        View.CoreWebView2.NewWindowRequested -= OnWebSshNewWindow;
        View.CoreWebView2.NewWindowRequested += OnWebSshNewWindow;

        var tcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        void OnNav(object? sender, CoreWebView2NavigationCompletedEventArgs e)
        {
            View.CoreWebView2.NavigationCompleted -= OnNav;
            tcs.TrySetResult(e.IsSuccess);
            if (!e.IsSuccess)
                Log.Warn($"Web 页面导航失败 WebErrorStatus={e.WebErrorStatus}", "webssh");
        }
        View.CoreWebView2.NavigationCompleted += OnNav;
        var safe = System.Text.RegularExpressions.Regex.Replace(url, @"[?&]token=[^&]*", "?token=***");
        Log.Info($"内嵌 Web 加载 {safe} external={allowExternalHosts}", "webssh");
        View.CoreWebView2.Navigate(url);

        var done = await Task.WhenAny(tcs.Task, Task.Delay(15_000)).ConfigureAwait(true);
        if (done != tcs.Task || !await tcs.Task.ConfigureAwait(true))
            Log.Warn("Web 页面导航超时或失败（页面可能仍部分可用）", "webssh");

        _connected = true;
        _jsReady = true;
        try { ConnectedChanged?.Invoke(this, true); } catch { }
        try { StatusChanged?.Invoke(this, allowExternalHosts ? "Web 页面已加载" : "Web 终端已加载"); } catch { }
        Log.Info(allowExternalHosts ? "内嵌 Web 外部页已加载" : "内嵌 Web 终端已加载", "webssh");
    }

    private void OnWebSshNewWindow(object? sender, CoreWebView2NewWindowRequestedEventArgs e)
    {
        try
        {
            e.Handled = true;
            if (!string.IsNullOrEmpty(e.Uri))
                View.CoreWebView2?.Navigate(e.Uri);
        }
        catch { }
    }

    private void OnWebSshNavStarting(object? sender, CoreWebView2NavigationStartingEventArgs e)
    {
        try
        {
            if (!Uri.TryCreate(e.Uri, UriKind.Absolute, out var u))
            {
                e.Cancel = true;
                return;
            }
            var host = (u.Host ?? "").ToLowerInvariant();
            var loopback = host is "127.0.0.1" or "localhost" or "::1" or "";
            var okScheme = u.Scheme is "http" or "https" or "about" or "blob" or "data";
            if (!okScheme)
            {
                Log.Warn($"内嵌 Web 拦截 scheme: {e.Uri}", "webssh");
                e.Cancel = true;
                return;
            }
            if (_webAllowExternal)
            {
                if (loopback || string.IsNullOrEmpty(host))
                    return;
                var allow = (_webAllowedHost ?? "").ToLowerInvariant();
                if (!string.IsNullOrEmpty(allow))
                {
                    if (host == allow || host.EndsWith("." + allow, StringComparison.Ordinal)
                        || allow.EndsWith("." + host, StringComparison.Ordinal)
                        || SameSite(host, allow))
                        return;
                    Log.Warn($"内嵌 Web 拦截跨站: {e.Uri} allow={_webAllowedHost}", "webssh");
                    e.Cancel = true;
                    return;
                }
                _webAllowedHost = host;
                return;
            }
            if (!loopback)
            {
                Log.Warn($"内嵌 Web 拦截外链: {e.Uri}", "webssh");
                e.Cancel = true;
            }
        }
        catch { e.Cancel = true; }
    }

    private static bool SameSite(string a, string b)
    {
        static string Base(string h)
        {
            var parts = h.Split('.');
            if (parts.Length >= 2) return parts[^2] + "." + parts[^1];
            return h;
        }
        return Base(a) == Base(b);
    }

    /// <summary>Web 终端刷新（重连菜单走这里，不建 SSH）。</summary>
    public async Task ReloadWebSshAsync()
    {
        if (string.IsNullOrEmpty(_webSshUrl) || View.CoreWebView2 == null)
        {
            if (!string.IsNullOrEmpty(_webSshUrl))
                await InitWebSshAsync(_webSshUrl).ConfigureAwait(true);
            return;
        }
        View.CoreWebView2.Navigate(_webSshUrl);
        _connected = true;
        try { StatusChanged?.Invoke(this, "Web 终端已刷新"); } catch { }
    }

    /// <summary>关闭 tab 时调用：断开底层连接并释放 WebView2。</summary>
    public void Dispose()
    {
        Disconnect();
        try
        {
            if (View.CoreWebView2 != null)
            {
                View.CoreWebView2.NavigationStarting -= OnWebSshNavStarting;
                View.CoreWebView2.NewWindowRequested -= OnWebSshNewWindow;
                View.CoreWebView2.WebMessageReceived -= OnWebMessageReceived;
            }
        }
        catch { }
        try { View.CoreWebView2.ContextMenuRequested -= OnContextMenuRequested; } catch { }
        try { View.SizeChanged -= OnViewSizeChanged; } catch { }
        _fitTimer?.Stop();
        try { View.Dispose(); } catch { }
    }
}
