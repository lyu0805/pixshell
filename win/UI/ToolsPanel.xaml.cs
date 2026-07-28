using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace PixShell.UI;

/// <summary>
/// 工具面板（顶栏宫格图标 flyout）。远端命令与 mac UI/ToolsPanel.swift 完全一致。
/// 以独立 Owner 窗口展示，避免 WebView2 HwndHost airspace（禁止再藏终端 HWND）。
/// 对齐 ToolResultWindow 模式：独立 HWND，终端永不隐藏。
/// </summary>
public partial class ToolsPanel : UserControl
{
    public const string CmdProcess = "ps -eo pid,user,rss,pcpu,comm,args --sort=-pcpu 2>/dev/null | head -n 80 || ps w 2>/dev/null | head -n 80";
    public const string CmdNetwork = "ss -tulnpH 2>/dev/null || netstat -tulnp 2>/dev/null | tail -n +3";
    public static string CmdRoute(string host) =>
        $"echo '=== PING ==='; ping -c 4 -W 2 {host} 2>&1; echo; echo '=== TRACE ==='; traceroute -n -w 1 -q 1 -m 12 {host} 2>&1 || tracepath {host} 2>&1";
    public const string CmdSpeed =
        "echo '下载 10MB 测速中…'\n" +
        "curl -o /dev/null -s -w '下载速度: %{speed_download} B/s\\n耗时: %{time_total} s\\n' https://speed.cloudflare.com/__down?bytes=10000000 2>&1 " +
        "|| wget -O /dev/null https://speed.cloudflare.com/__down?bytes=10000000 2>&1 | tail -3 " +
        "|| echo '未找到 curl/wget'";

    public Func<List<(string title, bool active)>>? SessionsProvider { get; set; }
    public Action<int>? OnSelectSession { get; set; }
    public Func<string, Task<string>>? OnExec { get; set; }
    public Action? OnPickDownloadDir { get; set; }
    public Action? OnOpenDownloadDir { get; set; }
    public Action? OnClose { get; set; }

    private bool _suppressSelection;
    private readonly ToolResultWindow _result = new();
    private Window? _host;

    public ToolsPanel()
    {
        InitializeComponent();
        DownloadTasks.Changed += ReloadDownloads;
    }

    /// <summary>浮窗是否已显示（看独立 host 窗口，不看 MainWindow 树里的 0×0 占位）。</summary>
    public bool IsOpen => _host is { IsVisible: true };

    /// <summary>
    /// 确保有一个独立 Owner 窗口承载本控件。
    /// 从 MainWindow 视觉树摘出后塞进 host，终端 WebView2 HWND 完全不受影响。
    /// </summary>
    private void EnsureHost()
    {
        if (_host != null) return;

        // 从 MainWindow 树摘出（0×0 占位），再作为 Content 放进独立窗口。
        if (Parent is Panel panel)
            panel.Children.Remove(this);
        else if (Parent is Decorator decorator)
            decorator.Child = null;
        else if (Parent is ContentControl cc)
            cc.Content = null;

        // 恢复正常尺寸（XAML 里 Width/Height=0 只是占位）
        Width = double.NaN;
        Height = double.NaN;
        Visibility = Visibility.Visible;
        IsHitTestVisible = true;

        // 紧凑可缩放：默认 SizeToContent，用户可拖大；禁止被主窗 0.85 拉伸（UpdateChildWindowsSize 跳过 SizeToContent）。
        _host = new Window
        {
            Title = "工具 / 下载",
            Content = this,
            SizeToContent = SizeToContent.WidthAndHeight,
            MinWidth = 200,
            MinHeight = 160,
            MaxWidth = 480,
            MaxHeight = 520,
            ResizeMode = ResizeMode.CanResizeWithGrip,
            WindowStyle = WindowStyle.None,
            AllowsTransparency = true,
            ShowInTaskbar = false,
            Topmost = true,
            Background = Brushes.Transparent,
            WindowStartupLocation = WindowStartupLocation.Manual,
            Tag = "NoAutoResize",
        };
        // 用户开始拖缩放后改为 Manual，避免 SizeToContent 抢回尺寸
        _host.SizeChanged += (_, _) =>
        {
            if (_host is { SizeToContent: not SizeToContent.Manual, ActualWidth: > 0 })
            {
                // 首次布局后保持紧凑；仅当用户明显拉大时切 Manual
                if (_host.ActualWidth > 280 || _host.ActualHeight > 360)
                {
                    _host.SizeToContent = SizeToContent.Manual;
                    if (Card != null)
                    {
                        Card.Width = double.NaN;
                        Card.HorizontalAlignment = HorizontalAlignment.Stretch;
                        Card.VerticalAlignment = VerticalAlignment.Stretch;
                    }
                }
            }
        };
        // 关窗只 Hide，复用同一 host；不 Deactivated 自动关（文件夹选择器/结果窗会抢焦点导致闪关）。
        _host.Closing += (_, e) =>
        {
            e.Cancel = true;
            HideFlyout();
        };
        _host.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                HideFlyout();
                e.Handled = true;
            }
        };
    }

    public void Show()
    {
        EnsureHost();
        ReloadSessions();
        ReloadDownloads();

        if (Application.Current.MainWindow is Window owner && owner != _host)
        {
            _host!.Owner = owner;
            // 顶栏靠右：工具按钮附近
            try
            {
                // 紧凑卡片 ~220 宽：贴顶栏工具按钮附近，不盖满半屏
                double ox = owner.Left + owner.ActualWidth - 260;
                double oy = owner.Top + 48;
                if (ox < owner.Left + 12) ox = owner.Left + 12;
                if (oy < owner.Top + 12) oy = owner.Top + 48;
                _host.Left = ox;
                _host.Top = oy;
            }
            catch
            {
                _host!.WindowStartupLocation = WindowStartupLocation.CenterOwner;
            }
        }

        _host!.Show();
        _host.Activate();
        Focus();
    }

    public void HideFlyout()
    {
        if (_host is { IsVisible: true })
            _host.Hide();
        OnClose?.Invoke();
    }

    private void ReloadDownloads()
    {
        if (DlList == null) return;
        DlList.Children.Clear();
        var tasks = DownloadTasks.Items;
        DlEmpty.Visibility = tasks.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        foreach (var t in tasks.Take(20)) DlList.Children.Add(DownloadRow(t));
    }

    private UIElement DownloadRow(DownloadTasks.Task t)
    {
        var (color, text) = t.State switch
        {
            DownloadTasks.State.Running => (Color.FromRgb(0x0A, 0x84, 0xFF), "下载中"),
            DownloadTasks.State.Done    => (Color.FromRgb(0x30, 0xD1, 0x58), "完成"),
            _                           => (Color.FromRgb(0xFF, 0x45, 0x3A),
                                            string.IsNullOrEmpty(t.Detail) ? "失败" : "失败 · " + t.Detail),
        };
        var row = new DockPanel { Margin = new Thickness(8, 3, 8, 3) };
        row.Children.Add(new System.Windows.Shapes.Ellipse
        {
            Width = 6, Height = 6, Fill = new SolidColorBrush(color),
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0),
        });
        var state = new TextBlock
        {
            Text = text, FontSize = 10, Foreground = (Brush)Application.Current.Resources["BrushMuted"],
            VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis,
        };
        DockPanel.SetDock(state, Dock.Right);
        row.Children.Add(state);
        row.Children.Add(new TextBlock
        {
            Text = t.Name, FontSize = 11, FontWeight = FontWeights.Medium,
            Foreground = (Brush)Application.Current.Resources["BrushText"],
            VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis,
        });
        return row;
    }

    public void SetDownloadPath(string p)
    {
        if (DlPathText != null) DlPathText.Text = p;
    }

    public void ReloadSessions()
    {
        if (HostCombo == null) return;
        _suppressSelection = true;
        HostCombo.Items.Clear();
        var list = SessionsProvider?.Invoke() ?? new List<(string, bool)>();
        if (list.Count == 0)
        {
            HostCombo.Items.Add("无活动会话");
            HostCombo.IsEnabled = false;
            HostCombo.SelectedIndex = 0;
            _suppressSelection = false;
            return;
        }
        HostCombo.IsEnabled = true;
        int activeIdx = 0;
        for (int i = 0; i < list.Count; i++)
        {
            HostCombo.Items.Add(list[i].title);
            if (list[i].active) activeIdx = i;
        }
        HostCombo.SelectedIndex = activeIdx;
        _suppressSelection = false;
    }

    private void HostCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressSelection) return;
        OnSelectSession?.Invoke(HostCombo.SelectedIndex);
    }

    private void Close_Click(object sender, RoutedEventArgs e) => HideFlyout();
    private void PickDir_Click(object sender, RoutedEventArgs e) => OnPickDownloadDir?.Invoke();
    private void OpenDir_Click(object sender, RoutedEventArgs e) => OnOpenDownloadDir?.Invoke();

    private void Process_Click(object sender, RoutedEventArgs e) => Run("进程管理", CmdProcess);
    private void Network_Click(object sender, RoutedEventArgs e) => Run("网络监控", CmdNetwork);
    private void Speed_Click(object sender, RoutedEventArgs e) => Run("速度测试", CmdSpeed);

    private void Route_Click(object sender, RoutedEventArgs e)
    {
        var host = PromptText("路由追踪", "输入目标主机 / IP", "1.1.1.1");
        if (string.IsNullOrWhiteSpace(host)) return;
        Run($"路由追踪 {host}", CmdRoute(host));
    }

    private async void Run(string label, string cmd) => await RunAsync(label, cmd);

    public async Task RunAsync(string label, string cmd)
    {
        if (OnExec == null) { _result.ShowText("未连接会话", label); return; }
        _result.ShowRunning(label);
        var result = await OnExec(cmd);
        _result.ShowText(string.IsNullOrEmpty(result) ? $"{label}: 无输出（远端可能缺少该命令）" : result, label);
    }

    private void Card_MouseDown(object sender, MouseButtonEventArgs e) => e.Handled = true;
    private void Root_MouseDown(object sender, MouseButtonEventArgs e) => HideFlyout();
    private void Root_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) { HideFlyout(); e.Handled = true; }
    }

    private static string? PromptText(string title, string message, string defaultValue)
    {
        var win = new Window
        {
            Background = (Brush)Application.Current.Resources["BrushBg"],
            Foreground = (Brush)Application.Current.Resources["BrushText"],
            Title = title, Width = 320, Height = 150,
            WindowStartupLocation = WindowStartupLocation.CenterScreen,
            ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false
        };
        var sp = new StackPanel { Margin = new Thickness(12) };
        sp.Children.Add(new TextBlock { Text = message, Margin = new Thickness(0, 0, 0, 6) });
        var tb = new TextBox { Text = defaultValue };
        sp.Children.Add(tb);
        var ok = new Button { Content = "开始", Width = 70, Margin = new Thickness(0, 12, 0, 0), HorizontalAlignment = HorizontalAlignment.Right, IsDefault = true };
        string? result = null;
        ok.Click += (_, _) => { result = tb.Text; win.DialogResult = true; };
        sp.Children.Add(ok);
        win.Content = sp;
        tb.Focus(); tb.SelectAll();
        return win.ShowDialog() == true ? result : null;
    }
}
