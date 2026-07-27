import AppKit

/// 终端文字配色的用户自定义覆盖（设置里的「高亮文字颜色 / 普通文字颜色」）。
///
/// 默认两项都是 nil = **跟随主题**（保持内置的明暗两套调色板不变）。
/// 只有用户显式挑了颜色才生效：
///  - `highlight`：语义高亮命中的那些 token（路径 / IP / 域名 / 关键字…）统一改用这个色
///  - `plain`：未被高亮命中的普通正文颜色
/// 以十六进制串持久化，跟 mac/Windows 两端共用同一套 key，便于对齐。
enum HighlightColors {
    private static let keyHL = "pixshell.hl.color"
    private static let keyPlain = "pixshell.hl.plainColor"

    static var highlight: NSColor? {
        get { read(keyHL) }
        set { write(newValue, keyHL); changed?() }
    }
    static var plain: NSColor? {
        get { read(keyPlain) }
        set { write(newValue, keyPlain); changed?() }
    }

    /// 改动通知：宿主据此把已开的会话重绘一遍（不用重启也能看到效果）。
    static var changed: (() -> Void)?

    /// 十六进制串（#RRGGBB），供 SemanticHighlight 直接拼 truecolor 转义。
    static var highlightHex: String? { hex(highlight) }
    static var plainHex: String? { hex(plain) }

    private static func read(_ k: String) -> NSColor? {
        guard let s = UserDefaults.standard.string(forKey: k), !s.isEmpty else { return nil }
        return Theme.c(s)
    }
    private static func write(_ c: NSColor?, _ k: String) {
        if let c = c, let h = hex(c) { UserDefaults.standard.set(h, forKey: k) }
        else { UserDefaults.standard.removeObject(forKey: k) }
    }
    private static func hex(_ c: NSColor?) -> String? {
        guard let rgb = c?.usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
