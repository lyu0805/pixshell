import AppKit

// MARK: - 十六进制颜色解析

/// 把 "#rgb" / "#rrggbb" / "#rrggbbaa" 解析成 NSColor。
/// 解析失败（长度不对、包含非十六进制字符等）时返回不透明黑色兜底，绝不崩溃。
private func hexColor(_ hex: String) -> NSColor {
    let fallback = NSColor.black
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    guard !s.isEmpty, s.allSatisfy({ $0.isHexDigit }) else { return fallback }

    func byte(_ pair: ArraySlice<Character>) -> CGFloat? {
        guard pair.count == 2, let v = UInt8(String(pair), radix: 16) else { return nil }
        return CGFloat(v) / 255.0
    }

    let chars = Array(s)
    switch chars.count {
    case 3:
        // #rgb：每一位重复一次展开成 #rrggbb
        guard let r = byte([chars[0], chars[0]][...]),
              let g = byte([chars[1], chars[1]][...]),
              let b = byte([chars[2], chars[2]][...]) else { return fallback }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    case 6:
        guard let r = byte(chars[0..<2]),
              let g = byte(chars[2..<4]),
              let b = byte(chars[4..<6]) else { return fallback }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    case 8:
        guard let r = byte(chars[0..<2]),
              let g = byte(chars[2..<4]),
              let b = byte(chars[4..<6]),
              let a = byte(chars[6..<8]) else { return fallback }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    default:
        // 不认识的长度（例如 #rrgb 这种畸形值），直接兜底，不尝试猜测
        return fallback
    }
}

// MARK: - TermScheme

/// 单个终端配色方案：背景/前景/光标/选区 + 完整 16 色 ANSI 表。
struct TermScheme {
    let id: String
    let name: String
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let selection: NSColor?
    /// 固定 16 个 ANSI 颜色，顺序为：
    /// black, red, green, yellow, blue, magenta, cyan, white,
    /// 然后是对应的 bright 变体。
    let ansi: [NSColor]
    /// 由背景亮度推导出的深浅色标记，供 UI 决定搭配的浅色/深色控件。
    var isDark: Bool

    init(id: String, name: String, background: NSColor, foreground: NSColor, cursor: NSColor, selection: NSColor?, ansi: [NSColor]) {
        self.id = id
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selection = selection
        self.ansi = ansi
        self.isDark = TermScheme.luma(of: background) < 0.5
    }

    /// 简化版相对亮度（ITU BT.601 感知加权），无法读取分量时按深色处理。
    private static func luma(of color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }
}

// MARK: - 原始数据表（照搬自 packages/terminal/src/schemes.js 的 SCHEMES 常量）

/// 表格中转结构：只存十六进制字符串，构建 TermScheme 时统一转换成 NSColor。
/// 这样下面的表格能保持和 schemes.js 里几乎一一对应的可读形态。
private struct Raw {
    let id: String
    let name: String
    let bg: String
    let fg: String
    let cursor: String
    let selection: String
    let ansi: [String]
}

/// 顺序与字段均照搬自 schemes.js；native-112 精简后剩余 32 个高对比度方案。
private let rawSchemeTable: [Raw] = [
    // 水墨：真·水墨画配色 —— 冷调灰白纸 + 浓墨字，ANSI 基本是**一整套墨阶**（焦墨→淡墨），
    // 只有 red 位留一点印章朱砂。刻意不上其它颜色，那才是水墨；上了颜料就变成"复古"了。
    // 水墨：真·水墨画配色 —— 宋代山水构图、五色墨阶与留白意境
    Raw(id: "ink_wash", name: "水墨", bg: "#F2EBE5", fg: "#1F2326", cursor: "#9A322C", selection: "#DED6CE", ansi: [
        "#111314", // 0 black - 焦墨 (极黑)
        "#A8342C", // 1 red - 朱砂 (印泥红)
        "#2C3537", // 2 green - 浓墨 (深灰黑)
        "#4A5557", // 3 yellow - 重墨 (中灰)
        "#788588", // 4 blue - 淡墨 (浅灰)
        "#A1AEB1", // 5 magenta - 清墨 (极浅水灰)
        "#3E545B", // 6 cyan - 花青 (带蓝调的传统墨色)
        "#F2EBE5", // 7 white - 宣纸白 (留白)
        "#1F2326", // 8 br black
        "#C43C33", // 9 br red
        "#3B474A", // 10 br green
        "#5E6A6D", // 11 br yellow
        "#8B989B", // 12 br blue
        "#B6C3C6", // 13 br magenta
        "#4D676F", // 14 br cyan
        "#FAFAF9"  // 15 br white
    ]),
    // 复古：暖米宣纸 + 矿物颜料（朱砂/靛青/石绿/赭黄）。做旧调，和上面的水墨是两回事。
    Raw(id: "retro_paper", name: "复古", bg: "#f7f4ec", fg: "#2b2b2b", cursor: "#b13b3b", selection: "#dcd5c4", ansi: ["#3a3a3a", "#b13b3b", "#5c8a4a", "#c9922e", "#3f6b7a", "#7a5c86", "#4f8a87", "#5f5a52", "#6b6b6b", "#c9564f", "#6fa05a", "#d8a94a", "#5286a0", "#96739f", "#69a3a0", "#2b2b2b"]),
    Raw(id: "pix-dark", name: "Pix Dark (Default)", bg: "#002945", fg: "#ffffff", cursor: "#00d05c", selection: "#05609f", ansi: ["#555555", "#ff2222", "#38de21", "#ffe50a", "#1460d2", "#ff005d", "#ff2222", "#bbbbbb", "#555555", "#f40e17", "#3bd01d", "#edc809", "#5555ff", "#ff99ff", "#ff5555", "#ffffff"]),
    Raw(id: "dracula", name: "Dracula", bg: "#1e1f29", fg: "#f8f8f2", cursor: "#bbbbbb", selection: "#44475a", ansi: ["#000000", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#bbbbbb", "#555555", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#ffffff"]),
    Raw(id: "monokai_soda", name: "Monokai Soda", bg: "#1a1a1a", fg: "#c4c5b5", cursor: "#f6f7ec", selection: "#343434", ansi: ["#1a1a1a", "#f4005f", "#98e024", "#fa8419", "#9d65ff", "#f4005f", "#58d1eb", "#c4c5b5", "#625e4c", "#f4005f", "#98e024", "#e0d561", "#9d65ff", "#f4005f", "#58d1eb", "#f6f6ef"]),
    Raw(id: "gruvbox_dark", name: "Gruvbox Dark", bg: "#1e1e1e", fg: "#e6d4a3", cursor: "#bbbbbb", selection: "#685c51", ansi: ["#161819", "#f73028", "#aab01e", "#f7b125", "#719586", "#c77089", "#7db669", "#faefbb", "#7f7061", "#be0f17", "#868715", "#cc881a", "#377375", "#a04b73", "#578e57", "#e6d4a3"]),
    Raw(id: "solarized_dark", name: "Solarized Dark", bg: "#001e27", fg: "#708284", cursor: "#708284", selection: "#002831", ansi: ["#002831", "#d11c24", "#738a05", "#a57706", "#2176c7", "#c61c6f", "#259286", "#eae3cb", "#001e27", "#bd3613", "#475b62", "#536870", "#708284", "#5956ba", "#819090", "#fcf4dc"]),
    Raw(id: "solarized_dark_higher_contrast", name: "Solarized Dark Higher Contrast", bg: "#001e27", fg: "#9cc2c3", cursor: "#f34b00", selection: "#003748", ansi: ["#002831", "#d11c24", "#6cbe6c", "#a57706", "#2176c7", "#c61c6f", "#259286", "#eae3cb", "#006488", "#f5163b", "#51ef84", "#b27e28", "#178ec8", "#e24d8e", "#00b39e", "#fcf4dc"]),
    Raw(id: "tomorrow_night", name: "Tomorrow Night", bg: "#1d1f21", fg: "#c5c8c6", cursor: "#c5c8c6", selection: "#373b41", ansi: ["#000000", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#ffffff", "#000000", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#ffffff"]),
    Raw(id: "tomorrow_night_bright", name: "Tomorrow Night Bright", bg: "#000000", fg: "#eaeaea", cursor: "#eaeaea", selection: "#424242", ansi: ["#000000", "#d54e53", "#b9ca4a", "#e7c547", "#7aa6da", "#c397d8", "#70c0b1", "#ffffff", "#000000", "#d54e53", "#b9ca4a", "#e7c547", "#7aa6da", "#c397d8", "#70c0b1", "#ffffff"]),
    Raw(id: "tomorrow_night_blue", name: "Tomorrow Night Blue", bg: "#002451", fg: "#ffffff", cursor: "#ffffff", selection: "#003f8e", ansi: ["#000000", "#ff9da4", "#d1f1a9", "#ffeead", "#bbdaff", "#ebbbff", "#99ffff", "#ffffff", "#000000", "#ff9da4", "#d1f1a9", "#ffeead", "#bbdaff", "#ebbbff", "#99ffff", "#ffffff"]),
    Raw(id: "atom", name: "Atom", bg: "#161719", fg: "#c5c8c6", cursor: "#d0d0d0", selection: "#444444", ansi: ["#000000", "#fd5ff1", "#87c38a", "#ffd7b1", "#85befd", "#b9b6fc", "#85befd", "#e0e0e0", "#000000", "#fd5ff1", "#94fa36", "#f5ffa8", "#96cbfe", "#b9b6fc", "#85befd", "#e0e0e0"]),
    Raw(id: "ayu", name: "ayu", bg: "#0f1419", fg: "#e6e1cf", cursor: "#f29718", selection: "#253340", ansi: ["#000000", "#ff3333", "#b8cc52", "#e7c547", "#36a3d9", "#f07178", "#95e6cb", "#ffffff", "#323232", "#ff6565", "#eafe84", "#fff779", "#68d5ff", "#ffa3aa", "#c7fffd", "#ffffff"]),
    Raw(id: "seti", name: "Seti", bg: "#111213", fg: "#cacecd", cursor: "#e3bf21", selection: "#303233", ansi: ["#323232", "#c22832", "#8ec43d", "#e0c64f", "#43a5d5", "#8b57b5", "#8ec43d", "#eeeeee", "#323232", "#c22832", "#8ec43d", "#e0c64f", "#43a5d5", "#8b57b5", "#8ec43d", "#ffffff"]),
    Raw(id: "spacegray", name: "SpaceGray", bg: "#20242d", fg: "#b3b8c3", cursor: "#b3b8c3", selection: "#16181e", ansi: ["#000000", "#b04b57", "#87b379", "#e5c179", "#7d8fa4", "#a47996", "#85a7a5", "#b3b8c3", "#000000", "#b04b57", "#87b379", "#e5c179", "#7d8fa4", "#a47996", "#85a7a5", "#ffffff"]),
    Raw(id: "cobalt2", name: "Cobalt2", bg: "#132738", fg: "#ffffff", cursor: "#f0cc09", selection: "#18354f", ansi: ["#000000", "#ff0000", "#38de21", "#ffe50a", "#1460d2", "#ff005d", "#00bbbb", "#bbbbbb", "#555555", "#f40e17", "#3bd01d", "#edc809", "#5555ff", "#ff55ff", "#6ae3fa", "#ffffff"]),
    Raw(id: "ciapre", name: "Ciapre", bg: "#191c27", fg: "#aea47a", cursor: "#92805b", selection: "#172539", ansi: ["#181818", "#810009", "#48513b", "#cc8b3f", "#576d8c", "#724d7c", "#5c4f4b", "#aea47f", "#555555", "#ac3835", "#a6a75d", "#dcdf7c", "#3097c6", "#d33061", "#f3dbb2", "#f4f4f4"]),
    Raw(id: "afterglow", name: "Afterglow", bg: "#212121", fg: "#d0d0d0", cursor: "#d0d0d0", selection: "#303030", ansi: ["#151515", "#ac4142", "#7e8e50", "#e5b567", "#6c99bb", "#9f4e85", "#7dd6cf", "#d0d0d0", "#505050", "#ac4142", "#7e8e50", "#e5b567", "#6c99bb", "#9f4e85", "#7dd6cf", "#f5f5f5"]),
    Raw(id: "homebrew", name: "Homebrew", bg: "#000000", fg: "#00ff00", cursor: "#23ff18", selection: "#083905", ansi: ["#000000", "#990000", "#00a600", "#999900", "#0000b2", "#b200b2", "#00a6b2", "#bfbfbf", "#666666", "#e50000", "#00d900", "#e5e500", "#0000ff", "#e500e5", "#00e5e5", "#e5e5e5"]),
    Raw(id: "jellybeans", name: "Jellybeans", bg: "#121212", fg: "#dedede", cursor: "#ffa560", selection: "#474e91", ansi: ["#929292", "#e27373", "#94b979", "#ffba7b", "#97bedc", "#e1c0fa", "#00988e", "#dedede", "#bdbdbd", "#ffa1a1", "#bddeab", "#ffdca0", "#b1d8f6", "#fbdaff", "#1ab2a8", "#ffffff"]),
    Raw(id: "jetbrains_darcula", name: "JetBrains Darcula", bg: "#202020", fg: "#adadad", cursor: "#ffffff", selection: "#1a3272", ansi: ["#000000", "#fa5355", "#126e00", "#c2c300", "#4581eb", "#fa54ff", "#33c2c1", "#adadad", "#555555", "#fb7172", "#67ff4f", "#ffff00", "#6d9df1", "#fb82ff", "#60d3d1", "#eeeeee"]),
    Raw(id: "wombat", name: "Wombat", bg: "#171717", fg: "#dedacf", cursor: "#bbbbbb", selection: "#453b39", ansi: ["#000000", "#ff615a", "#b1e969", "#ebd99c", "#5da9f6", "#e86aff", "#82fff7", "#dedacf", "#313131", "#f58c80", "#ddf88f", "#eee5b2", "#a5c7ff", "#ddaaff", "#b7fff9", "#ffffff"]),
    Raw(id: "zenburn", name: "Zenburn", bg: "#3f3f3f", fg: "#dcdccc", cursor: "#73635a", selection: "#21322f", ansi: ["#4d4d4d", "#705050", "#60b48a", "#f0dfaf", "#506070", "#dc8cc3", "#8cd0d3", "#dcdccc", "#709080", "#dca3a3", "#c3bf9f", "#e0cf9f", "#94bff3", "#ec93d3", "#93e0e3", "#ffffff"]),
    Raw(id: "flat", name: "Flat", bg: "#002240", fg: "#2cc55d", cursor: "#e5be0c", selection: "#792b9c", ansi: ["#222d3f", "#a82320", "#32a548", "#e58d11", "#3167ac", "#781aa0", "#2c9370", "#b0b6ba", "#212c3c", "#d4312e", "#2d9440", "#e5be0c", "#3c7dd2", "#8230a7", "#35b387", "#e7eced"]),
    Raw(id: "obsidian", name: "Obsidian", bg: "#283033", fg: "#cdcdcd", cursor: "#c0cad0", selection: "#3e4c4f", ansi: ["#000000", "#a60001", "#00bb00", "#fecd22", "#3a9bdb", "#bb00bb", "#00bbbb", "#bbbbbb", "#555555", "#ff0003", "#93c863", "#fef874", "#a1d7ff", "#ff55ff", "#55ffff", "#ffffff"]),
    Raw(id: "duotone_dark", name: "Duotone Dark", bg: "#1f1d27", fg: "#b7a1ff", cursor: "#ff9839", selection: "#353147", ansi: ["#1f1d27", "#d9393e", "#2dcd73", "#d9b76e", "#ffc284", "#de8d40", "#2488ff", "#b7a1ff", "#353147", "#d9393e", "#2dcd73", "#d9b76e", "#ffc284", "#de8d40", "#2488ff", "#eae5ff"]),
    Raw(id: "glacier", name: "Glacier", bg: "#0c1115", fg: "#ffffff", cursor: "#6c6c6c", selection: "#bd2523", ansi: ["#2e343c", "#bd0f2f", "#35a770", "#fb9435", "#1f5872", "#bd2523", "#778397", "#ffffff", "#404a55", "#bd0f2f", "#49e998", "#fddf6e", "#2a8bc1", "#ea4727", "#a0b6d3", "#ffffff"]),
    Raw(id: "hardcore", name: "Hardcore", bg: "#121212", fg: "#a0a0a0", cursor: "#bbbbbb", selection: "#453b39", ansi: ["#1b1d1e", "#f92672", "#a6e22e", "#fd971f", "#66d9ef", "#9e6ffe", "#5e7175", "#ccccc6", "#505354", "#ff669d", "#beed5f", "#e6db74", "#66d9ef", "#9e6ffe", "#a3babf", "#f8f8f2"]),
    Raw(id: "solarized_light", name: "Solarized Light", bg: "#fcf4dc", fg: "#536870", cursor: "#536870", selection: "#eae3cb", ansi: ["#002831", "#d11c24", "#738a05", "#a57706", "#2176c7", "#c61c6f", "#259286", "#eae3cb", "#001e27", "#bd3613", "#475b62", "#536870", "#708284", "#5956ba", "#819090", "#fcf4dc"]),
    Raw(id: "atomonelight", name: "AtomOneLight", bg: "#f9f9f9", fg: "#2a2c33", cursor: "#bbbbbb", selection: "#ededed", ansi: ["#000000", "#de3e35", "#3f953a", "#d2b67c", "#2f5af3", "#950095", "#3f953a", "#bbbbbb", "#000000", "#de3e35", "#3f953a", "#d2b67c", "#2f5af3", "#a00095", "#3f953a", "#ffffff"]),
    Raw(id: "ayu_light", name: "ayu_light", bg: "#fafafa", fg: "#5c6773", cursor: "#ff6a00", selection: "#f0eee4", ansi: ["#000000", "#ff3333", "#86b300", "#f29718", "#41a6d9", "#f07178", "#4dbf99", "#ffffff", "#323232", "#ff6565", "#b8e532", "#ffc94a", "#73d8ff", "#ffa3aa", "#7ff1cb", "#ffffff"]),
    Raw(id: "github", name: "Github", bg: "#f4f4f4", fg: "#3e3e3e", cursor: "#3f3f3f", selection: "#a9c1e2", ansi: ["#3e3e3e", "#970b16", "#07962a", "#f8eec7", "#003e8a", "#e94691", "#89d1ec", "#ffffff", "#666666", "#de0000", "#87d5a2", "#f1d007", "#2e6cba", "#ffa29f", "#1cfafe", "#ffffff"]),
    Raw(id: "tomorrow", name: "Tomorrow", bg: "#ffffff", fg: "#4d4d4c", cursor: "#4d4d4c", selection: "#d6d6d6", ansi: ["#000000", "#c82829", "#718c00", "#eab700", "#4271ae", "#8959a8", "#3e999f", "#ffffff", "#000000", "#c82829", "#718c00", "#eab700", "#4271ae", "#8959a8", "#3e999f", "#ffffff"]),
    Raw(id: "terminal_basic", name: "Terminal Basic", bg: "#ffffff", fg: "#000000", cursor: "#7f7f7f", selection: "#a4c9ff", ansi: ["#000000", "#990000", "#00a600", "#999900", "#0000b2", "#b200b2", "#00a6b2", "#bfbfbf", "#666666", "#e50000", "#00d900", "#e5e500", "#0000ff", "#e500e5", "#00e5e5", "#e5e5e5"]),
]

// MARK: - TermSchemes 查找 API

/// 终端配色方案表的统一入口：只读数据 + 按 id/别名查找。
enum TermSchemes {
    /// 按 schemes.js 原始顺序排列、已按 id 去重（先出现者优先）的完整方案表。
    static let all: [TermScheme] = buildAll()

    /// 默认深色方案：对齐旧仓库 ui-settings.js 里 colorScheme 的默认值。
    static let defaultDarkId = "pix-dark"
    /// 默认浅色方案：schemes.js 未显式指定"浅色默认值"这个概念，
    /// 这里选用移植集合里最常见、对比度完整的浅色方案 Solarized Light。
    static let defaultLightId = "solarized_light"

    /// 旧版本 / 已移除方案 id → 现有方案 id 的别名表，逐条照搬自 schemes.js 的 getScheme() ALIAS。
    private static let alias: [String: String] = [
        "monokai": "monokai_soda",
        "nord": "spacegray",
        "one_dark": "atom",
        "onedark": "atom",
        "solarized": "solarized_dark",
        "solarized_dark_patched": "solarized_dark",
        "espresso": "afterglow",
        "idletoes": "afterglow",
        "batman": "dracula",
        "chalk": "ciapre",
        "chalkboard": "ciapre",
        "dimmedmonokai": "monokai_soda",
        "spacegray_eighties": "spacegray",
        "cobalt_neon": "cobalt2",
        "adventuretime": "tomorrow_night_blue",
        "argonaut": "dracula",
        "ocean": "cobalt2",
        "hybrid": "atom",
        "wez": "hardcore",
        "brogrammer": "hardcore",
        "darkside": "afterglow",
        "firewatch": "duotone_dark",
        "mathias": "hardcore",
        "paulmillr": "hardcore",
        "smyck": "jellybeans",
        "symfonic": "tomorrow_night_blue",
        "twilight": "zenburn",
        "material": "github",
        "clrs": "terminal_basic",
        "novel": "terminal_basic",
        "pencillight": "atomonelight",
        "piatto_light": "github",
        "3024_day": "terminal_basic",
        "tomorrow_night_eighties": "tomorrow_night",
        "spiderman": "dracula",
        "crayonponyfish": "dracula",
    ]

    /// id → TermScheme 的查找索引，基于 all 构建一次。
    private static let byId: [String: TermScheme] = {
        var map: [String: TermScheme] = [:]
        for s in all { map[s.id] = s }
        return map
    }()

    /// 按 id 查找方案，找不到原样 id 时会尝试规范化形式，再尝试别名表；
    /// 都找不到则返回 nil（调用方可退回 defaultDarkId / defaultLightId）。
    static func get(_ id: String) -> TermScheme? {
        if let s = byId[id] { return s }
        let normalized = normalize(id)
        if let s = byId[normalized] { return s }
        if let target = alias[normalized], let s = byId[target] { return s }
        return nil
    }

    /// 对应 JS 里的 `raw.toLowerCase().replace(/[^a-z0-9]+/g, '_')`：
    /// 转小写，非字母数字的连续片段统一折叠成一个下划线。
    private static func normalize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var result = ""
        var lastWasSeparator = false
        for ch in lowered {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                result.append(ch)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                result.append("_")
                lastWasSeparator = true
            }
        }
        return result
    }

    /// 把中转数据表转换成正式的 TermScheme 数组：
    /// - 按 id 去重，先出现者优先；
    /// - 防御性地把 ANSI 颜色补齐/截断到恰好 16 个（理论上 schemes.js 里都已是 16 色）。
    private static func buildAll() -> [TermScheme] {
        var seenIds = Set<String>()
        var result: [TermScheme] = []
        for r in rawSchemeTable {
            guard !seenIds.contains(r.id) else { continue }
            seenIds.insert(r.id)

            var ansi = r.ansi.map(hexColor)
            if ansi.count < 16 {
                // 源数据缺色时，用最后一个已知色（没有则用前景色）填满剩余位置
                let base = ansi.last ?? hexColor(r.fg)
                ansi.append(contentsOf: Array(repeating: base, count: 16 - ansi.count))
            } else if ansi.count > 16 {
                ansi = Array(ansi.prefix(16))
            }

            result.append(TermScheme(
                id: r.id,
                name: r.name,
                background: hexColor(r.bg),
                foreground: hexColor(r.fg),
                cursor: r.cursor.isEmpty ? hexColor(r.fg) : hexColor(r.cursor),
                selection: r.selection.isEmpty ? nil : hexColor(r.selection),
                ansi: ansi
            ))
        }

        #if DEBUG
        validate(result)
        #endif
        return result
    }

    #if DEBUG
    /// 调试期断言：每个方案必须恰好 16 个 ANSI 色，且 id 全局唯一。
    private static func validate(_ schemes: [TermScheme]) {
        var ids = Set<String>()
        for s in schemes {
            assert(s.ansi.count == 16, "方案 \(s.id) 的 ANSI 颜色数量应为 16，实际为 \(s.ansi.count)")
            assert(!ids.contains(s.id), "方案 id 重复: \(s.id)")
            ids.insert(s.id)
        }
    }
    #endif
}
