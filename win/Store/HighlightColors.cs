using System;
using System.IO;
using System.Text.Json;
using System.Windows.Media;
using PixShell.Logging;

namespace PixShell;

/// <summary>
/// 终端文字配色的用户自定义覆盖（设置里的「高亮文字颜色 / 普通文字颜色」）。
/// 对齐 mac Store/HighlightColors.swift，两端用同一套语义：
///  - 两项默认都为空 = **跟随主题**（保持内置的明暗调色板不变）
///  - <c>Highlight</c>：语义高亮命中的 token（路径/IP/域名/关键字…）统一改用这个色
///  - <c>Plain</c>：未被高亮命中的普通正文颜色
/// 持久化到 <c>highlight-colors.json</c>（照 TermSchemeStore 的写法放在 HostStore.AppDir）。
/// </summary>
public static class HighlightColors
{
    private sealed class Saved
    {
        public string Highlight { get; set; } = "";
        public string Plain { get; set; } = "";
    }

    private static string FilePath => Path.Combine(HostStore.AppDir, "highlight-colors.json");

    /// <summary>#RRGGBB，空串 = 跟随主题。</summary>
    public static string HighlightHex { get; private set; } = "";
    public static string PlainHex { get; private set; } = "";

    /// <summary>改动通知：宿主据此把已开的会话重绘一遍（不用重启也能看到效果）。</summary>
    public static event Action? Changed;

    public static void Load()
    {
        try
        {
            if (!File.Exists(FilePath)) return;
            var s = JsonSerializer.Deserialize<Saved>(File.ReadAllText(FilePath));
            HighlightHex = s?.Highlight ?? "";
            PlainHex = s?.Plain ?? "";
        }
        catch (Exception ex) { Log.Warn($"读取自定义文字颜色失败，用默认值: {ex.Message}", "ui"); }
    }

    /// <summary>传空串表示"跟随主题"。</summary>
    public static void Set(string highlightHex, string plainHex)
    {
        HighlightHex = Normalize(highlightHex);
        PlainHex = Normalize(plainHex);
        try
        {
            Directory.CreateDirectory(HostStore.AppDir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(
                new Saved { Highlight = HighlightHex, Plain = PlainHex }));
        }
        catch (Exception ex) { Log.Warn($"保存自定义文字颜色失败: {ex.Message}", "ui"); }
        Changed?.Invoke();
    }

    public static Color ToColor(string hex, Color fallback)
    {
        var h = Normalize(hex);
        if (h.Length != 7) return fallback;
        try
        {
            return Color.FromRgb(
                Convert.ToByte(h.Substring(1, 2), 16),
                Convert.ToByte(h.Substring(3, 2), 16),
                Convert.ToByte(h.Substring(5, 2), 16));
        }
        catch { return fallback; }
    }

    public static string FromColor(Color c) => $"#{c.R:x2}{c.G:x2}{c.B:x2}";

    /// <summary>统一成 #rrggbb；识别不了就当"跟随主题"（空串），不要塞半截值进去。</summary>
    private static string Normalize(string? hex)
    {
        if (string.IsNullOrWhiteSpace(hex)) return "";
        var h = hex.Trim();
        if (!h.StartsWith("#")) h = "#" + h;
        return h.Length == 7 ? h.ToLowerInvariant() : "";
    }
}
