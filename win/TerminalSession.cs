using System.Windows;
using System.Windows.Threading;
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
    /// <summary>本会话独占的 WebView2 控件，放进对应 TabItem 的内容区。
    /// DefaultBackgroundColor 跟配色方案走，避免页面未铺满时露出系统黑底（半截黑屏）。</summary>
    public WebView2 View { get; } = CreateView();

    private static WebView2 CreateView()
    {
        var v = new WebView2
        {
            HorizontalAlignment = System.Windows.HorizontalAlignment.Stretch,
            VerticalAlignment = System.Windows.VerticalAlignment.Stretch,
            // 与 TermSchemes.pix-dark 默认底一致；ApplyTermScheme 会再改
            DefaultBackgroundColor = HexToDrawingColor("#002945"),
        };
        // SizeChanged → pixFit 在实例构造函数里挂（CreateView 是 static）
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
            // 兜底：无 SourceHost 时剥 user@ / : ~ 再显示，避免标签变成系统提示符
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

    /// <summary>远端 OSC 标题变化。标签头**不**订阅此事件（用 TabTitle）。</summary>
    public event Action<TerminalSession>? TitleChanged;

    /// <summary>状态变化 → 若为当前活动 tab，MainWindow 显示到状态栏。</summary>
    public event Action<TerminalSession, string>? StatusChanged;

    /// <summary>连接状态变化（连上/断开）→ MainWindow 清 SFTP/系统信息等侧栏。</summary>
    public event Action<TerminalSession, bool>? ConnectedChanged;

    private readonly string _htmlPath;

    // ---- 以下为单会话桥逻辑的实例化字段（与 P1 完全一致，仅从窗口移入会话）----
    private SshClient? _ssh;
    private ShellStream? _shell;
    /// <summary>本机 shell 进程（ConnectionType=300）；与 _ssh/_shell 互斥。</summary>
    private Process? _localProc;
    private Stream? _localStdin;
    private Thread? _readThread;
    // SizeChanged → pixFit 防抖（拖坞/resize 风暴）；MainWindow.SuppressTerminalFit 时全跳
    private DispatcherTimer? _fitTimer;
    private uint _cols = 80;
    private uint _rows = 24;
    private object? _channel;
    private MethodInfo? _windowChange;
    private volatile bool _connected;
    private volatile bool _isLocal;
    // ExecAsync 命令追踪：Disconnect 前取消所有正在执行的 SshCommand，防止 SSH.NET CancelAsync 向
    // 已断开连接发送 TERM 导致 "Client not connected" 异常从线程池回调逃逸 → 整程序闪退。
    private CancellationTokenSource? _execCts;

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
    /// <summary>InitAsync 等待 JS ready；超时/失败则连接前就能明确报错，避免黑屏假成功。</summary>
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
        View.Visibility = System.Windows.Visibility.Collapsed; // 默认隐藏，切到此 tab 时由 OnTabSelectionChanged 亮起
        WireTerminalView();
        Title = label;
        _htmlPath = htmlPath;
    }

    /// <summary>共享 WebView2 环境：固定 UserDataFolder，避免默认目录被多实例/僵尸进程锁死导致 0x800705B4 超时。</summary>
    private static CoreWebView2Environment? _sharedEnv;
    private static readonly SemaphoreSlim EnvLock = new(1, 1);

    private static async Task<CoreWebView2Environment> GetSharedEnvironmentAsync()
    {
        if (_sharedEnv != null) return _sharedEnv;
        await EnvLock.WaitAsync().ConfigureAwait(true);
        try
        {
            if (_sharedEnv != null) return _sharedEnv;
            // Roaming\PixShell\webview2 —— 与 HostStore 同根，可写、可清、不抢 exe 旁默认缓存
            var dataDir = Path.Combine(HostStore.AppDir, "webview2");
            Directory.CreateDirectory(dataDir);
            // 多会话共用一个环境，UserDataFolder 唯一；每 tab 仍是独立 CoreWebView2Controller
            var opts = new CoreWebView2EnvironmentOptions
            {
                // 关后台节流，避免最小化/后台时初始化拖死
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

    /// <summary>初始化 WebView2 并加载本地 xterm 页面（连接前调用一次）。
    /// 缺 terminal.html / Runtime 缺失 / 导航失败 / ready 超时都会抛异常，
    /// 由 MainWindow 回滚 tab 并展示明确失败，而不是成功动画+黑屏。</summary>
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
            // 必须带 Environment：裸 EnsureCoreWebView2Async() 会抢 exe 旁默认 UserData，
            // 多 tab / 残留 msedgewebview2 / 并发初始化 → ERROR_TIMEOUT 0x800705B4。
            var env = await GetSharedEnvironmentAsync().ConfigureAwait(true);
            // 给一次重试：僵尸锁/首次建 profile 偶发超时，清 lock 文件再来
            for (var attempt = 1; ; attempt++)
            {
                try
                {
                    var init = View.EnsureCoreWebView2Async(env);
                    var winner = await Task.WhenAny(init, Task.Delay(25_000)).ConfigureAwait(true);
                    if (winner != init)
                        throw new TimeoutException("EnsureCoreWebView2Async 超过 25s（0x800705B4 同类超时）");
                    await init.ConfigureAwait(true); // 传播真实异常
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
        // 关掉 WebView2 自带的浏览器右键菜单（刷新/查看源码等），改用下面的自绘终端右键菜单
        // （复制/粘贴/全选/清屏 + 设置背景，对齐 mac 版终端右键菜单）。
        // AreDefaultContextMenusEnabled=true 才能触发 ContextMenuRequested；
        // 处理器里只清默认项并塞自定义项，Handled 保持 false 让 WebView2 自己弹原生菜单。
        View.CoreWebView2.Settings.AreDefaultContextMenusEnabled = true;
        View.CoreWebView2.Settings.IsStatusBarEnabled = false;
        View.CoreWebView2.Settings.AreBrowserAcceleratorKeysEnabled = false;
        // 右键菜单配色跟随 App 主题（WebView2 原生菜单走 PreferredColorScheme）
        try
        {
            View.CoreWebView2.Profile.PreferredColorScheme = ThemeManager.IsDark
                ? CoreWebView2PreferredColorScheme.Dark
                : CoreWebView2PreferredColorScheme.Light;
        }
        catch { /* 旧 runtime 无 Profile API 时忽略 */ }
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

    /// <summary>清 WebView2 profile 里常见的 lock/单例文件（不删整个缓存，避免每次冷启动）。</summary>
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
                    try { File.Delete(f); } catch { /* 占用中就跳过 */ }
                }
            }
        }
        catch { /* best-effort */ }
    }

    // ---------------------------------------------------------------------
    // 终端右键菜单：复制/粘贴/全选/清屏 + 设置背景(12 预设+恢复默认)
    // 对齐 mac App/AppDelegate+TermMenu.swift。
    //
    // **必须**走 WebView2 原生 ContextMenuItem：WPF ContextMenu 弹在 WebView2 HWND
    // 之上被 airspace 挡死，用户右键等于没反应（mac 截图那套菜单 Windows 上「不存在」的根因）。
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
        // Handled 必须保持 false：WebView2 才会用我们改过的 MenuItems 弹出原生菜单。
        // 设 true 等于自己负责画菜单——WPF Popup 又被 HWND airspace 挡死，右键等于没反应。
        var env = View.CoreWebView2?.Environment;
        if (env == null) return;

        var items = e.MenuItems;
        items.Clear();

        void AddCmd(string label, Action action)
        {
            var mi = env.CreateContextMenuItem(label, null, CoreWebView2ContextMenuItemKind.Command);
            mi.CustomItemSelected += (_, _) =>
            {
                // 回调在 WebView2 线程；切回 UI 线程再动剪贴板 / 终端
                try { View.Dispatcher.BeginInvoke(action); } catch { /* disposed */ }
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

        // 设置背景 ▸ 子菜单（原生 submenu，不靠 WPF Popup）
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
        // 清掉首屏欢迎语 / 上一次会话残留，终端只留给远端真实输出
        ClearScreen();
        _isLocal = false;
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
        // 不往终端写 [pixshell] connected —— 状态栏已有；终端只留远端 MOTD/提示符。
        try { ConnectedChanged?.Invoke(this, true); } catch { }
        FocusWhenReady();
    }

    /// <summary>
    /// 应用内本机终端：启动 cmd.exe / powershell 并把 stdout/stderr 接到 xterm，
    /// stdin 走标准输入。**禁止** Process.Start 弹外部 wt/cmd 窗口。
    /// 右键菜单走 InitAsync 已挂的 WebView2 ContextMenu（复制/粘贴/清屏/背景），与 SSH 会话相同。
    /// </summary>
    public async Task ConnectLocalAsync()
    {
        if (_connected) Disconnect();
        ClearScreen();
        _isLocal = true;
        _host = "localhost";
        _port = 0;
        _user = Environment.UserName;
        _pass = "";
        _keyPath = null;
        _proxy = null;
        Log.Info("启动本机 shell …", "local");
        SetStatus("启动本机终端 …");
        try
        {
            await Task.Run(StartLocalShell);
        }
        catch (Exception ex)
        {
            Log.Error($"本机 shell 启动失败: {ex.Message}", "local");
            throw;
        }
        _connected = true;
        Log.Info("本机 shell 已就绪", "local");
        SetStatus("本机终端");
        try { ConnectedChanged?.Invoke(this, true); } catch { }
        FocusWhenReady();
    }

    /// <summary>起本机 shell 子进程（重定向 stdio，CreateNoWindow）。优先 ComSpec/cmd，其次 powershell。</summary>
    private void StartLocalShell()
    {
        var shell = ResolveLocalShell(out var args);
        var psi = new ProcessStartInfo
        {
            FileName = shell,
            Arguments = args,
            WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            // 输入也按 UTF-8，避免中文路径/命令乱码
            StandardInputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
        };
        // 给子进程一个可用的终端环境变量（即便没有真 ConPTY）
        psi.Environment["TERM"] = "xterm-256color";
        psi.Environment["COLORTERM"] = "truecolor";
        psi.Environment["PIXSHELL_LOCAL"] = "1";
        try { psi.Environment["COLUMNS"] = _cols.ToString(); } catch { }
        try { psi.Environment["LINES"] = _rows.ToString(); } catch { }

        var proc = new Process { StartInfo = psi, EnableRaisingEvents = true };
        if (!proc.Start())
            throw new InvalidOperationException("无法启动本机 shell：" + shell);

        _localProc = proc;
        _localStdin = proc.StandardInput.BaseStream;
        // 退出时清连接态（对齐 SSH ReadPump finally）
        proc.Exited += (_, _) =>
        {
            View.Dispatcher.BeginInvoke(new Action(() =>
            {
                if (_connected)
                {
                    _connected = false;
                    Log.Info("本机 shell 已退出", "local");
                    SetStatus("本机终端已关闭");
                    try { ConnectedChanged?.Invoke(this, false); } catch { }
                }
            }));
        };

        _readThread = new Thread(() => LocalReadPump(proc))
        {
            IsBackground = true,
            Name = "local-shell-read"
        };
        _readThread.Start();
    }

    private static string ResolveLocalShell(out string args)
    {
        // cmd.exe：/K 保持交互；ComSpec 优先
        var comspec = Environment.GetEnvironmentVariable("ComSpec");
        if (!string.IsNullOrWhiteSpace(comspec) && File.Exists(comspec))
        {
            args = "/K chcp 65001>nul";
            return comspec;
        }
        var sysCmd = Path.Combine(Environment.SystemDirectory, "cmd.exe");
        if (File.Exists(sysCmd))
        {
            args = "/K chcp 65001>nul";
            return sysCmd;
        }
        // 兜底 powershell
        args = "-NoLogo -NoExit";
        return "powershell.exe";
    }

    /// <summary>并行读 stdout + stderr，按 UTF-8 解码后 base64 推到 xterm（复用 SSH out 通路）。</summary>
    private void LocalReadPump(Process proc)
    {
        var outs = new[] { proc.StandardOutput.BaseStream, proc.StandardError.BaseStream };
        var threads = new List<Thread>();
        foreach (var stream in outs)
        {
            var s = stream;
            var th = new Thread(() =>
            {
                var buf = new byte[4096];
                var decoder = Encoding.UTF8.GetDecoder();
                var chars = new char[Encoding.UTF8.GetMaxCharCount(buf.Length)];
                try
                {
                    while (true)
                    {
                        int n;
                        try { n = s.Read(buf, 0, buf.Length); }
                        catch { break; }
                        if (n <= 0) break;
                        int c = decoder.GetChars(buf, 0, n, chars, 0, flush: false);
                        var text = c > 0 ? new string(chars, 0, c) : "";
                        if (text.Length > 0) AppendOutputBuffer(text);
                        string b64;
                        if (HighlightEnabled && c > 0)
                        {
                            b64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(
                                Highlight.SemanticHighlight.Decorate(text, ThemeManager.IsDark)));
                        }
                        else
                        {
                            b64 = Convert.ToBase64String(buf, 0, n);
                        }
                        View.Dispatcher.BeginInvoke(new Action(() => SendToTerm("out", b64)));
                    }
                }
                catch { /* 进程退出 */ }
            })
            { IsBackground = true, Name = "local-shell-stream" };
            th.Start();
            threads.Add(th);
        }
        foreach (var t in threads)
        {
            try { t.Join(); } catch { }
        }
        // 双流出空：等进程退，Exited 事件会清 _connected
        try { proc.WaitForExit(500); } catch { }
    }

    // 后台线程：建立 SSH 会话 + 交互式 shell + 启动读线程。
    // try/finally：Connect/CreateShellStream 中途失败时释放 SshClient，避免句柄泄漏。
    private void Connect(string host, int port, string user, string pass, string? keyPath, ProxyConfig? proxy)
    {
        // 局域网 IP 直连时跳过 DNS/反向查找带来的数秒停顿：把主机名解析成 IP 再拨。
        // 解析失败则原样回退（主机名仍可连，只是可能慢）。
        var connectHost = ResolveFast(host);
        var info = BuildConnectionInfo(connectHost, port, user, pass, keyPath, proxy);

        var ssh = new SshClient(info);
        try
        {
            ssh.KeepAliveInterval = TimeSpan.FromSeconds(30);
            ssh.Connect();

            var shell = ssh.CreateShellStream("xterm-256color", _cols, _rows, 0, 0, 4096);

            _ssh = ssh;
            _shell = shell;
            ssh = null; // 所有权已转给字段，finally 不再 Dispose

            CacheChannelReflection(shell);

            _readThread = new Thread(ReadPump) { IsBackground = true, Name = "ssh-read-pump" };
            _readThread.Start();
        }
        finally
        {
            if (ssh != null)
            {
                try { ssh.Dispose(); } catch { /* 失败路径清理 */ }
            }
        }
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
                    // 不往终端写 [pixshell] session closed —— 状态栏已有。
                    ConnectedChanged?.Invoke(this, false);
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
                    _readyTcs?.TrySetResult(true);
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
        if (!_connected || string.IsNullOrEmpty(data)) return;
        try
        {
            var bytes = Encoding.UTF8.GetBytes(data);
            // 本机 shell：写 stdin
            if (_isLocal)
            {
                var stdin = _localStdin;
                if (stdin == null) return;
                stdin.Write(bytes, 0, bytes.Length);
                stdin.Flush();
                return;
            }
            var shell = _shell;
            if (shell == null) return;
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
        // 本机会话：另起一次性 cmd /c，不干扰交互 shell。
        if (_isLocal)
        {
            try
            {
                return await Task.Run(() =>
                {
                    var psi = new ProcessStartInfo
                    {
                        FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe",
                        Arguments = "/c " + command,
                        UseShellExecute = false,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        CreateNoWindow = true,
                        StandardOutputEncoding = Encoding.UTF8,
                        StandardErrorEncoding = Encoding.UTF8,
                    };
                    using var p = Process.Start(psi);
                    if (p == null) return "";
                    var stdout = p.StandardOutput.ReadToEnd();
                    var stderr = p.StandardError.ReadToEnd();
                    p.WaitForExit(20_000);
                    return string.IsNullOrEmpty(stdout) ? stderr : stdout;
                });
            }
            catch (Exception ex)
            {
                return "执行失败: " + ex.Message;
            }
        }
        if (_ssh is not { IsConnected: true }) return "";
        _execCts?.Cancel(); _execCts?.Dispose();
        _execCts = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        var ct = _execCts.Token;
        try
        {
            return await Task.Run(() =>
            {
                using var cmd = _ssh.CreateCommand(command);
                cmd.CommandTimeout = TimeSpan.FromSeconds(20);
                ct.ThrowIfCancellationRequested();
                var result = cmd.Execute();
                return string.IsNullOrEmpty(result) ? (cmd.Error ?? "") : result;
            }, ct);
        }
        catch (OperationCanceledException)
        {
            return "执行取消: 会话已断开";
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
        // 空 hex = 恢复默认：强制用 scheme 原背景，并再 fit 一次
        SendThemeWithBackground(scheme, string.IsNullOrEmpty(hex) ? null : hex);
        try
        {
            _ = View.CoreWebView2?.ExecuteScriptAsync(
                "try{if(window.term&&window.term.options){window.term.refresh(0,window.term.rows-1)}window.pixFit&&window.pixFit()}catch(e){}");
        }
        catch { /* ignore */ }
    }

    private void SendThemeWithBackground(TermScheme scheme, string? bgOverride)
    {
        var bg = string.IsNullOrEmpty(bgOverride) ? scheme.Background : bgOverride;
        var theme = new
        {
            background = bg,
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
        // WebView2 控件底色与 scheme 同步，fit 未铺满时不再露系统黑。
        try
        {
            if (!string.IsNullOrEmpty(bg))
                View.DefaultBackgroundColor = HexToDrawingColor(bg);
        }
        catch { /* 非法 hex 忽略 */ }
        SendRawToTerm("{\"t\":\"theme\",\"theme\":" + themeJson + "}");
        // 强制再 fit 一次，消除半高/半截黑
        try { _ = View.CoreWebView2?.ExecuteScriptAsync("try{window.pixFit&&window.pixFit()}catch(e){}"); } catch { }
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
        if (_isLocal) throw new InvalidOperationException("本机终端无远端 SFTP");
        var info = BuildConnectionInfo(_host, _port, _user, _pass, _keyPath, _proxy);
        info.Timeout = TimeSpan.FromSeconds(30);
        var sftp = new SftpClient(info)
        {
            OperationTimeout = TimeSpan.FromSeconds(30)
        };
        sftp.Connect();
        return sftp;
    }

    /// <summary>SCP 客户端（Dropbear 原生支持，无需 openssh-sftp-server）。</summary>
    public ScpClient CreateScpClient()
    {
        if (!_connected) throw new InvalidOperationException("会话未连接");
        if (_isLocal) throw new InvalidOperationException("本机终端无远端 SCP");
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
    /// 快路径解析：字面量 IP 直接返回；主机名用 DNS 解析，优先 IPv4，失败原样返回。
    /// 目的是避免 SSH.NET 内部对主机名做额外反向/多栈解析导致局域网 3–4s 停顿。
    /// </summary>
    private static string ResolveFast(string host)
    {
        if (string.IsNullOrWhiteSpace(host)) return host;
        if (System.Net.IPAddress.TryParse(host, out _)) return host;
        try
        {
            var addrs = System.Net.Dns.GetHostAddresses(host);
            var v4 = addrs.FirstOrDefault(a => a.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork);
            if (v4 != null)
            {
                Log.Info($"DNS 快解析 {host} → {v4}", "ssh");
                return v4.ToString();
            }
            var any = addrs.FirstOrDefault();
            if (any != null)
            {
                Log.Info($"DNS 快解析 {host} → {any}", "ssh");
                return any.ToString();
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"DNS 快解析失败 {host}: {ex.Message}，回退原主机名", "ssh");
        }
        return host;
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
            // 局域网直连：15s 太长，握手/TCP 超时压到 5s；失败更快露出错误而不是干等。
            info = new ConnectionInfo(host, port, user, proxyType, proxy.Host, proxy.Port,
                proxy.Username ?? "", proxy.Password ?? "", methods.ToArray())
            { Timeout = TimeSpan.FromSeconds(8) };
        }
        else
        {
            info = new ConnectionInfo(host, port, user, methods.ToArray()) { Timeout = TimeSpan.FromSeconds(5) };
        }

        // SSH.NET 2024.2 默认已启用全部自带算法；这里只重排提议顺序，现代优先、旧设备兜底。
        // 字典可改（Clear/Add），不能替换属性本身。
        PreferCompatibleAlgorithms(info);
        return info;
    }

    /// <summary>
    /// 保留 SSH.NET 全部已注册算法，仅按兼容优先序重排客户端提议列表。
    /// 库内已含：chacha/aes-ctr/aes-gcm/aes-cbc/3des、curve25519/ecdh/dh-group*、
    /// ed25519/ecdsa/rsa-sha2/ssh-rsa/ssh-dss、hmac-sha2/sha1(+etm)。
    /// 注意：blowfish-cbc / cast128-cbc 不在 SSH.NET 2024.2 实现内，无法凭空注册。
    /// </summary>
    private static void PreferCompatibleAlgorithms(ConnectionInfo info)
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

    /// <summary>按 preferred 顺序重建字典，未列出的算法追加在末尾（不丢库默认项）。</summary>
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
        var connected = _connected;
        var ch = _channel;
        var wc = _windowChange;
        if (!connected || wc == null || ch == null) return;
        try
        {
            wc.Invoke(ch, new object[] { cols, rows, 0u, 0u });
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

    /// <summary>把键盘焦点交回终端（命令框 Esc / 发送后等场景，对齐 mac 回终端）。</summary>
    public void FocusTerminal()
    {
        try { View.Focus(); } catch { /* ignore */ }
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
        var was = _connected;
        if (was)
        {
            if (_isLocal) Log.Info("主动关闭本机终端", "local");
            else Log.Info($"主动断开 {_user}@{_host}:{_port}", "ssh");
        }
        _connected = false;
        // 本机 shell
        try
        {
            if (_localProc is { HasExited: false })
            {
                try { _localProc.Kill(entireProcessTree: true); } catch { try { _localProc.Kill(); } catch { } }
            }
        }
        catch { }
        try { _localStdin?.Dispose(); } catch { }
        try { _localProc?.Dispose(); } catch { }
        _localStdin = null;
        _localProc = null;
        // 取消所有正在执行的 SshCommand（防止 SSH.NET CancelAsync 在连接已断开后回调）
        try { _execCts?.Cancel(); } catch { }
        try { _execCts?.Dispose(); } catch { }
        _execCts = null;
        // SSH
        try { _shell?.Dispose(); } catch { }
        try { _ssh?.Disconnect(); } catch { }
        try { _ssh?.Dispose(); } catch { }
        _shell = null;
        _ssh = null;
        _channel = null;
        _windowChange = null;
        _isLocal = false;
        if (was)
        {
            try { ConnectedChanged?.Invoke(this, false); } catch { }
        }
        _fitTimer?.Stop();
    }

    /// <summary>true = 允许非回环 http(s)（外部 Web/VNC）；false = 仅 127.0.0.1（本地桥 token 页）。</summary>
    private bool _webAllowExternal;
    /// <summary>外部模式下优先放行的 host；同站跳转粗匹配。</summary>
    private string? _webAllowedHost;

    /// <summary>
    /// 应用内 Web 页：初始化 WebView2 后 Navigate。
    /// - 本地桥：/webssh?token=…（allowExternalHosts=false，仅回环）
    /// - 外部页：noVNC / 面板（allowExternalHosts=true，同站可跳转）
    /// **禁止** Process.Start 外开系统浏览器——那是错误主路径。
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
        catch { /* 旧 runtime */ }

        View.CoreWebView2.NavigationStarting -= OnWebSshNavStarting;
        View.CoreWebView2.NavigationStarting += OnWebSshNavStarting;
        // target=_blank → 同页打开（仍受 NavigationStarting 约束）；noVNC 有时弹新窗
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
        // 日志抹掉 token
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
        catch { /* ignore */ }
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
                    return; // allow
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
                // 无 allowedHost：首次外链即放行并锁定
                _webAllowedHost = host;
                return;
            }
            // 本地桥模式：仅回环
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

    /// <summary>关闭 tab 时调用：断开 SSH 并释放 WebView2。</summary>
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
