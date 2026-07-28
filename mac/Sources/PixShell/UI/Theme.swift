import AppKit

/// 设计令牌：**从老仓库 shell.css 的 :root 变量 1:1 提取**，作为自绘 UI 的唯一依据。
/// 深色为主（下方 dark），浅色留 light 备用。
enum Theme {

    /// 四套主题：深色 / 浅色 / 水墨 / 复古。后两个都是浅底，
    /// 所以它们的 `dark` 也是 false —— 所有既有 `Theme.dark` 判断（浅底就用深字）继续成立。
    ///
    /// **水墨 vs 复古的区别（别再搞混）**：
    /// - 水墨 = 真·水墨画：冷调**近乎单色的灰白**（远山薄雾那种），只有印章朱砂一点红，不上别的颜色。
    /// - 复古 = 暖米色宣纸 + 靛青/赭黄/青绿等矿物颜料 —— 那是做旧/复古调，不是水墨。
    enum Kind: String {
        case dark, light, ink, retro
        var display: String {
            switch self {
            case .dark: return "深色"
            case .light: return "浅色"
            case .ink: return "水墨"
            case .retro: return "复古"
            }
        }
    }

    /// 当前主题。优先级：PIXSHELL_THEME 环境变量 > 上次保存的选择 > 默认水墨。
    /// 产品默认主题固定为水墨，禁止首启随机落到深色/浅色。
    static var kind: Kind = {
        if let env = ProcessInfo.processInfo.environment["PIXSHELL_THEME"] {
            return Kind(rawValue: env) ?? .ink
        }
        if let saved = UserDefaults.standard.string(forKey: "pixshell.theme") {
            return Kind(rawValue: saved) ?? .ink
        }
        return .ink
    }() {
        didSet { UserDefaults.standard.set(kind.rawValue, forKey: "pixshell.theme") }
    }

    /// 用户选定的「浅色」是哪一套：浅色 / 水墨 / 复古。
    /// 在设置里选了水墨或复古，就等于把它**定义成这台机器的浅色主题**；
    /// 之后顶栏按钮只在 深色 ⇄ 这一套 之间切，不再挨个轮一遍。
    static var lightKind: Kind = {
        if let s = UserDefaults.standard.string(forKey: "pixshell.lightKind"),
           let k = Kind(rawValue: s), k != .dark { return k }
        return .ink
    }() {
        didSet {
            if lightKind == .dark { lightKind = .light; return }   // 深色不能当"浅色"
            UserDefaults.standard.set(lightKind.rawValue, forKey: "pixshell.lightKind")
        }
    }

    /// 是否深底主题。历史上全项目都用它做二选一判断，保留语义：水墨/复古都算浅底。
    /// 赋值仍可用（老代码 `Theme.dark = false`），false 会切到用户选定的那套浅色。
    static var dark: Bool {
        get { kind == .dark }
        set { kind = newValue ? .dark : lightKind }
    }
    private static var ink: Bool { kind == .ink }
    private static var retro: Bool { kind == .retro }

    // 主题相关色：computed，随 kind 切换。深色=老仓库 shell.css :root；浅色=其 light 变体；
    // 水墨=冷调灰白（远山薄雾）+ 浓墨字 + 朱砂印章一点红；复古=暖米宣纸 + 矿物颜料。
    // 注意：视图在构建时把 .cgColor 定格，切主题需整窗重建（见 AppDelegate.installContent）。
    static var bg: NSColor        { ink ? c("#eef1f2") : retro ? c("#f5f2ea") : dark ? c("#1c1c1e") : c("#f2f2f7") }
    static var bg2: NSColor       { ink ? c("#f7f9fa") : retro ? c("#fbf9f4") : dark ? c("#2c2c2e") : c("#ffffff") }
    static var bg3: NSColor       { ink ? c("#dfe4e6") : retro ? c("#e8e2d5") : dark ? c("#3a3a3c") : c("#e5e5ea") }
    static var side: NSColor      { ink ? c("#e7ebed") : retro ? c("#efe9dc") : dark ? c("#1c1c1e") : c("#ececf0") }
    static var term: NSColor      { ink ? c("#f4f7f8") : retro ? c("#f7f4ec") : dark ? c("#191c27") : c("#d4d6dc") }
    static var statusBg: NSColor  { ink ? c("#e7ebed") : retro ? c("#efe9dc") : dark ? c("#1c1c1e") : c("#ececf0") }
    static var border: NSColor       { ink ? inkAlpha(0.10) : retro ? sepiaAlpha(0.12)
                                           : dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.10) }
    static var borderStrong: NSColor { ink ? inkAlpha(0.18) : retro ? sepiaAlpha(0.20)
                                           : dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.18) }
    static var text: NSColor      { ink ? c("#1f2528") : retro ? c("#2b2b2b") : dark ? c("#f7f7fa") : c("#1c1c1e") }
    static var muted: NSColor     { ink ? inkAlpha(0.55) : retro ? sepiaAlpha(0.62)
                                        : dark ? NSColor(srgbRed: 235/255, green: 235/255, blue: 245/255, alpha: 0.78)
                                               : NSColor(srgbRed: 60/255, green: 60/255, blue: 67/255, alpha: 0.66) }
    // 水墨里几乎不上色：强调色用「焦墨青」这种极低饱和的墨调，不用蓝。
    static var accent: NSColor      { ink ? c("#4a5a61") : retro ? c("#3f6b7a") : c("#0a84ff") }
    static var accentHover: NSColor { ink ? c("#5d7078") : retro ? c("#4d8093") : c("#409cff") }
    static var accentSoft: NSColor  { ink ? NSColor(srgbRed: 74/255, green: 90/255, blue: 97/255, alpha: 0.14)
                                          : retro ? NSColor(srgbRed: 63/255, green: 107/255, blue: 122/255, alpha: 0.18)
                                          : NSColor(srgbRed: 10/255, green: 132/255, blue: 255/255, alpha: 0.22) }
    static var ok: NSColor          { ink ? c("#5f7a68") : retro ? c("#5c8a4a") : c("#30d158") }   // 淡墨绿
    static var warn: NSColor        { ink ? c("#8c7a4e") : retro ? c("#c9922e") : c("#ffd60a") }   // 淡墨黄
    /// 水墨里唯一允许的那点颜色 —— 印章朱砂。既符合画面，也保证"出错"仍然醒目。
    static var err: NSColor         { ink ? c("#9c3d35") : retro ? c("#b13b3b") : c("#ff453a") }
    static var control: NSColor      { ink ? inkAlpha(0.07) : retro ? sepiaAlpha(0.08)
                                           : dark ? NSColor(srgbRed: 120/255, green: 120/255, blue: 128/255, alpha: 0.32)
                                                  : NSColor(srgbRed: 120/255, green: 120/255, blue: 128/255, alpha: 0.20) }
    static var controlHover: NSColor { ink ? inkAlpha(0.13) : retro ? sepiaAlpha(0.14)
                                           : NSColor(srgbRed: 120/255, green: 120/255, blue: 128/255, alpha: 0.42) }
    static var fill: NSColor        { ink ? inkAlpha(0.09) : retro ? sepiaAlpha(0.10)
                                          : dark ? NSColor(srgbRed: 120/255, green: 120/255, blue: 128/255, alpha: 0.24)
                                                 : NSColor(srgbRed: 120/255, green: 120/255, blue: 128/255, alpha: 0.14) }

    /// 水墨的"淡墨"：同一味冷墨按浓度化开（偏青冷，不是中性灰）。
    private static func inkAlpha(_ a: CGFloat) -> NSColor {
        NSColor(srgbRed: 31/255, green: 37/255, blue: 40/255, alpha: a)
    }
    /// 复古的"旧墨"：暖褐调。
    private static func sepiaAlpha(_ a: CGFloat) -> NSColor {
        NSColor(srgbRed: 43/255, green: 43/255, blue: 43/255, alpha: a)
    }

    // MARK: 尺寸 / 圆角（--radius 等）
    static let radius: CGFloat = 10
    static let radiusSm: CGFloat = 7
    static let radiusLg: CGFloat = 14
    static let menubarH: CGFloat = 30
    static let tabH: CGFloat = 24
    static let cmdH: CGFloat = 26
    static let statusH: CGFloat = 36
    static let sidebarW: CGFloat = 200
    static let bottomH: CGFloat = 200

    // MARK: 字体（--font / --mono）
    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
    static func mono(_ size: CGFloat) -> NSFont {
        NSFont(name: "JetBrains Mono", size: size)
            ?? NSFont(name: "SF Mono", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func c(_ hex: String) -> NSColor {
        var s = hex; if s.hasPrefix("#") { s.removeFirst() }
        let n = Int(s, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((n>>16)&255)/255, green: CGFloat((n>>8)&255)/255, blue: CGFloat(n&255)/255, alpha: 1)
    }
}

// MARK: - 视图便捷：圆角/边框/背景
extension NSView {
    @discardableResult
    func rounded(_ r: CGFloat, bg: NSColor? = nil, border: NSColor? = nil, borderWidth: CGFloat = 1) -> Self {
        wantsLayer = true
        layer?.cornerRadius = r
        layer?.masksToBounds = true
        if let bg = bg { layer?.backgroundColor = bg.cgColor }
        if let border = border { layer?.borderColor = border.cgColor; layer?.borderWidth = borderWidth }
        return self
    }
}
