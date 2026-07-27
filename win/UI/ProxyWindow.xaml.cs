using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using PixShell.Proxy;

namespace PixShell.UI;

/// <summary>
/// 代理管理窗口：新建/编辑/删除（对齐 mac UI/ProxyPanel.swift）。
/// 列表读写走 <see cref="Proxy.ProxyStore"/>（%APPDATA%\PixShell\proxies.json）。
/// </summary>
public partial class ProxyWindow : Window
{
    public ProxyWindow()
    {
        InitializeComponent();
        Reload();
    }

    private void Reload()
    {
        ListPanel.Children.Clear();
        var items = ProxyStore.List();
        if (items.Count == 0)
        {
            ListPanel.Children.Add(new TextBlock
            {
                Text = "暂无代理，点右上角「＋新建代理」",
                Foreground = (Brush)Application.Current.Resources["BrushMuted"],
                Margin = new Thickness(4, 12, 0, 0)
            });
            return;
        }
        foreach (var p in items) ListPanel.Children.Add(BuildRow(p));
    }

    private UIElement BuildRow(ProxyConfig p)
    {
        var row = Chips.Card();
        row.Margin = new Thickness(0, 0, 0, 8);
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var info = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        info.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(p.Name) ? p.Host : p.Name, FontWeight = FontWeights.SemiBold,
            Foreground = (Brush)Application.Current.Resources["BrushText"], Margin = new Thickness(0, 0, 8, 0)
        });
        info.Children.Add(Chips.Badge(p.DisplayName, p.Type == ProxyType.SshJump ? Chips.BadgeKind.Gray : Chips.BadgeKind.Accent));
        info.Children.Add(new TextBlock
        {
            Text = $"{p.Host}:{p.Port}", FontFamily = (FontFamily)Application.Current.Resources["FontMono"],
            FontSize = 11.5, Foreground = (Brush)Application.Current.Resources["BrushMuted"], Margin = new Thickness(8, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center
        });
        if (!string.IsNullOrEmpty(p.Username))
            info.Children.Add(new Border { Margin = new Thickness(8, 0, 0, 0), Child = Chips.Badge("已认证", Chips.BadgeKind.Green) });
        Grid.SetColumn(info, 0);

        var btns = new StackPanel { Orientation = Orientation.Horizontal };
        var editBtn = new Button { Content = "编辑", Style = (Style)Application.Current.Resources["PillButton"], Margin = new Thickness(0, 0, 6, 0) };
        editBtn.Click += (_, _) => EditProxy(p);
        var delBtn = new Button { Content = "删除", Tag = "Danger", Style = (Style)Application.Current.Resources["PillButton"] };
        delBtn.Click += (_, _) => { ProxyStore.Delete(p.Id); Reload(); };
        btns.Children.Add(editBtn); btns.Children.Add(delBtn);
        Grid.SetColumn(btns, 1);

        grid.Children.Add(info); grid.Children.Add(btns);
        row.Child = grid;
        return row;
    }

    private void New_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new ProxyEditWindow(null) { Owner = this };
        if (dlg.ShowDialog() == true) { ProxyStore.Upsert(dlg.Result); Reload(); }
    }

    private void EditProxy(ProxyConfig p)
    {
        var dlg = new ProxyEditWindow(p) { Owner = this };
        if (dlg.ShowDialog() == true) { ProxyStore.Upsert(dlg.Result); Reload(); }
    }

    private void Close_Click(object sender, RoutedEventArgs e) => Close();
}
