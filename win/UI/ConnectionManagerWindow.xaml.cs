using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace PixShell.UI;

/// <summary>连接管理器独立弹窗：按分组列出全部主机 + 连接/编辑/删除 + 新建（对齐 mac ConnManager）。</summary>
public partial class ConnectionManagerWindow : Window
{
    public Func<List<HostEntry>>? HostsProvider { get; set; }
    public Action<HostEntry>? OnConnect { get; set; }
    public Action? OnNew { get; set; }
    public Action<HostEntry>? OnEdit { get; set; }
    public Action<HostEntry>? OnDelete { get; set; }
    public Action? OnClose { get; set; }
    /// <summary>＋分组：把当前无分组（"默认"）的主机移入新分组。</summary>
    public Action<string>? OnCreateGroup { get; set; }
    /// <summary>分组重命名：旧名 → 新名。</summary>
    public Action<string, string>? OnRenameGroup { get; set; }
    /// <summary>删除分组：组内主机移回"默认"，不删主机。</summary>
    public Action<string>? OnDeleteGroup { get; set; }

    /// <summary>已折叠的分组名（对齐 mac ConnManager.collapsed）。</summary>
    private readonly HashSet<string> _collapsed = new(StringComparer.Ordinal);

    public ConnectionManagerWindow()
    {
        InitializeComponent();
        SourceInitialized += (s, e) => WindowInterop.ApplyBackdrop(this, ThemeManager.IsDark);
    }

    public new void Show() { Reload(); base.Show(); Focus(); }

    public void Reload()
    {
        ListPanel.Children.Clear();
        var hosts = HostsProvider?.Invoke() ?? new List<HostEntry>();
        if (hosts.Count == 0)
        {
            ListPanel.Children.Add(new TextBlock
            {
                Text = "暂无主机 —— 点右上角「＋ 新建主机」添加一台",
                Foreground = (Brush)Application.Current.Resources["BrushMuted"], Margin = new Thickness(4, 12, 0, 0)
            });
            return;
        }
        foreach (var group in hosts.GroupBy(h => string.IsNullOrWhiteSpace(h.Group) ? "默认" : h.Group)
                                   .OrderBy(g => g.Key == "默认" ? 1 : 0)
                                   .ThenBy(g => g.Key, StringComparer.Ordinal))
        {
            var name = group.Key;
            var list = group.ToList();

            // Create a Border representing the group card, styled matching Theme.bg2 / Theme.border
            var groupBorder = new Border
            {
                Background = (Brush)Application.Current.Resources["BrushBg2"],
                BorderBrush = (Brush)Application.Current.Resources["BrushBorder"],
                BorderThickness = new Thickness(1),
                CornerRadius = (CornerRadius)Application.Current.Resources["RadiusSm"],
                Padding = new Thickness(10, 8, 10, 8),
                Margin = new Thickness(0, 0, 0, 10)
            };

            var groupStack = new StackPanel { Orientation = Orientation.Vertical };

            // Add Header
            var header = BuildGroupHeader(name, list.Count);
            groupStack.Children.Add(header);

            if (!_collapsed.Contains(name))
            {
                // 分组内独立滚动：MaxHeight 压矮，Visible 强制出滑块轨道
                var hostsScroll = new ScrollViewer
                {
                    VerticalScrollBarVisibility = ScrollBarVisibility.Visible,
                    HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                    Margin = new Thickness(0, 6, 0, 0),
                    MaxHeight = 140, // 约 4 行主机；再矮一点保证多主机时一定出滑块
                    CanContentScroll = false,
                    PanningMode = PanningMode.VerticalOnly
                };

                // Add mouse wheel redirection to bubble scroll to parent ScrollViewer when boundaries are hit
                hostsScroll.PreviewMouseWheel += (sender, e) =>
                {
                    if (sender is ScrollViewer sv)
                    {
                        if (sv.ScrollableHeight <= 0)
                        {
                            var parent = FindAncestor<ScrollViewer>(sv);
                            if (parent != null)
                            {
                                e.Handled = true;
                                var eventArg = new MouseWheelEventArgs(e.MouseDevice, e.Timestamp, e.Delta)
                                {
                                    RoutedEvent = UIElement.MouseWheelEvent,
                                    Source = sv
                                };
                                parent.RaiseEvent(eventArg);
                            }
                        }
                        else
                        {
                            bool isAtTop = sv.VerticalOffset <= 0;
                            bool isAtBottom = sv.VerticalOffset >= sv.ScrollableHeight;
                            if ((e.Delta > 0 && isAtTop) || (e.Delta < 0 && isAtBottom))
                            {
                                var parent = FindAncestor<ScrollViewer>(sv);
                                if (parent != null)
                                {
                                    e.Handled = true;
                                    var eventArg = new MouseWheelEventArgs(e.MouseDevice, e.Timestamp, e.Delta)
                                    {
                                        RoutedEvent = UIElement.MouseWheelEvent,
                                        Source = sv
                                    };
                                    parent.RaiseEvent(eventArg);
                                }
                            }
                        }
                    }
                };

                var hostsStack = new StackPanel { Orientation = Orientation.Vertical };
                foreach (var h in list)
                {
                    hostsStack.Children.Add(BuildRow(h));
                }

                hostsScroll.Content = hostsStack;
                groupStack.Children.Add(hostsScroll);
            }

            groupBorder.Child = groupStack;
            ListPanel.Children.Add(groupBorder);
        }
    }

    /// <summary>分组标题行：▶/▼ + 名称 + 数量 + 重命名/删除。点击标题折叠/展开（对齐 mac）。</summary>
    private UIElement BuildGroupHeader(string name, int count)
    {
        var collapsed = _collapsed.Contains(name);
        var panel = new DockPanel
        {
            Margin = new Thickness(4, 10, 0, 4),
            LastChildFill = true,
            Cursor = Cursors.Hand,
            Background = Brushes.Transparent, // 让整行可点
        };
        panel.MouseLeftButtonUp += (_, e) =>
        {
            // 点按钮时不折叠
            if (e.OriginalSource is DependencyObject d && FindAncestor<Button>(d) != null) return;
            if (_collapsed.Contains(name)) _collapsed.Remove(name); else _collapsed.Add(name);
            Reload();
        };

        if (name != "默认")
        {
            var delBtn = new Button { Content = "删除分组", Tag = "Danger", Style = (Style)Application.Current.Resources["PillButton"], Margin = new Thickness(6, 0, 0, 0) };
            delBtn.Click += (_, _) => DeleteGroup(name);
            var renameBtn = new Button { Content = "重命名", Style = (Style)Application.Current.Resources["PillButton"], Margin = new Thickness(10, 0, 0, 0) };
            renameBtn.Click += (_, _) => RenameGroup(name);
            DockPanel.SetDock(delBtn, Dock.Right);
            DockPanel.SetDock(renameBtn, Dock.Right);
            panel.Children.Add(delBtn);
            panel.Children.Add(renameBtn);
        }

        var arrow = new TextBlock
        {
            Text = collapsed ? "▶" : "▼", FontSize = 10, Width = 14,
            Foreground = (Brush)Application.Current.Resources["BrushMuted"],
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0),
        };
        var title = new TextBlock
        {
            Text = $"📁 {name}  ({count})", FontWeight = FontWeights.Bold, FontSize = 12,
            Foreground = (Brush)Application.Current.Resources["BrushAccent"],
            VerticalAlignment = VerticalAlignment.Center,
        };
        var left = new StackPanel { Orientation = Orientation.Horizontal };
        left.Children.Add(arrow);
        left.Children.Add(title);
        panel.Children.Add(left);
        return panel;
    }

    private static T? FindAncestor<T>(DependencyObject? start) where T : DependencyObject
    {
        while (start != null)
        {
            if (start is T hit) return hit;
            start = VisualTreeHelper.GetParent(start);
        }
        return null;
    }

    private void NewGroup_Click(object sender, RoutedEventArgs e)
    {
        var name = PromptText("新建分组", "输入分组名称（当前分组为「默认」的主机会移入该分组）：", "");
        if (string.IsNullOrEmpty(name)) return;
        OnCreateGroup?.Invoke(name);
        Reload();
    }

    private void RenameGroup(string oldName)
    {
        var name = PromptText("重命名分组", $"把「{oldName}」改名为：", oldName);
        if (string.IsNullOrEmpty(name) || name == oldName) return;
        OnRenameGroup?.Invoke(oldName, name);
        Reload();
    }

    private void DeleteGroup(string name)
    {
        if (MessageBox.Show(this, $"删除分组「{name}」？该组内主机不会被删除，会移回「默认」分组。",
                "PixShell", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
        OnDeleteGroup?.Invoke(name);
        Reload();
    }

    private string? PromptText(string title, string message, string preset)
    {
        var win = new Window
        {

            Background = (System.Windows.Media.Brush)System.Windows.Application.Current.Resources["BrushBg"],
            Foreground = (System.Windows.Media.Brush)System.Windows.Application.Current.Resources["BrushText"],
            Title = title, Width = 340, SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, Owner = this,
            ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false
        };
        var sp = new StackPanel { Margin = new Thickness(14) };
        sp.Children.Add(new TextBlock { Text = message, Margin = new Thickness(0, 0, 0, 8), TextWrapping = TextWrapping.Wrap });
        var tb = new TextBox { Text = preset };
        sp.Children.Add(tb);
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        var ok = new Button { Content = "确定", Width = 72, Margin = new Thickness(0, 0, 8, 0), IsDefault = true };
        var cancel = new Button { Content = "取消", Width = 72, IsCancel = true };
        var okClicked = false;
        ok.Click += (_, _) => { okClicked = true; win.DialogResult = true; };
        row.Children.Add(ok); row.Children.Add(cancel);
        sp.Children.Add(row);
        win.Content = sp;
        tb.Focus(); tb.SelectAll();
        var result = win.ShowDialog();
        return (result == true && okClicked) ? tb.Text.Trim() : null;
    }

    private UIElement BuildRow(HostEntry h)
    {
        var row = new Border
        {
            Background = (Brush)Application.Current.Resources["BrushBg"],
            BorderBrush = (Brush)Application.Current.Resources["BrushBorder"],
            BorderThickness = new Thickness(1),
            CornerRadius = (CornerRadius)Application.Current.Resources["RadiusSm"],
            Padding = new Thickness(10, 8, 10, 8),
            Margin = new Thickness(0, 0, 0, 6),
        };
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var info = new Grid();
        info.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        info.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var nameTxt = new TextBlock
        {
            Text = h.Display,
            FontWeight = FontWeights.SemiBold,
            Foreground = (Brush)Application.Current.Resources["BrushText"],
            TextTrimming = TextTrimming.CharacterEllipsis
        };
        Grid.SetRow(nameTxt, 0);
        info.Children.Add(nameTxt);

        var subTxt = new TextBlock
        {
            Text = h.Subtitle,
            FontSize = 11,
            FontFamily = (FontFamily)Application.Current.Resources["FontMono"],
            Foreground = (Brush)Application.Current.Resources["BrushMuted"],
            TextTrimming = TextTrimming.CharacterEllipsis
        };
        Grid.SetRow(subTxt, 1);
        info.Children.Add(subTxt);

        Grid.SetColumn(info, 0);

        var btns = new StackPanel { Orientation = Orientation.Horizontal };
        var connectBtn = new Button { Content = "连接", Tag = "Primary", Style = (Style)Application.Current.Resources["PillButton"], Margin = new Thickness(0, 0, 6, 0) };
        connectBtn.Click += (_, _) => OnConnect?.Invoke(h);
        var editBtn = new Button { Content = "编辑", Style = (Style)Application.Current.Resources["PillButton"], Margin = new Thickness(0, 0, 6, 0) };
        editBtn.Click += (_, _) => OnEdit?.Invoke(h);
        var delBtn = new Button { Content = "删除", Tag = "Danger", Style = (Style)Application.Current.Resources["PillButton"] };
        delBtn.Click += (_, _) => { OnDelete?.Invoke(h); Reload(); };
        btns.Children.Add(connectBtn); btns.Children.Add(editBtn); btns.Children.Add(delBtn);
        Grid.SetColumn(btns, 1);

        grid.Children.Add(info); grid.Children.Add(btns);
        row.Child = grid;
        return row;
    }

    private void New_Click(object sender, RoutedEventArgs e) => OnNew?.Invoke();
    private void Close_Click(object sender, RoutedEventArgs e) { OnClose?.Invoke(); Close(); }
    
    private void Window_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        DragMove();
    }
    
    private void Window_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) { OnClose?.Invoke(); Close(); }
    }
}
