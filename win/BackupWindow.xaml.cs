using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace PixShell;

/// <summary>
/// 备份选项对话框（菜单「云端同步 → 备份选项配置…」）。对齐 mac UI/BackupPanel.swift：
/// 默认全部关闭；7 个 provider 卡（名称+未配置徽章+说明+启用勾选+配置）；
/// 底部「导出本地包…/导入本地包…」+「取消/保存配置」。
/// </summary>
public partial class BackupWindow : Window
{
    private record Provider(string Id, string Name, string Desc);

    private static readonly Provider[] Providers =
    {
        new("local",    "本地",        "导出/导入本机 JSON 备份包（hosts / 设置 / 快捷命令）"),
        new("webdav",   "WebDAV",      "一键打开坚果云等登录页，再填应用密码/路径"),
        new("github",   "GitHub",      "一键登录 GitHub（Device Flow）或浏览器授权，自动写入 Token"),
        new("google",   "谷歌云盘",     "Google Drive API（OAuth 客户端）"),
        new("onedrive", "微软 OneDrive","Microsoft Graph / OneDrive"),
        new("baidu",    "百度网盘",     "百度网盘开放平台应用"),
        new("quark",    "夸克网盘",     "夸克开放能力 / Cookie 会话（按官方文档）"),
    };

    private readonly Dictionary<string, CheckBox> _checks = new();

    /// <summary>已启用的 provider id 集合（Save 后回传给调用方持久化）。</summary>
    public HashSet<string> Enabled { get; private set; } = new();

    public Action? OnExport { get; set; }
    public Action? OnImport { get; set; }
    /// <summary>"webdav" 卡片的「配置」按钮 → 打开真正的 URL/用户名/应用密码设置窗口（MainWindow.WebdavConfigure）。</summary>
    public Action? OnConfigureWebDav { get; set; }

    public BackupWindow(HashSet<string> enabled)
    {
        InitializeComponent();
        Enabled = new HashSet<string>(enabled);
        foreach (var p in Providers) CardsPanel.Children.Add(BuildCard(p));
    }

    private UIElement BuildCard(Provider p)
    {
        var box = UI.Chips.Card();
        box.Width = 310; box.Margin = new Thickness(0, 0, 12, 12);

        var name = new TextBlock { Text = p.Name, FontSize = 14, FontWeight = FontWeights.SemiBold, Foreground = (Brush)Application.Current.Resources["BrushText"] };
        var badge = UI.Chips.Badge("未配置");
        var top = new DockPanel();
        DockPanel.SetDock(badge, Dock.Right);
        top.Children.Add(badge); top.Children.Add(name);

        var desc = new TextBlock
        {
            Text = p.Desc, FontSize = 11.5, TextWrapping = TextWrapping.Wrap,
            Foreground = (Brush)Application.Current.Resources["BrushMuted"], Margin = new Thickness(0, 8, 0, 8)
        };

        var check = new CheckBox { Content = "启用", IsChecked = Enabled.Contains(p.Id), Foreground = (Brush)Application.Current.Resources["BrushText"] };
        check.Checked += (_, _) => Enabled.Add(p.Id);
        check.Unchecked += (_, _) => Enabled.Remove(p.Id);
        _checks[p.Id] = check;

        var cfgBtn = new Button { Content = "配置", Style = (Style)Application.Current.Resources["PillButton"], HorizontalAlignment = HorizontalAlignment.Right };
        cfgBtn.Click += (_, _) => ConfigureProvider(p);

        var bottom = new DockPanel();
        DockPanel.SetDock(cfgBtn, Dock.Right);
        bottom.Children.Add(cfgBtn); bottom.Children.Add(check);

        var v = new StackPanel();
        v.Children.Add(top); v.Children.Add(desc); v.Children.Add(bottom);
        box.Child = v;
        return box;
    }

    private void ConfigureProvider(Provider p)
    {
        if (p.Id == "webdav") { OnConfigureWebDav?.Invoke(); return; }
        var msg = p.Id == "local"
            ? "本地备份无需凭据：用下方「导出/导入本地包」即可。"
            : $"{p.Desc}\n\n凭据请在此填写（保存在本机设置中）。此版本尚未接入真实 OAuth/API，仅作为占位入口。";
        MessageBox.Show(this, msg, $"{p.Name} · 配置", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private void Export_Click(object sender, RoutedEventArgs e) => OnExport?.Invoke();
    private void Import_Click(object sender, RoutedEventArgs e) => OnImport?.Invoke();
    private void Cancel_Click(object sender, RoutedEventArgs e) { DialogResult = false; Close(); }
    private void Save_Click(object sender, RoutedEventArgs e) { DialogResult = true; Close(); }
}
