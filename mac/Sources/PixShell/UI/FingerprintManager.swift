import AppKit

/// 主机指纹管理：独立弹出窗口（对齐 KeyManager / ConnManager）。
/// 列出 ~/.ssh/known_hosts 条目（主机 / 类型 / SHA256·MD5 指纹），支持删除。
final class FingerprintManager: NSWindowController {
    private let card = NSView()
    private let listStack = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private var entries: [KnownHosts.Entry] = []

    var onClose: (() -> Void)?

    init() {
        // 标题栏多了「导入…/导出…」，默认宽略增，避免与标题重叠
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                         styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
                         backing: .buffered, defer: false)
        w.title = "主机指纹管理"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 380, height: 280)
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

        let title = NSTextField(labelWithString: "主机指纹管理")
        title.font = Theme.ui(15, .semibold); title.textColor = Theme.text
        let importBtn = PillButton("导入…", style: .secondary, hPad: 10, target: self, action: #selector(importAction))
        let exportBtn = PillButton("导出…", style: .secondary, hPad: 10, target: self, action: #selector(exportAction))
        let refBtn = PillButton("刷新", style: .secondary, hPad: 10, target: self, action: #selector(reloadAction))
        let closeBtn = PillButton("关闭", style: .secondary, hPad: 10, target: self, action: #selector(hideAction))
        let rightBtns = NSStackView(views: [importBtn, exportBtn, refBtn, closeBtn]); rightBtns.spacing = 6
        let head = NSStackView(views: [title, NSView(), rightBtns]); head.spacing = 12; head.alignment = .centerY
        head.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = Theme.ui(12); countLabel.textColor = Theme.muted
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.lineBreakMode = .byTruncatingMiddle

        listStack.orientation = .vertical; listStack.alignment = .leading; listStack.spacing = 8
        listStack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.verticalScroller = InvisibleScroller()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(listStack); scroll.documentView = doc
        NSLayoutConstraint.activate([
            listStack.topAnchor.constraint(equalTo: doc.topAnchor), listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor), listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
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
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            doc.topAnchor.constraint(equalTo: scroll.topAnchor), doc.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            listStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 4),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -4),
            listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -4),
        ])
    }

    func reload() {
        entries = KnownHosts.list()
        countLabel.stringValue = entries.isEmpty
            ? "~/.ssh/known_hosts 为空 —— 首次 SSH 连接后会自动写入"
            : "\(entries.count) 条指纹 · ~/.ssh/known_hosts"
        listStack.arrangedSubviews.forEach { listStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (i, e) in entries.enumerated() {
            let row = entryRow(e, index: i)
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    private func entryRow(_ e: KnownHosts.Entry, index: Int) -> NSView {
        let box = CardView(radius: Theme.radiusSm, bg: Theme.bg2, border: Theme.border)

        let name = NSTextField(labelWithString: e.hosts)
        name.font = Theme.ui(13, .semibold); name.textColor = Theme.text
        name.lineBreakMode = .byTruncatingMiddle
        let typeBadge = Badge(e.keyTypeShort, kind: .accent)
        var topViews: [NSView] = [name, typeBadge]
        if let m = e.marker {
            topViews.append(Badge(m, kind: .gray))
        }
        topViews.append(NSView())
        let topRow = NSStackView(views: topViews)
        topRow.spacing = 6; topRow.alignment = .centerY

        let sha = NSTextField(labelWithString: e.fingerprintSHA256)
        sha.font = Theme.mono(10.5); sha.textColor = Theme.muted
        sha.lineBreakMode = .byTruncatingMiddle
        let md5 = NSTextField(labelWithString: e.fingerprintMD5)
        md5.font = Theme.mono(10.5); md5.textColor = Theme.muted
        md5.lineBreakMode = .byTruncatingMiddle

        let delBtn = PillButton("删除指纹", style: .danger, hPad: 8, height: 24,
                                font: Theme.ui(11, .medium), target: self, action: #selector(deleteEntry(_:)))
        delBtn.identifier = .init("\(index)")
        let btnRow = NSStackView(views: [NSView(), delBtn])
        btnRow.spacing = 6; btnRow.alignment = .centerY

        let v = NSStackView(views: [topRow, sha, md5, btnRow])
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
            name.widthAnchor.constraint(lessThanOrEqualTo: topRow.widthAnchor, constant: -80),
        ])
        return box
    }

    private func entry(_ b: NSButton) -> KnownHosts.Entry? {
        guard let i = Int(b.identifier?.rawValue ?? ""), entries.indices.contains(i) else { return nil }
        return entries[i]
    }

    @objc private func hideAction() { hide() }
    @objc private func reloadAction() { reload() }

    @objc private func exportAction() {
        let p = NSSavePanel()
        p.nameFieldStringValue = entries.isEmpty ? "known_hosts.txt" : "known_hosts_backup.txt"
        p.allowedContentTypes = [.plainText]
        p.canCreateDirectories = true
        p.isExtensionHidden = false
        p.title = "导出主机指纹"
        p.message = "将 ~/.ssh/known_hosts 导出为文本文件"
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let n = try KnownHosts.export(to: url)
            let a = NSAlert.pix(); a.messageText = "导出完成"
            a.informativeText = "已导出 \(n) 条指纹\n\(url.path)"
            a.addButton(withTitle: "好")
            a.runModal()
        } catch {
            let a = NSAlert.pix(); a.messageText = "导出失败"
            a.informativeText = error.localizedDescription
            a.addButton(withTitle: "好")
            a.runModal()
        }
    }

    @objc private func importAction() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        // 不限类型：known_hosts 常无扩展名
        p.title = "导入主机指纹"
        p.message = "选择 known_hosts 格式文本文件，新条目将合并进 ~/.ssh/known_hosts"
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let r = try KnownHosts.importMerging(from: url)
            reload()
            let a = NSAlert.pix(); a.messageText = "导入完成"
            a.informativeText = "新增 \(r.added) 条 · 跳过重复 \(r.skippedDuplicate) · 无效 \(r.skippedInvalid)"
            a.addButton(withTitle: "好")
            a.runModal()
        } catch {
            let a = NSAlert.pix(); a.messageText = "导入失败"
            a.informativeText = error.localizedDescription
            a.addButton(withTitle: "好")
            a.runModal()
        }
    }

    @objc private func deleteEntry(_ b: NSButton) {
        guard let e = entry(b) else { return }
        let a = NSAlert.pix(); a.messageText = "删除主机指纹？"
        a.informativeText = "将从 ~/.ssh/known_hosts 移除：\n\(e.hosts)  ·  \(e.keyTypeShort)\n\n下次连接该主机时会重新确认主机密钥。"
        a.addButton(withTitle: "删除"); a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        KnownHosts.delete(e)
        reload()
    }
}
