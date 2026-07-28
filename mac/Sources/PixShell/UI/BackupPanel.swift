import AppKit

/// 备份选项弹窗（菜单「云端同步 → 备份选项配置…」）。
/// 独立 NSWindow，尺寸对齐连接管理器（约 400×420），可缩放；
/// 不再作为主窗全屏遮罩（会比软件 UI 大、盖住底栏）。
final class BackupPanel: NSWindowController {
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
    private var checks: [String: NSButton] = [:]

    var enabled: Set<String> = []
    var onSave: ((Set<String>) -> Void)?
    var onExport: (() -> Void)?
    var onImport: (() -> Void)?
    var onClose: (() -> Void)?

    init() {
        // 对齐 ConnManager 380×400，略加宽以容纳 2 列 provider 卡
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
                         styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 320, height: 280)
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: w)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(enabled set: Set<String>) {
        enabled = set
        for (id, b) in checks { b.state = set.contains(id) ? .on : .off }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
        onClose?()
    }

    private func build() {
        guard let w = window else { return }

        card.rounded(Theme.radiusLg, bg: Theme.bg, border: Theme.borderStrong)
        card.translatesAutoresizingMaskIntoConstraints = false

        let root = EscapableView()
        root.onEscape = { [weak self] in self?.hide() }
        root.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: root.topAnchor),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        w.contentView = root

        let title = NSTextField(labelWithString: "备份选项")
        title.font = Theme.ui(15, .semibold); title.textColor = Theme.text
        let closeBtn = IconButton(symbol: "xmark", tooltip: "关闭",
                                  size: NSSize(width: 24, height: 24),
                                  target: self, action: #selector(hideAction))
        let head = NSStackView(views: [title, NSView(), closeBtn])
        head.spacing = 10; head.alignment = .centerY
        head.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(wrappingLabelWithString: "默认全部关闭。勾选「启用」并保存后，对应云端同步菜单才会真正执行备份。")
        hint.font = Theme.ui(11.5); hint.textColor = Theme.muted
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 2 列小卡；卡片略缩小以适配 ~420 宽窗
        let grid = FlowGrid(); grid.translatesAutoresizingMaskIntoConstraints = false
        grid.cardSize = NSSize(width: 180, height: 108)
        grid.setCards(Self.providers.map { providerCard($0) })

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(grid); scroll.documentView = doc

        let exportB = PillButton("导出本地包…", style: .secondary, hPad: 10, height: 26, target: self, action: #selector(exportAction))
        let importB = PillButton("导入本地包…", style: .secondary, hPad: 10, height: 26, target: self, action: #selector(importAction))
        let cancelB = PillButton("取消", style: .secondary, hPad: 12, height: 26, target: self, action: #selector(hideAction))
        let saveB = PillButton("保存配置", style: .primary, hPad: 14, height: 26, target: self, action: #selector(saveAction))
        let foot = NSStackView(views: [exportB, importB, NSView(), cancelB, saveB])
        foot.spacing = 6; foot.alignment = .centerY
        foot.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(head); card.addSubview(hint); card.addSubview(scroll); card.addSubview(foot)
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            head.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            head.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            hint.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            hint.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: foot.topAnchor, constant: -10),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            grid.topAnchor.constraint(equalTo: doc.topAnchor),
            grid.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            foot.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            foot.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            foot.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
    }

    private func providerCard(_ p: Provider) -> NSView {
        let box = CardView(radius: Theme.radius, bg: Theme.bg2, border: Theme.border)
        let name = NSTextField(labelWithString: p.name)
        name.font = Theme.ui(12.5, .semibold); name.textColor = Theme.text
        let badge = Badge("未配置", kind: .gray)
        let top = NSStackView(views: [name, NSView(), badge]); top.spacing = 6; top.alignment = .centerY
        let desc = NSTextField(wrappingLabelWithString: p.desc)
        desc.font = Theme.ui(10.5); desc.textColor = Theme.muted
        desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        desc.maximumNumberOfLines = 3
        let check = NSButton(checkboxWithTitle: "启用", target: self, action: #selector(toggleProvider(_:)))
        check.identifier = .init(p.id); check.contentTintColor = Theme.text
        check.font = Theme.ui(11)
        checks[p.id] = check
        let cfg = PillButton("配置", style: .ghost, hPad: 6, height: 20, target: self, action: #selector(configProvider(_:)))
        cfg.identifier = .init(p.id)
        let bottom = NSStackView(views: [check, NSView(), cfg]); bottom.spacing = 6; bottom.alignment = .centerY

        let v = NSStackView(views: [top, desc, bottom])
        v.orientation = .vertical; v.alignment = .leading; v.spacing = 6
        v.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            v.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            v.bottomAnchor.constraint(lessThanOrEqualTo: box.bottomAnchor, constant: -10),
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
        if let win = window { a.beginSheetModal(for: win) } else { a.runModal() }
    }
    @objc private func exportAction() { onExport?() }
    @objc private func importAction() { onImport?() }
    @objc private func saveAction() { onSave?(enabled); hide() }
    @objc private func hideAction() { hide() }
}
