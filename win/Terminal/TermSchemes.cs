using System;
using System.Collections.Generic;
using System.Linq;

namespace PixShell.Terminal;

/// <summary>
/// 单个终端配色方案：背景/前景/光标/选区 + 完整 16 色 ANSI 表。
/// 颜色一律以 "#rrggbb" 十六进制字符串存放（而非 WPF Color），因为最终消费方是
/// xterm.js 的 theme 对象（JSON），字符串可以直接序列化过去，不需要中间转换。
/// 对齐 mac Terminal/TermSchemes.swift 的 TermScheme。
/// </summary>
public sealed class TermScheme
{
    public string Id { get; }
    public string Name { get; }
    public string Background { get; }
    public string Foreground { get; }
    public string Cursor { get; }
    public string? Selection { get; }

    /// <summary>固定 16 个 ANSI 颜色：black,red,green,yellow,blue,magenta,cyan,white，
    /// 然后是对应的 bright 变体，顺序对齐 mac 版。</summary>
    public IReadOnlyList<string> Ansi { get; }

    /// <summary>由背景亮度推导出的深浅色标记。</summary>
    public bool IsDark { get; }

    public TermScheme(string id, string name, string background, string foreground, string cursor, string? selection, IReadOnlyList<string> ansi)
    {
        Id = id; Name = name; Background = background; Foreground = foreground; Cursor = cursor; Selection = selection; Ansi = ansi;
        IsDark = Luma(background) < 0.5;
    }

    /// <summary>简化版相对亮度（ITU BT.601 感知加权），解析失败按深色处理。</summary>
    private static double Luma(string hex)
    {
        var (r, g, b, _) = ParseHex(hex);
        return 0.299 * r + 0.587 * g + 0.114 * b;
    }

    /// <summary>把 "#rgb"/"#rrggbb"/"#rrggbbaa" 解析成 0..1 浮点分量；解析失败返回黑色兜底，绝不抛异常。</summary>
    internal static (double r, double g, double b, double a) ParseHex(string hex)
    {
        try
        {
            var s = (hex ?? "").Trim();
            if (s.StartsWith("#")) s = s[1..];
            if (s.Length == 0 || !s.All(Uri.IsHexDigit)) return (0, 0, 0, 1);
            double B(string pair) => Convert.ToInt32(pair, 16) / 255.0;
            switch (s.Length)
            {
                case 3:
                    return (B($"{s[0]}{s[0]}"), B($"{s[1]}{s[1]}"), B($"{s[2]}{s[2]}"), 1);
                case 6:
                    return (B(s[0..2]), B(s[2..4]), B(s[4..6]), 1);
                case 8:
                    return (B(s[0..2]), B(s[2..4]), B(s[4..6]), B(s[6..8]));
                default:
                    return (0, 0, 0, 1);
            }
        }
        catch { return (0, 0, 0, 1); }
    }
}

/// <summary>
/// 终端配色方案表的统一入口：只读数据 + 按 id/别名查找。数据表 1:1 移植自 mac
/// Terminal/TermSchemes.swift（即老仓库 packages/terminal/src/schemes.js 的 SCHEMES 常量，
/// native-112 精简后剩余 32 个高对比度方案 + 34 条别名）。
/// </summary>
public static class TermSchemes
{
    private sealed record Raw(string Id, string Name, string Bg, string Fg, string Cursor, string Selection, string[] Ansi);

    private static readonly Raw[] RawTable =
    {
        // 水墨：真·水墨画配色 —— 冷调灰白纸 + 浓墨字，ANSI 基本是**一整套墨阶**（焦墨→淡墨），
        // 只有 red 位留一点印章朱砂。刻意不上其它颜色，那才是水墨；上了颜料就变成"复古"了。
        new("ink_wash", "水墨", "#f4f7f8", "#1f2528", "#9c3d35", "#d6dee1", new[] { "#1f2528", "#9c3d35", "#5f7a68", "#8c7a4e", "#4a5a61", "#6b6570", "#5b7076", "#6e777b", "#3d474b", "#b25248", "#728f7c", "#a08f62", "#5d7078", "#837c88", "#6f868c", "#1f2528" }),
        // 复古：暖米宣纸 + 矿物颜料（朱砂/靛青/石绿/赭黄）。做旧调，和上面的水墨是两回事。
        new("retro_paper", "复古", "#f7f4ec", "#2b2b2b", "#b13b3b", "#dcd5c4", new[] { "#3a3a3a", "#b13b3b", "#5c8a4a", "#c9922e", "#3f6b7a", "#7a5c86", "#4f8a87", "#5f5a52", "#6b6b6b", "#c9564f", "#6fa05a", "#d8a94a", "#5286a0", "#96739f", "#69a3a0", "#2b2b2b" }),
        new("pix-dark", "Pix Dark (Default)", "#002945", "#ffffff", "#00d05c", "#05609f", new[] { "#555555", "#ff2222", "#0dbc79", "#ffe50a", "#1460d2", "#ff005d", "#00bbbb", "#f2f2f7", "#555555", "#f40e17", "#3bd01d", "#edc809", "#5555ff", "#ff99ff", "#6ae3fa", "#ffffff" }),
        new("dracula", "Dracula", "#1e1f29", "#f8f8f2", "#bbbbbb", "#44475a", new[] { "#000000", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#bbbbbb", "#555555", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#ffffff" }),
        new("monokai_soda", "Monokai Soda", "#1a1a1a", "#c4c5b5", "#f6f7ec", "#343434", new[] { "#1a1a1a", "#f4005f", "#98e024", "#fa8419", "#9d65ff", "#f4005f", "#58d1eb", "#c4c5b5", "#625e4c", "#f4005f", "#98e024", "#e0d561", "#9d65ff", "#f4005f", "#58d1eb", "#f6f6ef" }),
        new("gruvbox_dark", "Gruvbox Dark", "#1e1e1e", "#e6d4a3", "#bbbbbb", "#685c51", new[] { "#161819", "#f73028", "#aab01e", "#f7b125", "#719586", "#c77089", "#7db669", "#faefbb", "#7f7061", "#be0f17", "#868715", "#cc881a", "#377375", "#a04b73", "#578e57", "#e6d4a3" }),
        new("solarized_dark", "Solarized Dark", "#001e27", "#708284", "#708284", "#002831", new[] { "#002831", "#d11c24", "#738a05", "#a57706", "#2176c7", "#c61c6f", "#259286", "#eae3cb", "#001e27", "#bd3613", "#475b62", "#536870", "#708284", "#5956ba", "#819090", "#fcf4dc" }),
        new("solarized_dark_higher_contrast", "Solarized Dark Higher Contrast", "#001e27", "#9cc2c3", "#f34b00", "#003748", new[] { "#002831", "#d11c24", "#6cbe6c", "#a57706", "#2176c7", "#c61c6f", "#259286", "#eae3cb", "#006488", "#f5163b", "#51ef84", "#b27e28", "#178ec8", "#e24d8e", "#00b39e", "#fcf4dc" }),
        new("tomorrow_night", "Tomorrow Night", "#1d1f21", "#c5c8c6", "#c5c8c6", "#373b41", new[] { "#000000", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#ffffff", "#000000", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#ffffff" }),
        new("tomorrow_night_bright", "Tomorrow Night Bright", "#000000", "#eaeaea", "#eaeaea", "#424242", new[] { "#000000", "#d54e53", "#b9ca4a", "#e7c547", "#7aa6da", "#c397d8", "#70c0b1", "#ffffff", "#000000", "#d54e53", "#b9ca4a", "#e7c547", "#7aa6da", "#c397d8", "#70c0b1", "#ffffff" }),
        new("tomorrow_night_blue", "Tomorrow Night Blue", "#002451", "#ffffff", "#ffffff", "#003f8e", new[] { "#000000", "#ff9da4", "#d1f1a9", "#ffeead", "#bbdaff", "#ebbbff", "#99ffff", "#ffffff", "#000000", "#ff9da4", "#d1f1a9", "#ffeead", "#bbdaff", "#ebbbff", "#99ffff", "#ffffff" }),
        new("atom", "Atom", "#161719", "#c5c8c6", "#d0d0d0", "#444444", new[] { "#000000", "#fd5ff1", "#87c38a", "#ffd7b1", "#85befd", "#b9b6fc", "#85befd", "#e0e0e0", "#000000", "#fd5ff1", "#94fa36", "#f5ffa8", "#96cbfe", "#b9b6fc", "#85befd", "#e0e0e0" }),
        new("ayu", "ayu", "#0f1419", "#e6e1cf", "#f29718", "#253340", new[] { "#000000", "#ff3333", "#b8cc52", "#e7c547", "#36a3d9", "#f07178", "#95e6cb", "#ffffff", "#323232", "#ff6565", "#eafe84", "#fff779", "#68d5ff", "#ffa3aa", "#c7fffd", "#ffffff" }),
        new("seti", "Seti", "#111213", "#cacecd", "#e3bf21", "#303233", new[] { "#323232", "#c22832", "#8ec43d", "#e0c64f", "#43a5d5", "#8b57b5", "#8ec43d", "#eeeeee", "#323232", "#c22832", "#8ec43d", "#e0c64f", "#43a5d5", "#8b57b5", "#8ec43d", "#ffffff" }),
        new("spacegray", "SpaceGray", "#20242d", "#b3b8c3", "#b3b8c3", "#16181e", new[] { "#000000", "#b04b57", "#87b379", "#e5c179", "#7d8fa4", "#a47996", "#85a7a5", "#b3b8c3", "#000000", "#b04b57", "#87b379", "#e5c179", "#7d8fa4", "#a47996", "#85a7a5", "#ffffff" }),
        new("cobalt2", "Cobalt2", "#132738", "#ffffff", "#f0cc09", "#18354f", new[] { "#000000", "#ff0000", "#38de21", "#ffe50a", "#1460d2", "#ff005d", "#00bbbb", "#bbbbbb", "#555555", "#f40e17", "#3bd01d", "#edc809", "#5555ff", "#ff55ff", "#6ae3fa", "#ffffff" }),
        new("ciapre", "Ciapre", "#191c27", "#aea47a", "#92805b", "#172539", new[] { "#181818", "#810009", "#48513b", "#cc8b3f", "#576d8c", "#724d7c", "#5c4f4b", "#aea47f", "#555555", "#ac3835", "#a6a75d", "#dcdf7c", "#3097c6", "#d33061", "#f3dbb2", "#f4f4f4" }),
        new("afterglow", "Afterglow", "#212121", "#d0d0d0", "#d0d0d0", "#303030", new[] { "#151515", "#ac4142", "#7e8e50", "#e5b567", "#6c99bb", "#9f4e85", "#7dd6cf", "#d0d0d0", "#505050", "#ac4142", "#7e8e50", "#e5b567", "#6c99bb", "#9f4e85", "#7dd6cf", "#f5f5f5" }),
        new("homebrew", "Homebrew", "#000000", "#00ff00", "#23ff18", "#083905", new[] { "#000000", "#990000", "#00a600", "#999900", "#0000b2", "#b200b2", "#00a6b2", "#bfbfbf", "#666666", "#e50000", "#00d900", "#e5e500", "#0000ff", "#e500e5", "#00e5e5", "#e5e5e5" }),
        new("jellybeans", "Jellybeans", "#121212", "#dedede", "#ffa560", "#474e91", new[] { "#929292", "#e27373", "#94b979", "#ffba7b", "#97bedc", "#e1c0fa", "#00988e", "#dedede", "#bdbdbd", "#ffa1a1", "#bddeab", "#ffdca0", "#b1d8f6", "#fbdaff", "#1ab2a8", "#ffffff" }),
        new("jetbrains_darcula", "JetBrains Darcula", "#202020", "#adadad", "#ffffff", "#1a3272", new[] { "#000000", "#fa5355", "#126e00", "#c2c300", "#4581eb", "#fa54ff", "#33c2c1", "#adadad", "#555555", "#fb7172", "#67ff4f", "#ffff00", "#6d9df1", "#fb82ff", "#60d3d1", "#eeeeee" }),
        new("wombat", "Wombat", "#171717", "#dedacf", "#bbbbbb", "#453b39", new[] { "#000000", "#ff615a", "#b1e969", "#ebd99c", "#5da9f6", "#e86aff", "#82fff7", "#dedacf", "#313131", "#f58c80", "#ddf88f", "#eee5b2", "#a5c7ff", "#ddaaff", "#b7fff9", "#ffffff" }),
        new("zenburn", "Zenburn", "#3f3f3f", "#dcdccc", "#73635a", "#21322f", new[] { "#4d4d4d", "#705050", "#60b48a", "#f0dfaf", "#506070", "#dc8cc3", "#8cd0d3", "#dcdccc", "#709080", "#dca3a3", "#c3bf9f", "#e0cf9f", "#94bff3", "#ec93d3", "#93e0e3", "#ffffff" }),
        new("flat", "Flat", "#002240", "#2cc55d", "#e5be0c", "#792b9c", new[] { "#222d3f", "#a82320", "#32a548", "#e58d11", "#3167ac", "#781aa0", "#2c9370", "#b0b6ba", "#212c3c", "#d4312e", "#2d9440", "#e5be0c", "#3c7dd2", "#8230a7", "#35b387", "#e7eced" }),
        new("obsidian", "Obsidian", "#283033", "#cdcdcd", "#c0cad0", "#3e4c4f", new[] { "#000000", "#a60001", "#00bb00", "#fecd22", "#3a9bdb", "#bb00bb", "#00bbbb", "#bbbbbb", "#555555", "#ff0003", "#93c863", "#fef874", "#a1d7ff", "#ff55ff", "#55ffff", "#ffffff" }),
        new("duotone_dark", "Duotone Dark", "#1f1d27", "#b7a1ff", "#ff9839", "#353147", new[] { "#1f1d27", "#d9393e", "#2dcd73", "#d9b76e", "#ffc284", "#de8d40", "#2488ff", "#b7a1ff", "#353147", "#d9393e", "#2dcd73", "#d9b76e", "#ffc284", "#de8d40", "#2488ff", "#eae5ff" }),
        new("glacier", "Glacier", "#0c1115", "#ffffff", "#6c6c6c", "#bd2523", new[] { "#2e343c", "#bd0f2f", "#35a770", "#fb9435", "#1f5872", "#bd2523", "#778397", "#ffffff", "#404a55", "#bd0f2f", "#49e998", "#fddf6e", "#2a8bc1", "#ea4727", "#a0b6d3", "#ffffff" }),
        new("hardcore", "Hardcore", "#121212", "#a0a0a0", "#bbbbbb", "#453b39", new[] { "#1b1d1e", "#f92672", "#a6e22e", "#fd971f", "#66d9ef", "#9e6ffe", "#5e7175", "#ccccc6", "#505354", "#ff669d", "#beed5f", "#e6db74", "#66d9ef", "#9e6ffe", "#a3babf", "#f8f8f2" }),
        new("solarized_light", "Solarized Light", "#fcf4dc", "#536870", "#536870", "#eae3cb", new[] { "#002831", "#d11c24", "#738a05", "#a57706", "#2176c7", "#c61c6f", "#259286", "#eae3cb", "#001e27", "#bd3613", "#475b62", "#536870", "#708284", "#5956ba", "#819090", "#fcf4dc" }),
        new("atomonelight", "AtomOneLight", "#f9f9f9", "#2a2c33", "#bbbbbb", "#ededed", new[] { "#000000", "#de3e35", "#3f953a", "#d2b67c", "#2f5af3", "#950095", "#3f953a", "#bbbbbb", "#000000", "#de3e35", "#3f953a", "#d2b67c", "#2f5af3", "#a00095", "#3f953a", "#ffffff" }),
        new("ayu_light", "ayu_light", "#fafafa", "#5c6773", "#ff6a00", "#f0eee4", new[] { "#000000", "#ff3333", "#86b300", "#f29718", "#41a6d9", "#f07178", "#4dbf99", "#ffffff", "#323232", "#ff6565", "#b8e532", "#ffc94a", "#73d8ff", "#ffa3aa", "#7ff1cb", "#ffffff" }),
        new("github", "Github", "#f4f4f4", "#3e3e3e", "#3f3f3f", "#a9c1e2", new[] { "#3e3e3e", "#970b16", "#07962a", "#f8eec7", "#003e8a", "#e94691", "#89d1ec", "#ffffff", "#666666", "#de0000", "#87d5a2", "#f1d007", "#2e6cba", "#ffa29f", "#1cfafe", "#ffffff" }),
        new("tomorrow", "Tomorrow", "#ffffff", "#4d4d4c", "#4d4d4c", "#d6d6d6", new[] { "#000000", "#c82829", "#718c00", "#eab700", "#4271ae", "#8959a8", "#3e999f", "#ffffff", "#000000", "#c82829", "#718c00", "#eab700", "#4271ae", "#8959a8", "#3e999f", "#ffffff" }),
        new("terminal_basic", "Terminal Basic", "#ffffff", "#000000", "#7f7f7f", "#a4c9ff", new[] { "#000000", "#990000", "#00a600", "#999900", "#0000b2", "#b200b2", "#00a6b2", "#bfbfbf", "#666666", "#e50000", "#00d900", "#e5e500", "#0000ff", "#e500e5", "#00e5e5", "#e5e5e5" }),
    };

    /// <summary>旧版本/已移除方案 id → 现有方案 id 的别名表，逐条照搬自 mac 版 alias（对应老仓库 schemes.js 的 getScheme() ALIAS）。</summary>
    private static readonly Dictionary<string, string> AliasTable = new()
    {
        ["monokai"] = "monokai_soda",
        ["nord"] = "spacegray",
        ["one_dark"] = "atom",
        ["onedark"] = "atom",
        ["solarized"] = "solarized_dark",
        ["solarized_dark_patched"] = "solarized_dark",
        ["espresso"] = "afterglow",
        ["idletoes"] = "afterglow",
        ["batman"] = "dracula",
        ["chalk"] = "ciapre",
        ["chalkboard"] = "ciapre",
        ["dimmedmonokai"] = "monokai_soda",
        ["spacegray_eighties"] = "spacegray",
        ["cobalt_neon"] = "cobalt2",
        ["adventuretime"] = "tomorrow_night_blue",
        ["argonaut"] = "dracula",
        ["ocean"] = "cobalt2",
        ["hybrid"] = "atom",
        ["wez"] = "hardcore",
        ["brogrammer"] = "hardcore",
        ["darkside"] = "afterglow",
        ["firewatch"] = "duotone_dark",
        ["mathias"] = "hardcore",
        ["paulmillr"] = "hardcore",
        ["smyck"] = "jellybeans",
        ["symfonic"] = "tomorrow_night_blue",
        ["twilight"] = "zenburn",
        ["material"] = "github",
        ["clrs"] = "terminal_basic",
        ["novel"] = "terminal_basic",
        ["pencillight"] = "atomonelight",
        ["piatto_light"] = "github",
        ["3024_day"] = "terminal_basic",
        ["tomorrow_night_eighties"] = "tomorrow_night",
        ["spiderman"] = "dracula",
        ["crayonponyfish"] = "dracula",
    };

    /// <summary>按 schemes.js 原始顺序排列、已按 id 去重（先出现者优先）的完整方案表。</summary>
    public static readonly IReadOnlyList<TermScheme> All = BuildAll();

    /// <summary>默认深色方案：对齐旧仓库 ui-settings.js 里 colorScheme 的默认值。</summary>
    public const string DefaultDarkId = "pix-dark";
    /// <summary>默认浅色方案：schemes.js 未显式指定"浅色默认值"，这里选用移植集合里
    /// 最常见、对比度完整的浅色方案 Solarized Light。</summary>
    public const string DefaultLightId = "solarized_light";

    private static readonly Dictionary<string, TermScheme> ById =
        All.ToDictionary(s => s.Id, s => s);

    /// <summary>按 id 查找方案，找不到原样 id 时会尝试规范化形式，再尝试别名表；
    /// 都找不到则返回 null（调用方可退回 DefaultDarkId/DefaultLightId）。</summary>
    public static TermScheme? Get(string id)
    {
        if (string.IsNullOrEmpty(id)) return null;
        if (ById.TryGetValue(id, out var s)) return s;
        var normalized = Normalize(id);
        if (ById.TryGetValue(normalized, out var s2)) return s2;
        if (AliasTable.TryGetValue(normalized, out var target) && ById.TryGetValue(target, out var s3)) return s3;
        return null;
    }

    /// <summary>对应 JS 里的 `raw.toLowerCase().replace(/[^a-z0-9]+/g, '_')`：
    /// 转小写，非字母数字的连续片段统一折叠成一个下划线。</summary>
    private static string Normalize(string raw)
    {
        var lowered = raw.ToLowerInvariant();
        var result = new System.Text.StringBuilder();
        bool lastWasSeparator = false;
        foreach (var ch in lowered)
        {
            if (ch is >= 'a' and <= 'z' or >= '0' and <= '9')
            {
                result.Append(ch);
                lastWasSeparator = false;
            }
            else if (!lastWasSeparator)
            {
                result.Append('_');
                lastWasSeparator = true;
            }
        }
        return result.ToString();
    }

    /// <summary>把中转数据表转换成正式的 TermScheme 数组：按 id 去重（先出现者优先），
    /// 防御性地把 ANSI 颜色补齐/截断到恰好 16 个。</summary>
    private static List<TermScheme> BuildAll()
    {
        var seen = new HashSet<string>();
        var result = new List<TermScheme>();
        foreach (var r in RawTable)
        {
            if (!seen.Add(r.Id)) continue;
            var ansi = r.Ansi.ToList();
            if (ansi.Count < 16)
            {
                var baseColor = ansi.Count > 0 ? ansi[^1] : r.Fg;
                while (ansi.Count < 16) ansi.Add(baseColor);
            }
            else if (ansi.Count > 16)
            {
                ansi = ansi.Take(16).ToList();
            }
            result.Add(new TermScheme(r.Id, r.Name, r.Bg, r.Fg,
                string.IsNullOrEmpty(r.Cursor) ? r.Fg : r.Cursor,
                string.IsNullOrEmpty(r.Selection) ? null : r.Selection,
                ansi));
        }
        return result;
    }
}
