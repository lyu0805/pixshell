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

    public ConnectionManagerWindow()
    {
        InitializeComponent();
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
        foreach (var group in hosts.GroupBy(h => string.IsNullOrWhiteSpace(h.Group) ? "默认" : h.Group))
        {
            ListPanel.Children.Add(BuildGroupHeader(group.Key, group.Count()));
            foreach (var h in group) ListPanel.Children.Add(BuildRow(h));
        }
    }

    /// <summary>分组标题行：名称 + 数量 + 重命名/删除（"默认"分组是隐式的，不提供重命名/删除）。</summary>
    private UIElement BuildGroupHeader(string name, int count)
    {
        var panel = new DockPanel { Margin = new Thickness(4, 10, 0, 4), LastChildFill = false };
        var title = new TextBlock
        {
            Text = $"{name} ({count})", FontWeight = FontWeights.Bold, FontSize = 12,
            Foreground = (Brush)Application.Current.Resources["BrushAccent"], VerticalAlignment = VerticalAlignment.Center
        };
        panel.Children.Add(title);
        if (name != "默认")
        {
            var renameBtn = new Button { Content = "重命名", Style = (Style)Application.Current.Resources["PillButton"], Margin = new Thickness(10, 0, 0, 0) };
            renameBtn.Click += (_, _) => RenameGroup(name);
            var delBtn = new Button { Content = "删除分组", Tag = "Danger", Style = (Style)Application.Current.Resources["PillButton"], Margin = new Thickness(6, 0, 0, 0) };
            delBtn.Click += (_, _) => DeleteGroup(name);
            DockPanel.SetDock(delBtn, Dock.Right);
            DockPanel.SetDock(renameBtn, Dock.Right);
            panel.Children.Add(renameBtn);
            panel.Children.Add(delBtn);
        }
        return panel;
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

        var info = new StackPanel();
        info.Children.Add(new TextBlock { Text = h.Display, FontWeight = FontWeights.SemiBold, Foreground = (Brush)Application.Current.Resources["BrushText"] });
        info.Children.Add(new TextBlock
        {
            Text = h.Subtitle, FontSize = 11, FontFamily = (FontFamily)Application.Current.Resources["FontMono"],
            Foreground = (Brush)Application.Current.Resources["BrushMuted"]
        });
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
