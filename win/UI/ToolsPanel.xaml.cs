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
/// 工具面板（顶栏宫格图标 flyout）。远端命令与 mac UI/ToolsPanel.swift 完全一致，
/// 保证两端"路由追踪/进程管理/网络监控/速度测试"行为对齐。
/// </summary>
public partial class ToolsPanel : UserControl
{
    // 与 mac 版 1:1 一致的远端命令。
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
    public Action? OnCustomAccel { get; set; }
    public Action? OnClose { get; set; }

    private bool _suppressSelection;

    /// <summary>工具输出的承载窗口（进程/网络/路由/测速）——不塞进 360px 浮窗里。</summary>
    private readonly ToolResultWindow _result = new();

    public ToolsPanel()
    {
        InitializeComponent();
        DownloadTasks.Changed += ReloadDownloads;
    }

    /// <summary>浮窗是否已显示（供顶栏图标做"再点一下收起"）。</summary>
    public bool IsOpen => Visibility == Visibility.Visible;

    public void Show()
    {
        Visibility = Visibility.Visible;
        ReloadSessions();
        ReloadDownloads();
        Focus();
    }

    /// <summary>下载任务列表（浮窗主体内容）。</summary>
    private void ReloadDownloads()
    {
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

    public void SetDownloadPath(string p) => DlPathText.Text = p;

    public void ReloadSessions()
    {
        _suppressSelection = true;
        HostCombo.Items.Clear();
        var list = SessionsProvider?.Invoke() ?? new List<(string, bool)>();
        if (list.Count == 0) { HostCombo.Items.Add("无活动会话"); HostCombo.IsEnabled = false; HostCombo.SelectedIndex = 0; _suppressSelection = false; return; }
        HostCombo.IsEnabled = true;
        int activeIdx = 0;
        for (int i = 0; i < list.Count; i++) { HostCombo.Items.Add(list[i].title); if (list[i].active) activeIdx = i; }
        HostCombo.SelectedIndex = activeIdx;
        _suppressSelection = false;
    }

    private void HostCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressSelection) return;
        OnSelectSession?.Invoke(HostCombo.SelectedIndex);
    }

    private void Close_Click(object sender, RoutedEventArgs e) => OnClose?.Invoke();
    private void PickDir_Click(object sender, RoutedEventArgs e) => OnPickDownloadDir?.Invoke();
    private void OpenDir_Click(object sender, RoutedEventArgs e) => OnOpenDownloadDir?.Invoke();
    private void Accel_Click(object sender, RoutedEventArgs e) => OnCustomAccel?.Invoke();

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

    /// <summary>公开版本：供汉堡菜单「进程管理/网络监控」等外部触发复用（对齐 mac toolsPanelRun）。</summary>
    public async Task RunAsync(string label, string cmd)
    {
        if (OnExec == null) { _result.ShowText("未连接会话", label); return; }
        _result.ShowRunning(label);
        var result = await OnExec(cmd);
        _result.ShowText(string.IsNullOrEmpty(result) ? $"{label}: 无输出（远端可能缺少该命令）" : result, label);
    }

    private void Root_MouseDown(object sender, MouseButtonEventArgs e) => OnClose?.Invoke();
    private void Card_MouseDown(object sender, MouseButtonEventArgs e) => e.Handled = true; // 点卡片内部不关闭
    private void Root_KeyDown(object sender, KeyEventArgs e) { if (e.Key == Key.Escape) OnClose?.Invoke(); }

    private static string? PromptText(string title, string message, string defaultValue)
    {
        var win = new Window
        {

            Background = (System.Windows.Media.Brush)System.Windows.Application.Current.Resources["BrushBg"],
            Foreground = (System.Windows.Media.Brush)System.Windows.Application.Current.Resources["BrushText"],
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
