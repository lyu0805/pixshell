import AppKit

/// 密钥管理器：独立弹出窗口（对齐 ConnManager），不再盖主窗口全屏遮罩。
/// 列出 ~/.ssh 下的私钥（类型/位数/指纹/注释/是否带口令），
/// 支持 生成 / 复制公钥 / 用于当前主机 / 删除 / 在访达中显示。
final class KeyManager: NSWindowController {
    private let card = NSView()
    private let listStack = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private var keys: [SSHKeys.KeyInfo] = []

    /// 「用于此主机」：把选中的私钥路径回填给调用方（通常是主机编辑表单 / 当前主机）。
    var onUseKey: ((String) -> Void)?
    var onClose: (() -> Void)?

    init() {
        // 比旧遮罩卡片 560×(scroll 400) 约小三分之一 → 380×(scroll 270)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 360),
                         styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
                         backing: .buffered, defer: false)
        w.title = "密钥管理"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 320, height: 260)
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: w)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        reload()
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

        let title = NSTextField(labelWithString: "密钥管理")
        title.font = Theme.ui(15, .semibold); title.textColor = Theme.text
        let genBtn = PillButton(L10n.t("keys.generate"), style: .primary, hPad: 10, target: self, action: #selector(generateAction))
        let refBtn = PillButton(L10n.t("keys.refresh"), style: .secondary, hPad: 10, target: self, action: #selector(reloadAction))
        let closeBtn = PillButton(L10n.t("common.close"), style: .secondary, hPad: 10, target: self, action: #selector(hideAction))
        let rightBtns = NSStackView(views: [genBtn, refBtn, closeBtn]); rightBtns.spacing = 6
        let head = NSStackView(views: [title, NSView(), rightBtns]); head.spacing = 12; head.alignment = .centerY
        head.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = Theme.ui(12); countLabel.textColor = Theme.muted
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.lineBreakMode = .byTruncatingMiddle

        listStack.orientation = .vertical; listStack.alignment = .leading; listStack.spacing = 8
        listStack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = OverlayScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.verticalScroller = InvisibleScroller()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(listStack); scroll.documentView = doc
        NSLayoutConstraint.activate([
            listStack.topAnchor.constraint(equalTo: doc.topAnchor), listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor), listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor)
        ])

        card.addSubview(head); card.addSubview(countLabel); card.addSubview(scroll)
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            head.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            head.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            countLabel.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 8),
            countLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            countLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            doc.topAnchor.constraint(equalTo: scroll.topAnchor), doc.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            listStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 4),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -4),
            listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -4),
        ])
    }

    func reload() {
        keys = SSHKeys.list()
        countLabel.stringValue = keys.isEmpty
            ? L10n.t("keys.empty")
            : "\(keys.count) 个密钥 · ~/.ssh"
        listStack.arrangedSubviews.forEach { listStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (i, k) in keys.enumerated() {
            let row = keyRow(k, index: i)
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    private func keyRow(_ k: SSHKeys.KeyInfo, index: Int) -> NSView {
        let box = CardView(radius: Theme.radiusSm, bg: Theme.bg2, border: Theme.border)

        let name = NSTextField(labelWithString: k.name)
        name.font = Theme.ui(13, .semibold); name.textColor = Theme.text
        let typeBadge = Badge(k.type == "-" ? "未知" : "\(k.type) \(k.bits)", kind: .accent)
        let lockBadge = k.encrypted ? Badge("带口令", kind: .green) : Badge("无口令", kind: .gray)
        let pubBadge = k.hasPublic ? Badge(".pub 就绪", kind: .gray) : Badge("缺 .pub", kind: .gray)
        let topRow = NSStackView(views: [name, typeBadge, lockBadge, pubBadge, NSView()])
        topRow.spacing = 6; topRow.alignment = .centerY

        let fp = NSTextField(labelWithString: k.fingerprint)
        fp.font = Theme.mono(10.5); fp.textColor = Theme.muted
        fp.lineBreakMode = .byTruncatingMiddle
        let cmt = NSTextField(labelWithString: k.comment.isEmpty ? k.path : "\(k.comment) · \(k.path)")
        cmt.font = Theme.ui(10.5); cmt.textColor = Theme.muted
        cmt.lineBreakMode = .byTruncatingMiddle

        let useBtn = PillButton(L10n.t("keys.useForHost"), style: .primary, hPad: 8, height: 24,
                                font: Theme.ui(11, .semibold), target: self, action: #selector(useKey(_:)))
        let copyBtn = PillButton(L10n.t("keys.copyPub"), style: .secondary, hPad: 8, height: 24,
                                 font: Theme.ui(11, .medium), target: self, action: #selector(copyPub(_:)))
        let showBtn = PillButton("访达", style: .secondary, hPad: 8, height: 24,
                                 font: Theme.ui(11, .medium), target: self, action: #selector(revealKey(_:)))
        let delBtn = PillButton(L10n.t("keys.delete"), style: .danger, hPad: 8, height: 24,
                                font: Theme.ui(11, .medium), target: self, action: #selector(deleteKey(_:)))
        for b in [useBtn, copyBtn, showBtn, delBtn] { b.identifier = .init("\(index)") }
        let btnRow = NSStackView(views: [useBtn, copyBtn, showBtn, NSView(), delBtn])
        btnRow.spacing = 6; btnRow.alignment = .centerY

        let v = NSStackView(views: [topRow, fp, cmt, btnRow])
        v.orientation = .vertical; v.alignment = .leading; v.spacing = 5
        v.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            v.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            v.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            topRow.widthAnchor.constraint(equalTo: v.widthAnchor),
            btnRow.widthAnchor.constraint(equalTo: v.widthAnchor),
        ])
        return box
    }

    private func key(_ b: NSButton) -> SSHKeys.KeyInfo? {
        guard let i = Int(b.identifier?.rawValue ?? ""), keys.indices.contains(i) else { return nil }
        return keys[i]
    }

    // MARK: 动作
    @objc private func hideAction() { hide() }
    @objc private func reloadAction() { reload() }

    @objc private func useKey(_ b: NSButton) {
        guard let k = key(b) else { return }
        Log.info("选用密钥 \(k.name) → 当前主机", "keys")
        onUseKey?(k.path)
        hide()
    }

    @objc private func copyPub(_ b: NSButton) {
        guard let k = key(b) else { return }
        guard let text = SSHKeys.publicKeyText(k) else {
            Log.warn("读不到公钥 \(k.name)（缺 .pub 且私钥带口令）", "keys")
            let a = NSAlert.pix(); a.messageText = "读不到公钥"
            a.informativeText = "缺少 \(k.name).pub，且私钥带口令无法派生。可以用终端执行：\nssh-keygen -y -f \(k.path) > \(k.path).pub"
            a.runModal(); return
        }
        Log.info("复制公钥 \(k.name)", "keys")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let a = NSAlert.pix(); a.messageText = "公钥已复制"
        a.informativeText = "粘到服务器的 ~/.ssh/authorized_keys 即可免密登录。"
        a.runModal()
    }

    @objc private func revealKey(_ b: NSButton) {
        guard let k = key(b) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: k.path)])
    }

    @objc private func deleteKey(_ b: NSButton) {
        guard let k = key(b) else { return }
        let a = NSAlert.pix(); a.messageText = "删除密钥 \(k.name)？"
        a.informativeText = "会同时删除 \(k.name) 和 \(k.name).pub。此操作不可撤销；如果服务器上还留着对应的 authorized_keys 记录，请自行清理。"
        a.addButton(withTitle: "删除"); a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        SSHKeys.delete(k)
        reload()
    }

    /// 生成密钥表单：文件名 / 类型 / 注释 / 口令。
    @objc private func generateAction() {
        let a = NSAlert.pix()
        a.messageText = L10n.t("keys.genTitle")
        a.informativeText = L10n.t("keys.genBody")
        a.addButton(withTitle: L10n.t("keys.gen")); a.addButton(withTitle: L10n.t("common.cancel"))

        let nameField = NSTextField(); nameField.stringValue = "id_pixshell"
        let typePopup = NSPopUpButton()
        typePopup.addItems(withTitles: SSHKeys.KeyType.allCases.map { $0.display })
        let commentField = NSTextField()
        commentField.stringValue = "\(NSUserName())@\(ProcessInfo.processInfo.hostName)"
        let passField = NSSecureTextField()
        passField.placeholderString = "留空 = 不加口令"

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.columnSpacing = 8; grid.rowSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        for (label, view) in [("文件名", nameField as NSView), ("类型", typePopup), ("注释", commentField), ("口令", passField)] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let l = NSTextField(labelWithString: label); l.alignment = .right
            grid.addRow(with: [l, view])
        }
        let wrap = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 132))
        wrap.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 6),
            grid.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 6),
            grid.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -6),
            grid.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -6),
        ])
        a.accessoryView = wrap

        guard a.runModal() == .alertFirstButtonReturn else { return }
        let type = SSHKeys.KeyType.allCases[max(0, typePopup.indexOfSelectedItem)]
        Log.info("请求生成密钥 name=\(nameField.stringValue) type=\(type.rawValue) 带口令=\(!passField.stringValue.isEmpty)", "keys")
        switch SSHKeys.generate(name: nameField.stringValue, type: type,
                                comment: commentField.stringValue, passphrase: passField.stringValue) {
        case .success(let path):
            reload()
            let ok = NSAlert.pix(); ok.messageText = "密钥已生成"
            ok.informativeText = "\(path)\n\n点这条记录上的「复制公钥」，粘到服务器 ~/.ssh/authorized_keys 就能免密登录。"
            ok.runModal()
        case .failure(let e):
            Log.error("生成密钥失败: \(e.message)", "keys")
            let err = NSAlert.pix(); err.messageText = "生成失败"; err.informativeText = e.message
            err.runModal()
        }
    }
}
