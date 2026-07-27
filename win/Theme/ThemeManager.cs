using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Windows;

namespace PixShell;

/// <summary>
/// 主题切换：每套令牌各是一份 ResourceDictionary（Theme/Theme{Dark,Light,Ink,Retro}.xaml），
/// key 名字完全一致（BrushBg/BrushText/…）。切换时只把 App.Resources.MergedDictionaries
/// 里对应槽位的字典换掉，所有用 {DynamicResource BrushXxx} 的控件自动跟着换色，无需重建窗口。
/// 对齐 mac 版 Theme.Kind + applyThemeKind()。
///
/// **切换语义（别改回轮播）**：设置里的四选一是"选定当前主题"；选中浅色系的任意一套
/// （浅色/水墨/复古）会同时把它记为 <see cref="LightKind"/> = 这台机器的"浅色"是哪一套。
/// 顶栏主题按钮此后只在 **深色 ⇄ LightKind** 两态之间切，不再挨个轮一遍（用户明确要求）。
///
/// 持久化：<c>theme.json</c>（照 TermSchemeStore 的写法放在 HostStore.AppDir）。
/// 之前 Windows 端主题**完全没持久化**，每次启动都回到深色，顺带修掉。
/// </summary>
public static class ThemeManager
{
    public enum Kind { Dark, Light, Ink, Retro }

    private static readonly (Kind kind, string file, string display)[] Table =
    {
        (Kind.Dark,  "Theme/ThemeDark.xaml",  "深色"),
        (Kind.Light, "Theme/ThemeLight.xaml", "浅色"),
        (Kind.Ink,   "Theme/ThemeInk.xaml",   "水墨"),
        (Kind.Retro, "Theme/ThemeRetro.xaml", "复古"),
    };

    private sealed class Saved
    {
        public string Theme { get; set; } = "ink";
        public string LightKind { get; set; } = "light";
    }

    private static string FilePath => Path.Combine(HostStore.AppDir, "theme.json");

    public static Kind Current { get; private set; } = Kind.Ink;

    /// <summary>用户选定的「浅色」是哪一套（浅色/水墨/复古），深色不算。</summary>
    public static Kind LightKind { get; private set; } = Kind.Light;

    /// <summary>是否深底主题。水墨/复古都算浅底，既有按 IsDark 分支的代码不用改。</summary>
    public static bool IsDark => Current == Kind.Dark;

    /// <summary>主题变化通知（供需要手动重算的控件，如渐变条/火花线颜色）。</summary>
    public static event Action<bool>? ThemeChanged;

    public static string Display(Kind k) => Table.First(t => t.kind == k).display;
    public static Kind[] AllKinds => Table.Select(t => t.kind).ToArray();

    /// <summary>启动时调用：读回上次的选择并真正把字典换上。</summary>
    public static void Initialize(bool darkFallback = true)
    {
        var s = Load();
        LightKind = ParseLight(s?.LightKind);
        Current = Parse(s?.Theme) ?? (darkFallback ? Kind.Dark : LightKind);
        // App.xaml 默认静态合并的是深色；不是深色就得真的换一次字典。
        if (Current != Kind.Dark) SwapDictionary(Current);
        ThemeChanged?.Invoke(IsDark);
    }

    /// <summary>顶栏按钮：只做 深色 ⇄ 选定的浅色 两态切换。</summary>
    public static void Toggle() => ApplyKind(IsDark ? LightKind : Kind.Dark);

    /// <summary>老接口保留：false 会切到用户选定的那套浅色，而不是写死的 Light。</summary>
    public static void Apply(bool dark) => ApplyKind(dark ? Kind.Dark : LightKind);

    public static void ApplyKind(Kind kind)
    {
        Current = kind;
        // 选了浅色系的某一套 → 同时定为"我的浅色"
        if (kind != Kind.Dark) LightKind = kind;
        SwapDictionary(kind);
        Save();
        ThemeChanged?.Invoke(IsDark);
    }

    private static void SwapDictionary(Kind kind)
    {
        var dicts = Application.Current?.Resources.MergedDictionaries;
        if (dicts == null) return;
        var newDict = new ResourceDictionary
        {
            Source = new Uri(Table.First(t => t.kind == kind).file, UriKind.Relative),
        };
        // 找到当前挂着的主题字典（Source 文件名命中表里任意一套）并替换；找不到就直接加。
        var old = dicts.FirstOrDefault(d => d.Source != null &&
            Table.Any(t => d.Source.OriginalString.EndsWith(Path.GetFileName(t.file), StringComparison.OrdinalIgnoreCase)));
        if (old != null) dicts[dicts.IndexOf(old)] = newDict;
        else dicts.Add(newDict);
    }

    private static Saved? Load()
    {
        try { return File.Exists(FilePath) ? JsonSerializer.Deserialize<Saved>(File.ReadAllText(FilePath)) : null; }
        catch { return null; }   // 读坏了就用默认值，不要因为配置炸掉启动
    }

    private static void Save()
    {
        try
        {
            Directory.CreateDirectory(HostStore.AppDir);
            var s = new Saved
            {
                Theme = Current.ToString().ToLowerInvariant(),
                LightKind = LightKind.ToString().ToLowerInvariant(),
            };
            File.WriteAllText(FilePath, JsonSerializer.Serialize(s));
        }
        catch { /* 存不下去不影响使用 */ }
    }

    private static Kind? Parse(string? s) => s?.ToLowerInvariant() switch
    {
        "dark" => Kind.Dark, "light" => Kind.Light, "ink" => Kind.Ink, "retro" => Kind.Retro, _ => null,
    };
    private static Kind ParseLight(string? s)
    {
        var k = Parse(s);
        return (k == null || k == Kind.Dark) ? Kind.Light : k.Value;   // 深色不能当"浅色"
    }
}
