import AppKit
import SwiftTerm

// 终端右键菜单（对齐老仓库：复制/粘贴/清屏/全选 + 设置背景色预设 + 字号）。
extension AppDelegate {

    /// 老仓库 TERM_BG_PRESETS（12 个预设，值 1:1 照搬）
    static let termBgPresets: [(id: String, name: String, color: String)] = [
        ("deep", "深灰", "#0f1419"), ("default", "默认", "#1e1f29"),
        ("night", "Night", "#1a1b26"), ("dracula", "Dracula", "#282a36"),
        ("solar", "Solarized", "#002b36"), ("cat", "Catppuccin", "#1e1e2e"),
        ("github", "GitHub", "#0d1117"), ("nord", "Nord", "#2e3440"),
        ("rose", "Rosé", "#191724"), ("tokyo", "Tokyo", "#16161e"),
        ("gray", "黑灰", "#1c1c1c"), ("black", "纯黑", "#000000"),
    ]

    /// 背景覆盖色（老仓库 settings.termBgOverride），空 = 用配色方案/主题默认
    var termBgOverride: String {
        get { UserDefaults.standard.string(forKey: "pixshell.termBgOverride") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "pixshell.termBgOverride") }
    }

    func buildTerminalMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ t: String, _ a: Selector, _ key: String = "") {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: key); i.target = self; m.addItem(i)
        }
        add("复制", #selector(termCopy), "c")
        add("粘贴", #selector(termPaste), "v")
        add("全选", #selector(termSelectAll), "a")
        m.addItem(.separator())
        add("清屏", #selector(termClear), "k")
        m.addItem(.separator())

        // 设置背景 ▸ 预设色板
        let bgItem = NSMenuItem(title: "设置背景", action: nil, keyEquivalent: "")
        let bgMenu = NSMenu(title: "设置背景")
        for p in Self.termBgPresets {
            let it = NSMenuItem(title: p.name, action: #selector(pickTermBg(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = p.color
            it.image = swatch(p.color)
            if p.color.lowercased() == termBgOverride.lowercased() { it.state = .on }
            bgMenu.addItem(it)
        }
        bgMenu.addItem(.separator())
        let reset = NSMenuItem(title: "恢复配色默认", action: #selector(resetTermBg), keyEquivalent: "")
        reset.target = self; bgMenu.addItem(reset)
        bgItem.submenu = bgMenu
        m.addItem(bgItem)

        m.addItem(.separator())
        add("放大字号", #selector(fontBigger), "+")
        add("缩小字号", #selector(fontSmaller), "-")
        return m
    }

    /// 小色块图标，做色板预览
    private func swatch(_ hex: String) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let img = NSImage(size: size)
        img.lockFocus()
        TermTheme.ns(hex).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 3, yRadius: 3).fill()
        img.unlockFocus()
        return img
    }

    @objc func termSelectAll() {
        // 输入框聚焦时 ⌘A 必须全选文本，不能落到终端
        if textEditingFocused() {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
            return
        }
        guard sessions.indices.contains(current) else { return }
        sessions[current].termView.selectAll(self)
    }
    @objc func pickTermBg(_ sender: NSMenuItem) {
        guard let hex = sender.representedObject as? String else { return }
        termBgOverride = hex
        Log.info("终端背景 → \(hex)", "ui")
        applyTermBackground()
    }
    @objc func resetTermBg() {
        termBgOverride = ""
        Log.info("终端背景 → 恢复配色默认", "ui")
        // 必须整套重刷：ink_wash 用 clear，其它方案用 scheme.background；
        // 之前只 apply 在部分时序下不触发重绘，看起来「恢复默认」无效。
        for s in sessions {
            TermTheme.apply(to: s.termView, dark: darkTheme)
            s.termView.needsDisplay = true
            s.termView.setNeedsDisplay(s.termView.bounds)
        }
    }
    /// 只覆盖背景色，不动前景/ANSI（老仓库 termBgOverride 行为）
    func applyTermBackground() {
        if termBgOverride.isEmpty {
            // 空覆盖 = 恢复方案默认背景（与 resetTermBg 同路径，避免只写 set 不刷）
            for s in sessions {
                TermTheme.apply(to: s.termView, dark: darkTheme)
                s.termView.setNeedsDisplay(s.termView.bounds)
            }
            return
        }
        let c = TermTheme.ns(termBgOverride)
        for s in sessions {
            s.termView.nativeBackgroundColor = c
            s.termView.setNeedsDisplay(s.termView.bounds)
        }
    }
}
