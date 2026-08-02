import AppKit
import SwiftTerm

/// 终端配色主题（对齐 Electron 老仓库：深色底 #1e1f29 / 浅色底 #d4d6dc + ANSI 16 色）。
enum TermTheme {
    /// 当前配色方案 id（空 = 用下面的内置明/暗调色板）。持久化在 UserDefaults。
    static var schemeId: String {
        get { UserDefaults.standard.string(forKey: "pixshell.colorScheme") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "pixshell.colorScheme") }
    }
    /// 终端字号（设置页可调）
    static var fontSize: CGFloat {
        get { let v = UserDefaults.standard.double(forKey: "pixshell.fontSize"); return v > 0 ? CGFloat(v) : 13 }
        set { UserDefaults.standard.set(Double(newValue), forKey: "pixshell.fontSize") }
    }

    static func apply(to tv: TerminalView, dark: Bool = true) {
        // 选了配色方案就用方案；否则回退内置明/暗调色板
        if !schemeId.isEmpty, let s = TermSchemes.get(schemeId) {
            apply(scheme: s, to: tv)
            return
        }
        let bg = dark ? "#1e1f29" : "#d4d6dc"
        let fg = dark ? "#f2f2f7" : "#0b0b0d"
        
        let nBg = ns(bg)
        tv.nativeBackgroundColor = nBg
        tv.layer?.backgroundColor = nBg.cgColor
        tv.enclosingScrollView?.backgroundColor = nBg
        
        let nFg = ns(fg)
        tv.nativeForegroundColor = nFg
        tv.caretColor = ns(dark ? "#f2f2f7" : "#0055d4")
        tv.installColors(dark ? darkPalette : lightPalette)
        if let f = NSFont(name: "Menlo", size: fontSize) { tv.font = f }
        tv.setNeedsDisplay(tv.bounds)
    }

    /// 应用一套 TermSchemes 方案（NSColor → SwiftTerm.Color）
    static func apply(scheme s: TermScheme, to tv: TerminalView) {
        let nBg: NSColor = s.id == "ink_wash" ? .clear : s.background
        tv.nativeBackgroundColor = nBg
        tv.layer?.backgroundColor = nBg.cgColor
        tv.enclosingScrollView?.backgroundColor = nBg
        
        tv.nativeForegroundColor = s.foreground
        tv.caretColor = s.cursor
        tv.installColors(s.ansi.map(term))
        if let f = NSFont(name: "Menlo", size: fontSize) { tv.font = f }
        tv.setNeedsDisplay(tv.bounds)
    }
    private static func term(_ c: NSColor) -> SwiftTerm.Color {
        let s = c.usingColorSpace(.sRGB) ?? c
        return SwiftTerm.Color(red: UInt16(s.redComponent * 65535),
                               green: UInt16(s.greenComponent * 65535),
                               blue: UInt16(s.blueComponent * 65535))
    }

    // ANSI 16 色（照搬老仓库明暗调色板）
    static let darkPalette: [SwiftTerm.Color] = [
        c("#000000"), c("#ff2d20"), c("#0dbc79"), c("#ffcc00"),
        c("#bd93f9"), c("#ff79c6"), c("#8be9fd"), c("#f2f2f7"),
        c("#a0a0a8"), c("#ff453a"), c("#23d18b"), c("#ffd426"),
        c("#d6bbff"), c("#ff92d0"), c("#a4f0ff"), c("#f7f7fa"),
    ]
    static let lightPalette: [SwiftTerm.Color] = [
        c("#0b0b0d"), c("#b00014"), c("#00782a"), c("#9a4200"),
        c("#0b4db8"), c("#6b2f9a"), c("#0a6a78"), c("#0b0b0d"),
        c("#4a4a52"), c("#d4001f"), c("#16825d"), c("#b84f00"),
        c("#0d5fd4"), c("#8538c0"), c("#0c8496"), c("#000000"),
    ]

    private static func rgb(_ hex: String) -> (Int, Int, Int) {
        var s = hex; if s.hasPrefix("#") { s.removeFirst() }
        let n = Int(s, radix: 16) ?? 0
        return ((n >> 16) & 255, (n >> 8) & 255, n & 255)
    }
    static func c(_ hex: String) -> SwiftTerm.Color {
        let (r, g, b) = rgb(hex)
        return SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
    }
    static func ns(_ hex: String) -> NSColor {
        let (r, g, b) = rgb(hex)
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}
