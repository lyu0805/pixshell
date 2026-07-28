using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;
using static System.Windows.Visibility;
using PixShell.Logging;
using PixShell.Proxy;
using PixShell.UI;
using Renci.SshNet.Common;

namespace PixShell;

/// <summary>
/// PixShell Windows 原生端主窗口（新布局，对齐 mac 重做后的五区布局）。
///
/// 顶栏：折叠侧栏/连接管理器/新建连接 | 会话胶囊 tab | ＋快速连接 … 主题/工具/汉堡。
/// 侧栏：服务器监控仪表盘（<see cref="UI.MonitorSidebar"/>，非主机列表）；可整块折叠为窄轨。
/// 工作区：无会话 → 快速连接落地页(<see cref="UI.QuickConnectView"/>)；有会话 → 终端。
///   命令栏在坞上方；底部坞单行 [文件][命令] + 文件操作图标，整体可折叠到 0 高。
/// 主机列表只在「连接管理器」弹层(<see cref="UI.ConnectionManagerOverlay"/>)里维护。
/// </summary>
public partial class MainWindow : Window
{
    private readonly ObservableCollection<HostEntry> _hosts = new();
    private string _htmlPath = "";
    /// <summary>与 csproj / mac CFBundleShortVersionString 对齐的展示与更新比较版本。</summary>
    private const string AppVersion = "0.1.1";

    private bool _sideCollapsed;
    private double _sidebarWidth = UiStore.Load().SidebarWidth;
    private bool _dockCollapsed;
    private bool _showingQuickConnect;
    private double _dockHeight = Math.Max(160, UiStore.Load().BottomHeight > 0 ? UiStore.Load().BottomHeight : 230);

    private string _downloadDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");

    private HashSet<string> _backupEnabled = new();

    private readonly DispatcherTimer _monitorTimer = new() { Interval = TimeSpan.FromSeconds(3) };

    // 本地 CLI/AI-Agent 桥（对齐 mac AppDelegate.agentBridge + bridgeTimer）。
    private Bridge.AgentBridge? _agentBridge;
    private readonly DispatcherTimer _bridgeStatusTimer = new() { Interval = TimeSpan.FromSeconds(3) };

    public MainWindow()
    {
        InitializeComponent();
        SidebarColumn.Width = new GridLength(_sidebarWidth);
        Loaded += OnLoaded;
        Closed += OnClosed;
        Sessions.SelectionChanged += OnTabSelectionChanged;
        _monitorTimer.Tick += (_, _) => _ = PollMonitor();
        _bridgeStatusTimer.Tick += (_, _) => UpdateCliStatus();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        Log.Banner(AppVersion);
        ThemeManager.Initialize();   // 读回上次选的主题（之前 Windows 端主题完全没持久化）
        HighlightColors.Load();
        // 恢复上次坞高度（GridLength 默认 230，这里覆盖成 prefs）
        if (_dockHeight >= 160)
            DockRow.Height = new GridLength(_dockHeight);
        SourceInitialized += MainWindow_SourceInitialized;

        Terminal.TermSchemeStore.Load();
        Terminal.TermSchemeStore.Changed += scheme =>
        {
            // 设置里选了新配色 → 广播给所有已开的会话 tab（不止当前活动的）。
            foreach (var obj in Sessions.Items)
                if (obj is TabItem { Tag: TerminalSession s }) s.ApplyTermScheme(scheme);
        };
        Terminal.TermBackgroundStore.Load();
        Terminal.TermBackgroundStore.Changed += hex =>
        {
            // 终端右键菜单「设置背景/恢复配色默认」→ 广播给所有已开的会话 tab（对齐 mac applyTermBackground）。
            foreach (var obj in Sessions.Items)
                if (obj is TabItem { Tag: TerminalSession s }) s.ApplyBackgroundOverride(hex);
        };
        _htmlPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "web", "terminal.html");

        foreach (var h in HostStore.Load()) _hosts.Add(h);

        // 连接管理器弹层：主机的增删改连全部在这里，侧栏不再放主机列表。
        // 现在为独立窗口，在 ShowConnectionManager() 中实例化。

        // 快速连接/历史落地页。
        QuickConnectPanel.HostsProvider = () => RecentsStore.RecentHosts(_hosts);
        QuickConnectPanel.HasPassword = h => CredentialStore.GetPassword(h.Id) != null;
        QuickConnectPanel.OnConnect = ConnectToHost;
        QuickConnectPanel.OnEdit = EditHostFlow;
        QuickConnectPanel.OnNew = NewHostFlow;
        QuickConnectPanel.OnClear = () => { RecentsStore.ClearRecents(); QuickConnectPanel.Reload(); };
        // logo → 应用内本机终端（不弹 wt/cmd）
        QuickConnectPanel.OnLocalTerminal = () => _ = OpenLocalTerminalSession();
        // 有会话时从 QC 返回当前终端（对齐 mac QuickConnect.onBack）
        QuickConnectPanel.OnBack = () =>
        {
            _showingQuickConnect = false;
            SetSessionViewsVisible(true);
            QuickConnectPanel.Visibility = Visibility.Collapsed;
            QuickConnectPanel.SetShowsBack(false);
            UpdateWorkCenterVisibility();
            if (Sessions.SelectedItem is TabItem { Tag: TerminalSession s })
            {
                try { s.View.Focus(); } catch { /* ignore */ }
            }
        };
        QuickConnectPanel.Reload(); // <- Added to fix history not showing by default

        // 工具面板（宫格图标 flyout）。
        ToolsFlyout.SessionsProvider = BuildSessionTitles;
        ToolsFlyout.OnSelectSession = i => { if (i >= 0 && i < Sessions.Items.Count) Sessions.SelectedIndex = i; };
        ToolsFlyout.OnExec = async cmd => ActiveSession != null ? await ActiveSession.ExecAsync(cmd) : "";
        ToolsFlyout.OnPickDownloadDir = PickDownloadDir;
        ToolsFlyout.OnOpenDownloadDir = () => { try { Process.Start(new ProcessStartInfo(_downloadDir) { UseShellExecute = true }); } catch { } };
        // 工具面板走独立 Owner 窗口（ToolsPanel.Show/EnsureHost），不再藏 WebView2。
        ToolsFlyout.OnClose = () => { /* HideFlyout 已关窗；终端 HWND 从未隐藏 */ };
        ToolsFlyout.SetDownloadPath(_downloadDir);

        // 侧栏监控仪表盘。
        Monitor.OnCopyIp += () => { var ip = ActiveSession?.SourceHost?.Host; if (!string.IsNullOrEmpty(ip)) Clipboard.SetText(ip); };
        Monitor.OnSysInfo += () => _ = ShowSysInfo();
        // 侧栏状态行按钮：已连接 → 手动断开；已断开 → 原地重连；没有会话 → 打开连接管理器选主机。
        Monitor.OnToggleConnection += () =>
        {
            if (Sessions.SelectedItem is not TabItem item) { ShowConnectionManager(); return; }
            if (ActiveSession is { Connected: true }) { MenuDisconnect(); }
            else { _ = ReconnectInPlaceAsync(item); }
        };

        // SFTP 面板：路径变化同步到坞行的共享路径标签；双击文件→内置编辑器；右键"插入命令框"。
        Sftp.OnPathChange += p => DockPathText.Text = p;
        Sftp.OnOpenFile += OpenEditor;
        Sftp.OnInsertToCommand += InsertToCommandBox;
        // P0：SFTP 与终端完全独立，禁止 OnUserNavigate → 终端 cd 联动
        // Sftp.OnUserNavigate += SyncTerminalCd;
        // 智能打包传输需要远端执行命令能力（tar 打包/解包/清理），复用当前活动会话的 ExecAsync。
        Sftp.ExecRunner = cmd => ActiveSession != null ? ActiveSession.ExecAsync(cmd) : Task.FromResult("");

        // 命令板：目标下拉数据源(全部会话+连接状态) + 发送回调(解析 当前/所有已连接/指定会话)，
        // 对齐 mac cmdPanel.sessionsProvider / cmdPanel.onSendTo（AppDelegate+Layout.swift）。
        Cmds.SessionsProvider = BuildSessionConnStates;
        Cmds.OnSendTo = SendToCommandTarget;

        // 自绘机器人，跟随主题着色（Segoe MDL2 没有这个字形）
        ChatBtn.Content = UI.RobotIcon.Make();
        ApplyLocalHiddenIndicator();
        UpdateWorkCenterVisibility();
        ThemeBtn.Content = ThemeManager.IsDark ? "\uE708" : "\uE706";  // Segoe MDL2: 月/日，单色随主题
        _monitorTimer.Start();
        StartAgentBridge();
        StateChanged += (_, __) => UpdateMaxButtonGlyph();   // Win+↑/双击顶栏也要同步图标

        // 注册独立 ToolsFlyout 窗口的关闭控制，确保 Esc/Outside Click / Alt-Tab 均能正常关闭
        PreviewMouseLeftButtonDown += MainWindow_PreviewMouseLeftButtonDown;
        PreviewKeyDown += MainWindow_PreviewKeyDown;
        Deactivated += MainWindow_Deactivated;
        LocationChanged += (s, ev) => CloseToolsFlyout();
        SizeChanged += (s, ev) => CloseToolsFlyout();
        StateChanged += (s, ev) => CloseToolsFlyout();
    }

    private void MainWindow_SourceInitialized(object? sender, EventArgs e)
    {
        WindowInterop.ApplyBackdrop(this, ThemeManager.IsDark);
    }

    private void UpdateChildWindowsSize()
    {
        // 只跟随移动「显式 opt-in」的大面板；弹出式对话框/工具/连接管理器禁止被 0.85 主窗拉伸（会重叠、比主窗还大）。
        foreach (Window w in Application.Current.Windows)
        {
            if (w == this || w.Owner != this) continue;
            if (Equals(w.Tag, "NoAutoResize")) continue;
            if (w.WindowStyle is WindowStyle.ToolWindow or WindowStyle.None) continue;
            if (w.SizeToContent != SizeToContent.Manual) continue;
            if (w.ResizeMode is ResizeMode.NoResize or ResizeMode.CanResizeWithGrip) continue;
            if (w is UI.ConnectionManagerWindow or HostEditWindow) continue;
            string typeName = w.GetType().Name;
            if (typeName.Contains("Connection") || typeName.Contains("HostEdit") ||
                typeName.Contains("Tools") || typeName.Contains("ToolResult")) continue;
            // 名称/标题启发式：编辑主机、工具、连接管理器、密钥等
            var title = w.Title ?? "";
            if (title.Contains("主机", StringComparison.Ordinal) ||
                title.Contains("连接", StringComparison.Ordinal) ||
                title.Contains("工具", StringComparison.Ordinal) ||
                title.Contains("密钥", StringComparison.Ordinal) ||
                title.Contains("指纹", StringComparison.Ordinal) ||
                title.Contains("代理", StringComparison.Ordinal) ||
                title.Contains("设置", StringComparison.Ordinal))
                continue;
            if (w.MaxWidth is > 0 and < 600) continue;
            if (w.ActualWidth > 0 && w.ActualWidth < 420) continue;

            // 仅对真正的大附属窗（如系统信息）做跟随缩放，且不放大超过 Max*
            var targetWidth = Math.Max(w.MinWidth > 0 ? w.MinWidth : 400, ActualWidth * 0.85);
            var targetHeight = Math.Max(w.MinHeight > 0 ? w.MinHeight : 300, ActualHeight * 0.85);
            if (w.MaxWidth > 0 && !double.IsInfinity(w.MaxWidth)) targetWidth = Math.Min(targetWidth, w.MaxWidth);
            if (w.MaxHeight > 0 && !double.IsInfinity(w.MaxHeight)) targetHeight = Math.Min(targetHeight, w.MaxHeight);
            if (Math.Abs(w.Width - targetWidth) > 1) w.Width = targetWidth;
            if (Math.Abs(w.Height - targetHeight) > 1) w.Height = targetHeight;
            w.Left = this.Left + (this.ActualWidth - w.Width) / 2;
            w.Top = this.Top + (this.ActualHeight - w.Height) / 2;
        }
    }

    protected override void OnRenderSizeChanged(SizeChangedInfo sizeInfo)
    {
        base.OnRenderSizeChanged(sizeInfo);
        UpdateChildWindowsSize();
    }

    protected override void OnLocationChanged(EventArgs e)
    {
        base.OnLocationChanged(e);
        UpdateChildWindowsSize();
    }

    private ConnectionManagerWindow? _connMgrWin;
    private UI.SysInfoWindow? _sysInfoWin;
    private void ShowConnectionManager()
    {
        if (_connMgrWin != null && _connMgrWin.IsLoaded)
        {
            _connMgrWin.Focus();
            return;
        }

        _connMgrWin = new ConnectionManagerWindow
        {
            Owner = this,
            HostsProvider = () => _hosts.ToList(),
            OnConnect = h => { _connMgrWin?.Close(); ConnectToHost(h); },
            OnNew = () => { _connMgrWin?.Close(); NewHostFlow(); },
            OnEdit = h => { _connMgrWin?.Close(); EditHostFlow(h); },
            OnDelete = DeleteHostFlow,
            OnCreateGroup = name =>
            {
                Log.Info($"新建分组 {name}", "hosts");
                foreach (var h in _hosts.Where(h => string.IsNullOrWhiteSpace(h.Group) || h.Group == "默认")) h.Group = name;
                PersistHosts();
                RefreshHostViews();
            },
            OnRenameGroup = (oldName, newName) =>
            {
                Log.Info($"分组重命名 {oldName} → {newName}", "hosts");
                foreach (var h in _hosts.Where(h => (string.IsNullOrWhiteSpace(h.Group) ? "默认" : h.Group) == oldName)) h.Group = newName;
                PersistHosts();
                RefreshHostViews();
            },
            OnDeleteGroup = name =>
            {
                Log.Info($"删除分组 {name}（成员移回默认）", "hosts");
                foreach (var h in _hosts.Where(h => (string.IsNullOrWhiteSpace(h.Group) ? "默认" : h.Group) == name)) h.Group = "默认";
                PersistHosts();
                RefreshHostViews();
            }
        };
        UpdateChildWindowsSize();
        _connMgrWin.Show();
    }

    // =====================================================================
    // 本地 CLI/AI-Agent 桥：启动 + 状态栏三态轮询（对齐 mac startAgentBridge/updateCliStatus）。
    // 桥本身实现在 Bridge/AgentBridge.cs；本类通过 MainWindow.Bridge.cs 实现 IBridgeHost。
    // =====================================================================
    private void StartAgentBridge()
    {
        _agentBridge = new Bridge.AgentBridge(this);
        _agentBridge.Start();
        Bridge.AgentCLI.Install(_agentBridge.Port);   // 生成 pixshell.cmd / pixshell.py（CLI + MCP server）
        UpdateCliStatus();
        _bridgeStatusTimer.Start();
    }

    /// <summary>CLI 状态三态（严格对齐老仓库/mac 口径，别把"桥在监听"写成"已连接/已对接"）：
    /// 未开启(红) = 桥没在听；已开启(黄) = 本地桥在听但还没有外部请求；
    /// 已对接(绿) = 5 分钟内有鉴权通过的外部请求。</summary>
    private void UpdateCliStatus()
    {
        if (_agentBridge == null) return;
        var listening = _agentBridge.IsRunning;
        var last = _agentBridge.LastClientAt;
        var paired = listening && last.HasValue && (DateTime.UtcNow - last.Value) < TimeSpan.FromMinutes(5);

        if (paired)
        {
            CliDot.Fill = (Brush)Application.Current.Resources["BrushOk"];
            CliStatusText.Text = "CLI 已对接";
            CliStatusText.ToolTip = $"外部 CLI/Agent 已对接 · 127.0.0.1:{_agentBridge.Port}";
        }
        else if (listening)
        {
            CliDot.Fill = (Brush)Application.Current.Resources["BrushWarn"];
            CliStatusText.Text = "CLI 已开启";
            CliStatusText.ToolTip = $"本地桥监听中，等待外部 CLI/Agent · 127.0.0.1:{_agentBridge.Port}";
        }
        else
        {
            CliDot.Fill = (Brush)Application.Current.Resources["BrushErr"];
            CliStatusText.Text = "CLI 未开启";
            CliStatusText.ToolTip = "本地桥未启动";
        }
    }

    // =====================================================================
    // 主机增删改（连接管理器 / 快速连接 共用）
    // =====================================================================
    private void NewHostFlow()
    {
        var dlg = new HostEditWindow(null) { Owner = this };
        if (dlg.ShowDialog() != true) return;
        _hosts.Add(dlg.Entry);
        if (dlg.Password != null) CredentialStore.SetPassword(dlg.Entry.Id, dlg.Password);
        PersistHosts();
        RefreshHostViews();
    }

    private void EditHostFlow(HostEntry host)
    {
        var dlg = new HostEditWindow(host) { Owner = this };
        if (dlg.ShowDialog() != true) return;
        host.Name = dlg.Entry.Name; host.Host = dlg.Entry.Host; host.Port = dlg.Entry.Port;
        host.Username = dlg.Entry.Username; host.Group = dlg.Entry.Group; host.OsId = dlg.Entry.OsId;
        host.KeyPath = dlg.Entry.KeyPath; host.ProxyId = dlg.Entry.ProxyId;
        if (dlg.Password != null) CredentialStore.SetPassword(host.Id, dlg.Password);
        PersistHosts();
        RefreshHostViews();
    }

    private void DeleteHostFlow(HostEntry host)
    {
        if (MessageBox.Show(this, $"删除主机「{host}」？", "PixShell", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK)
            return;
        CredentialStore.Remove(host.Id);
        _hosts.Remove(host);
        PersistHosts();
        RefreshHostViews();
    }

    private void PersistHosts()
    {
        try { HostStore.Save(_hosts.ToList()); }
        catch (Exception ex) { SetStatus("保存失败: " + ex.Message); }
    }

    private void RefreshHostViews()
    {
        _connMgrWin?.Reload();
        QuickConnectPanel.Reload();
    }

    // 密码解析：DPAPI 已存 → 直接用；有可用私钥可无密码直连；否则弹框输入(可选记住)。
    // 对齐 ReconnectInPlaceAsync / BridgeConnect：key-only 不强制 PromptPassword。
    private void ConnectToHost(HostEntry host)
    {
        // 本机终端：应用内 Local shell，不经 SSH/密码、不弹外部终端。
        if (host.IsLocal) { _ = OpenLocalTerminalSession(host); return; }
        // RDP 类型不走 SSH：直接拉起系统远程桌面 mstsc（对齐老仓库 app.js connectionType===200 分支）。
        if (host.IsRdp) { LaunchRdp(host); return; }
        var pass = CredentialStore.GetPassword(host.Id);
        if (pass == null)
        {
            if (HasUsablePrivateKey(host))
            {
                // 私钥文件在：允许空密码走公钥认证，不再无条件弹框。
                pass = "";
            }
            else
            {
                var (entered, remember) = PromptPassword(host);
                if (entered == null) return;
                pass = entered;
                if (remember) CredentialStore.SetPassword(host.Id, pass);
            }
        }
        RecentsStore.NoteRecent(host.Id);
        QuickConnectPanel.Reload();
        _ = OpenSessionTab(host, pass);
    }

    /// <summary>主机配置了 KeyPath 且文件真实存在（展开 ~ / 环境变量后）。</summary>
    private static bool HasUsablePrivateKey(HostEntry host)
    {
        if (string.IsNullOrWhiteSpace(host.KeyPath)) return false;
        try { return File.Exists(TerminalSession.ExpandKeyPath(host.KeyPath)); }
        catch { return false; }
    }

    /// <summary>RDP 主机：拉起 Windows 系统远程桌面 mstsc。端口默认 3389（主机端口是 SSH 默认 22 时兜底）。
    /// 对齐老仓库 win32 分支 `mstsc /v:host:port`。</summary>
    private void LaunchRdp(HostEntry host)
    {
        RecentsStore.NoteRecent(host.Id);
        QuickConnectPanel.Reload();
        int port = (host.Port == 22 || host.Port == 0) ? 3389 : host.Port;
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = "mstsc",
                Arguments = $"/v:{host.Host}:{port}",
                UseShellExecute = true,
            });
            Log.Info($"拉起 RDP {host.Host}:{port}");
            SetStatus($"已启动 RDP：{host.Host}:{port}");
        }
        catch (Exception ex)
        {
            SetStatus("RDP 失败：" + ex.Message);
            MessageBox.Show(this, "启动远程桌面失败：" + ex.Message, "PixShell",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private (string? password, bool remember) PromptPassword(HostEntry host)
    {
        var win = new Window
        {

            Background = (System.Windows.Media.Brush)System.Windows.Application.Current.Resources["BrushBg"],
            Foreground = (System.Windows.Media.Brush)System.Windows.Application.Current.Resources["BrushText"],
            Title = "连接 " + host.Display, Width = 340, SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, Owner = this,
            ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false
        };
        var sp = new StackPanel { Margin = new Thickness(14) };
        sp.Children.Add(new TextBlock { Text = $"{host.Subtitle} 需要密码：", Margin = new Thickness(0, 0, 0, 8) });
        var pb = new PasswordBox();
        sp.Children.Add(pb);
        var remember = new CheckBox { Content = "记住密码", Margin = new Thickness(0, 8, 0, 0) };
        sp.Children.Add(remember);
        var btnRow = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        var ok = new Button { Content = "连接", Width = 72, Margin = new Thickness(0, 0, 8, 0), IsDefault = true };
        var cancel = new Button { Content = "取消", Width = 72, IsCancel = true };
        bool okClicked = false;
        ok.Click += (_, _) => { okClicked = true; win.DialogResult = true; };
        btnRow.Children.Add(ok); btnRow.Children.Add(cancel);
        sp.Children.Add(btnRow);
        win.Content = sp;
        pb.Focus();
        var result = win.ShowDialog();
        return (result == true && okClicked) ? (pb.Password, remember.IsChecked == true) : (null, false);
    }

    // =====================================================================
    // 会话 tab（新开/关闭/切换）
    // =====================================================================
    /// <summary>快速连接 logo：软件内新开本机终端标签（cmd/powershell 重定向到 xterm）。
    /// 右键菜单与 SSH 会话相同（InitAsync 已挂 WebView2 复制/粘贴/清屏/背景）。</summary>
    private async Task OpenLocalTerminalSession(HostEntry? host = null)
    {
        var h = host ?? HostEntry.LocalTerminal();
        Log.Info("打开本机终端", "session");
        var session = new TerminalSession(h.Display, _htmlPath) { SourceHost = h };
        session.StatusChanged += (s, msg) => { if (IsActiveSession(s)) SetStatus(msg); };
        session.ConnectedChanged += (s, on) =>
        {
            if (on) return;
            if (!IsActiveSession(s)) return;
            Dispatcher.BeginInvoke(new Action(() =>
            {
                ClearSessionSidePanels();
                RefreshConnState();
            }));
        };

        var item = new TabItem { Tag = session, Content = session.View };
        BuildTabHeader(item, session);
        Sessions.Items.Add(item);
        Sessions.SelectedItem = item;
        _showingQuickConnect = false;
        UpdateWorkCenterVisibility();
        ConnectAnim.Begin("本机终端");

        try
        {
            await session.InitAsync();
        }
        catch (Exception ex)
        {
            Log.Error($"本机终端初始化失败: {ex.Message}", "session");
            ConnectAnim.Fail("终端初始化失败");
            SetStatus("终端初始化失败: " + ex.Message);
            MessageBox.Show(this,
                "终端无法启动：\n" + ex.Message,
                "PixShell", MessageBoxButton.OK, MessageBoxImage.Warning);
            CloseTab(item);
            return;
        }

        try
        {
            session.ApplyTermScheme(Terminal.TermSchemeStore.Current);
            await session.ConnectLocalAsync();
            // 本机无远端 SFTP；仍同步 dock 以便本地文件侧可用
            SyncDockSession();
            Monitor.SetConnected(true, "local");
            ConnectAnim.Succeed();
            RefreshConnState();
        }
        catch (Exception ex)
        {
            Log.Error($"本机 shell 启动失败: {ex.Message}", "session");
            ConnectAnim.Fail("启动失败");
            SetStatus("本机终端启动失败: " + ex.Message);
        }
    }

    private async Task OpenSessionTab(HostEntry host, string pass)
    {
        if (host.IsLocal) { await OpenLocalTerminalSession(host); return; }
        Log.Info($"打开会话 {host.Username}@{host.Host}:{host.Port}", "session");
        var session = new TerminalSession(host.Display, _htmlPath) { SourceHost = host };
        session.StatusChanged += (s, msg) => { if (IsActiveSession(s)) SetStatus(msg); };
        // P1：活动会话掉线 → 清 SFTP + 关系统信息（与关标签/手动断开同路径）
        session.ConnectedChanged += (s, on) =>
        {
            if (on) return;
            if (!IsActiveSession(s)) return;
            Dispatcher.BeginInvoke(new Action(() =>
            {
                ClearSessionSidePanels();
                RefreshConnState();
            }));
        };

        var item = new TabItem { Tag = session, Content = session.View };
        BuildTabHeader(item, session);

        Sessions.Items.Add(item);
        Sessions.SelectedItem = item;
        UpdateWorkCenterVisibility();

        ConnectAnim.Begin($"{host.Username}@{host.Host}:{host.Port}");   // 连接动画（终端里不写"连接中"）

        // ---- 终端初始化与 SSH 分 catch：Init 失败绝不当成认证失败、不删密码、不成功动画 ----
        try
        {
            await session.InitAsync();
        }
        catch (Exception ex)
        {
            Log.Error($"终端初始化失败 {host.Username}@{host.Host}: {ex.Message}", "session");
            ConnectAnim.Fail("终端初始化失败");
            SetStatus("终端初始化失败: " + ex.Message);
            MessageBox.Show(this,
                "终端无法启动：\n" + ex.Message + "\n\n不会尝试 SSH 连接，已保存的密码也未改动。",
                "PixShell", MessageBoxButton.OK, MessageBoxImage.Warning);
            CloseTab(item);
            return;
        }

        try
        {
            session.ApplyTermScheme(Terminal.TermSchemeStore.Current);
            var proxy = ProxyStore.Find(host.ProxyId);
            await session.ConnectAsync(host.Host, host.Port, host.Username, pass, host.KeyPath, proxy);
            SyncDockSession();
            Monitor.SetConnected(true, host.Host);
            ConnectAnim.Succeed();
            _ = DetectRemoteOsAsync(session, host);   // 首次连上 → 认出发行版，主机图标换成对应系统标志
        }
        catch (Exception ex)
        {
            Log.Error($"会话打开失败 {host.Username}@{host.Host}: {ex.Message}", "session");
            var authFail = IsAuthFailure(ex);
            // 仅认证失败才清 DPAPI 密码；断网/超时/算法协商等保留凭据，避免误伤。
            if (authFail) CredentialStore.Remove(host.Id);
            ConnectAnim.Fail(authFail ? "认证失败" : "连接失败");
            SetStatus((authFail ? "认证失败: " : "连接失败: ") + ex.Message);
            // 认证失败且非私钥路径：当场重弹密码框（对齐 mac promptRetryPassword）。
            // 私钥登录失败不弹密码框——那是 key 的问题。
            if (authFail && string.IsNullOrEmpty(host.KeyPath)) PromptRetryPassword(host, item);
        }
    }

    /// <summary>区分 SSH 认证失败 vs 网络/超时/其它。只有前者才应清掉已存密码。</summary>
    private static bool IsAuthFailure(Exception ex)
    {
        for (Exception? e = ex; e != null; e = e.InnerException)
        {
            if (e is SshAuthenticationException) return true;
            var name = e.GetType().FullName ?? e.GetType().Name;
            if (name.Contains("SshAuthentication", StringComparison.OrdinalIgnoreCase)) return true;
            var msg = e.Message ?? "";
            if (msg.Contains("Permission denied", StringComparison.OrdinalIgnoreCase)) return true;
            if (msg.Contains("Authentication failed", StringComparison.OrdinalIgnoreCase)) return true;
            if (msg.Contains("authentication failed", StringComparison.OrdinalIgnoreCase)) return true;
            if (msg.Contains("认证失败", StringComparison.Ordinal) || msg.Contains("认证被拒", StringComparison.Ordinal)) return true;
        }
        return false;
    }

    /// <summary>
    /// 首次连接成功后识别远端系统，写回 host.OsId —— 主机卡片图标随之变成该系统的标志
    /// （对齐 mac detectRemoteOS：连过一次就认得这台机器是什么系统，不用用户手填）。
    /// 已经有 OsId 的主机不覆盖：用户可能在表单里手动指定过。
    /// </summary>
    private async Task DetectRemoteOsAsync(TerminalSession session, HostEntry host)
    {
        if (host.IsLocal) return;
        if (!string.IsNullOrWhiteSpace(host.OsId)) return;
        try
        {
            // /etc/os-release 的 ID 最准（ubuntu/debian/centos/alpine/openwrt…），退回 uname。
            var raw = await session.ExecAsync(". /etc/os-release 2>/dev/null && printf '%s' \"$ID\" || uname -s 2>/dev/null");
            var id = (raw ?? "").Trim().Split('\n').LastOrDefault()?.Trim().ToLowerInvariant() ?? "";
            if (id.Length == 0 || id.Length > 32 || id.Contains(' ')) return;

            var entry = _hosts.FirstOrDefault(h => h.Id == host.Id);
            if (entry == null || !string.IsNullOrWhiteSpace(entry.OsId)) return;
            entry.OsId = id;
            host.OsId = id;
            PersistHosts();
            Log.Info($"识别远端系统 {host.Username}@{host.Host} → {id}", "session");
            RefreshHostViews();
        }
        catch (Exception ex) { Log.Warn($"识别远端系统失败 {host.Host}: {ex.Message}", "session"); }
    }

    private bool _retryPrompting;   // 防止连续失败叠出多个密码框

    /// <summary>认证失败后重新要密码并在**当前标签**上重连（勾选记住则写回 DPAPI 凭据库）。</summary>
    private void PromptRetryPassword(HostEntry host, TabItem item)
    {
        if (_retryPrompting) return;
        _retryPrompting = true;
        // 延后一拍：此刻还在 ConnectAsync 的异常处理里，直接弹模态框会和正在收尾的会话打架。
        Dispatcher.BeginInvoke(new Action(async () =>
        {
            try
            {
                var (entered, remember) = PromptPassword(host);
                if (string.IsNullOrEmpty(entered)) return;
                if (remember) CredentialStore.SetPassword(host.Id, entered);
                if (item.Tag is TerminalSession s)
                {
                    s.Disconnect();
                    var proxy = ProxyStore.Find(host.ProxyId);
                    await s.ConnectAsync(host.Host, host.Port, host.Username, entered, host.KeyPath, proxy);
                    _showingQuickConnect = false;
                    SetSessionViewsVisible(true);
                    SyncDockSession();
                    Monitor.SetConnected(true, host.Host);
                    RefreshConnState();
                }
            }
            catch (Exception ex2)
            {
                Log.Error($"重试连接仍失败 {host.Username}@{host.Host}: {ex2.Message}", "session");
                SetStatus("连接失败: " + ex2.Message);
            }
            finally { _retryPrompting = false; }
        }), System.Windows.Threading.DispatcherPriority.Background);
    }

    private void BuildTabHeader(TabItem item, TerminalSession session)
    {
        // 标签只显示用户设的名字（TabTitle）；远端 OSC 标题（root@host:~）只进 ToolTip。
        // 对齐 mac TermSession.tabTitle —— 禁止再订阅 TitleChanged 把系统提示符盖到标签上。
        var titleBlock = new TextBlock
        {
            Text = session.TabTitle, VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = 150, TextTrimming = TextTrimming.CharacterEllipsis,
            ToolTip = session.Title,
        };
        var closeBtn = new Button
        {
            Content = "×", Width = 24, Height = 24, Padding = new Thickness(0), FontSize = 14,
            Margin = new Thickness(6, 0, 0, 0), Focusable = false, ToolTip = "关闭标签",
            Style = (Style)Application.Current.Resources["IconButton"]
        };
        closeBtn.Click += (_, _) => CloseTab(item);

        var header = new StackPanel { Orientation = Orientation.Horizontal };
        header.Children.Add(titleBlock); header.Children.Add(closeBtn);
        item.Header = header;
        item.ContextMenu = BuildTabContextMenu(item);

        // OSC 标题变化 → 只刷新 tooltip，标签文字保持用户命名
        session.TitleChanged += s => titleBlock.Dispatcher.BeginInvoke(new Action(() =>
        {
            titleBlock.Text = s.TabTitle;
            titleBlock.ToolTip = s.Title;
        }));

        // 点击 tab（哪怕是已选中的同一个）都要把强制显示的快速连接落地页收起——
        // WPF 的 SelectionChanged 只在选中项真正变化时触发，重选同一 tab 不会触发，
        // 而 mac 版每个 tab 按钮点击都直接调用 selectSession，行为不同，这里补上。
        item.PreviewMouseLeftButtonDown += (_, _) =>
        {
            _showingQuickConnect = false;
            SetSessionViewsVisible(true);
            QuickConnectPanel.Visibility = Collapsed;
            QuickConnectPanel.SetShowsBack(false);
            UpdateWorkCenterVisibility();
        };
    }

    /// <summary>标签右键菜单：切换到此标签 / 重新连接 / 再开一个同主机会话 / 关闭 / 关闭其他
    /// （对齐 mac App/AppDelegate+Sessions.swift 的 tabMenu(for:)）。</summary>
    private ContextMenu BuildTabContextMenu(TabItem item)
    {
        var menu = new ContextMenu();
        menu.Items.Add(Item("切换到此标签", () => Sessions.SelectedItem = item));
        menu.Items.Add(Item("重新连接", () => TabMenuReconnect(item)));
        menu.Items.Add(Item("再开一个同主机会话", () => TabMenuDuplicate(item)));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("关闭", () => CloseTab(item)));
        menu.Items.Add(Item("关闭其他", () => TabMenuCloseOthers(item)));
        return menu;
    }

    private void TabMenuReconnect(TabItem item) => _ = ReconnectInPlaceAsync(item);

    /// <summary>
    /// 原地重连：**复用同一个标签和同一个终端视图**，不新开 tab。
    /// 旧实现是 CloseTab + OpenSessionTab —— 每次「断开→重连」都会多出一个标签页，
    /// 而且历史输出跟着旧标签一起没了。TerminalSession.ConnectAsync 本身就会先 Disconnect，
    /// 所以直接在原会话上重连即可（与 mac reconnectCurrent 同一套语义）。
    /// </summary>
    private async Task ReconnectInPlaceAsync(TabItem item)
    {
        if (item.Tag is not TerminalSession session || session.SourceHost is not { } host) return;
        Sessions.SelectedItem = item;

        // 本机终端：原地重启本地 shell，不弹密码。
        if (host.IsLocal)
        {
            try
            {
                session.Disconnect();
                ConnectAnim.Begin("本机终端");
                await session.ConnectLocalAsync();
                _showingQuickConnect = false;
                SetSessionViewsVisible(true);
                SyncDockSession();
                Monitor.SetConnected(true, "local");
                ConnectAnim.Succeed();
                RefreshConnState();
            }
            catch (Exception ex)
            {
                Log.Error($"本机终端重连失败: {ex.Message}", "session");
                ConnectAnim.Fail("重连失败");
                SetStatus("重连失败: " + ex.Message);
                RefreshConnState();
            }
            return;
        }

        var pass = session.Password ?? CredentialStore.GetPassword(host.Id);
        // 没有可用密码且没有可用私钥 → 要一次密码（框里带"记住密码"）。
        if (string.IsNullOrEmpty(pass) && !HasUsablePrivateKey(host))
        {
            var (entered, remember) = PromptPassword(host);
            if (entered == null) return;
            pass = entered;
            if (remember) CredentialStore.SetPassword(host.Id, pass);
        }

        try
        {
            session.Disconnect();
            ConnectAnim.Begin($"{host.Username}@{host.Host}:{host.Port}");
            var proxy = ProxyStore.Find(host.ProxyId);
            await session.ConnectAsync(host.Host, host.Port, host.Username, pass ?? "", host.KeyPath, proxy);
            _showingQuickConnect = false;
            SetSessionViewsVisible(true);
            SyncDockSession();
            Monitor.SetConnected(true, host.Host);
            ConnectAnim.Succeed();
            RefreshConnState();
        }
        catch (Exception ex)
        {
            Log.Error($"重连失败 {host.Username}@{host.Host}: {ex.Message}", "session");
            ConnectAnim.Fail("重连失败");
            SetStatus("重连失败: " + ex.Message);
            RefreshConnState();
        }
    }

    /// <summary>同主机多开（对齐 mac tabMenuDuplicate / 老仓库 forceNew）。</summary>
    private void TabMenuDuplicate(TabItem item)
    {
        if (item.Tag is not TerminalSession session || session.SourceHost is not { } host) return;
        var pass = session.Password;
        if (!string.IsNullOrEmpty(pass)) _ = OpenSessionTab(host, pass); else ConnectToHost(host);
    }

    private void TabMenuCloseOthers(TabItem keep)
    {
        var others = Sessions.Items.Cast<object>().Where(o => !ReferenceEquals(o, keep)).Cast<TabItem>().ToList();
        foreach (var item in others) CloseTab(item);
    }

    private void CloseTab(TabItem item)
    {
        var wasActive = ReferenceEquals(Sessions.SelectedItem, item);
        if (item.Tag is TerminalSession session) { try { session.Dispose(); } catch { } }
        Sessions.Items.Remove(item);
        // P1：关标签就清侧栏；空会话或关掉的是当前活动标签都要
        if (Sessions.Items.Count == 0 || wasActive) ClearSessionSidePanels();
        UpdateWorkCenterVisibility();
        SyncDockSession();
    }

    /// <summary>刷新「连接状态」相关 UI：状态栏文案 + 侧栏红绿灯/断开·连接按钮。
    /// 连接、断开、重连、重试后都要调，否则侧栏那颗灯和按钮会停在旧状态。</summary>
    private void RefreshConnState()
    {
        var on = ActiveSession is { Connected: true };
        SetStatus(on ? "已连接" : "未连接");
        Monitor.SetConnected(on, ActiveSession?.SourceHost?.Host ?? "");
    }

    private void OnTabSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!ReferenceEquals(e.Source, Sessions)) return;
        if (IsLoaded && e.RemovedItems.Count > 0) PlayRippleTransition();
        _showingQuickConnect = false;
        SetSessionViewsVisible(true);
        RefreshConnState();
        SyncDockSession();
        UpdateWorkCenterVisibility();
        _ = PollMonitor();
    }

    private void PlayRippleTransition()
    {
        try
        {
            var rtb = new System.Windows.Media.Imaging.RenderTargetBitmap((int)MainArea.ActualWidth, (int)MainArea.ActualHeight, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
            rtb.Render(MainArea);
            TransitionImage.Source = rtb;
            TransitionImage.Visibility = Visibility.Visible;
            TransitionImage.Opacity = 1;

            var brush = new System.Windows.Media.RadialGradientBrush { Center = new System.Windows.Point(0.5, 0.5), GradientOrigin = new System.Windows.Point(0.5, 0.5) };
            var stop1 = new System.Windows.Media.GradientStop(System.Windows.Media.Colors.Transparent, 0);
            var stop2 = new System.Windows.Media.GradientStop(System.Windows.Media.Colors.Black, 0.05);
            brush.GradientStops.Add(stop1);
            brush.GradientStops.Add(stop2);
            TransitionImage.OpacityMask = brush;

            var duration = ThemeManager.Current.ToString() == "Ink" ? 0.85 : 0.6;
            var ease = new System.Windows.Media.Animation.CubicEase { EasingMode = System.Windows.Media.Animation.EasingMode.EaseOut };
            
            var anim1 = new System.Windows.Media.Animation.DoubleAnimation(0, 1.5, TimeSpan.FromSeconds(duration)) { EasingFunction = ease };
            var anim2 = new System.Windows.Media.Animation.DoubleAnimation(0.05, 1.55, TimeSpan.FromSeconds(duration)) { EasingFunction = ease };
            anim2.Completed += (_, _) => { TransitionImage.Visibility = Visibility.Collapsed; TransitionImage.Source = null; TransitionImage.OpacityMask = null; };

            stop1.BeginAnimation(System.Windows.Media.GradientStop.OffsetProperty, anim1);
            stop2.BeginAnimation(System.Windows.Media.GradientStop.OffsetProperty, anim2);
            
            var fade = new System.Windows.Media.Animation.DoubleAnimation(1, 0, TimeSpan.FromSeconds(duration)) { EasingFunction = ease };
            TransitionImage.BeginAnimation(UIElement.OpacityProperty, fade);
        }
        catch { }
    }

    private void SyncDockSession()
    {
        Sftp.SetSession(ActiveSession);
        // 命令板不持有会话引用：目标解析走 SessionsProvider/OnSendTo，这里只需要在会话集合变化时
        // 刷新一次目标下拉（新开的已连接会话要能立刻在下拉里选到）。
        Cmds.ReloadTargets();
        if (!_filesTabActive) return;
        Sftp.ConnectIfNeeded();
    }

    private TerminalSession? ActiveSession => (Sessions.SelectedItem as TabItem)?.Tag as TerminalSession;
    private bool IsActiveSession(TerminalSession s) => ReferenceEquals(ActiveSession, s);

    private List<(string title, bool active)> BuildSessionTitles()
    {
        var list = new List<(string, bool)>();
        for (int i = 0; i < Sessions.Items.Count; i++)
            if (Sessions.Items[i] is TabItem { Tag: TerminalSession s })
                list.Add((s.TabTitle, ReferenceEquals(s, ActiveSession)));
        return list;
    }

    /// <summary>命令板目标下拉数据源：全部会话标题 + 是否已连接。</summary>
    private List<(string title, bool connected)> BuildSessionConnStates()
    {
        var list = new List<(string, bool)>();
        foreach (var obj in Sessions.Items)
            if (obj is TabItem { Tag: TerminalSession s })
                list.Add((s.TabTitle, s.Connected));
        return list;
    }

    /// <summary>命令板发送：解析 当前会话/所有已连接会话/指定会话下标 三种目标（对齐 mac cmdPanel.onSendTo）。</summary>
    private void SendToCommandTarget(string text, Store.SendTarget target)
    {
        var bytes = text; // TerminalSession.SendText 内部按 UTF-8 编码发送
        switch (target.Kind)
        {
            case Store.SendTargetKind.Current:
                if (ActiveSession is { Connected: true } cur) cur.SendText(bytes);
                break;
            case Store.SendTargetKind.AllConnected:
                foreach (var obj in Sessions.Items)
                    if (obj is TabItem { Tag: TerminalSession s } && s.Connected) s.SendText(bytes);
                break;
            case Store.SendTargetKind.Session:
                if (target.SessionIndex >= 0 && target.SessionIndex < Sessions.Items.Count &&
                    Sessions.Items[target.SessionIndex] is TabItem { Tag: TerminalSession si } && si.Connected)
                    si.SendText(bytes);
                break;
        }
    }

    // 终端可见性：SessionContent + 各 WebView2 必须一起收/放。
    // WebView2 是 HWND 空气空间，仅叠 QC 仍会穿透，点不着落地页。
    private void SetSessionViewsVisible(bool vis)
    {
        var v = vis ? Visibility.Visible : Visibility.Collapsed;
        SessionContent.Visibility = v;
        foreach (var obj in Sessions.Items)
            if (obj is TabItem { Tag: TerminalSession s })
                s.View.Visibility = v;
    }

    // 背景一律走主题令牌：空态 BrushBg，有会话 BrushTerm。禁止 Transparent/White 硬编码，
    // 否则深色下白屏、浅色下透黑边。
    private void UpdateWorkCenterVisibility()
    {
        bool empty = Sessions.Items.Count == 0;
        if (_showingQuickConnect || empty)
        {
            QuickConnectPanel.Visibility = Visibility.Visible;
            WorkCenter.SetResourceReference(BackgroundProperty, "BrushBg");
            QuickConnectPanel.SetResourceReference(BackgroundProperty, "BrushBg");
            if (empty)
            {
                _showingQuickConnect = false;
                QuickConnectPanel.Reload();
            }
            // QC 模式有会话时：必须藏 SessionContent/WebView2，否则空气空间挡点击
            SetSessionViewsVisible(false);
        }
        else
        {
            QuickConnectPanel.Visibility = Visibility.Collapsed;
            WorkCenter.SetResourceReference(BackgroundProperty, "BrushTerm");
            SetSessionViewsVisible(true);
        }
    }

    // =====================================================================
    // 顶栏动作
    // =====================================================================
    private void CollapseSidebar_Click(object sender, RoutedEventArgs e) => SetSidebarCollapsed(!_sideCollapsed);
    private void SidebarRail_Click(object sender, MouseButtonEventArgs e) => SetSidebarCollapsed(false);

    private void SetSidebarCollapsed(bool collapsed)
    {
        Log.Info(collapsed ? "折叠侧栏" : "展开侧栏", "ui");
        _sideCollapsed = collapsed;
        SidebarColumn.Width = new GridLength(collapsed ? 26 : _sidebarWidth);
        Monitor.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
        SidebarRail.Visibility = collapsed ? Visibility.Visible : Visibility.Collapsed;
    }

    private void SideSplitter_DragCompleted(object sender, System.Windows.Controls.Primitives.DragCompletedEventArgs e)
    {
        if (!_sideCollapsed)
        {
            _sidebarWidth = SidebarColumn.Width.Value;
            var prefs = UiStore.Load();
            prefs.SidebarWidth = _sidebarWidth;
            UiStore.Save(prefs);
        }
    }

    private void OpenConnMgr_Click(object sender, RoutedEventArgs e) => ShowConnectionManager();
    private void NewHost_Click(object sender, RoutedEventArgs e) => NewHostFlow();

    // ＋快速连接：始终显示落地页（覆盖当前终端），并收起侧栏+坞，对齐 mac showQuickConnect/collapseChrome。
    private void QuickConnect_Click(object sender, RoutedEventArgs e)
    {
        _showingQuickConnect = true;
        QuickConnectPanel.Visibility = Visible;
        QuickConnectPanel.SetResourceReference(BackgroundProperty, "BrushBg");
        WorkCenter.SetResourceReference(BackgroundProperty, "BrushBg");
        // 有会话才出返回箭头
        QuickConnectPanel.SetShowsBack(Sessions.Items.Count > 0);
        QuickConnectPanel.Reload();
        SetSidebarCollapsed(true);
        SetDockCollapsed(true);
        SetSessionViewsVisible(false);
    }

    private void ToggleTheme_Click(object sender, RoutedEventArgs e)
    {
        Log.Info("切换主题 → " + (ThemeManager.IsDark ? "浅色" : "深色"), "ui");
        ThemeManager.Toggle();
        AfterThemeChanged();
    }

    /// <summary>主题切换后的统一收尾：DWM 边框深浅、按钮图标、落地页/卡片重绘。
    /// 设置对话框与顶栏按钮共用，避免一边换色一边边框/滚动条残留旧主题。</summary>
    private void AfterThemeChanged()
    {
        WindowInterop.ApplyBackdrop(this, ThemeManager.IsDark);
        ThemeBtn.Content = ThemeManager.IsDark ? "\uE708" : "\uE706";  // Segoe MDL2: 月/日
        // 动态内容（卡片/表格行）里有代码赋值的 brush，需要主动重建。
        RefreshHostViews();
        // 工作区背景跟令牌走，防止切主题后 QC 残留本地 brush。
        if (QuickConnectPanel.Visibility == Visibility.Visible)
        {
            WorkCenter.SetResourceReference(BackgroundProperty, "BrushBg");
            QuickConnectPanel.SetResourceReference(BackgroundProperty, "BrushBg");
        }
        else if (Sessions.Items.Count > 0)
        {
            WorkCenter.SetResourceReference(BackgroundProperty, "BrushTerm");
        }
        // 已开会话：再 fit + 右键菜单配色跟主题
        foreach (var obj in Sessions.Items)
        {
            if (obj is TabItem { Tag: TerminalSession s })
            {
                try
                {
                    if (s.View.CoreWebView2 != null)
                    {
                        s.View.CoreWebView2.Profile.PreferredColorScheme = ThemeManager.IsDark
                            ? Microsoft.Web.WebView2.Core.CoreWebView2PreferredColorScheme.Dark
                            : Microsoft.Web.WebView2.Core.CoreWebView2PreferredColorScheme.Light;
                    }
                }
                catch { /* 旧 runtime */ }
                try { _ = s.View.CoreWebView2?.ExecuteScriptAsync("try{window.pixFit&&window.pixFit()}catch(e){}"); }
                catch { }
            }
        }
    }

    /// <summary>顶栏宫格：点一下呼出、再点收起。
    /// 工具面板在**独立 Owner 窗口**里画（同 ToolResultWindow），绝不藏 WebView2。</summary>
    private void OpenTools_Click(object sender, RoutedEventArgs e)
    {
        if (ToolsFlyout.IsOpen)
        {
            ToolsFlyout.HideFlyout();
            return;
        }
        Log.Info("打开工具浮窗（独立窗口，不藏终端）", "ui");
        ToolsFlyout.SetDownloadPath(_downloadDir);
        ToolsFlyout.Show();
    }

    private void CloseToolsFlyout()
    {
        if (ToolsFlyout.IsOpen)
            ToolsFlyout.HideFlyout();
    }

    private void MainWindow_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (!ToolsFlyout.IsOpen) return;
        // 点主窗非工具按钮区域时收起；工具是独立 Owner 窗，点它不会走到这里。
        CloseToolsFlyout();
        var hit = VisualTreeHelper.HitTest(this, e.GetPosition(this));
        if (hit?.VisualHit == null) return;
        for (DependencyObject? obj = hit.VisualHit; obj != null; obj = VisualTreeHelper.GetParent(obj))
        {
            if (obj == ToolsBtn)
            {
                e.Handled = true; // 避免同一次点击又被 OpenTools 打开
                break;
            }
        }
    }

    private void MainWindow_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape && ToolsFlyout.IsOpen)
        {
            CloseToolsFlyout();
            e.Handled = true;
        }
    }

    private void MainWindow_Deactivated(object? sender, EventArgs e)
    {
        // 不在失焦时自动关工具窗：文件夹选择器/结果窗/子对话框会抢焦点导致闪关。
        // 关闭靠 ✕ / Esc / 再点工具按钮 / 点主窗空白。
    }

    private void PickDownloadDir()
    {
        var dlg = new OpenFolderDialog { InitialDirectory = _downloadDir };
        if (dlg.ShowDialog(this) == true)
        {
            _downloadDir = dlg.FolderName;
            ToolsFlyout.SetDownloadPath(_downloadDir);
        }
    }

    private void OpenProxyWindow()
    {
        var win = new UI.ProxyWindow { Owner = this };
        win.ShowDialog();
    }

    // =====================================================================
    // 侧栏折叠 / 坞折叠 / 文件·命令 切换
    // =====================================================================
    private bool _filesTabActive = true;

    private void ToggleDock_Click(object sender, RoutedEventArgs e) => SetDockCollapsed(!_dockCollapsed);

    private void SetDockCollapsed(bool collapsed)
    {
        Log.Info(collapsed ? "折叠底栏" : "展开底栏", "ui");
        _dockCollapsed = collapsed;
        DockRow.Height = collapsed ? new GridLength(0) : new GridLength(_dockHeight);
        DockSplitterRow.Height = collapsed ? new GridLength(0) : new GridLength(4);
        DockBorder.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
        DockSplitter.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
        DockToggleBtn.Content = collapsed ? "▴" : "▾";
        DockToggleBtn.ToolTip = collapsed ? "显示文件/命令" : "隐藏文件/命令";
    }

    /// <summary>拖完坞分隔条后，把实际高度写回 _dockHeight 并持久化（对齐 mac dragDockHeight）。</summary>
    private void DockSplitter_DragCompleted(object sender, System.Windows.Controls.Primitives.DragCompletedEventArgs e)
    {
        if (_dockCollapsed) return;
        var h = DockRow.ActualHeight;
        if (h < 160) h = 160;
        var max = Math.Max(240, ActualHeight - 220);
        if (h > max) h = max;
        _dockHeight = h;
        DockRow.Height = new GridLength(_dockHeight);
        try
        {
            var prefs = UiStore.Load();
            prefs.BottomHeight = _dockHeight;
            UiStore.Save(prefs);
        }
        catch { /* 持久化失败不挡 UI */ }
        Log.Info($"底栏高度 → {(int)_dockHeight}", "ui");
    }

    private void ShowFiles_Click(object sender, RoutedEventArgs e) => SetFilesActive(true);
    private void ShowCmds_Click(object sender, RoutedEventArgs e) => SetFilesActive(false);

    private void SetFilesActive(bool files)
    {
        _filesTabActive = files;
        FilesTabBtn.Tag = files ? "Primary" : null;
        CmdsTabBtn.Tag = files ? null : "Primary";
        Sftp.Visibility = files ? Visibility.Visible : Visibility.Collapsed;
        Cmds.Visibility = files ? Visibility.Collapsed : Visibility.Visible;
        FileOpsPanel.Visibility = files ? Visibility.Visible : Visibility.Collapsed;
        if (files) Sftp.ConnectIfNeeded();
    }

    private void ApplyLocalHiddenIndicator() { /* 本地列默认隐藏，由 SftpPanel 自行管理 */ }

    // =====================================================================
    // 内置文本编辑器（SFTP 双击文件 → 打开；保存 → 写回远端，对齐 mac editorPanel 接线）
    // =====================================================================
    private void OpenEditor(string remotePath, string text)
    {
        Log.Info($"打开编辑器 {remotePath}（{text.Length} 字符）", "editor");
        var win = new UI.EditorWindow { Owner = this };
        win.Open(remotePath, text);
        // 新签名：编辑器要求回报保存结果（null=成功），成功才清脏/才关闭；结果由编辑器自己在头部显示。
        win.OnSave = (t, report) => Sftp.SaveRemoteFile(remotePath, t, err => report(err));
        // 非模态：编辑远端文件时常要把编辑器挪开对照终端（对齐 mac 独立窗口的初衷）。
        win.Show();
    }

    /// <summary>SFTP 右键"插入命令框"：把远端路径追加到命令输入框末尾，光标留在输入框。</summary>
    private void InsertToCommandBox(string text)
    {
        CmdInput.Text = string.IsNullOrEmpty(CmdInput.Text) ? text : CmdInput.Text.TrimEnd() + " " + text;
        CmdInput.Focus();
        CmdInput.CaretIndex = CmdInput.Text.Length;
    }

    // =====================================================================
    // 命令栏：↑↓ 历史 / Tab 远端路径补全 / ${参数} 弹框 / 发送后焦点保持 / cd↔SFTP 同步
    // 对齐 mac Store/CommandBox.swift + App/AppDelegate+CommandBox.swift。
    // =====================================================================
    private readonly Store.CommandHistory _cmdHistory = new();

    private void SendCommand_Click(object sender, RoutedEventArgs e) => SendCurrentCommand();

    private void CmdInput_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Up:
                CmdInput.Text = _cmdHistory.Older(CmdInput.Text);
                CmdInput.CaretIndex = CmdInput.Text.Length;
                e.Handled = true;
                break;
            case Key.Down:
                CmdInput.Text = _cmdHistory.Newer();
                CmdInput.CaretIndex = CmdInput.Text.Length;
                e.Handled = true;
                break;
            case Key.Tab:
                CompleteRemotePath();
                e.Handled = true;
                break;
            case Key.Enter:
                SendCurrentCommand();
                e.Handled = true;
                break;
        }
    }

    private void SendCurrentCommand()
    {
        var text = CmdInput.Text;
        if (string.IsNullOrWhiteSpace(text)) return;
        if (ActiveSession is not { Connected: true })
        {
            SetStatus("无活动会话");
            return;
        }

        // ${参数} → 逐个弹框取值；取消则整条放弃。
        if (Store.CommandParams.HasUnresolved(text))
        {
            var values = new Dictionary<string, string>();
            foreach (var name in Store.CommandParams.Parse(text))
            {
                var v = AskParam(name);
                if (v == null) return;
                values[name] = v;
            }
            text = Store.CommandParams.Render(text, values);
        }

        ActiveSession.SendText(text + "\r");
        _cmdHistory.Push(text);
        ApplyCdSync(text);
        CmdInput.Text = "";
        CmdInput.Focus(); // 发送后焦点留在命令框（底栏 UX，对齐 mac sendCommandBox）
    }

    private string? AskParam(string name)
    {
        var win = new Window
        {

            Background = (System.Windows.Media.Brush)System.Windows.Application.Current.Resources["BrushBg"],
            Foreground = (System.Windows.Media.Brush)System.Windows.Application.Current.Resources["BrushText"],
            Title = "参数 " + name, Width = 320, SizeToContent = SizeToContent.Height, Owner = this,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false
        };
        var sp = new StackPanel { Margin = new Thickness(14) };
        sp.Children.Add(new TextBlock { Text = $"请输入 ${{{name}}} 的值", Margin = new Thickness(0, 0, 0, 8) });
        var tb = new TextBox();
        sp.Children.Add(tb);
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        var ok = new Button { Content = "确定", Width = 72, Margin = new Thickness(0, 0, 8, 0), IsDefault = true };
        var cancel = new Button { Content = "取消", Width = 72, IsCancel = true };
        var okClicked = false;
        ok.Click += (_, _) => { okClicked = true; win.DialogResult = true; };
        row.Children.Add(ok); row.Children.Add(cancel);
        sp.Children.Add(row);
        win.Content = sp;
        tb.Focus();
        var result = win.ShowDialog();
        return result == true && okClicked ? tb.Text : null;
    }

    /// <summary>Tab 补全：把最后一个 token 当远端路径前缀，用 ls 列同级候选，补到公共前缀。</summary>
    private void CompleteRemotePath()
    {
        if (ActiveSession is not { Connected: true } session) return;
        var text = CmdInput.Text;
        var lastSpace = text.LastIndexOf(' ');
        if (lastSpace < 0) return; // 第一个 token 是命令名，不补路径
        var prefixPart = text[..(lastSpace + 1)];
        var token = text[(lastSpace + 1)..];

        string dir, stub;
        var slash = token.LastIndexOf('/');
        if (slash >= 0)
        {
            dir = token[..slash].Length == 0 ? "/" : token[..(slash + 1)];
            stub = token[(slash + 1)..];
        }
        else
        {
            dir = Sftp.CurrentRemotePath;
            stub = token;
        }
        var quoted = dir.Replace("'", "'\\''");
        _ = CompleteRemotePathAsync(session, prefixPart, token, dir, stub, quoted);
    }

    private async Task CompleteRemotePathAsync(TerminalSession session, string prefixPart, string token, string dir, string stub, string quoted)
    {
        var outp = await session.ExecAsync($"ls -1ap '{quoted}' 2>/dev/null");
        if (!IsActiveSession(session)) return;
        var names = outp.Split('\n')
            .Select(s => s.TrimEnd('\r'))
            .Where(s => s.Length > 0 && s != "./" && s != "../" && (stub.Length == 0 || s.StartsWith(stub)))
            .ToList();
        if (names.Count == 0) return;
        if (names.Count == 1)
        {
            var joined = token.Contains('/') ? dir + names[0] : names[0];
            CmdInput.Text = prefixPart + joined;
        }
        else
        {
            var common = CommonPrefix(names);
            if (common.Length > stub.Length)
            {
                var joined = token.Contains('/') ? dir + common : common;
                CmdInput.Text = prefixPart + joined;
            }
            SetStatus(string.Join("  ", names.Take(8)));
        }
        CmdInput.CaretIndex = CmdInput.Text.Length;
    }

    private static string CommonPrefix(List<string> list)
    {
        if (list.Count == 0) return "";
        var p = list[0];
        foreach (var s in list.Skip(1))
            while (!s.StartsWith(p) && p.Length > 0) p = p[..^1];
        return p;
    }

    /// <summary>P0：SFTP 与终端独立 — 终端 cd 不再驱动 SFTP。</summary>
    private void ApplyCdSync(string command)
    {
        // 保留空实现，避免调用点改漏；如需旧联动行为再打开下方逻辑。
        _ = command;
    }

    /// <summary>P0：SFTP 进目录不再往终端灌 cd（旧 OnUserNavigate 已解绑）。</summary>
    private void SyncTerminalCd(string path)
    {
        _ = path;
    }

    /// <summary>P1：SSH 断开/关标签 → 清 SFTP + 关系统信息窗口。</summary>
    private void ClearSessionSidePanels()
    {
        try { Sftp.Cleanup(); } catch { }
        try { DockPathText.Text = "远端未连接"; } catch { }
        try
        {
            if (_sysInfoWin is { IsVisible: true })
            {
                _sysInfoWin.Close();
            }
        }
        catch { }
        _sysInfoWin = null;
    }

    /// <summary>命令栏「历史」按钮：按当前输入过滤历史，弹出选取菜单。</summary>
    private void ShowCommandHistory_Click(object sender, RoutedEventArgs e)
    {
        var items = _cmdHistory.Filter(CmdInput.Text);
        if (items.Count == 0) { SetStatus("暂无历史命令"); return; }
        var menu = new ContextMenu { PlacementTarget = CmdInput, Placement = System.Windows.Controls.Primitives.PlacementMode.Top };
        foreach (var c in items)
        {
            var mi = new MenuItem();
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            
            var tb = new TextBlock { Text = c, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 16, 0) };
            grid.Children.Add(tb);
            
            var sp = new StackPanel { Orientation = Orientation.Horizontal, Visibility = Visibility.Hidden };
            Grid.SetColumn(sp, 1);
            
            var btnRun = new Button { Content = "运行", Style = (Style)FindResource("PillButton"), Margin = new Thickness(4,0,0,0) };
            btnRun.Click += (_, ev) => { ev.Handled = true; menu.IsOpen = false; CmdInput.Text = c; SendCurrentCommand(); };
            
            var btnCopy = new Button { Content = "复制", Style = (Style)FindResource("PillButton"), Margin = new Thickness(4,0,0,0) };
            btnCopy.Click += (_, ev) => { ev.Handled = true; menu.IsOpen = false; Clipboard.SetText(c); };
            
            var btnDel = new Button { Content = "删除", Style = (Style)FindResource("PillButton"), Margin = new Thickness(4,0,0,0) };
            btnDel.Click += (_, ev) => { ev.Handled = true; menu.IsOpen = false; _cmdHistory.Remove(c); };
            
            sp.Children.Add(btnRun);
            sp.Children.Add(btnCopy);
            sp.Children.Add(btnDel);
            grid.Children.Add(sp);
            
            mi.Header = grid;
            mi.MouseEnter += (_, _) => sp.Visibility = Visibility.Visible;
            mi.MouseLeave += (_, _) => sp.Visibility = Visibility.Hidden;
            mi.Click += (_, _) => { CmdInput.Text = c; CmdInput.Focus(); CmdInput.CaretIndex = c.Length; };
            menu.Items.Add(mi);
        }
        
        menu.Items.Add(new Separator());
        var clearMi = new MenuItem { Header = "清空全部历史记录", Foreground = System.Windows.Media.Brushes.Red };
        clearMi.Click += (_, _) => { _cmdHistory.Clear(); menu.IsOpen = false; };
        menu.Items.Add(clearMi);
        
        menu.IsOpen = true;
    }

    // =====================================================================
    // 底部坞：文件操作图标（转发给 SftpPanel）
    // =====================================================================
    private void SftpUp_Click(object sender, RoutedEventArgs e) => Sftp.GoUp();
    private void SftpRefresh_Click(object sender, RoutedEventArgs e) => Sftp.Refresh();
    private void SftpDownload_Click(object sender, RoutedEventArgs e) => Sftp.Download();
    private void SftpUpload_Click(object sender, RoutedEventArgs e) => Sftp.Upload();
    private void SftpMkdir_Click(object sender, RoutedEventArgs e) => Sftp.Mkdir();
    private void SftpDelete_Click(object sender, RoutedEventArgs e) => Sftp.Delete();
    private void SftpToggleLocal_Click(object sender, RoutedEventArgs e) => Sftp.ToggleLocal();

    /// <summary>坞里的机器人按钮：切换左栏「本地文件 / 与本机 agent 对话」。</summary>
    private void SftpToggleChat_Click(object sender, RoutedEventArgs e) => Sftp.ToggleChat();

    // =====================================================================
    // 监控轮询（对齐 mac AppDelegate+Sessions.startMonitor，3 秒一次）
    // =====================================================================
    private async Task PollMonitor()
    {
        var session = ActiveSession;
        if (session is not { Connected: true })
        {
            Monitor.SetConnected(false, "");
            return;
        }
        var host = session.SourceHost?.Host ?? session.HostName;
        Monitor.SetConnected(true, host);
        var outp = await session.ExecAsync(UI.MonitorSidebar.MonitorCommand);
        if (!IsActiveSession(session)) return; // tab 可能在等待期间已切走
        if (outp.Contains("===mon===")) Monitor.Update(UI.MonitorSidebar.ParseMonitor(outp));
    }

    // =====================================================================
    // 系统信息：结构化卡片面板（对齐 mac UI/SysInfoPanel.swift + Monitor/SysInfoParser.swift）
    // =====================================================================
    private async Task ShowSysInfo()
    {
        Log.Info("打开系统信息面板", "ui");
        if (ActiveSession is not { Connected: true } session) { MessageBox.Show(this, "请先连接一个会话。", "系统信息"); return; }
        try { _sysInfoWin?.Close(); } catch { }
        var win = new UI.SysInfoWindow { Owner = this, Title = "系统信息 · " + (session.SourceHost?.Display ?? session.HostName) };
        win.OnRefresh = () => IsActiveSession(session) ? session.ExecAsync(UI.SysInfoWindow.Command) : Task.FromResult("");
        win.Closed += (_, _) => { if (ReferenceEquals(_sysInfoWin, win)) _sysInfoWin = null; };
        _sysInfoWin = win;
        win.Show();
        await win.Reload();
    }

    // =====================================================================
    // 汉堡菜单（嵌套：文件/查看/选项 + 密钥管理器 + 云端同步 + 帮助，对齐 mac #mainMenu）
    // =====================================================================
    private void OpenMenu_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu { PlacementTarget = MenuBtn, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };

        var file = new MenuItem { Header = "文件" };
        file.Items.Add(Item("连接管理器…", () => ShowConnectionManager()));
        file.Items.Add(Item("新建连接…", NewHostFlow));
        file.Items.Add(Item("连接", MenuConnect));
        file.Items.Add(Item("断开", MenuDisconnect));
        file.Items.Add(Item("重新连接", MenuReconnect));
        file.Items.Add(new Separator());
        file.Items.Add(Item("密钥管理…", OpenKeyManager));
        file.Items.Add(Item("主机指纹管理…", OpenFingerprintManager));
        file.Items.Add(new Separator());
        file.Items.Add(Item("导入主机…", ImportHosts));
        file.Items.Add(Item("导出主机…", ExportHosts));
        menu.Items.Add(file);

        var view = new MenuItem { Header = "查看" };
        view.Items.Add(Item("显示/隐藏侧栏", () => SetSidebarCollapsed(!_sideCollapsed)));
        view.Items.Add(Item("显示/隐藏底栏", () => SetDockCollapsed(!_dockCollapsed)));
        view.Items.Add(Item("文件面板", () => SetFilesActive(true)));
        view.Items.Add(Item("命令面板", () => SetFilesActive(false)));
        view.Items.Add(new Separator());
        view.Items.Add(Item("系统信息", () => _ = ShowSysInfo()));
        view.Items.Add(Item("进程管理", () => MenuToolRun(UI.ToolsPanel.CmdProcess, "进程管理")));
        view.Items.Add(Item("网络监控", () => MenuToolRun(UI.ToolsPanel.CmdNetwork, "网络监控")));
        menu.Items.Add(view);

        var options = new MenuItem { Header = "选项" };
        options.Items.Add(Item("设置…", OpenSettings));
        options.Items.Add(Item("代理服务器…", OpenProxyWindow));
        menu.Items.Add(options);

        menu.Items.Add(new Separator());
        menu.Items.Add(Item("密钥管理器", OpenKeyManager));   // 对齐 mac 顶层 menuKeyMgr（原先误接到自定义加速）
        menu.Items.Add(Item("主机指纹管理…", OpenFingerprintManager));

        var cloud = new MenuItem { Header = "云端同步" };
        cloud.Items.Add(Item("备份选项配置…", OpenBackupWindow));
        cloud.Items.Add(new Separator());
        cloud.Items.Add(Item("WebDAV 设置…", WebdavConfigure));
        cloud.Items.Add(Item("上传到 WebDAV", WebdavPush));
        cloud.Items.Add(Item("从 WebDAV 恢复", WebdavPull));
        cloud.Items.Add(new Separator());
        cloud.Items.Add(Item("立即导出本地包…", ExportHosts));
        cloud.Items.Add(Item("从本地包导入…", ImportHosts));
        menu.Items.Add(cloud);

        menu.Items.Add(Item("软件更新", CheckUpdate));   // 对齐 mac 顶层 checkUpdate

        // AI 对接：后端 AgentBridge / AgentCLI 已就绪，汉堡菜单提供一键入口
        var ai = new MenuItem { Header = "AI 对接" };
        ai.Items.Add(Item("接入 AI 工具…", OpenAIIntegration));
        ai.Items.Add(new Separator());
        ai.Items.Add(Item("复制 CLI 用法", CopyCLIUsage));
        ai.Items.Add(Item("复制 MCP 注册命令", CopyMCPRegister));
        ai.Items.Add(Item("复制 Desktop MCP 配置", CopyMCPDesktop));
        ai.Items.Add(new Separator());
        ai.Items.Add(Item("打开 CLI 脚本目录", OpenCLIBinDir));
        ai.Items.Add(Item("重新安装 CLI / MCP", ReinstallCLIBridge));
        menu.Items.Add(ai);

        menu.Items.Add(new Separator());
        var help = new MenuItem { Header = "帮助" };
        help.Items.Add(Item("关于 PixShell", () => MessageBox.Show(this, $"PixShell {AppVersion}\nWindows 原生 SSH / SFTP 客户端\nWPF + WebView2/xterm.js + SSH.NET\nhttps://github.com/lyu0805/pixshell", "关于")));
        help.Items.Add(Item("接入 AI 工具…", OpenAIIntegration));
        help.Items.Add(new Separator());
        help.Items.Add(Item("项目仓库", () => { try { Process.Start(new ProcessStartInfo("https://github.com/lyu0805/pixshell") { UseShellExecute = true }); } catch { } }));
        menu.Items.Add(help);

        // 暗色主题：系统 ContextMenu 默认白底，而 Window.Foreground 是浅色字 → 白底看不见字。
        menu.SetResourceReference(Control.BackgroundProperty, "BrushBg2");
        menu.SetResourceReference(Control.ForegroundProperty, "BrushText");
        menu.SetResourceReference(Control.BorderBrushProperty, "BrushBorderStrong");
        ApplyMenuTheme(menu);
        menu.IsOpen = true;
    }

    /// <summary>递归给 MenuItem 上主题前景，防止暗色白底无字。</summary>
    private static void ApplyMenuTheme(ItemsControl root)
    {
        foreach (var obj in root.Items)
        {
            if (obj is MenuItem mi)
            {
                mi.SetResourceReference(Control.ForegroundProperty, "BrushText");
                mi.SetResourceReference(Control.BackgroundProperty, "BrushBg2");
                if (mi.HasItems) ApplyMenuTheme(mi);
            }
            else if (obj is Separator sep)
            {
                sep.SetResourceReference(Control.BackgroundProperty, "BrushBorder");
            }
        }
    }

    private void CopyCLIUsage()
    {
        if (_agentBridge != null) Bridge.AgentCLI.Install(_agentBridge.Port);
        try { Clipboard.SetText(Bridge.AgentCLI.PromptPreamble()); SetStatus("已复制 CLI 用法"); } catch { }
    }
    private void CopyMCPRegister()
    {
        if (_agentBridge != null) Bridge.AgentCLI.Install(_agentBridge.Port);
        try { Clipboard.SetText(Bridge.AgentCLI.ClaudeCodeCommand()); SetStatus("已复制 MCP 注册命令"); } catch { }
    }
    private void CopyMCPDesktop()
    {
        if (_agentBridge != null) Bridge.AgentCLI.Install(_agentBridge.Port);
        try { Clipboard.SetText(Bridge.AgentCLI.DesktopConfigSnippet()); SetStatus("已复制 Desktop MCP 配置"); } catch { }
    }
    private void OpenCLIBinDir()
    {
        if (_agentBridge != null) Bridge.AgentCLI.Install(_agentBridge.Port);
        try
        {
            Directory.CreateDirectory(Bridge.AgentCLI.BinDir);
            Process.Start(new ProcessStartInfo("explorer.exe", Bridge.AgentCLI.BinDir) { UseShellExecute = true });
            SetStatus("已打开 " + Bridge.AgentCLI.BinDir);
        }
        catch (Exception ex) { SetStatus("打开失败: " + ex.Message); }
    }
    private void ReinstallCLIBridge()
    {
        if (_agentBridge == null || !_agentBridge.IsRunning) StartAgentBridge();
        if (_agentBridge != null) Bridge.AgentCLI.Install(_agentBridge.Port);
        UpdateCliStatus();
        SetStatus($"已重新安装 CLI / MCP（端口 {_agentBridge?.Port ?? 0}）");
    }

    private static MenuItem Item(string header, Action action)
    {
        var mi = new MenuItem { Header = header };
        mi.Click += (_, _) => action();
        return mi;
    }

    private void MenuConnect()
    {
        if (ActiveSession is { Connected: false }) { MenuReconnect(); return; }
        ShowConnectionManager();
    }
    private void MenuDisconnect()
    {
        ActiveSession?.Disconnect();
        ClearSessionSidePanels();   // P1：断开即清 SFTP + 系统信息
        RefreshConnState();   // 侧栏红绿灯 + 断开/连接按钮跟着切
        SetStatus("已断开");
    }
    /// <summary>重新连接：原地复用当前标签（见 ReconnectInPlaceAsync —— 旧实现会多开一个标签页）。</summary>
    private void MenuReconnect()
    {
        if (Sessions.SelectedItem is TabItem item) _ = ReconnectInPlaceAsync(item);
    }

    /// <summary>软件更新：对齐 mac AppUpdate/checkUpdate。
    /// 请求 GitHub Releases latest，semver 比较；网络/解析失败不谎称已是最新。</summary>
    private void CheckUpdate()
    {
        SetStatus("检查更新…");
        _ = CheckUpdateAsync();
    }

    private async Task CheckUpdateAsync()
    {
        const string repo = "lyu0805/pixshell";
        const string releasesUrl = "https://github.com/" + repo + "/releases";
        const string apiUrl = "https://api.github.com/repos/" + repo + "/releases/latest";
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
            http.DefaultRequestHeaders.TryAddWithoutValidation("Accept", "application/vnd.github+json");
            http.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", "PixShell/" + AppVersion);
            using var resp = await http.GetAsync(apiUrl);
            if (!resp.IsSuccessStatusCode)
            {
                Log.Warn($"检查更新 HTTP {(int)resp.StatusCode}", "update");
                SetStatus("无法获取更新信息");
                var fail = MessageBox.Show(this,
                    "无法获取更新信息（网络或仓库不可达）。\n是否打开发行页？",
                    "检查更新", MessageBoxButton.YesNo, MessageBoxImage.Information);
                if (fail == MessageBoxResult.Yes)
                    Process.Start(new ProcessStartInfo(releasesUrl) { UseShellExecute = true });
                return;
            }
            var json = await resp.Content.ReadAsStringAsync();
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var tag = root.TryGetProperty("tag_name", out var tn) ? tn.GetString() ?? ""
                    : root.TryGetProperty("name", out var nm) ? nm.GetString() ?? "" : "";
            var latest = NormalizeVersion(tag);
            if (string.IsNullOrEmpty(latest))
            {
                SetStatus("无法获取更新信息");
                MessageBox.Show(this, "无法解析远端版本号。", "检查更新",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            // 该次 release 页（优先 html_url）
            string? releasePage = null;
            if (root.TryGetProperty("html_url", out var hu)) releasePage = hu.GetString();
            if (string.IsNullOrEmpty(releasePage))
                releasePage = $"https://github.com/{repo}/releases/tag/{(tag.StartsWith("v") ? tag : "v" + latest)}";

            // 匹配 win-x64 安装包 / zip
            string? assetName = null, assetUrl = null;
            if (root.TryGetProperty("assets", out var assets) && assets.ValueKind == JsonValueKind.Array)
            {
                string[] hints = { "win-x64-setup.exe", "win-x64.zip", "windows-x64", "win64" };
                foreach (var hint in hints)
                {
                    foreach (var a in assets.EnumerateArray())
                    {
                        var n = a.TryGetProperty("name", out var an) ? an.GetString() ?? "" : "";
                        var u = a.TryGetProperty("browser_download_url", out var au) ? au.GetString() : null;
                        if (!string.IsNullOrEmpty(n) && !string.IsNullOrEmpty(u)
                            && n.Contains(hint, StringComparison.OrdinalIgnoreCase))
                        {
                            assetName = n; assetUrl = u; break;
                        }
                    }
                    if (assetUrl != null) break;
                }
                if (assetUrl == null)
                {
                    foreach (var a in assets.EnumerateArray())
                    {
                        var n = a.TryGetProperty("name", out var an) ? an.GetString() ?? "" : "";
                        var u = a.TryGetProperty("browser_download_url", out var au) ? au.GetString() : null;
                        var low = n.ToLowerInvariant();
                        if ((low.Contains("win") || low.Contains("windows"))
                            && (low.EndsWith(".exe") || low.EndsWith(".zip") || low.EndsWith(".msi"))
                            && !string.IsNullOrEmpty(u))
                        {
                            assetName = n; assetUrl = u; break;
                        }
                    }
                }
            }

            var cmp = CompareSemver(latest, AppVersion);
            if (cmp > 0)
            {
                SetStatus($"发现新版本 {latest}");
                var info = $"发现新版本 {latest}\n当前 {AppVersion}，来源 GitHub Releases（{repo}）。";
                if (!string.IsNullOrEmpty(assetName)) info += $"\n匹配资产：{assetName}";

                if (!string.IsNullOrEmpty(assetUrl) && !string.IsNullOrEmpty(assetName))
                {
                    var ans = MessageBox.Show(this,
                        info + "\n\n是 = 下载并打开\n否 = 打开发行页\n取消 = 稍后",
                        "软件更新", MessageBoxButton.YesNoCancel, MessageBoxImage.Information);
                    if (ans == MessageBoxResult.Yes)
                        await DownloadReleaseAssetAsync(assetUrl!, assetName!);
                    else if (ans == MessageBoxResult.No)
                        Process.Start(new ProcessStartInfo(releasePage!) { UseShellExecute = true });
                }
                else
                {
                    var ans = MessageBox.Show(this,
                        info + "\n\n是否打开发行页？",
                        "软件更新", MessageBoxButton.YesNo, MessageBoxImage.Information);
                    if (ans == MessageBoxResult.Yes)
                        Process.Start(new ProcessStartInfo(releasePage!) { UseShellExecute = true });
                }
            }
            else
            {
                SetStatus($"已是最新版本 {AppVersion}");
                MessageBox.Show(this, $"当前 {AppVersion} 已是最新版本（GitHub Releases）", "已是最新",
                    MessageBoxButton.OK, MessageBoxImage.Information);
            }
            Log.Info($"检查更新结果 latest={latest} current={AppVersion} cmp={cmp} asset={assetName ?? "-"}", "update");
        }
        catch (Exception ex)
        {
            Log.Warn($"检查更新失败: {ex.Message}", "update");
            SetStatus("无法获取更新信息");
            var fail = MessageBox.Show(this,
                "无法获取更新信息（网络或仓库不可达）。\n是否打开发行页？",
                "检查更新", MessageBoxButton.YesNo, MessageBoxImage.Information);
            if (fail == MessageBoxResult.Yes)
                Process.Start(new ProcessStartInfo(releasesUrl) { UseShellExecute = true });
        }
    }

    /// <summary>下载 release 资产到「下载」目录并打开。</summary>
    private async Task DownloadReleaseAssetAsync(string url, string name)
    {
        try
        {
            SetStatus($"正在下载 {name}…");
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
            Directory.CreateDirectory(dir);
            var dest = Path.Combine(dir, name);
            using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
            http.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", "PixShell/" + AppVersion);
            var bytes = await http.GetByteArrayAsync(url);
            await File.WriteAllBytesAsync(dest, bytes);
            SetStatus($"已下载 {name}");
            Process.Start(new ProcessStartInfo(dest) { UseShellExecute = true });
            // 顺带在资源管理器中选中
            try { Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{dest}\"") { UseShellExecute = true }); }
            catch { /* 忽略 */ }
        }
        catch (Exception ex)
        {
            Log.Warn($"下载更新失败: {ex.Message}", "update");
            SetStatus("下载失败");
            MessageBox.Show(this, "下载失败：" + ex.Message, "软件更新",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    /// <summary>状态栏 GitHub Mark → 打开仓库主页。</summary>
    private void GitHubMark_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo("https://github.com/lyu0805/pixshell") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "无法打开浏览器：" + ex.Message, "PixShell",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    /// <summary>去掉前缀 v，只留版本主体。</summary>
    private static string NormalizeVersion(string raw)
    {
        var s = (raw ?? "").Trim();
        if (s.StartsWith("v", StringComparison.OrdinalIgnoreCase)) s = s[1..];
        return s.Trim();
    }

    /// <summary>语义化比较：a&gt;b → 1，a&lt;b → -1，相等 0（缺失段按 0）。</summary>
    private static int CompareSemver(string a, string b)
    {
        static int[] Parts(string v) =>
            NormalizeVersion(v).Split('.').Select(p =>
            {
                var digits = new string(p.TakeWhile(char.IsDigit).ToArray());
                return int.TryParse(digits, out var n) ? n : 0;
            }).ToArray();

        var x = Parts(a);
        var y = Parts(b);
        var n = Math.Max(x.Length, y.Length);
        for (var i = 0; i < n; i++)
        {
            var l = i < x.Length ? x[i] : 0;
            var r = i < y.Length ? y[i] : 0;
            if (l != r) return l > r ? 1 : -1;
        }
        return 0;
    }

    private async Task TermCopy()
    {
        // 焦点在命令输入时：复制走当前选区（命令框 / 编辑器），别硬拉终端选区
        if (PasteTargetIsCommandBox())
        {
            try
            {
                if (CmdInput.IsKeyboardFocusWithin && !string.IsNullOrEmpty(CmdInput.SelectedText))
                { Clipboard.SetText(CmdInput.SelectedText); return; }
                if (Cmds.Visibility == Visibility.Visible && Cmds.IsKeyboardFocusWithin
                    && !string.IsNullOrEmpty(Cmds.Editor.SelectedText))
                { Clipboard.SetText(Cmds.Editor.SelectedText); return; }
            }
            catch { /* 剪贴板偶发占用 */ }
        }
        if (ActiveSession == null) return;
        var text = await ActiveSession.GetSelectionAsync();
        if (!string.IsNullOrEmpty(text)) Clipboard.SetText(text);
    }

    /// <summary>P0：粘贴优先进命令输入框。菜单/快捷键若总绑 TermPaste，命令板聚焦时也会把命令打进终端。</summary>
    private void TermPaste()
    {
        if (PasteIntoCommandBoxIfFocused()) return;
        if (ActiveSession == null) return;
        try { var text = Clipboard.GetText(); if (!string.IsNullOrEmpty(text)) ActiveSession.SendText(text); } catch { }
    }

    private bool PasteTargetIsCommandBox()
    {
        // 严格按焦点：只有命令框/命令板编辑器聚焦才截胡，终端聚焦时仍进终端
        if (CmdInput.IsKeyboardFocusWithin) return true;
        if (Cmds.Visibility == Visibility.Visible
            && (Cmds.IsKeyboardFocusWithin || Cmds.Editor.IsKeyboardFocusWithin || Cmds.Editor.IsFocused))
            return true;
        return false;
    }

    /// <summary>命令输入聚焦时把剪贴板塞进命令框，返回 true 表示已处理。</summary>
    private bool PasteIntoCommandBoxIfFocused()
    {
        if (!PasteTargetIsCommandBox()) return false;
        string clip;
        try { clip = Clipboard.GetText(); } catch { return true; } // 聚焦命令框但剪贴板炸了，也别漏进终端
        if (string.IsNullOrEmpty(clip)) return true;

        // 1) 底栏单行 CmdInput
        if (CmdInput.IsKeyboardFocusWithin)
        {
            var oneLine = clip.Replace("\r\n", " ").Replace("\n", " ").Replace("\r", " ");
            var start = CmdInput.SelectionStart;
            var len = CmdInput.SelectionLength;
            var t = CmdInput.Text ?? "";
            CmdInput.Text = t.Substring(0, start) + oneLine + t.Substring(start + len);
            CmdInput.CaretIndex = start + oneLine.Length;
            CmdInput.Focus();
            return true;
        }

        // 2) 命令板多行 Editor
        if (Cmds.Visibility == Visibility.Visible
            && (Cmds.IsKeyboardFocusWithin || Cmds.Editor.IsKeyboardFocusWithin || Cmds.Editor.IsFocused))
        {
            var ed = Cmds.Editor;
            var start = ed.SelectionStart;
            var len = ed.SelectionLength;
            var t = ed.Text ?? "";
            ed.Text = t.Substring(0, start) + clip + t.Substring(start + len);
            ed.CaretIndex = start + clip.Length;
            ed.Focus();
            return true;
        }
        return false;
    }

    private void MenuToolRun(string cmd, string label)
    {
        // 只跑工具结果窗；不强制打开下载浮窗，避免和终端抢 airspace。
        _ = ToolsFlyout.RunAsync(label, cmd);
    }

    private UI.KeyManagerWindow? _keyManager;
    private UI.FingerprintManagerWindow? _fingerprintManager;

    /// <summary>密钥管理（菜单 文件 → 密钥管理…）。「用于此主机」会把私钥路径写回当前会话的主机。</summary>
    private void OpenKeyManager()
    {
        _keyManager ??= new UI.KeyManagerWindow
        {
            OnUseKey = path =>
            {
                if (ActiveSession?.SourceHost is not { } h) { SetStatus("已选密钥 " + path); return; }
                var entry = _hosts.FirstOrDefault(x => x.Id == h.Id);
                if (entry == null) return;
                entry.KeyPath = path;
                h.KeyPath = path;
                PersistHosts();
                RefreshHostViews();
                SetStatus($"已把密钥设为 {h.Display} 的登录私钥");
            },
        };
        Log.Info("打开密钥管理", "ui");
        _keyManager.Show(this);
    }

    /// <summary>主机指纹管理（汉堡 / 文件 → 主机指纹管理…）。</summary>
    private void OpenFingerprintManager()
    {
        _fingerprintManager ??= new UI.FingerprintManagerWindow();
        Log.Info("打开主机指纹管理", "ui");
        _fingerprintManager.Show(this);
    }

    /// <summary>「接入 AI 工具」：把 MCP / CLI 两种接法摆出来，一键复制。
    /// 故意**不**替用户去改他的 Claude Desktop 配置文件 —— 只给现成片段，改不改他自己定。</summary>
    private void OpenAIIntegration()
    {
        var text =
            "PixShell 已经把自己开放给本机的 AI 工具了，两条路都跑在**同一条已连接的 SSH 会话**上，\n" +
            "不会每条指令都重连。\n\n" +
            "① MCP（推荐，桌面 AI 应用 / 支持 MCP 的客户端都吃这套）\n" +
            "   Claude Code CLI 注册：\n   " + Bridge.AgentCLI.ClaudeCodeCommand() + "\n\n" +
            "   Claude Desktop 等配置文件型客户端，把这段并进它的 MCP 配置：\n" +
            Bridge.AgentCLI.DesktopConfigSnippet() + "\n\n" +
            "② 命令行（任何终端里的 agent / 脚本 / 计划任务）\n   " +
            Bridge.AgentCLI.CmdPath + " screen 50\n   " +
            Bridge.AgentCLI.CmdPath + " exec \"systemctl status nginx\"\n\n" +
            "工具：list_sessions / read_screen / exec_command / type_text / list_hosts / sftp_list\n" +
            "大输出会自动截断并说明截了多少（避免 MCP 大负载失败），要更多用 findstr/head 收窄或调 max_bytes。";

        var win = new Window
        {

            Title = "接入 AI 工具", Owner = this, Width = 620, SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize,
            Background = (Brush)Application.Current.Resources["BrushBg"],
        };
        var sp = new StackPanel { Margin = new Thickness(14) };
        sp.Children.Add(new TextBox
        {
            Text = text, IsReadOnly = true, TextWrapping = TextWrapping.NoWrap, AcceptsReturn = true,
            FontFamily = (FontFamily)Application.Current.Resources["FontMono"], FontSize = 11,
            Height = 320, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
        });
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        var b1 = new Button { Content = "复制 MCP 注册命令", Margin = new Thickness(0, 0, 8, 0), Padding = new Thickness(10, 3, 10, 3) };
        b1.Click += (_, _) => { try { Clipboard.SetText(Bridge.AgentCLI.ClaudeCodeCommand()); SetStatus("已复制 MCP 注册命令"); } catch { } };
        var b2 = new Button { Content = "复制 Desktop 配置", Margin = new Thickness(0, 0, 8, 0), Padding = new Thickness(10, 3, 10, 3) };
        b2.Click += (_, _) => { try { Clipboard.SetText(Bridge.AgentCLI.DesktopConfigSnippet()); SetStatus("已复制 Desktop MCP 配置"); } catch { } };
        var b3 = new Button { Content = "关闭", Padding = new Thickness(10, 3, 10, 3), IsCancel = true };
        b3.Click += (_, _) => win.Close();
        row.Children.Add(b1); row.Children.Add(b2); row.Children.Add(b3);
        sp.Children.Add(row);
        win.Content = sp;
        win.ShowDialog();
    }

    private void OpenSettings()
    {
        var win = new Window
        {
            Background = (System.Windows.Media.Brush)Application.Current.Resources["BrushBg"],
            Foreground = (System.Windows.Media.Brush)Application.Current.Resources["BrushText"],
            Title = "设置", Width = 360, MinWidth = 300, MinHeight = 280,
            SizeToContent = SizeToContent.Manual, Height = 420, Owner = this,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ResizeMode = ResizeMode.CanResizeWithGrip, ShowInTaskbar = false,
        };
        var sp = new StackPanel { Margin = new Thickness(14) };
        sp.Children.Add(new TextBlock { Text = "主题", Margin = new Thickness(0, 0, 0, 4) });
        var combo = new ComboBox();
        var kinds = ThemeManager.AllKinds;
        foreach (var k in kinds) combo.Items.Add(ThemeManager.Display(k));
        combo.SelectedIndex = Array.IndexOf(kinds, ThemeManager.Current);
        sp.Children.Add(combo);

        // 终端配色方案（32 套 + 别名，Terminal/TermSchemes.cs）。
        sp.Children.Add(new TextBlock { Text = "终端配色", Margin = new Thickness(0, 12, 0, 4) });
        var schemeCombo = new ComboBox { MaxDropDownHeight = 320 };
        foreach (var s in Terminal.TermSchemes.All) schemeCombo.Items.Add(s.Name);
        var currentIndex = Terminal.TermSchemes.All.ToList().FindIndex(s => s.Id == Terminal.TermSchemeStore.CurrentId);
        schemeCombo.SelectedIndex = currentIndex >= 0 ? currentIndex : 0;
        sp.Children.Add(schemeCombo);

        // 自定义高亮/普通文字颜色：留空(=跟随主题)是默认值，改了才覆盖（对齐 mac 设置页）
        sp.Children.Add(new TextBlock { Text = "高亮文字颜色（#rrggbb，留空=跟随主题）", Margin = new Thickness(0, 12, 0, 4) });
        var hlBox = new TextBox { Text = HighlightColors.HighlightHex };
        sp.Children.Add(hlBox);
        sp.Children.Add(new TextBlock { Text = "普通文字颜色（#rrggbb，留空=跟随主题）", Margin = new Thickness(0, 8, 0, 4) });
        var plainBox = new TextBox { Text = HighlightColors.PlainHex };
        sp.Children.Add(plainBox);
        var hlChk = new CheckBox { Content = "终端语义高亮", IsChecked = TerminalSession.HighlightEnabled, Margin = new Thickness(0, 10, 0, 0) };
        sp.Children.Add(hlChk);

        var btnRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 14, 0, 0),
        };
        var cancelBtn = new Button
        {
            Content = "取消", Width = 80, Margin = new Thickness(0, 0, 8, 0), IsCancel = true,
        };
        cancelBtn.Click += (_, _) => win.Close();
        var doneBtn = new Button { Content = "完成", Width = 80, IsDefault = true };
        doneBtn.Click += (_, _) =>
        {
            // 选浅色系的任意一套 → ApplyKind 内部会把它记为"我的浅色"，
            // 之后顶栏按钮只在 深色 ⇄ 它 之间切（不轮播）。
            var wantKind = kinds[Math.Max(0, combo.SelectedIndex)];
            if (wantKind != ThemeManager.Current)
            {
                ThemeManager.ApplyKind(wantKind);
                AfterThemeChanged();
            }
            var chosen = Terminal.TermSchemes.All[schemeCombo.SelectedIndex];
            if (chosen.Id != Terminal.TermSchemeStore.CurrentId)
            {
                Log.Info("切换终端配色 → " + chosen.Name, "ui");
                Terminal.TermSchemeStore.SetCurrent(chosen.Id);
            }
            TerminalSession.HighlightEnabled = hlChk.IsChecked == true;
            HighlightColors.Set(hlBox.Text, plainBox.Text);
            win.Close();
        };
        btnRow.Children.Add(cancelBtn);
        btnRow.Children.Add(doneBtn);
        sp.Children.Add(btnRow);
        win.Content = sp;
        win.ShowInTaskbar = false;
        win.ShowDialog();
    }

    // =====================================================================
    // 导入 / 导出备份包（bundle v1，对齐 mac exportHosts/importHosts；菜单 + 备份窗口 共用）
    // =====================================================================

    /// <summary>当前配置打包（密码不入包：HostEntry 本身就不含密码，对齐 mac currentBundle）。</summary>
    private Store.BackupBundle CurrentBundle()
    {
        // 导出用户实际存储的快捷命令（quick-commands.json），而非内置占位列表。
        var quick = Cmds.CommandStore.Commands;
        var settings = new Dictionary<string, string>
        {
            ["theme"] = ThemeManager.IsDark ? "dark" : "light",
            ["colorScheme"] = Terminal.TermSchemeStore.CurrentId,
            ["termBgOverride"] = Terminal.TermBackgroundStore.Override,
        };
        return Store.BackupBundle.Make(_hosts.ToList(), quick, settings);
    }

    /// <summary>导出本地备份包（bundle v1）。</summary>
    private void ExportHosts()
    {
        var dlg = new SaveFileDialog { FileName = "pixshell-backup.json", Filter = "JSON (*.json)|*.json" };
        if (dlg.ShowDialog(this) != true) return;
        try
        {
            File.WriteAllText(dlg.FileName, CurrentBundle().Encode());
            Log.Info("导出备份包 → " + dlg.FileName, "backup");
            MessageBox.Show(this, "导出完成: " + dlg.FileName, "PixShell");
        }
        catch (Exception ex) { MessageBox.Show(this, "导出失败: " + ex.Message, "PixShell", MessageBoxButton.OK, MessageBoxImage.Warning); }
    }

    /// <summary>导入本地备份包（bundle v1；也兼容老的纯 [HostEntry] 数组格式）。</summary>
    private void ImportHosts()
    {
        var dlg = new OpenFileDialog { Filter = "PixShell 备份包 (*.json)|*.json" };
        if (dlg.ShowDialog(this) != true) return;
        try { ApplyBundleJson(File.ReadAllText(dlg.FileName), Path.GetFileName(dlg.FileName)); }
        catch (Exception ex) { MessageBox.Show(this, "导入失败: " + ex.Message, "PixShell", MessageBoxButton.OK, MessageBoxImage.Warning); }
    }

    /// <summary>把备份包 JSON 应用到本地（主机；密码不在包内，需重新输入）。先按 v1 bundle 解析，失败再退回旧的纯数组格式。</summary>
    private void ApplyBundleJson(string json, string source)
    {
        try
        {
            var b = Store.BackupBundle.Decode(json);
            foreach (var h in b.Hosts) HostStore.Upsert(h);
            _hosts.Clear();
            foreach (var h in HostStore.Load()) _hosts.Add(h);
            RefreshHostViews();
            Log.Info($"导入备份包 {source}：主机 {b.Hosts.Count} / 快捷命令 {b.QuickCommands.Count}", "backup");
            MessageBox.Show(this, $"主机 {b.Hosts.Count} 台，快捷命令 {b.QuickCommands.Count} 条\n（密码不在备份包内，需重新输入）", "导入完成");
            return;
        }
        catch (Exception bundleEx)
        {
            try
            {
                var list = JsonSerializer.Deserialize<List<HostEntry>>(json);
                if (list == null || list.Count == 0) throw new Exception("空文件");
                foreach (var h in list) HostStore.Upsert(h);
                _hosts.Clear();
                foreach (var h in HostStore.Load()) _hosts.Add(h);
                RefreshHostViews();
                MessageBox.Show(this, $"已导入/更新 {list.Count} 台主机", "导入完成");
            }
            catch
            {
                MessageBox.Show(this, "导入失败: 不是 PixShell 备份包 (" + bundleEx.Message + ")", "PixShell",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }
    }

    private void OpenBackupWindow()
    {
        var win = new BackupWindow(_backupEnabled) { Owner = this };
        win.OnExport = ExportHosts;
        win.OnImport = ImportHosts;
        win.OnConfigureWebDav = WebdavConfigure;
        if (win.ShowDialog() == true) _backupEnabled = win.Enabled;
    }

    // =====================================================================
    // WebDAV 备份：配置 + 上传 / 恢复（对齐 mac webdavConfigure/webdavPush/webdavPull）
    // =====================================================================
    private void WebdavConfigure()
    {
        var cur = Store.WebDavBackup.Load() ?? new Store.WebDavBackup.Config();
        var win = new Window
        {

            Background = (System.Windows.Media.Brush)System.Windows.Application.Current.Resources["BrushBg"],
            Foreground = (System.Windows.Media.Brush)System.Windows.Application.Current.Resources["BrushText"],
            Title = "WebDAV 备份", Width = 420, SizeToContent = SizeToContent.Height, Owner = this,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize
        };
        var sp = new StackPanel { Margin = new Thickness(14) };
        sp.Children.Add(new TextBlock
        {
            Text = "填写完整文件 URL 与应用密码（如坚果云 https://dav.jianguoyun.com/dav/pixshell/backup.json）",
            TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 10)
        });
        sp.Children.Add(new TextBlock { Text = "URL" });
        var urlBox = new TextBox { Text = cur.Url, Margin = new Thickness(0, 2, 0, 8) };
        sp.Children.Add(urlBox);
        sp.Children.Add(new TextBlock { Text = "用户名" });
        var userBox = new TextBox { Text = cur.Username, Margin = new Thickness(0, 2, 0, 8) };
        sp.Children.Add(userBox);
        sp.Children.Add(new TextBlock { Text = "应用密码" });
        var passBox = new PasswordBox { Password = cur.Password, Margin = new Thickness(0, 2, 0, 8) };
        sp.Children.Add(passBox);
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0) };
        var save = new Button { Content = "保存", Width = 72, Margin = new Thickness(0, 0, 8, 0), IsDefault = true };
        var cancel = new Button { Content = "取消", Width = 72, IsCancel = true };
        save.Click += (_, _) =>
        {
            Store.WebDavBackup.Save(new Store.WebDavBackup.Config
            {
                Url = urlBox.Text.Trim(), Username = userBox.Text.Trim(), Password = passBox.Password
            });
            win.DialogResult = true;
        };
        row.Children.Add(save); row.Children.Add(cancel);
        sp.Children.Add(row);
        win.Content = sp;
        if (win.ShowDialog() == true) MessageBox.Show(this, "已保存，接下来可用「上传到 WebDAV / 从 WebDAV 恢复」", "PixShell");
    }

    private async void WebdavPush()
    {
        var c = Store.WebDavBackup.Load();
        if (c is not { Url.Length: > 0 }) { WebdavConfigure(); return; }
        var err = await Store.WebDavBackup.Push(c, CurrentBundle());
        if (err != null) MessageBox.Show(this, "上传失败: " + err, "PixShell", MessageBoxButton.OK, MessageBoxImage.Warning);
        else MessageBox.Show(this, "备份已推送到 WebDAV", "上传完成");
    }

    private async void WebdavPull()
    {
        var c = Store.WebDavBackup.Load();
        if (c is not { Url.Length: > 0 }) { WebdavConfigure(); return; }
        var (bundle, err) = await Store.WebDavBackup.Pull(c);
        if (bundle == null) { MessageBox.Show(this, "下载失败: " + err, "PixShell", MessageBoxButton.OK, MessageBoxImage.Warning); return; }
        foreach (var h in bundle.Hosts) HostStore.Upsert(h);
        _hosts.Clear();
        foreach (var h in HostStore.Load()) _hosts.Add(h);
        RefreshHostViews();
        MessageBox.Show(this, $"主机 {bundle.Hosts.Count} 台（备份时间 {bundle.ExportedAt}）", "恢复完成");
    }

    // =====================================================================
    // 收尾
    // =====================================================================
    private void SetStatus(string s) => StatusText.Text = s;

    private void OnClosed(object? sender, EventArgs e)
    {
        _monitorTimer.Stop();
        _bridgeStatusTimer.Stop();
        try { _agentBridge?.Stop(); } catch { }
        try { Sftp.Cleanup(); } catch { }
        foreach (var obj in Sessions.Items)
            if (obj is TabItem { Tag: TerminalSession s })
                try { s.Dispose(); } catch { }
    }

    // ── Windows 窗口控制（右侧 — □ ✕，与 mac 左侧红绿灯相反，注意别照搬 mac 顺序）──
    private void WinMinimize_Click(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;

    private void WinMaximize_Click(object sender, RoutedEventArgs e)
    {
        WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
        UpdateMaxButtonGlyph();
    }

    private void WinClose_Click(object sender, RoutedEventArgs e) => Close();

    /// <summary>最大化/还原图标切换（Segoe MDL2：E922 最大化 / E923 还原）。</summary>
    private void UpdateMaxButtonGlyph()
    {
        if (MaxBtn != null)
            MaxBtn.Content = WindowState == WindowState.Maximized ? "\uE923" : "\uE922";
    }
}
