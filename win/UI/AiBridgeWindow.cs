using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using PixShell.Bridge;
using PixShell.Logging;

namespace PixShell.UI;

/// <summary>
/// AI 工具 SSH 桥接注册窗口（汉堡菜单「一键注册 AI 默认 SSH…」）。
///
/// 纯代码构建（不配 XAML）：与 KeyManagerWindow / FingerprintManagerWindow 同样取舍。
/// 铁律：ToolWindow + CanResizeWithGrip；BrushBg / BrushText 动态资源，零色差。
/// </summary>
public sealed class AiBridgeWindow
{
    private Window? _window;
    private TextBlock? _statusLine;
    private TextBlock? _detailLine;
    private WrapPanel? _toolBadges;
    private TextBlock? _pathLine;
    private Func<int>? _bridgePort;
    private Action<string>? _onStatus;

    private static Brush B(string key) => (Brush)Application.Current.Resources[key];

    /// <summary>取当前桥端口（注册时写进 AgentCLI 脚本）。桥未起时回落 DefaultPort。</summary>
    public Func<int>? BridgePortProvider
    {
        get => _bridgePort;
        set => _bridgePort = value;
    }

    /// <summary>主窗状态栏回调（可选）。</summary>
    public Action<string>? OnStatus
    {
        get => _onStatus;
        set => _onStatus = value;
    }

    public void Show(Window owner)
    {
        if (_window == null) Build(owner);
        Refresh();
        _window!.Show();
        _window.Activate();
    }

    private void Build(Window owner)
    {
        var title = new TextBlock
        {
            Text = "AI 工具 SSH 桥接",
            FontSize = 15,
            FontWeight = FontWeights.SemiBold,
            Foreground = B("BrushText"),
            Margin = new Thickness(0, 0, 0, 8),
        };

        var desc = new TextBlock
        {
            Text = "将 PixShell 设为 Claude Code / Codex / OpenCode 等 AI 工具的默认交互式 SSH 引擎。",
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            Foreground = B("BrushMuted"),
            Margin = new Thickness(0, 0, 0, 12),
        };

        _statusLine = new TextBlock
        {
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = B("BrushText"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 6),
        };

        _toolBadges = new WrapPanel { Margin = new Thickness(0, 0, 0, 8) };

        _detailLine = new TextBlock
        {
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            Foreground = B("BrushMuted"),
            Margin = new Thickness(0, 0, 0, 6),
        };

        _pathLine = new TextBlock
        {
            FontSize = 10.5,
            TextWrapping = TextWrapping.Wrap,
            FontFamily = (FontFamily)Application.Current.Resources["FontMono"],
            Foreground = B("BrushMuted"),
            Margin = new Thickness(0, 0, 0, 12),
        };

        var regBtn = new Button
        {
            Content = "一键注册为 AI 默认 SSH 工具",
            Style = (Style)Application.Current.Resources["PillButton"],
            Tag = "Primary",
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(12, 8, 12, 8),
            Margin = new Thickness(0, 0, 0, 8),
            FontSize = 12,
        };
        regBtn.Click += (_, _) => DoRegister();

        var unregBtn = new Button
        {
            Content = "一键取消注册",
            Style = (Style)Application.Current.Resources["PillButton"],
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(12, 6, 12, 6),
            Margin = new Thickness(0, 0, 0, 8),
            FontSize = 12,
        };
        unregBtn.Click += (_, _) => DoUnregister();

        var refreshBtn = new Button
        {
            Content = "重新探测 AI 工具",
            Style = (Style)Application.Current.Resources["PillButton"],
            Margin = new Thickness(0, 0, 8, 0),
            Padding = new Thickness(10, 4, 10, 4),
            FontSize = 11,
        };
        refreshBtn.Click += (_, _) => Refresh();

        var closeBtn = new Button
        {
            Content = "关闭",
            Style = (Style)Application.Current.Resources["PillButton"],
            Padding = new Thickness(10, 4, 10, 4),
            FontSize = 11,
            IsCancel = true,
        };
        closeBtn.Click += (_, _) => _window!.Hide();

        var foot = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 4, 0, 0),
        };
        foot.Children.Add(refreshBtn);
        foot.Children.Add(closeBtn);

        var body = new StackPanel();
        body.Children.Add(title);
        body.Children.Add(desc);
        body.Children.Add(_statusLine);
        body.Children.Add(_toolBadges);
        body.Children.Add(_detailLine);
        body.Children.Add(_pathLine);
        body.Children.Add(regBtn);
        body.Children.Add(unregBtn);
        body.Children.Add(foot);

        var root = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = new Border
            {
                Padding = new Thickness(14),
                Child = body,
            },
        };

        _window = new Window
        {
            Title = "AI 工具 SSH 桥接",
            Owner = owner,
            Width = 380,
            Height = 360,
            MinWidth = 320,
            MinHeight = 260,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            WindowStyle = WindowStyle.ToolWindow,
            ResizeMode = ResizeMode.CanResizeWithGrip,
            ShowInTaskbar = false,
            Background = B("BrushBg"),
            Foreground = B("BrushText"),
            Content = root,
        };
        // 关掉只隐藏，下次复用
        _window.Closing += (_, e) => { e.Cancel = true; _window!.Hide(); };
    }

    private int ResolvePort()
    {
        try
        {
            var p = _bridgePort?.Invoke() ?? 0;
            return p > 0 ? p : AgentBridge.DefaultPort;
        }
        catch { return AgentBridge.DefaultPort; }
    }

    private void Refresh()
    {
        var snap = AiSshRegister.Snapshot(ResolvePort());
        if (_statusLine != null)
        {
            _statusLine.Text = snap.Registered
                ? "状态：已注册为 AI 默认 SSH"
                : "状态：未注册";
            _statusLine.Foreground = snap.Registered
                ? new SolidColorBrush(Color.FromRgb(0x30, 0xD1, 0x58))
                : B("BrushText");
        }

        if (_toolBadges != null)
        {
            _toolBadges.Children.Clear();
            if (snap.DetectedTools.Count == 0)
            {
                _toolBadges.Children.Add(Chips.Badge("未检测到 AI 工具", Chips.BadgeKind.Gray));
            }
            else
            {
                _toolBadges.Children.Add(Chips.Badge($"已检测 {snap.DetectedTools.Count} 个", Chips.BadgeKind.Accent));
                foreach (var t in snap.DetectedTools)
                    _toolBadges.Children.Add(Pad(Chips.Badge(t.Display, Chips.BadgeKind.Green)));
            }
        }

        if (_detailLine != null)
        {
            if (snap.DetectedTools.Count == 0)
            {
                _detailLine.Text = "本机 PATH 中未找到 Claude Code / Codex / Grok / OpenCode / Cursor / Windsurf / Ollama。\n" +
                                   "仍可注册：装好工具后新开进程即可吃到 PixShell SSH 包装器。";
            }
            else
            {
                _detailLine.Text = "已检测到：" + string.Join("、", snap.DetectedTools.Select(t => t.Display)) +
                                   "。\n注册 / 取消会对上述工具生效（新开进程读取用户 PATH）。";
            }
        }

        if (_pathLine != null)
        {
            _pathLine.Text =
                $"bin：{snap.BinDir}\n" +
                $"ssh.cmd：{(snap.SshCmdPresent ? "已就位" : "无")}" +
                $" · PATH：{(snap.PathContainsBin ? "已前置" : "未包含")}";
        }
    }

    private static UIElement Pad(UIElement el)
    {
        return new Border { Child = el, Margin = new Thickness(0, 4, 6, 0) };
    }

    private void DoRegister()
    {
        var port = ResolvePort();
        Log.Info($"AI SSH 一键注册 port={port}", "ui");
        var r = AiSshRegister.Register(port);
        Refresh();
        _onStatus?.Invoke(r.Ok ? "已注册 AI 默认 SSH" : ("注册失败：" + r.Message));
        MessageBox.Show(_window, r.Message, r.Ok ? "注册完成" : "注册失败",
            MessageBoxButton.OK, r.Ok ? MessageBoxImage.Information : MessageBoxImage.Warning);
    }

    private void DoUnregister()
    {
        Log.Info("AI SSH 一键取消注册", "ui");
        var r = AiSshRegister.Unregister();
        Refresh();
        _onStatus?.Invoke(r.Ok ? "已取消 AI 默认 SSH 注册" : ("取消失败：" + r.Message));
        MessageBox.Show(_window, r.Message, r.Ok ? "已取消注册" : "取消失败",
            MessageBoxButton.OK, r.Ok ? MessageBoxImage.Information : MessageBoxImage.Warning);
    }
}
