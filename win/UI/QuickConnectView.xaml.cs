using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Input;

namespace PixShell.UI;

/// <summary>
/// 快速连接/历史 落地页（对齐 mac UI/QuickConnect.swift）。
/// 显示顺序 = 历史顺序（最近连接在前），由 <see cref="HostsProvider"/> 提供。
/// </summary>
public partial class QuickConnectView : UserControl
{
    public Func<List<HostEntry>>? HostsProvider { get; set; }
    public Func<HostEntry, bool>? HasPassword { get; set; }
    public Action<HostEntry>? OnConnect { get; set; }
    public Action<HostEntry>? OnEdit { get; set; }
    public Action? OnNew { get; set; }
    public Action? OnClear { get; set; }
    /// <summary>有会话时点返回箭头 → 收起 QC 回终端。</summary>
    public Action? OnBack { get; set; }

    public QuickConnectView()
    {
        InitializeComponent();
    }

    /// <summary>有活动会话时显示返回箭头。</summary>
    public void SetShowsBack(bool show)
    {
        if (BackBtn != null)
            BackBtn.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
    }

    private void New_Click(object sender, RoutedEventArgs e) => OnNew?.Invoke();
    private void Clear_Click(object sender, RoutedEventArgs e) { OnClear?.Invoke(); Reload(); }
    private void Back_Click(object sender, RoutedEventArgs e) => OnBack?.Invoke();

    public void Reload()
    {
        var hosts = HostsProvider?.Invoke() ?? new List<HostEntry>();
        TitleText.Text = $"快速连接（历史 · {hosts.Count}）";
        CardsPanel.Children.Clear();
        for (int i = 0; i < hosts.Count; i++)
            CardsPanel.Children.Add(BuildCard(hosts[i], i + 1));
        EmptyHint.Visibility = hosts.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private UIElement BuildCard(HostEntry h, int index)
    {
        var box = Chips.Card();
        // 铁律：底部「连接/编辑」绝不能被裁掉。
        // 旧坑：固定 Height=128 / MinHeight 过小 + Card 自带 Padding + 内层再 Margin → 按钮出框。
        // 现：去掉双重 padding；Grid 底行 Auto 钉死按钮；高度只设 MinHeight，禁止 Height。
        box.Width = 280;
        box.MinHeight = 168;
        box.Margin = new Thickness(0, 0, 20, 20);
        box.Padding = new Thickness(14, 12, 14, 12);
        box.ClipToBounds = false;
        box.SnapsToDevicePixels = true;

        // 卡片阴影（对齐 mac）；Blur 不参与布局，勿再叠加裁切。
        var shadow = new System.Windows.Media.Effects.DropShadowEffect
        {
            BlurRadius = 12,
            ShadowDepth = 2,
            Opacity = 0.12,
            Direction = 270,
            Color = Colors.Black
        };
        box.Effect = shadow;

        var scale = new ScaleTransform(1.0, 1.0);
        box.RenderTransform = scale;
        box.RenderTransformOrigin = new Point(0.5, 0.5);

        box.MouseEnter += (_, _) =>
        {
            box.Cursor = Cursors.Hand;
            var anim = new System.Windows.Media.Animation.DoubleAnimation(1.02, TimeSpan.FromSeconds(0.2))
            {
                EasingFunction = new System.Windows.Media.Animation.CubicEase
                {
                    EasingMode = System.Windows.Media.Animation.EasingMode.EaseOut
                }
            };
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, anim);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, anim);
            shadow.BeginAnimation(
                System.Windows.Media.Effects.DropShadowEffect.BlurRadiusProperty,
                new System.Windows.Media.Animation.DoubleAnimation(20, TimeSpan.FromSeconds(0.2)));
        };
        box.MouseLeave += (_, _) =>
        {
            box.Cursor = Cursors.Arrow;
            var anim = new System.Windows.Media.Animation.DoubleAnimation(1.0, TimeSpan.FromSeconds(0.2))
            {
                EasingFunction = new System.Windows.Media.Animation.CubicEase
                {
                    EasingMode = System.Windows.Media.Animation.EasingMode.EaseOut
                }
            };
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, anim);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, anim);
            shadow.BeginAnimation(
                System.Windows.Media.Effects.DropShadowEffect.BlurRadiusProperty,
                new System.Windows.Media.Animation.DoubleAnimation(12, TimeSpan.FromSeconds(0.2)));
        };
        // 双击卡片 = 连接（按钮被挡时的兜底）
        box.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount == 2) { OnConnect?.Invoke(h); e.Handled = true; }
        };

        var textBrush = (Brush)Application.Current.Resources["BrushText"];
        var mutedBrush = (Brush)Application.Current.Resources["BrushMuted"];

        var svgIcon = OsIcons.GetIcon(h.OsId);
        var iconColor = ((SolidColorBrush)svgIcon.Fill).Color;
        var iconBoxBg = new SolidColorBrush(Color.FromArgb(30, iconColor.R, iconColor.G, iconColor.B));

        var iconBox = new Border
        {
            Width = 44, Height = 44, Background = iconBoxBg,
            CornerRadius = (CornerRadius)Application.Current.Resources["RadiusSm"],
            Child = svgIcon,
            VerticalAlignment = VerticalAlignment.Top
        };
        var nameText = new TextBlock
        {
            Text = h.Display, FontSize = 15, FontWeight = FontWeights.Bold,
            Foreground = textBrush, TextTrimming = TextTrimming.CharacterEllipsis
        };
        var subText = new TextBlock
        {
            Text = h.Subtitle, FontSize = 12,
            FontFamily = (FontFamily)Application.Current.Resources["FontMono"],
            Foreground = mutedBrush, TextTrimming = TextTrimming.CharacterEllipsis,
            Margin = new Thickness(0, 2, 0, 0)
        };
        var info = new StackPanel
        {
            Orientation = Orientation.Vertical,
            Margin = new Thickness(12, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center
        };
        info.Children.Add(nameText);
        info.Children.Add(subText);

        var osBadge = Chips.Badge(string.IsNullOrEmpty(h.OsId) ? "SSH" : h.OsId);
        osBadge.VerticalAlignment = VerticalAlignment.Top;
        osBadge.Margin = new Thickness(10, 0, 0, 0);

        // 顶行用 Grid，避免 DockPanel LastChildFill 把中间列纵向撑爆挤掉底按钮。
        var topRow = new Grid { Margin = new Thickness(0, 0, 0, 0) };
        topRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        topRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        topRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(iconBox, 0);
        Grid.SetColumn(info, 1);
        Grid.SetColumn(osBadge, 2);
        topRow.Children.Add(iconBox);
        topRow.Children.Add(info);
        topRow.Children.Add(osBadge);

        bool hasPw = HasPassword?.Invoke(h) ?? false;
        var pillRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 10, 0, 0)
        };
        pillRow.Children.Add(Wrap(Chips.Badge($"端口 {h.Port}")));
        pillRow.Children.Add(Wrap(hasPw
            ? Chips.Badge("已记住密码", Chips.BadgeKind.Green)
            : Chips.Badge("需要密码")));
        pillRow.Children.Add(Wrap(Chips.Badge($"#{index}")));

        var pillStyle = (Style)Application.Current.Resources["PillButton"];
        var connectBtn = new Button
        {
            Content = "连接",
            Style = pillStyle,
            Tag = "Primary",
            MinWidth = 72,
            MinHeight = 28,
            Padding = new Thickness(18, 5, 18, 5),
            VerticalAlignment = VerticalAlignment.Center,
            // 显式前景，防止主题/模板把字吃成同色
            Foreground = Brushes.White
        };
        connectBtn.Click += (_, e) => { OnConnect?.Invoke(h); e.Handled = true; };
        var editBtn = new Button
        {
            Content = "编辑",
            Style = pillStyle,
            MinWidth = 56,
            MinHeight = 28,
            Padding = new Thickness(12, 5, 12, 5),
            Margin = new Thickness(8, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = textBrush
        };
        editBtn.Click += (_, e) => { OnEdit?.Invoke(h); e.Handled = true; };

        var btnRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 12, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Left
        };
        btnRow.Children.Add(connectBtn);
        btnRow.Children.Add(editBtn);

        // 三行 Grid：内容 / 徽章 / 按钮。按钮行 Height=Auto 永远在卡片内。
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(topRow, 0);
        Grid.SetRow(pillRow, 1);
        Grid.SetRow(btnRow, 2);
        root.Children.Add(topRow);
        root.Children.Add(pillRow);
        root.Children.Add(btnRow);
        box.Child = root;
        return box;
    }

    private static FrameworkElement Wrap(FrameworkElement e) { e.Margin = new Thickness(0, 0, 6, 0); return e; }
}
