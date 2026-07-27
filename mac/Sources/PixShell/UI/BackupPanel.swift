import AppKit

/// 备份选项（菜单「云端同步 → 备份选项配置…」）。
/// 1:1 对齐老仓库：默认全部关闭；每个provider 一张卡（名称 + 未配置徽章 + 说明 + 启用勾选 + 配置）；
/// 底部「导出本地包…/导入本地包…」+「取消/保存配置」。
final class BackupPanel: NSView {
    struct Provider {
        let id: String, name: String, desc: String
    }
    static let providers: [Provider] = [
        .init(id: "local", name: "本地", desc: "导出/导入本机 JSON 备份包（hosts / 设置 / 快捷命令）"),
        .init(id: "webdav", name: "WebDAV", desc: "一键打开坚果云等登录页，再填应用密码/路径"),
        .init(id: "github", name: "GitHub", desc: "一键登录 GitHub（Device Flow）或浏览器授权，自动写入 Token"),
        .init(id: "google", name: "谷歌云盘", desc: "Google Drive API（OAuth 客户端）"),
        .init(id: "onedrive", name: "微软 OneDrive", desc: "Microsoft Graph / OneDrive"),
        .init(id: "baidu", name: "百度网盘", desc: "百度网盘开放平台应用"),
        .init(id: "quark", name: "夸克网盘", desc: "夸克开放能力 / Cookie 会话（按官方文档）"),
    ]

    private let card = NSView()
    private var cardX: NSLayoutConstraint!
    private var cardY: NSLayoutConstraint!
    private var checks: [String: NSButton] = [:]

    var enabled: Set<String> = []          // 已启用的 provider id
    var onSave: ((Set<String>) -> Void)?
    var onExport: (() -> Void)?
    var onImport: (() -> Void)?
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); build() }
    required init?(coder: NSCoder) { fatalError() }

    func show(enabled set: Set<String>) {
        enabled = set
        for (id, b) in checks { b.state = set.contains(id) ? .on : .off }
        isHidden = false
    }

    private func build() {
        wantsLayer = true; layer?.backgroundColor = NSColor(white: 0, alpha: 0.35).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        card.rounded(Theme.radiusLg, bg: Theme.bg, border: Theme.borderStrong)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let title = NSTextField(labelWithString: "备份选项"); title.font = Theme.ui(16, .semibold); title.textColor = Theme.text
        let close = PillButton("✕", style: .ghost, hPad: 8, height: 24, target: self, action: #selector(closeAction))
        let head = NSStackView(views: [title, NSView(), close]); head.spacing = 10; head.alignment = .centerY
        head.translatesAutoresizingMaskIntoConstraints = false
        head.addGestureRecognizer(HeaderPanGesture(target: self, action: #selector(dragCard(_:))))

        let hint = NSTextField(labelWithString: "默认全部关闭。勾选「启用」并保存后，对应云端同步菜单才会真正执行备份。")
        hint.font = Theme.ui(12); hint.textColor = Theme.muted
        hint.translatesAutoresizingMaskIntoConstraints = false

        // provider 卡片网格
        let grid = FlowGrid(); grid.translatesAutoresizingMaskIntoConstraints = false
        grid.cardSize = NSSize(width: 300, height: 132)
        grid.setCards(Self.providers.map { providerCard($0) })

        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(grid); scroll.documentView = doc

        let exportB = PillButton("导出本地包…", style: .secondary, hPad: 12, target: self, action: #selector(exportAction))
        let importB = PillButton("导入本地包…", style: .secondary, hPad: 12, target: self, action: #selector(importAction))
        let cancelB = PillButton("取消", style: .secondary, hPad: 14, target: self, action: #selector(closeAction))
        let saveB = PillButton("保存配置", style: .primary, hPad: 16, target: self, action: #selector(saveAction))
        let foot = NSStackView(views: [exportB, importB, NSView(), cancelB, saveB])
        foot.spacing = 8; foot.alignment = .centerY
        foot.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(head); card.addSubview(hint); card.addSubview(scroll); card.addSubview(foot)
        cardX = card.centerXAnchor.constraint(equalTo: centerXAnchor)
        cardY = card.topAnchor.constraint(equalTo: topAnchor, constant: 30)
        NSLayoutConstraint.activate([
            cardX, cardY,
            card.widthAnchor.constraint(equalToConstant: 700),
            card.heightAnchor.constraint(equalToConstant: 620),
            head.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            head.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            head.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            hint.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            hint.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            scroll.bottomAnchor.constraint(equalTo: foot.topAnchor, constant: -12),
            doc.topAnchor.constraint(equalTo: scroll.topAnchor), doc.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            grid.topAnchor.constraint(equalTo: doc.topAnchor), grid.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: doc.trailingAnchor), grid.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            foot.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            foot.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            foot.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
    }

    private func providerCard(_ p: Provider) -> NSView {
        let box = CardView(radius: Theme.radius, bg: Theme.bg2, border: Theme.border)
        let name = NSTextField(labelWithString: p.name); name.font = Theme.ui(14, .semibold); name.textColor = Theme.text
        let badge = Badge("未配置", kind: .gray)
        let top = NSStackView(views: [name, NSView(), badge]); top.spacing = 8; top.alignment = .centerY
        let desc = NSTextField(wrappingLabelWithString: p.desc)
        desc.font = Theme.ui(11.5); desc.textColor = Theme.muted
        desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let check = NSButton(checkboxWithTitle: "启用", target: self, action: #selector(toggleProvider(_:)))
        check.identifier = .init(p.id); check.contentTintColor = Theme.text
        checks[p.id] = check
        let cfg = PillButton("配置", style: .ghost, hPad: 8, height: 22, target: self, action: #selector(configProvider(_:)))
        cfg.identifier = .init(p.id)
        let bottom = NSStackView(views: [check, NSView(), cfg]); bottom.spacing = 8; bottom.alignment = .centerY

        let v = NSStackView(views: [top, desc, bottom]); v.orientation = .vertical; v.alignment = .leading; v.spacing = 8
        v.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            v.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            v.bottomAnchor.constraint(lessThanOrEqualTo: box.bottomAnchor, constant: -12),
            top.widthAnchor.constraint(equalTo: v.widthAnchor),
            desc.widthAnchor.constraint(equalTo: v.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: v.widthAnchor),
        ])
        return box
    }

    @objc private func toggleProvider(_ b: NSButton) {
        guard let id = b.identifier?.rawValue else { return }
        if b.state == .on { enabled.insert(id) } else { enabled.remove(id) }
    }
    @objc private func configProvider(_ b: NSButton) {
        guard let id = b.identifier?.rawValue,
              let p = Self.providers.first(where: { $0.id == id }) else { return }
        let a = NSAlert.pix(); a.messageText = "\(p.name) · 配置"
        a.informativeText = p.id == "local"
            ? "本地备份无需凭据：用下方「导出/导入本地包」即可。"
            : "\(p.desc)\n\n凭据请在此填写（保存在本机设置中）。"
        a.addButton(withTitle: "好")
        a.runModal()
    }
    @objc private func exportAction() { onExport?() }
    @objc private func importAction() { onImport?() }
    @objc private func saveAction() { onSave?(enabled); onClose?() }
    @objc private func closeAction() { onClose?() }
    @objc private func dragCard(_ g: NSPanGestureRecognizer) {
        let t = g.translation(in: self)
        cardX.constant += t.x; cardY.constant += t.y
        g.setTranslation(.zero, in: self)
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !card.frame.contains(p) { onClose?() } else { super.mouseDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !isHidden, event.keyCode == 53 { onClose?(); return true }
        return super.performKeyEquivalent(with: event)
    }
}
