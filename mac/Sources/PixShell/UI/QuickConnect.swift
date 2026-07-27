import AppKit

/// 快速连接 / 历史 落地页（自绘复刻老仓库"快速连接（历史·N）"）。
/// 打开 App 或新建 tab 且当前无活动会话时占据工作区中央：
/// 顶部标题 + 清空历史；下方主机卡片网格（图标/名称/root@ip/系统徽章/端口·已记住密码·#序号 + 连接/编辑）。
final class QuickConnect: NSView {
    private let title = NSTextField(labelWithString: "快速连接")
    private let grid = FlowGrid()
    private let subtitle = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "暂无历史记录 —— 点右上角 ＋ 新建连接，或打开连接管理器")

    var hostsProvider: (() -> [Host])?          // 卡片来源（历史顺序）
    var hasPassword: ((Host) -> Bool)?          // 是否已存密码（决定绿色徽章）
    var onConnect: ((Host) -> Void)?
    var onEdit: ((Host) -> Void)?
    var onNew: (() -> Void)?
    var onClear: (() -> Void)?

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); build() }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor

        let blur = NSVisualEffectView()
        blur.material = .windowBackground
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        // 头部：大标题 + 副标题竖排，右侧按钮主次分明（新建是主操作 → primary）
        title.font = Theme.ui(28, .bold); title.textColor = Theme.text
        title.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = Theme.ui(12); subtitle.textColor = Theme.muted
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        let titleCol = NSStackView(views: [title, subtitle])
        titleCol.orientation = .vertical; titleCol.alignment = .leading; titleCol.spacing = 2

        let newBtn = PillButton("＋ 新建连接", style: .primary, hPad: 14, height: 30, target: self, action: #selector(newAction))
        let clearBtn = PillButton("清空历史", style: .ghost, hPad: 12, height: 30, target: self, action: #selector(clearAction))
        let head = NSStackView(views: [titleCol, NSView(), newBtn, clearBtn])
        head.spacing = 8; head.alignment = .centerY
        head.translatesAutoresizingMaskIntoConstraints = false

        // 标题下一条细分隔线，把"头部"和"卡片区"在视觉上分开
        let rule = NSView(); rule.wantsLayer = true
        rule.layer?.backgroundColor = Theme.border.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(grid); grid.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc

        empty.font = Theme.ui(13); empty.textColor = Theme.muted
        empty.translatesAutoresizingMaskIntoConstraints = false; empty.isHidden = true

        addSubview(head); addSubview(rule); addSubview(scroll); addSubview(empty)
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            head.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            head.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            rule.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 14),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            rule.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            doc.topAnchor.constraint(equalTo: scroll.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            grid.topAnchor.constraint(equalTo: doc.topAnchor),
            grid.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 24),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
        ])
    }

    @objc private func newAction() { onNew?() }
    @objc private func clearAction() { onClear?(); reload() }

    func reload() {
        let hosts = hostsProvider?() ?? []
        title.stringValue = "快速连接"
        subtitle.stringValue = hosts.isEmpty
            ? "还没有主机 —— 点右上角「＋ 新建连接」添加第一台"
            : "\(hosts.count) 台主机 · 双击卡片直接连接"
        grid.setCards(hosts.enumerated().map { (i, h) in card(h, index: i + 1) })
        empty.isHidden = !hosts.isEmpty
    }

    // 单张主机卡片。
    private func card(_ h: Host, index: Int) -> NSView {
        let box = HoverCardView(radius: Theme.radius, bg: Theme.bg2, border: Theme.border)
        box.onDoubleClick = { [weak self] in self?.onConnect?(h) }   // 副标题承诺了"双击直接连接"
        box.toolTip = "\(h.display)\n\(h.subtitle)\n双击直接连接"

        // 图标框：底色与图标都跟随识别出的系统（osId 首次连接后自动写入）
        let tint = osTint(h.osId)
        let iconBox = NSView(); iconBox.rounded(Theme.radiusSm, bg: tint.withAlphaComponent(0.12))
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        
        // 优先使用 Assets.xcassets 里的真实矢量 OS Logo
        let iconName = osImageName(h.osId)
        var iconImg: NSImage? = nil
        
        // 1. Xcode 编译态: 从 Assets.car 加载
        if let img = Bundle.module.image(forResource: NSImage.Name(iconName)) {
            iconImg = img
            iconImg?.isTemplate = true
        }
        // 2. swift build 态: 从原始文件加载 (兼容未编译的情况)
        else if let url = Bundle.module.url(forResource: iconName, withExtension: "svg", subdirectory: "Assets.xcassets/\\(iconName).imageset") {
            iconImg = NSImage(contentsOf: url)
            iconImg?.isTemplate = true
        }
        
        let finalImg = iconImg ?? NSImage(systemSymbolName: osSymbol(h.osId), accessibilityDescription: nil) ?? NSImage()
        let icon = NSImageView(image: finalImg)
        icon.contentTintColor = tint; icon.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(icon)
        NSLayoutConstraint.activate([
            iconBox.widthAnchor.constraint(equalToConstant: 34), iconBox.heightAnchor.constraint(equalToConstant: 34),
            icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor), icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
        ])
        let name = NSTextField(labelWithString: h.display); name.font = Theme.ui(14, .semibold); name.textColor = Theme.text
        name.lineBreakMode = .byTruncatingTail; name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sub = NSTextField(labelWithString: h.subtitle); sub.font = Theme.mono(10.5); sub.textColor = Theme.muted
        sub.lineBreakMode = .byTruncatingTail; sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let info = NSStackView(views: [name, sub]); info.orientation = .vertical; info.alignment = .leading; info.spacing = 1
        let osBadge = Badge(h.osId.isEmpty ? "SSH" : h.osId, kind: .gray)
        let topRow = NSStackView(views: [iconBox, info, NSView(), osBadge]); topRow.spacing = 10; topRow.alignment = .centerY

        // 徽章行
        let pwBadge = (hasPassword?(h) ?? false) ? Badge("已记住密码", kind: .green) : Badge("需要密码", kind: .gray)
        let pillRow = NSStackView(views: [Badge("端口 \(h.port)", kind: .gray), pwBadge, Badge("#\(index)", kind: .gray), NSView()])
        pillRow.spacing = 6; pillRow.alignment = .centerY

        // 按钮行
        let conn = PillButton("连接", style: .primary, hPad: 18, height: 26)
        conn.target = self; conn.action = #selector(connectCard(_:)); conn.identifier = .init(h.id)
        let edit = PillButton("编辑", style: .secondary, hPad: 14, height: 26)
        edit.target = self; edit.action = #selector(editCard(_:)); edit.identifier = .init(h.id)
        let btnRow = NSStackView(views: [conn, edit, NSView()]); btnRow.spacing = 8; btnRow.alignment = .centerY

        let v = NSStackView(views: [topRow, pillRow, btnRow]); v.orientation = .vertical; v.alignment = .leading; v.spacing = 10
        v.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            v.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            v.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),
            topRow.widthAnchor.constraint(equalTo: v.widthAnchor),
            pillRow.widthAnchor.constraint(equalTo: v.widthAnchor),
            btnRow.widthAnchor.constraint(equalTo: v.widthAnchor),
        ])
        
        // 给卡片加一点环境光阴影增加层级感
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 8
        box.shadow = shadow

        return box
    }

    private func host(_ id: String) -> Host? { (hostsProvider?() ?? []).first { $0.id == id } }
    @objc private func connectCard(_ b: NSButton) { if let h = host(b.identifier?.rawValue ?? "") { onConnect?(h) } }
    @objc private func editCard(_ b: NSButton) { if let h = host(b.identifier?.rawValue ?? "") { onEdit?(h) } }

    private func osImageName(_ osId: String) -> String {
        let s = osId.lowercased()
        if s.contains("ubuntu") { return "os-ubuntu" }
        if s.contains("debian") { return "os-debian" }
        if s.contains("cent") { return "os-centos" }
        if s.contains("rhel") { return "os-rhel" }
        if s.contains("fedora") { return "os-fedora" }
        if s.contains("alpine") { return "os-alpine" }
        if s.contains("arch") { return "os-arch" }
        if s.contains("suse") { return "os-suse" }
        if s.contains("openwrt") || s.contains("router") || s.contains("ddwrt") { return "os-openwrt" }
        if s.contains("win") { return "os-windows" }
        if s.contains("mac") || s.contains("darwin") { return "os-mac" }
        if s.contains("freebsd") || s.contains("bsd") { return "os-freebsd" }
        if s.contains("linux") { return "os-linux" }
        return "os-linux"
    }

    /// osId → 备用系统图标 (SF Symbols)。
    /// 当 Assets 里找不到真实 logo 时兜底使用。
    private func osSymbol(_ osId: String) -> String {
        let s = osId.lowercased()
        if s.contains("openwrt") || s.contains("router") || s.contains("ddwrt") { return "wifi.router.fill" }
        if s.contains("win") { return "pc" }
        if s.contains("mac") || s.contains("darwin") { return "apple.logo" }
        if s.contains("ubuntu") { return "circle.hexagongrid.fill" }
        if s.contains("debian") { return "hexagon.fill" }
        if s.contains("cent") || s.contains("rhel") || s.contains("rocky") || s.contains("alma") || s.contains("fedora") { return "shippingbox.fill" }
        if s.contains("alpine") { return "mountain.2.fill" }
        if s.contains("arch") { return "triangle.fill" }
        if s.contains("suse") { return "lizard.fill" }
        if s.contains("freebsd") || s.contains("bsd") { return "flag.fill" }
        if s.contains("linux") { return "terminal.fill" }
        return "terminal.fill"
    }
    /// 不同系统给不同主色，卡片一眼能区分（老仓库靠彩色 logo，这里靠图标+色）。
    private func osTint(_ osId: String) -> NSColor {
        let s = osId.lowercased()
        if s.contains("ubuntu") { return Theme.c("#e95420") }
        if s.contains("debian") { return Theme.c("#d70a53") }
        if s.contains("cent") || s.contains("rhel") || s.contains("rocky") || s.contains("alma") { return Theme.c("#ee0000") }
        if s.contains("fedora") { return Theme.c("#51a2da") }
        if s.contains("alpine") { return Theme.c("#0d597f") }
        if s.contains("arch") { return Theme.c("#1793d1") }
        if s.contains("suse") { return Theme.c("#73ba25") }
        if s.contains("openwrt") { return Theme.c("#00b5e2") }
        if s.contains("win") { return Theme.c("#0078d4") }
        if s.contains("mac") || s.contains("darwin") { return Theme.text }
        return Theme.accent
    }
}

/// 简易流式网格：把固定尺寸的卡片按容器宽度从左到右排布并换行，自动撑高。
final class FlowGrid: NSView {
    private var cards: [NSView] = []
    /// 卡片尺寸（默认快速连接卡片；备份面板等可覆盖）
    var cardSize = NSSize(width: 270, height: 126)
    private var cardW: CGFloat { cardSize.width }
    private var cardH: CGFloat { cardSize.height }
    private let gap: CGFloat = 14
    private var heightC: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        heightC = heightAnchor.constraint(equalToConstant: 10); heightC.isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func setCards(_ views: [NSView]) {
        cards.forEach { $0.removeFromSuperview() }
        cards = views
        for v in cards {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            v.widthAnchor.constraint(equalToConstant: cardW).isActive = true
            v.heightAnchor.constraint(equalToConstant: cardH).isActive = true
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        guard w > 0 else { return }
        let cols = max(1, Int((w + gap) / (cardW + gap)))
        var x: CGFloat = 0, y: CGFloat = 0, col = 0
        for v in cards {
            v.frame = NSRect(x: x, y: y, width: cardW, height: cardH)
            col += 1
            if col >= cols { col = 0; x = 0; y += cardH + gap }
            else { x += cardW + gap }
        }
        let rows = cards.isEmpty ? 0 : Int(ceil(Double(cards.count) / Double(cols)))
        let h = rows == 0 ? 10 : CGFloat(rows) * cardH + CGFloat(max(0, rows - 1)) * gap
        if abs(heightC.constant - h) > 0.5 { heightC.constant = h }
    }
}
