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

    public QuickConnectView()
    {
        InitializeComponent();
    }

    private void New_Click(object sender, RoutedEventArgs e) => OnNew?.Invoke();
    private void Clear_Click(object sender, RoutedEventArgs e) { OnClear?.Invoke(); Reload(); }

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
        box.Width = 264; box.Height = 128; box.Margin = new Thickness(0, 0, 20, 20);
        
        // 卡片增加阴影效果，提升层次感（对齐 mac 效果）
        var shadow = new System.Windows.Media.Effects.DropShadowEffect
        {
            BlurRadius = 15,
            ShadowDepth = 2,
            Opacity = 0.15,
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
            var anim = new System.Windows.Media.Animation.DoubleAnimation(1.02, TimeSpan.FromSeconds(0.2)) { EasingFunction = new System.Windows.Media.Animation.CubicEase { EasingMode = System.Windows.Media.Animation.EasingMode.EaseOut } };
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, anim);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, anim);
            var shadowAnim = new System.Windows.Media.Animation.DoubleAnimation(25, TimeSpan.FromSeconds(0.2));
            shadow.BeginAnimation(System.Windows.Media.Effects.DropShadowEffect.BlurRadiusProperty, shadowAnim);
        };
        box.MouseLeave += (_, _) => 
        {
            box.Cursor = Cursors.Arrow;
            var anim = new System.Windows.Media.Animation.DoubleAnimation(1.0, TimeSpan.FromSeconds(0.2)) { EasingFunction = new System.Windows.Media.Animation.CubicEase { EasingMode = System.Windows.Media.Animation.EasingMode.EaseOut } };
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, anim);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, anim);
            var shadowAnim = new System.Windows.Media.Animation.DoubleAnimation(15, TimeSpan.FromSeconds(0.2));
            shadow.BeginAnimation(System.Windows.Media.Effects.DropShadowEffect.BlurRadiusProperty, shadowAnim);
        };

        var textBrush = (Brush)Application.Current.Resources["BrushText"];
        var mutedBrush = (Brush)Application.Current.Resources["BrushMuted"];
        var accentBrush = (Brush)Application.Current.Resources["BrushAccent"];
        var accentSoft = (Brush)Application.Current.Resources["BrushAccentSoft"];

        var svgIcon = OsIcons.GetIcon(h.OsId);
        var iconColor = ((SolidColorBrush)svgIcon.Fill).Color;
        var iconBoxBg = new SolidColorBrush(Color.FromArgb(30, iconColor.R, iconColor.G, iconColor.B));

        // 图标框
        var iconBox = new Border
        {
            Width = 44, Height = 44, Background = iconBoxBg,
            CornerRadius = (CornerRadius)Application.Current.Resources["RadiusSm"],
            Child = svgIcon
        };
        var nameText = new TextBlock { Text = h.Display, FontSize = 15, FontWeight = FontWeights.Bold, Foreground = textBrush, TextTrimming = TextTrimming.CharacterEllipsis };
        var subText = new TextBlock { Text = h.Subtitle, FontSize = 12, FontFamily = (FontFamily)Application.Current.Resources["FontMono"], Foreground = mutedBrush, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 2, 0, 0) };
        var info = new StackPanel { Orientation = Orientation.Vertical, Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        info.Children.Add(nameText); info.Children.Add(subText);

        var osBadge = Chips.Badge(string.IsNullOrEmpty(h.OsId) ? "SSH" : h.OsId);
        osBadge.VerticalAlignment = VerticalAlignment.Center;
        osBadge.Margin = new Thickness(10, 0, 0, 0);
        
        var topRow = new DockPanel();
        DockPanel.SetDock(iconBox, Dock.Left);
        DockPanel.SetDock(osBadge, Dock.Right);
        topRow.Children.Add(iconBox); topRow.Children.Add(osBadge); topRow.Children.Add(info);

        bool hasPw = HasPassword?.Invoke(h) ?? false;
        var pillRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
        pillRow.Children.Add(Wrap(Chips.Badge($"端口 {h.Port}")));
        pillRow.Children.Add(Wrap(hasPw ? Chips.Badge("已记住密码", Chips.BadgeKind.Green) : Chips.Badge("需要密码")));
        pillRow.Children.Add(Wrap(Chips.Badge($"#{index}")));

        var connectBtn = new Button { Content = "连接", Style = (Style)Application.Current.Resources["PillButton"], Tag = "Primary", Padding = new Thickness(18, 4, 18, 4) };
        connectBtn.Click += (_, _) => OnConnect?.Invoke(h);
        var editBtn = new Button { Content = "编辑", Style = (Style)Application.Current.Resources["PillButton"], Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(8, 0, 0, 0) };
        editBtn.Click += (_, _) => OnEdit?.Invoke(h);
        var btnRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 0) };
        btnRow.Children.Add(connectBtn); btnRow.Children.Add(editBtn);

        var v = new StackPanel { Orientation = Orientation.Vertical, Margin = new Thickness(16, 14, 16, 14) };
        v.Children.Add(topRow); v.Children.Add(pillRow); v.Children.Add(btnRow);
        box.Child = v;
        return box;
    }

    private static FrameworkElement Wrap(FrameworkElement e) { e.Margin = new Thickness(0, 0, 6, 0); return e; }
}
