using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace PixShell.UI;

/// <summary>
/// 主机指纹管理（对齐 mac UI/FingerprintManager.swift）。
/// 列出 %USERPROFILE%\.ssh\known_hosts 条目（主机 / 类型 / SHA256·MD5），支持删除。
/// 纯代码构建（与 KeyManagerWindow 同样取舍）。
/// </summary>
public sealed class FingerprintManagerWindow
{
    private Window? _window;
    private StackPanel? _list;
    private TextBlock? _count;
    private List<KnownHosts.Entry> _entries = new();

    private static Brush B(string key) => (Brush)Application.Current.Resources[key];

    public void Show(Window owner)
    {
        if (_window == null) Build(owner);
        Reload();
        _window!.Show();
        _window.Activate();
    }

    private void Build(Window owner)
    {
        _count = new TextBlock { FontSize = 12, Foreground = B("BrushMuted"), Margin = new Thickness(0, 0, 0, 8) };
        _list = new StackPanel();

        var refBtn = new Button { Content = "刷新", Style = (Style)Application.Current.Resources["PillButton"], Margin = new Thickness(0, 0, 6, 0) };
        refBtn.Click += (_, _) => Reload();
        var closeBtn = new Button { Content = "关闭", Style = (Style)Application.Current.Resources["PillButton"] };
        closeBtn.Click += (_, _) => _window!.Hide();

        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        var btns = new StackPanel { Orientation = Orientation.Horizontal };
        btns.Children.Add(refBtn); btns.Children.Add(closeBtn);
        DockPanel.SetDock(btns, Dock.Right);
        head.Children.Add(btns);
        head.Children.Add(new TextBlock
        {
            Text = "主机指纹管理", FontSize = 15, FontWeight = FontWeights.SemiBold,
            Foreground = B("BrushText"), VerticalAlignment = VerticalAlignment.Center,
        });

        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = _list };

        var root = new DockPanel { Margin = new Thickness(14) };
        DockPanel.SetDock(head, Dock.Top);
        DockPanel.SetDock(_count, Dock.Top);
        root.Children.Add(head);
        root.Children.Add(_count);
        root.Children.Add(scroll);

        _window = new Window
        {
            Title = "主机指纹管理", Owner = owner,
            Width = 380, Height = 400, MinWidth = 320, MinHeight = 280,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            WindowStyle = WindowStyle.ToolWindow,
            ResizeMode = ResizeMode.CanResizeWithGrip,
            ShowInTaskbar = false,
            Background = B("BrushBg"),
            Content = root,
        };
        _window.Closing += (_, e) => { e.Cancel = true; _window!.Hide(); };
    }

    private void Reload()
    {
        _entries = KnownHosts.List();
        _count!.Text = _entries.Count == 0
            ? "~/.ssh/known_hosts 为空 —— 首次 SSH 连接后会自动写入"
            : $"{_entries.Count} 条指纹 · {KnownHosts.Path}";
        _list!.Children.Clear();
        foreach (var e in _entries) _list.Children.Add(Row(e));
    }

    private UIElement Row(KnownHosts.Entry e)
    {
        var box = new Border
        {
            Background = B("BrushBg2"), BorderBrush = B("BrushBorder"), BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(7), Padding = new Thickness(12, 10, 12, 10),
            Margin = new Thickness(0, 0, 0, 8),
        };

        var top = new StackPanel { Orientation = Orientation.Horizontal };
        top.Children.Add(new TextBlock
        {
            Text = e.Hosts, FontSize = 13, FontWeight = FontWeights.SemiBold,
            Foreground = B("BrushText"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0),
            TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 200,
        });
        top.Children.Add(Chips.Badge(e.KeyTypeShort));
        if (!string.IsNullOrEmpty(e.Marker))
            top.Children.Add(Chips.Badge(e.Marker!));

        var sha = new TextBlock
        {
            Text = e.FingerprintSHA256, FontSize = 11, FontFamily = (FontFamily)Application.Current.Resources["FontMono"],
            Foreground = B("BrushMuted"), Margin = new Thickness(0, 4, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var md5 = new TextBlock
        {
            Text = e.FingerprintMD5, FontSize = 11, FontFamily = (FontFamily)Application.Current.Resources["FontMono"],
            Foreground = B("BrushMuted"), Margin = new Thickness(0, 2, 0, 6), TextTrimming = TextTrimming.CharacterEllipsis,
        };

        var delBtn = new Button { Content = "删除指纹", Style = (Style)Application.Current.Resources["PillButton"], FontSize = 11 };
        delBtn.Click += (_, _) => DeleteFlow(e);

        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        row.Children.Add(delBtn);

        var v = new StackPanel();
        v.Children.Add(top); v.Children.Add(sha); v.Children.Add(md5); v.Children.Add(row);
        box.Child = v;
        return box;
    }

    private void DeleteFlow(KnownHosts.Entry e)
    {
        var r = MessageBox.Show(_window!,
            $"将从 known_hosts 移除：\n{e.Hosts}  ·  {e.KeyTypeShort}\n\n下次连接该主机时会重新确认主机密钥。",
            "删除主机指纹？", MessageBoxButton.OKCancel, MessageBoxImage.Warning);
        if (r != MessageBoxResult.OK) return;
        KnownHosts.Delete(e);
        Reload();
    }
}
