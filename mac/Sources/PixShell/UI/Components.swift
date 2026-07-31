import AppKit

/// 翻转坐标视图：作 NSScrollView 的 documentView 时，内容从**顶部**排列（否则会沉底）。
final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// 竖向分隔条：视觉只有 1pt 细线，但**命中区左右各外扩 3pt**，细线也好拖。
final class DividerView: NSView {
    private static let grab: CGFloat = 3
    override func resetCursorRects() {
        addCursorRect(bounds.insetBy(dx: -Self.grab, dy: 0), cursor: .resizeLeftRight)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return bounds.insetBy(dx: -Self.grab, dy: 0).contains(p) ? self : nil
    }
}

/// 横向分隔条：同理，视觉 1pt，命中区上下各外扩 3pt。
final class HDividerView: NSView {
    private static let grab: CGFloat = 3
    override func resetCursorRects() {
        addCursorRect(bounds.insetBy(dx: 0, dy: -Self.grab), cursor: .resizeUpDown)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return bounds.insetBy(dx: 0, dy: -Self.grab).contains(p) ? self : nil
    }
}

/// 弹窗头部拖动手势：**落在按钮(NSControl)上的点击不参与识别**。
/// 否则手势会吞掉头部里「关闭/刷新/＋连接」等按钮的点击（曾导致系统信息弹窗关不掉）。
final class HeaderPanGesture: NSPanGestureRecognizer, NSGestureRecognizerDelegate {
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func gestureRecognizer(_ g: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard let v = view, let sv = v.superview else { return true }
        let p = sv.convert(event.locationInWindow, from: nil)
        if let hit = v.hitTest(p), hit is NSControl { return false }   // 落在按钮上 → 不识别，放行点击
        return true
    }
}

// 自绘组件库（对齐老仓库 CSS 的按钮/徽章/卡片/图标按钮样式）。

/// 胶囊按钮：primary(蓝实心) / secondary(灰) / danger(红) / ghost(透明)。对应 连接/编辑/删除。
final class PillButton: NSButton {
    enum Style { case primary, secondary, danger, ghost }
    private var _style: Style
    private var hovering = false
    private let hPad: CGFloat
    private let heightC: CGFloat

    private let customFont: NSFont?
    init(_ title: String, style: Style = .secondary, hPad: CGFloat = 14, height: CGFloat = 28,
         font: NSFont? = nil, target: AnyObject? = nil, action: Selector? = nil) {
        _style = style; self.hPad = hPad; self.heightC = height; self.customFont = font
        super.init(frame: .zero)
        self.title = title
        self.target = target; self.action = action
        isBordered = false; bezelStyle = .regularSquare; wantsLayer = true; focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    var style: Style { get { _style } set { _style = newValue; restyle() } }

    private func restyle() {
        layer?.cornerRadius = Theme.radiusSm
        let bgc: NSColor, fgc: NSColor
        switch _style {
        case .primary:   bgc = hovering ? Theme.accentHover : Theme.accent; fgc = .white
        case .secondary: bgc = hovering ? Theme.controlHover : Theme.control; fgc = Theme.text
        case .danger:    bgc = NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: hovering ? 0.26 : 0.16); fgc = Theme.err
        case .ghost:     bgc = hovering ? Theme.control : .clear; fgc = Theme.muted
        }
        layer?.backgroundColor = bgc.cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: fgc,
            .font: customFont ?? Theme.ui(12, _style == .primary ? .semibold : .medium),
        ])
    }
    override func layout() { super.layout(); layer?.cornerRadius = Theme.radiusSm }
    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize; s.width += hPad * 2; s.height = heightC; return s
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; restyle() }
    override func mouseExited(with event: NSEvent) { hovering = false; restyle() }
}

/// 药丸徽章：gray(端口/计数) / green(已记住密码) / accent。
final class Badge: NSView {
    enum Kind { case gray, green, accent }
    init(_ text: String, kind: Kind = .gray) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true; layer?.cornerRadius = 8
        let bgc: NSColor, fgc: NSColor
        switch kind {
        case .gray:   bgc = Theme.fill; fgc = Theme.muted
        case .green:  bgc = NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 0.18); fgc = Theme.ok
        case .accent: bgc = Theme.accentSoft; fgc = Theme.accent
        }
        layer?.backgroundColor = bgc.cgColor
        let label = NSTextField(labelWithString: text)
        label.font = Theme.ui(9.5, .medium); label.textColor = fgc
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1.5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1.5),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// 圆角卡片（bg2 + border + radius）。
final class CardView: NSView {
    init(radius: CGFloat = Theme.radius, bg: NSColor = Theme.bg2, border: NSColor = Theme.border) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        rounded(radius, bg: bg, border: border)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// 顶栏图标按钮（SF Symbol，方形圆角，control 底）。
final class IconButton: NSButton {
    /// size 可选：默认 32×24；坞的文件操作行用更紧凑的 26×20 省空间
    init(symbol: String, tooltip: String = "", size: NSSize = NSSize(width: 32, height: 24),
         target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false; wantsLayer = true; bezelStyle = .regularSquare; focusRingType = .none
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        imageScaling = .scaleProportionallyDown
        contentTintColor = Theme.muted
        toolTip = tooltip
        self.target = target; self.action = action
        rounded(Theme.radiusSm, bg: Theme.control)
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); layer?.cornerRadius = Theme.radiusSm }
}

/// 状态圆点。
final class Dot: NSView {
    init(_ color: NSColor, size: CGFloat = 8) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true; layer?.cornerRadius = size / 2
        layer?.backgroundColor = color.cgColor
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func setColor(_ c: NSColor) { layer?.backgroundColor = c.cgColor }
}

enum ScrollableText {
    /// 造一对「滚动视图 + 文本视图」：自动换行、竖向能随内容长、内容超高可滚。
    ///
    /// **一定要用 AppKit 自己的 `NSTextView.scrollableTextView()`**，不要手搓
    /// `scroll.documentView = NSTextView()`。手搓踩过两次（都是实测才发现）：
    ///  1. 什么都不配 → textView 宽度是 **0**、textContainer 宽度是负数，
    ///     `string` 写得进读得出，但一个字都不显示；
    ///  2. 改用 Auto Layout 把 documentView 钉在 clipView 上（top/width，不钉 bottom）
    ///     → 第一行能显示了，但高度不跟内容长，**第二行被裁掉**。
    /// 根子上是：documentView 的尺寸该由 NSTextView 的 isVerticallyResizable 机制管，
    /// 拿约束去按它就会互相打架。工厂方法已经把这些配好了。
    static func make(font: NSFont, editable: Bool, bg: NSColor, border: NSColor) -> (NSScrollView, NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else {
            return (scroll, NSTextView())   // 不会发生；给个不崩的兜底
        }
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = bg
        scroll.rounded(Theme.radiusSm, border: border)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        tv.isEditable = editable
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = font
        tv.textColor = Theme.text
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 6)
        return (scroll, tv)
    }
}

/// 会**悬停高亮 + 响应双击**的卡片。
///
/// 快速连接页原来是一堆静态方框，鼠标划过去没有任何反馈，看着"简陋"。
/// 这里加两件事：悬停时边框转强调色 + 底色提亮；双击卡片任意空白处直接连接
/// （按钮上的点击不受影响 —— NSButton 会自己吃掉事件，不会冒泡到这里）。
final class HoverCardView: NSView {
    var onDoubleClick: (() -> Void)?

    private let baseBg: NSColor
    private let baseBorder: NSColor
    private var hovering = false

    init(radius: CGFloat = Theme.radius, bg: NSColor = Theme.bg2, border: NSColor = Theme.border) {
        baseBg = bg; baseBorder = border
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        rounded(radius, bg: bg, border: border)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; restyle() }
    override func mouseExited(with event: NSEvent) { hovering = false; restyle() }

    private func restyle() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.175, 0.885, 0.32, 1.275)
            
            self.layer?.borderColor = (self.hovering ? Theme.accent : self.baseBorder).cgColor
            self.layer?.borderWidth = self.hovering ? 1.5 : 1
            self.layer?.backgroundColor = (self.hovering ? Theme.bg3.withAlphaComponent(0.8) : self.baseBg).cgColor
            
            // 物理悬浮效果
            if self.hovering {
                let transform = CATransform3DMakeScale(1.02, 1.02, 1.0)
                self.layer?.transform = transform
                self.layer?.shadowColor = NSColor.black.cgColor
                self.layer?.shadowOpacity = 0.4
                self.layer?.shadowRadius = 8
                self.layer?.shadowOffset = CGSize(width: 0, height: -4)
            } else {
                self.layer?.transform = CATransform3DIdentity
                self.layer?.shadowOpacity = 0
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }
}

/// 完全隐藏轨道的滚动条（防止 macOS 在插入鼠标时强行显示白底轨道）
final class InvisibleScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { return true }
    override func draw(_ dirtyRect: NSRect) {
        self.drawKnob()
    }
}

/// 强制内容铺满全宽、滚动条完全悬浮的滚动视图
final class OverlayScrollView: NSScrollView {
    override func tile() {
        super.tile()
        contentView.frame = bounds
        if let vs = verticalScroller {
            vs.frame = NSRect(x: bounds.maxX - vs.frame.width, y: 0, width: vs.frame.width, height: bounds.height)
            vs.layer?.zPosition = 1
        }
    }
    override func layout() {
        super.layout()
        if contentView.frame != bounds {
            contentView.frame = bounds
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }
}
