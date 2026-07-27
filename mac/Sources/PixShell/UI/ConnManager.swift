import AppKit

/// 连接管理器弹窗（自绘复刻老仓库 conn-mgr）：遮罩 + 居中圆角卡片，
/// 头部三色圆点 + 标题 + ＋连接/＋分组/刷新/关闭；搜索；分组行(▶ 📁 名称 计数 重命名 删除)。
/// 宿主提供 hosts()、连接/新建/编辑/删除回调。
final class ConnManager: NSWindowController {
    private let card = NSView()
    private let listStack = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private var collapsed = Set<String>()

    var hostsProvider: (() -> [Host])?
    var onConnect: ((Host) -> Void)?
    var onNew: (() -> Void)?
    var onEdit: ((Host) -> Void)?
    var onDelete: ((Host) -> Void)?
    var onCreateGroup: ((String) -> Void)?              // ＋分组
    var onRenameGroup: ((String, String) -> Void)?      // 旧名 → 新名
    var onDeleteGroup: ((String) -> Void)?              // 组内主机移回「默认」
    var onDuplicate: ((Host) -> Void)?                 // 右键「复制主机」

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 580),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true // 允许点卡片空白处拖动
        w.backgroundColor = .clear           // 背景透明，露出我们画的圆角卡片
        w.isOpaque = false
        w.hasShadow = true
        w.isReleasedWhenClosed = false
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
    func hide() { window?.orderOut(nil) }

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
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])
        w.contentView = root

        // 头部：标题 + 按钮
        // 这里原本画了一组红/黄/绿圆点冒充窗口红绿灯 —— 但它们只是装饰、点了没反应，
        // 右边已经有真正能用的「关闭」按钮，假按钮只会误导，直接去掉。
        let title = NSTextField(labelWithString: "连接管理器"); title.font = Theme.ui(15, .semibold); title.textColor = Theme.text
        let addBtn = PillButton("＋连接", style: .secondary, hPad: 10, target: self, action: #selector(newHost))
        let grpBtn = PillButton("＋分组", style: .secondary, hPad: 10, target: self, action: #selector(newGroup))
        let refBtn = PillButton("刷新", style: .secondary, hPad: 10, target: self, action: #selector(reloadAction))
        let closeBtn = IconButton(symbol: "xmark", tooltip: "关闭", size: NSSize(width: 24, height: 24), target: self, action: #selector(hideAction))
        let rightBtns = NSStackView(views: [addBtn, grpBtn, refBtn, closeBtn]); rightBtns.spacing = 6
        let head = NSStackView(views: [title, NSView(), rightBtns]); head.spacing = 12; head.alignment = .centerY
        head.translatesAutoresizingMaskIntoConstraints = false

        // 搜索
        countLabel.font = Theme.ui(12); countLabel.textColor = Theme.muted
        let search = NSTextField(); search.placeholderString = "搜索主机…"; search.font = Theme.ui(12)
        search.isBordered = false; search.drawsBackground = false; search.textColor = Theme.text
        search.focusRingType = .none
        let searchWrap = NSView(); searchWrap.rounded(Theme.radiusSm, bg: Theme.bg2, border: Theme.border)
        searchWrap.translatesAutoresizingMaskIntoConstraints = false
        search.translatesAutoresizingMaskIntoConstraints = false; searchWrap.addSubview(search)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: searchWrap.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: searchWrap.trailingAnchor, constant: -10),
            search.centerYAnchor.constraint(equalTo: searchWrap.centerYAnchor),
            searchWrap.heightAnchor.constraint(equalToConstant: 30),
        ])
        let searchRow = NSStackView(views: [countLabel, searchWrap]); searchRow.spacing = 10
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        searchWrap.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true

        // 列表
        listStack.orientation = .vertical; listStack.alignment = .leading; listStack.spacing = 8
        listStack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(listStack); scroll.documentView = doc

        card.addSubview(head); card.addSubview(searchRow); card.addSubview(scroll)
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            head.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            head.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            searchRow.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 12),
            searchRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            searchRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            scroll.heightAnchor.constraint(equalToConstant: 440),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            listStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 4),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -4),
            listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -4),
        ])
    }

    @objc private func hideAction() { hide() }
    @objc private func reloadAction() { reload() }
    @objc private func newHost() { onNew?() }

    /// ＋分组：把当前选中/首台主机移入新分组（分组是主机上的字段，没有主机的空分组无意义）
    @objc private func newGroup() {
        let name = ask("新建分组", "输入分组名称（之后可在主机编辑里把主机移入该分组）", preset: "")
        guard !name.isEmpty else { return }
        onCreateGroup?(name)
        reload()
    }
    @objc private func renameGroup(_ b: NSButton) {
        guard let old = b.identifier?.rawValue else { return }
        let name = ask("重命名分组", "把「\(old)」改名为：", preset: old)
        guard !name.isEmpty, name != old else { return }
        onRenameGroup?(old, name)
        reload()
    }
    @objc private func deleteGroup(_ b: NSButton) {
        guard let name = b.identifier?.rawValue else { return }
        let a = NSAlert.pix(); a.messageText = "删除分组「\(name)」？"
        a.informativeText = "该组内主机不会被删除，会移回「默认」分组。"
        a.addButton(withTitle: "删除分组"); a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        onDeleteGroup?(name)
        reload()
    }
    private func ask(_ title: String, _ info: String, preset: String) -> String {
        let a = NSAlert.pix(); a.messageText = title; a.informativeText = info
        a.addButton(withTitle: "确定"); a.addButton(withTitle: "取消")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        tf.stringValue = preset
        a.accessoryView = tf; a.window.initialFirstResponder = tf
        return a.runModal() == .alertFirstButtonReturn ? tf.stringValue.trimmingCharacters(in: .whitespaces) : ""
    }

    func reload() {
        let hosts = hostsProvider?() ?? []
        var groups: [String: [Host]] = [:]
        for h in hosts { groups[h.group.isEmpty ? "默认" : h.group, default: []].append(h) }
        let names = groups.keys.sorted { $0 == "默认" ? false : ($1 == "默认" ? true : $0 < $1) }
        countLabel.stringValue = "\(hosts.count) 台 · \(names.count) 组"
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for g in names { listStack.addArrangedSubview(groupRow(g, groups[g] ?? [])) }
        listStack.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true }
    }

    private func groupRow(_ name: String, _ hosts: [Host]) -> NSView {
        let box = NSView(); box.rounded(Theme.radius, bg: Theme.bg2, border: Theme.border)
        box.translatesAutoresizingMaskIntoConstraints = false
        let arrow = NSTextField(labelWithString: collapsed.contains(name) ? "▶" : "▼"); arrow.font = Theme.ui(10); arrow.textColor = Theme.muted
        let folder = NSTextField(labelWithString: "📁"); folder.font = Theme.ui(13)
        let title = NSTextField(labelWithString: name); title.font = Theme.ui(13, .semibold); title.textColor = Theme.text
        let count = Badge("\(hosts.count)", kind: .gray)
        // 分组重命名 / 删除（删除=把该组主机移回「默认」，不删主机）
        let renameBtn = PillButton("重命名", style: .ghost, hPad: 8, height: 20, target: self, action: #selector(renameGroup(_:)))
        renameBtn.identifier = .init(name)
        let delBtn = PillButton("删除", style: .ghost, hPad: 8, height: 20, target: self, action: #selector(deleteGroup(_:)))
        delBtn.identifier = .init(name)
        let head = NSStackView(views: [arrow, folder, title, NSView(), count, renameBtn, delBtn]); head.spacing = 8; head.alignment = .centerY
        head.setCustomSpacing(4, after: arrow)
        head.setCustomSpacing(2, after: folder)
        head.translatesAutoresizingMaskIntoConstraints = false
        let inner = NSStackView(views: [head]); inner.orientation = .vertical; inner.alignment = .leading; inner.spacing = 6
        inner.translatesAutoresizingMaskIntoConstraints = false
        if !collapsed.contains(name) {
            for h in hosts { inner.addArrangedSubview(hostRow(h)) }
        }
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
            head.widthAnchor.constraint(equalTo: inner.widthAnchor),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleGroup(_:)))
        head.addGestureRecognizer(click); head.identifier = .init(name)
        return box
    }
    @objc private func toggleGroup(_ g: NSClickGestureRecognizer) {
        guard let name = g.view?.identifier?.rawValue else { return }
        if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
        reload()
    }

    private func hostRow(_ h: Host) -> NSView {
        let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false
        row.menu = hostMenu(h)   // 右键：连接/新开会话/编辑/复制主机/连接本组/删除
        let name = NSTextField(labelWithString: h.display); name.font = Theme.ui(12, .medium); name.textColor = Theme.text
        let sub = NSTextField(labelWithString: h.subtitle); sub.font = Theme.mono(10); sub.textColor = Theme.muted
        let info = NSStackView(views: [name, sub]); info.orientation = .vertical; info.alignment = .leading; info.spacing = 1
        let conn = PillButton("连接", style: .primary, hPad: 12, height: 24)
        conn.target = self; conn.action = #selector(connectRow(_:)); conn.identifier = .init(h.id)
        let edit = PillButton("编辑", style: .secondary, hPad: 10, height: 24)
        edit.target = self; edit.action = #selector(editRow(_:)); edit.identifier = .init(h.id)
        let del = PillButton("删除", style: .danger, hPad: 10, height: 24)
        del.target = self; del.action = #selector(deleteRow(_:)); del.identifier = .init(h.id)
        let btns = NSStackView(views: [conn, edit, del]); btns.spacing = 6
        let s = NSStackView(views: [info, NSView(), btns]); s.spacing = 10; s.alignment = .centerY
        s.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(s)
        NSLayoutConstraint.activate([
            s.topAnchor.constraint(equalTo: row.topAnchor, constant: 4), s.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4),
            s.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 6), s.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6),
        ])
        return row
    }
    /// 主机右键菜单（对齐老仓库 docs/ui/interaction-logic.md §4）
    private func hostMenu(_ h: Host) -> NSMenu {
        let m = NSMenu()
        func add(_ t: String, _ a: Selector) {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: ""); i.target = self
            i.representedObject = h.id; m.addItem(i)
        }
        add("连接", #selector(menuConnectHost(_:)))
        add("新开会话", #selector(menuConnectHost(_:)))   // 本实现每次连接都是新会话
        m.addItem(.separator())
        add("编辑…", #selector(menuEditHost(_:)))
        add("复制主机", #selector(menuDuplicateHost(_:)))
        add("连接本组", #selector(menuConnectGroup(_:)))
        m.addItem(.separator())
        add("删除", #selector(menuDeleteHost(_:)))
        return m
    }
    @objc private func menuConnectHost(_ s: NSMenuItem) {
        guard let h = host(s.representedObject as? String ?? "") else { return }
        hide(); onConnect?(h)
    }
    @objc private func menuEditHost(_ s: NSMenuItem) {
        guard let h = host(s.representedObject as? String ?? "") else { return }
        onEdit?(h)
    }
    @objc private func menuDuplicateHost(_ s: NSMenuItem) {
        guard let h = host(s.representedObject as? String ?? "") else { return }
        onDuplicate?(h); reload()
    }
    /// 连接本组：把该主机所在分组里的主机逐个打开会话
    @objc private func menuConnectGroup(_ s: NSMenuItem) {
        guard let h = host(s.representedObject as? String ?? "") else { return }
        let g = h.group.isEmpty ? "默认" : h.group
        let members = (hostsProvider?() ?? []).filter { ($0.group.isEmpty ? "默认" : $0.group) == g }
        guard !members.isEmpty else { return }
        let a = NSAlert.pix(); a.messageText = "连接分组「\(g)」的 \(members.count) 台主机？"
        a.addButton(withTitle: "全部连接"); a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        hide()
        for m in members { onConnect?(m) }
    }
    @objc private func menuDeleteHost(_ s: NSMenuItem) {
        guard let h = host(s.representedObject as? String ?? "") else { return }
        onDelete?(h); reload()
    }

    private func host(_ id: String) -> Host? { (hostsProvider?() ?? []).first { $0.id == id } }
    @objc private func connectRow(_ b: NSButton) { if let h = host(b.identifier?.rawValue ?? "") { hide(); onConnect?(h) } }
    @objc private func editRow(_ b: NSButton) { if let h = host(b.identifier?.rawValue ?? "") { onEdit?(h) } }
    @objc private func deleteRow(_ b: NSButton) { if let h = host(b.identifier?.rawValue ?? "") { onDelete?(h); reload() } }
}

final class EscapableView: NSView {
    var onEscape: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { // Esc
            onEscape?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
