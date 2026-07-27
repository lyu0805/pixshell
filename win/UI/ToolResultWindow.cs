using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace PixShell.UI;

/// <summary>
/// 工具结果窗口（路由追踪 / 进程管理 / 网络监控 / 速度测试的输出）。
///
/// 为什么单独开窗：老仓库里这几个动作是 <c>data-act="tab-route|tab-process|tab-network"</c>，
/// 结果开在**中央工作区的标签页**里，而不是塞在那个 360px 的工具浮窗内 —— 工具浮窗本身
/// 只放主机下拉/工具入口/下载任务。原生端没有"任务标签页"这层，用一个独立窗口承载等价角色。
/// 对齐 mac UI/ToolResultWindow.swift。
///
/// 纯代码构建（不配 XAML）：内容只有标题 + 一个等宽只读文本框，为它单开一套 XAML 不划算。
/// </summary>
public sealed class ToolResultWindow
{
    private Window? _window;
    private TextBlock? _title;
    private TextBox? _body;

    private void EnsureWindow()
    {
        if (_window != null) return;

        _title = new TextBlock
        {
            FontSize = 12, FontWeight = FontWeights.SemiBold,
            Foreground = (Brush)Application.Current.Resources["BrushText"],
            Margin = new Thickness(0, 0, 0, 8),
        };
        _body = new TextBox
        {
            IsReadOnly = true, TextWrapping = TextWrapping.NoWrap, AcceptsReturn = true,
            BorderThickness = new Thickness(0), Background = Brushes.Transparent, Padding = new Thickness(8),
            FontFamily = (FontFamily)Application.Current.Resources["FontMono"], FontSize = 11,
            Foreground = (Brush)Application.Current.Resources["BrushText"],
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
        };

        var box = new Border
        {
            Background = (Brush)Application.Current.Resources["BrushBg"],
            BorderBrush = (Brush)Application.Current.Resources["BrushBorder"],
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(7),
            Child = _body,
        };

        var root = new DockPanel { Margin = new Thickness(14) };
        DockPanel.SetDock(_title, Dock.Top);
        root.Children.Add(_title);
        root.Children.Add(box);

        _window = new Window
        {

            Title = "工具",
            Width = 760, Height = 480, MinWidth = 520, MinHeight = 320,
            WindowStartupLocation = WindowStartupLocation.CenterScreen,
            Background = (Brush)Application.Current.Resources["BrushBg2"],
            Content = root,
        };
        // 关掉只隐藏，下次复用同一个窗口（否则每次工具动作都新开一个窗）。
        _window.Closing += (_, e) => { e.Cancel = true; _window!.Hide(); };
    }

    private void Present(string label)
    {
        EnsureWindow();
        _title!.Text = label;
        _window!.Show();
        _window.Activate();
    }

    public void ShowRunning(string label)
    {
        Present(label);
        _body!.Text = $"{label} 执行中…";
    }

    public void ShowText(string text, string label = "工具")
    {
        Present(label);
        _body!.Text = text;
    }
}
