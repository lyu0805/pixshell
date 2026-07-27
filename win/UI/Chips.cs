using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace PixShell.UI;

/// <summary>小徽章/卡片等复用的自绘辅助（对齐 mac UI/Components.swift 的 Badge/CardView/PillButton 思路）。</summary>
public static class Chips
{
    public enum BadgeKind { Gray, Green, Accent }

    public static Border Badge(string text, BadgeKind kind = BadgeKind.Gray)
    {
        var res = Application.Current.Resources;
        Brush fg, bg;
        switch (kind)
        {
            case BadgeKind.Green:
                fg = new SolidColorBrush(Color.FromRgb(0x30, 0xD1, 0x58));
                bg = new SolidColorBrush(Color.FromArgb(0x30, 0x30, 0xD1, 0x58));
                break;
            case BadgeKind.Accent:
                fg = (Brush)res["BrushAccent"];
                bg = (Brush)res["BrushAccentSoft"];
                break;
            default:
                fg = (Brush)res["BrushMuted"];
                bg = (Brush)res["BrushFill"];
                break;
        }
        var tb = new TextBlock { Text = text, FontSize = 10.5, Foreground = fg, VerticalAlignment = VerticalAlignment.Center };
        return new Border
        {
            Background = bg,
            CornerRadius = new CornerRadius(999),
            Padding = new Thickness(8, 2, 8, 2),
            Child = tb,
            VerticalAlignment = VerticalAlignment.Center,
        };
    }

    /// <summary>卡片外框：圆角 + bg2 底 + 细边框，对齐 mac CardView。</summary>
    public static Border Card()
    {
        var res = Application.Current.Resources;
        return new Border
        {
            Background = (Brush)res["BrushBg2"],
            BorderBrush = (Brush)res["BrushBorder"],
            BorderThickness = new Thickness(1),
            CornerRadius = (CornerRadius)res["RadiusMd"],
            Padding = new Thickness(12),
        };
    }

    /// <summary>按主机 osId 选一个近似图标 emoji（WPF 无 SF Symbols，用系统自带彩色 emoji 代替）。</summary>
    /// <summary>osId → 图标。osId 在首次连接成功后自动识别写入（见 MainWindow.DetectRemoteOsAsync），
    /// 所以连过一次的主机卡片就会显示它自己的系统标志，不用用户手填。</summary>
    public static string OsGlyph(string osId)
    {
        var s = (osId ?? "").ToLowerInvariant();
        if (s.Contains("openwrt") || s.Contains("router") || s.Contains("ddwrt")) return "📡";
        if (s.Contains("win")) return "🪟";
        if (s.Contains("mac") || s.Contains("darwin")) return "🍎";
        if (s.Contains("ubuntu")) return "🟠";
        if (s.Contains("debian")) return "🌀";
        if (s.Contains("cent") || s.Contains("rhel") || s.Contains("rocky") || s.Contains("alma")) return "🔴";
        if (s.Contains("fedora")) return "🔵";
        if (s.Contains("alpine")) return "🏔";
        if (s.Contains("arch")) return "🔷";
        if (s.Contains("suse")) return "🦎";
        if (s.Contains("bsd")) return "😈";
        if (s.Contains("linux")) return "🐧";
        return "💻";
    }

    /// <summary>不同系统给不同主色，卡片一眼能区分（对齐 mac QuickConnect.osTint）。</summary>
    public static System.Windows.Media.Color OsTint(string osId)
    {
        var s = (osId ?? "").ToLowerInvariant();
        System.Windows.Media.Color C(byte r, byte g, byte b) => System.Windows.Media.Color.FromRgb(r, g, b);
        if (s.Contains("ubuntu")) return C(0xE9, 0x54, 0x20);
        if (s.Contains("debian")) return C(0xD7, 0x0A, 0x53);
        if (s.Contains("cent") || s.Contains("rhel") || s.Contains("rocky") || s.Contains("alma")) return C(0xEE, 0x00, 0x00);
        if (s.Contains("fedora")) return C(0x51, 0xA2, 0xDA);
        if (s.Contains("alpine")) return C(0x0D, 0x59, 0x7F);
        if (s.Contains("arch")) return C(0x17, 0x93, 0xD1);
        if (s.Contains("suse")) return C(0x73, 0xBA, 0x25);
        if (s.Contains("openwrt")) return C(0x00, 0xB5, 0xE2);
        if (s.Contains("win")) return C(0x00, 0x78, 0xD4);
        return C(0x0A, 0x84, 0xFF);
    }
}
