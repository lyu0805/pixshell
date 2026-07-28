import AppKit

/// 「AI 工具 SSH 桥接」注册窗口。
/// 尺寸对齐 KeyManager / 新建连接（~380×360），可拖、可缩放；颜色只走 Theme。
final class AiSshBridgeManager: NSWindowController {

    private let card = NSView()
    private let statusDot = Dot(Theme.muted, size: 9)
    private let statusLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(wrappingLabelWithString: "")
    private let toolsLabel = NSTextField(wrappingLabelWithString: "")
    private let toolsStack = NSStackView()
    private let pathLabel = NSTextField(wrappingLabelWithString: "")
    private var registerBtn: PillButton!
    private var unregisterBtn: PillButton!
    private var refreshBtn: PillButton!

    /// 注册成功/失败时回调主窗状态栏（可选）。
    var onStatus: ((String) -> Void)?
    var bridgePortProvider: (() -> Int?)?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 360),
                         styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
                         backing: .buffered, defer: false)
        w.title = "AI 工具 SSH 桥接"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        // IRON：自由拖动
        w.isMovableByWindowBackground = true
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = true
        w.isReleasedWhenClosed = false
        // IRON：自由缩放
        w.minSize = NSSize(width: 320, height: 260)
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: w)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        reload()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func hide() { window?.orderOut(nil) }

    // MARK: - UI

    private func build() {
        guard let w = window else { return }

        // IRON：Theme.bg + Theme.borderStrong，无额外杂色描边
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

        let title = NSTextField(labelWithString: "AI 工具 SSH 桥接")
        title.font = Theme.ui(15, .semibold)
        title.textColor = Theme.text
        let closeBtn = PillButton("关闭", style: .secondary, hPad: 10, target: self, action: #selector(hideAction))
        let head = NSStackView(views: [title, NSView(), closeBtn])
        head.spacing = 12; head.alignment = .centerY
        head.translatesAutoresizingMaskIntoConstraints = false

        descLabel.stringValue = "将 PixShell 设为 Claude Code / Codex / OpenCode 等 AI 工具的默认交互式 SSH 引擎。"
        descLabel.font = Theme.ui(11.5)
        descLabel.textColor = Theme.muted
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 状态行
        statusLabel.font = Theme.ui(12, .medium)
        statusLabel.textColor = Theme.text
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        let statusRow = NSStackView(views: [statusDot, statusLabel, NSView()])
        statusRow.spacing = 8; statusRow.alignment = .centerY
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        // 已检测工具
        let toolsTitle = NSTextField(labelWithString: "本机 AI 工具")
        toolsTitle.font = Theme.ui(11, .semibold)
        toolsTitle.textColor = Theme.text
        toolsLabel.font = Theme.ui(11)
        toolsLabel.textColor = Theme.muted
        toolsLabel.translatesAutoresizingMaskIntoConstraints = false

        toolsStack.orientation = .horizontal
        toolsStack.spacing = 6
        toolsStack.alignment = .centerY
        toolsStack.translatesAutoresizingMaskIntoConstraints = false
        // 徽章过多时允许换行：外包一层可滚动区域
        let toolsBox = CardView(radius: Theme.radiusSm, bg: Theme.bg2, border: Theme.border)
        let toolsInner = NSStackView(views: [toolsTitle, toolsStack, toolsLabel])
        toolsInner.orientation = .vertical
        toolsInner.alignment = .leading
        toolsInner.spacing = 6
        toolsInner.translatesAutoresizingMaskIntoConstraints = false
        toolsBox.addSubview(toolsInner)
        NSLayoutConstraint.activate([
            toolsInner.topAnchor.constraint(equalTo: toolsBox.topAnchor, constant: 10),
            toolsInner.leadingAnchor.constraint(equalTo: toolsBox.leadingAnchor, constant: 10),
            toolsInner.trailingAnchor.constraint(equalTo: toolsBox.trailingAnchor, constant: -10),
            toolsInner.bottomAnchor.constraint(equalTo: toolsBox.bottomAnchor, constant: -10),
            toolsStack.widthAnchor.constraint(lessThanOrEqualTo: toolsInner.widthAnchor),
        ])

        pathLabel.font = Theme.mono(10)
        pathLabel.textColor = Theme.muted
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.lineBreakMode = .byTruncatingMiddle

        registerBtn = PillButton("一键注册为 AI 默认 SSH 工具", style: .primary, hPad: 12, height: 28,
                                 font: Theme.ui(12, .semibold), target: self, action: #selector(registerAction))
        unregisterBtn = PillButton("一键取消注册", style: .danger, hPad: 12, height: 28,
                                   font: Theme.ui(12, .medium), target: self, action: #selector(unregisterAction))
        refreshBtn = PillButton("刷新检测", style: .secondary, hPad: 10, height: 28,
                                font: Theme.ui(12, .medium), target: self, action: #selector(reloadAction))

        let btnCol = NSStackView(views: [registerBtn, unregisterBtn])
        btnCol.orientation = .vertical
        btnCol.spacing = 8
        btnCol.alignment = .leading
        btnCol.translatesAutoresizingMaskIntoConstraints = false

        let foot = NSStackView(views: [refreshBtn, NSView()])
        foot.spacing = 8; foot.alignment = .centerY
        foot.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(head)
        card.addSubview(descLabel)
        card.addSubview(statusRow)
        card.addSubview(toolsBox)
        card.addSubview(pathLabel)
        card.addSubview(btnCol)
        card.addSubview(foot)

        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            head.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            head.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),

            descLabel.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 10),
            descLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            descLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),

            statusRow.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 12),
            statusRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            statusRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),

            toolsBox.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 12),
            toolsBox.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            toolsBox.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),

            pathLabel.topAnchor.constraint(equalTo: toolsBox.bottomAnchor, constant: 10),
            pathLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            pathLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),

            btnCol.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 12),
            btnCol.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            btnCol.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            registerBtn.widthAnchor.constraint(equalTo: btnCol.widthAnchor),
            unregisterBtn.widthAnchor.constraint(equalTo: btnCol.widthAnchor),

            foot.topAnchor.constraint(equalTo: btnCol.bottomAnchor, constant: 10),
            foot.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            foot.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            foot.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - Reload

    func reload() {
        let st = AiSshBridge.status()
        switch st {
        case .registered(let wrapper, let link):
            statusDot.setColor(Theme.ok)
            statusLabel.stringValue = "当前状态：已注册"
            statusLabel.textColor = Theme.text
            if let link = link {
                pathLabel.stringValue = "软链 \(link)\n→ \(wrapper)"
            } else {
                pathLabel.stringValue = "包装 \(wrapper)\n（尚未链到 ~/.local/bin/ssh）"
            }
            registerBtn.title = "重新注册"
            unregisterBtn.isEnabled = true
        case .notRegistered:
            statusDot.setColor(Theme.muted)
            statusLabel.stringValue = "当前状态：未注册"
            statusLabel.textColor = Theme.text
            pathLabel.stringValue = "注册后将写入：\n\(AiSshBridge.wrapperPath.path)\n并软链 ~/.local/bin/ssh"
            registerBtn.title = "一键注册为 AI 默认 SSH 工具"
            unregisterBtn.isEnabled = true
        case .blocked(let existing):
            statusDot.setColor(Theme.warn)
            statusLabel.stringValue = "当前状态：被占用（未注册）"
            statusLabel.textColor = Theme.text
            pathLabel.stringValue = "\(existing) 已存在且不是 PixShell 包装。\n请手动处理后再注册（绝不覆盖用户文件）。"
            registerBtn.title = "一键注册为 AI 默认 SSH 工具"
            unregisterBtn.isEnabled = true
        }

        // 工具徽章
        toolsStack.arrangedSubviews.forEach { toolsStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let tools = AiSshBridge.detectTools()
        if tools.isEmpty {
            toolsLabel.stringValue = "未检测到 Claude Code / Codex / Grok / OpenCode / Cursor / Windsurf / Ollama。"
            let none = Badge("未检测到", kind: .gray)
            toolsStack.addArrangedSubview(none)
        } else {
            toolsLabel.stringValue = "已检测到：\(tools.map(\.display).joined(separator: "、"))。注册/取消将对全局 ssh 包装生效（上述工具共用）。"
            for t in tools {
                let kind: Badge.Kind = t.kind == .cli ? .green : .accent
                let b = Badge(t.display, kind: kind)
                toolsStack.addArrangedSubview(b)
            }
            toolsStack.addArrangedSubview(NSView()) // 弹簧
        }
    }

    // MARK: - Actions

    @objc private func hideAction() { hide() }
    @objc private func reloadAction() { reload() }

    @objc private func registerAction() {
        let port = bridgePortProvider?()
        let r = AiSshBridge.register(bridgePort: port)
        reload()
        onStatus?(r.message.components(separatedBy: "\n").first ?? r.message)
        let a = NSAlert.pix()
        a.messageText = r.ok ? "注册完成" : "注册未完成"
        a.informativeText = r.message
        a.addButton(withTitle: "好")
        a.runModal()
    }

    @objc private func unregisterAction() {
        let r = AiSshBridge.unregister()
        reload()
        onStatus?(r.message.components(separatedBy: "\n").first ?? r.message)
        let a = NSAlert.pix()
        a.messageText = "已取消注册"
        a.informativeText = r.message
        a.addButton(withTitle: "好")
        a.runModal()
    }
}
