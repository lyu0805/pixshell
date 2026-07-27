import AppKit

/// 代理管理面板：卡片弹窗 + 列表(新建/编辑/删除)。
/// 遮罩+圆角卡片+HeaderPanGesture+点遮罩关闭+Esc关闭 这套交互照抄 SysInfoPanel.swift 的写法，
/// 不改那个文件；新建/编辑表单则照抄 HostEditor.swift 的 NSAlert 附件视图 sheet 模式。
final class ProxyPanel: NSView {
    private let card = NSView()
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let list = NSStackView()
    private var cardX: NSLayoutConstraint!
    private var cardY: NSLayoutConstraint!
    private let store = ProxyStore()
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); build() }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        wantsLayer = true; layer?.backgroundColor = NSColor(white: 0, alpha: 0.35).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        card.rounded(Theme.radiusLg, bg: Theme.bg, border: Theme.borderStrong)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        // 原来这里画了一组红/黄/绿假红绿灯，点了没任何反应；右侧已有真正的「关闭」按钮，去掉假的。
        let title = NSTextField(labelWithString: "代理管理"); title.font = Theme.ui(15, .semibold); title.textColor = Theme.text
        let add = PillButton("新建代理", style: .primary, hPad: 12, target: self, action: #selector(newAction))
        let close = PillButton("关闭", style: .secondary, hPad: 12, target: self, action: #selector(closeAction))
        let head = NSStackView(views: [title, NSView(), add, close]); head.spacing = 12; head.alignment = .centerY
        head.translatesAutoresizingMaskIntoConstraints = false
        head.addGestureRecognizer(HeaderPanGesture(target: self, action: #selector(dragCard(_:))))

        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        doc.translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 8
        list.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        scroll.documentView = doc

        card.addSubview(head); card.addSubview(scroll)
        cardX = card.centerXAnchor.constraint(equalTo: centerXAnchor)
        cardY = card.topAnchor.constraint(equalTo: topAnchor, constant: 60)
        NSLayoutConstraint.activate([
            cardX, cardY,
            card.widthAnchor.constraint(equalToConstant: 560),
            card.heightAnchor.constraint(equalToConstant: 460),
            head.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            head.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            head.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            doc.topAnchor.constraint(equalTo: scroll.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 4),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -4),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -4),
        ])
    }

    @objc private func closeAction() { onClose?() }
    // 点遮罩(卡片外)关闭
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !card.frame.contains(p) { onClose?() } else { super.mouseDown(with: event) }
    }
    // Esc 关闭
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !isHidden, event.keyCode == 53 { onClose?(); return true }
        return super.performKeyEquivalent(with: event)
    }
    @objc private func dragCard(_ g: NSPanGestureRecognizer) {
        let t = g.translation(in: self)
        cardX.constant += t.x; cardY.constant += t.y
        g.setTranslation(.zero, in: self)
    }

    // MARK: - 展示入口

    func show() {
        isHidden = false
        reload()
    }

    private func reload() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let items = store.list()
        if items.isEmpty {
            let l = NSTextField(labelWithString: "暂无代理，点右上角「新建代理」")
            l.font = Theme.ui(13); l.textColor = Theme.muted
            list.addArrangedSubview(l)
            return
        }
        for p in items { addFullWidth(row(for: p)) }
    }

    /// 必须先加入 list(建立共同父视图)再激活等宽约束，否则 NSLayoutConstraint 会因
    /// "没有共同祖先"直接抛异常崩溃(照抄 SysInfoPanel.addFullWidth 的教训)。
    private func addFullWidth(_ v: NSView) {
        list.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
    }

    private func row(for p: ProxyConfig) -> NSView {
        let c = CardView()
        let name = NSTextField(labelWithString: p.name.isEmpty ? p.host : p.name)
        name.font = Theme.ui(13, .semibold); name.textColor = Theme.text
        let typeBadge = Badge(p.type.displayName, kind: p.type == .sshJump ? .gray : .accent)
        let addr = NSTextField(labelWithString: "\(p.host):\(p.port)")
        addr.font = Theme.mono(11.5); addr.textColor = Theme.muted
        var infoViews: [NSView] = [name, typeBadge, addr]
        if !p.username.isEmpty { infoViews.append(Badge("已认证", kind: .green)) }
        let info = NSStackView(views: infoViews); info.spacing = 8; info.alignment = .centerY

        let edit = PillButton("编辑", style: .secondary, hPad: 10, target: self, action: #selector(editTapped(_:)))
        let del = PillButton("删除", style: .danger, hPad: 10, target: self, action: #selector(deleteTapped(_:)))
        edit.identifier = NSUserInterfaceItemIdentifier(p.id)
        del.identifier = NSUserInterfaceItemIdentifier(p.id)
        let actions = NSStackView(views: [edit, del]); actions.spacing = 6

        let row = NSStackView(views: [info, NSView(), actions])
        row.orientation = .horizontal; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false

        c.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: c.topAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -10),
        ])
        return c
    }

    // MARK: - 新建/编辑/删除

    @objc private func newAction() { presentEditor(existing: nil) }

    @objc private func editTapped(_ sender: PillButton) {
        guard let id = sender.identifier?.rawValue, let p = store.list().first(where: { $0.id == id }) else { return }
        presentEditor(existing: p)
    }

    @objc private func deleteTapped(_ sender: PillButton) {
        guard let id = sender.identifier?.rawValue else { return }
        store.delete(id)
        reload()
    }

    /// 新建/编辑表单：照抄 HostEditor.present 的 NSAlert + 附件视图 sheet 模式。
    private func presentEditor(existing: ProxyConfig?) {
        guard let win = self.window else { return }
        let alert = NSAlert.pix()
        alert.messageText = existing == nil ? "新建代理" : "编辑代理"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let form = ProxyFormView(proxy: existing)
        alert.accessoryView = form
        alert.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let self else { return }
            self.store.upsert(form.build(base: existing))
            self.reload()
        }
    }
}

private extension ProxyType {
    var displayName: String {
        switch self {
        case .socks5: return "SOCKS5"
        case .socks4: return "SOCKS4"
        case .http: return "HTTP"
        case .sshJump: return "SSH跳板(暂不支持)"
        }
    }
}

/// 新建/编辑代理表单，字段/网格布局照抄 HostEditor.swift 的 HostFormView。
/// 类型选择只暴露 socks5/socks4/http 三种——ssh-jump(跳板机)本版本未实现真正逻辑，
/// 不提供入口新建；已存在的老 ssh-jump 配置进来编辑时默认落到 socks5，需要用户重新选择类型再保存。
final class ProxyFormView: NSView {
    private let nameField = NSTextField()
    private let typePopup = NSPopUpButton()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let userField = NSTextField()
    private let passField = NSSecureTextField()

    private let supportedTypes: [ProxyType] = [.socks5, .socks4, .http]

    init(proxy: ProxyConfig?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 210))
        nameField.stringValue = proxy?.name ?? ""
        typePopup.addItems(withTitles: supportedTypes.map(\.displayName))
        let currentType = proxy?.type ?? .socks5
        let idx = supportedTypes.firstIndex(of: currentType) ?? 0
        typePopup.selectItem(at: idx)
        hostField.stringValue = proxy?.host ?? ""
        portField.stringValue = proxy.map { String($0.port) } ?? ""
        portField.placeholderString = "留空按类型取默认端口"
        userField.stringValue = proxy?.username ?? ""
        passField.stringValue = proxy?.password ?? ""

        let rows: [(String, NSView)] = [
            ("名称", nameField), ("类型", typePopup), ("主机", hostField),
            ("端口", portField), ("用户名", userField), ("密码", passField),
        ]
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.columnSpacing = 8; grid.rowSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        for (label, view) in rows {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let lab = NSTextField(labelWithString: label); lab.alignment = .right
            grid.addRow(with: [lab, view])
        }
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func build(base: ProxyConfig?) -> ProxyConfig {
        var p = base ?? ProxyConfig()
        p.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let idx = typePopup.indexOfSelectedItem
        let type = (idx >= 0 && idx < supportedTypes.count) ? supportedTypes[idx] : .socks5
        p.type = type
        p.host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let portText = portField.stringValue.trimmingCharacters(in: .whitespaces)
        p.port = Int(portText) ?? ProxyConfig.defaultPort(for: type)
        p.username = userField.stringValue.trimmingCharacters(in: .whitespaces)
        p.password = passField.stringValue
        return p
    }
}
