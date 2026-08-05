import AppKit

/// 连接管理器弹窗（自绘复刻老仓库 conn-mgr）：遮罩 + 居中圆角卡片，
/// 头部三色圆点 + 标题 + ＋连接/＋分组/刷新/关闭；搜索；分组行(▶ 📁 名称 计数 重命名 删除)。
/// 宿主提供 hosts()、连接/新建/编辑/删除回调。
final class ConnManager: NSWindowController, NSTextFieldDelegate {
    private let card = NSView()
    private let listStack = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private let searchField = NSTextField()
    private let sortPicker = NSPopUpButton()
    private lazy var batchConnectButton = PillButton("连接所选", style: .primary, hPad: 10, target: self, action: #selector(connectSelected))
    private var collapsed = Set<String>()
    private var selectedHostIDs = Set<String>()
    private var firstLoad = true
    private enum HostSortMode: String { case manual, name, ip }
    private var sortMode: HostSortMode {
        get { HostSortMode(rawValue: UserDefaults.standard.string(forKey: "pixshell.connManager.hostSort") ?? "manual") ?? .manual }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "pixshell.connManager.hostSort") }
    }

    var hostsProvider: (() -> [Host])?
    var onConnect: ((Host) -> Void)?
    var onNew: (() -> Void)?
    var onEdit: ((Host) -> Void)?
    var onDelete: ((Host) -> Void)?
    var onCreateGroup: ((String) -> Void)?              // ＋分组
    var onRenameGroup: ((String, String) -> Void)?      // 旧名 → 新名
    var onDeleteGroup: ((String) -> Void)?              // 组内主机移回「默认」
    var onDuplicate: ((Host) -> Void)?                 // 右键「复制主机」
    var onMoveGroupBefore: ((String, String) -> Void)?
    var onMoveHostBefore: ((String, String) -> Void)?

    init() {
        // 原 560×580 缩约 1/3 → 380×400；允许用户拖角缩放
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 400),
                         styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        // 不能启用整窗背景拖动：它会抢走分组/主机“≡”排序手柄的鼠标拖动事件。
        // 窗口移动只由头部空白区处理，避免抢走排序手柄的鼠标事件。
        w.isMovableByWindowBackground = false
        w.backgroundColor = .clear           // 背景透明，露出我们画的圆角卡片
        w.isOpaque = false
        w.hasShadow = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 430, height: 260)
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true

        // 保存并恢复用户调整后的连接管理器位置和尺寸。
        let frameName = "PixShell-ConnManager-v1"
        if !w.setFrameUsingName(frameName) { w.center() }
        w.setFrameAutosaveName(frameName)

        super.init(window: w)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    func show() {
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
        batchConnectButton.isEnabled = false
        let rightBtns = NSStackView(views: [batchConnectButton, addBtn, grpBtn, refBtn, closeBtn]); rightBtns.spacing = 6
        let head = NSStackView(views: [title, WindowDragView(), rightBtns]); head.spacing = 12; head.alignment = .centerY
        head.translatesAutoresizingMaskIntoConstraints = false

        // 搜索
        countLabel.font = Theme.ui(12); countLabel.textColor = Theme.muted
        let search = searchField; search.placeholderString = "搜索主机…"; search.font = Theme.ui(12)
        search.isBordered = false; search.drawsBackground = false; search.textColor = Theme.text
        search.focusRingType = .none
        search.delegate = self
        let searchWrap = NSView(); searchWrap.rounded(Theme.radiusSm, bg: Theme.bg2, border: Theme.border)
        searchWrap.translatesAutoresizingMaskIntoConstraints = false
        search.translatesAutoresizingMaskIntoConstraints = false; searchWrap.addSubview(search)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: searchWrap.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: searchWrap.trailingAnchor, constant: -10),
            search.centerYAnchor.constraint(equalTo: searchWrap.centerYAnchor),
            searchWrap.heightAnchor.constraint(equalToConstant: 30),
        ])
        sortPicker.addItems(withTitles: ["手动排序", "按名称", "按 IP"])
        sortPicker.font = Theme.ui(11); sortPicker.target = self; sortPicker.action = #selector(changeSort(_:))
        let modes: [HostSortMode] = [.manual, .name, .ip]
        sortPicker.selectItem(at: modes.firstIndex(of: sortMode) ?? 0)
        let searchRow = NSStackView(views: [countLabel, searchWrap, sortPicker]); searchRow.spacing = 10
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        searchWrap.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        searchWrap.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // 列表：高度跟窗口走（可缩放），不再钉死 440
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
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            listStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 4),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -4),
            listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -4),
        ])
    }

    @objc private func hideAction() { hide() }
    @objc private func reloadAction() { reload() }
    func controlTextDidChange(_ obj: Notification) { reload() }
    @objc private func newHost() { onNew?() }
    @objc private func connectSelected() {
        let selected = (hostsProvider?() ?? []).filter { selectedHostIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        selectedHostIDs.removeAll()
        hide()
        for host in selected { onConnect?(host) }
    }

    @objc private func toggleHostSelection(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if sender.state == .on { selectedHostIDs.insert(id) } else { selectedHostIDs.remove(id) }
        updateBatchButton()
    }

    private func updateBatchButton() {
        let count = selectedHostIDs.count
        batchConnectButton.title = count == 0 ? "连接所选" : "连接所选（\(count)）"
        batchConnectButton.style = .primary
        batchConnectButton.isEnabled = count > 0
    }
    @objc private func changeSort(_ sender: NSPopUpButton) {
        let modes: [HostSortMode] = [.manual, .name, .ip]
        sortMode = modes[max(0, min(sender.indexOfSelectedItem, modes.count - 1))]
        reload()
    }

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
        let allHosts = hostsProvider?() ?? []
        selectedHostIDs.formIntersection(allHosts.map(\.id))
        updateBatchButton()
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hosts: [Host]
        if query.isEmpty {
            hosts = allHosts
        } else {
            hosts = allHosts.filter { h in
                [h.display, h.host, h.username, h.group, h.osId, h.subtitle]
                    .contains { $0.lowercased().contains(query) }
            }
        }

        var groups: [String: [Host]] = [:]
        for h in hosts { groups[h.group.isEmpty ? "默认" : h.group, default: []].append(h) }
        if sortMode == .name {
            for key in groups.keys { groups[key]?.sort { $0.display.localizedStandardCompare($1.display) == .orderedAscending } }
        } else if sortMode == .ip {
            for key in groups.keys {
                groups[key]?.sort {
                    let result = $0.host.compare($1.host, options: [.numeric, .caseInsensitive])
                    return result == .orderedSame
                        ? $0.display.localizedStandardCompare($1.display) == .orderedAscending
                        : result == .orderedAscending
                }
            }
        }
        var names: [String] = []
        for h in hosts {
            let name = h.group.isEmpty ? "默认" : h.group
            if !names.contains(name) { names.append(name) }
        }
        countLabel.stringValue = query.isEmpty ? "\(allHosts.count) 台 · \(names.count) 组" : "\(hosts.count)/\(allHosts.count) 台 · \(names.count) 组"
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // 首次打开：所有分组默认收起（对齐 Win ConnectionManagerWindow）
        if firstLoad {
            firstLoad = false
            for n in names { collapsed.insert(n) }
        }
        if hosts.isEmpty, !query.isEmpty {
            let empty = NSTextField(labelWithString: "没有匹配的主机")
            empty.font = Theme.ui(12); empty.textColor = Theme.muted
            listStack.addArrangedSubview(empty)
        } else {
            for g in names { listStack.addArrangedSubview(groupRow(g, groups[g] ?? [])) }
        }
        listStack.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true }
    }

    private func groupRow(_ name: String, _ hosts: [Host]) -> NSView {
        let box = NSView(); box.rounded(Theme.radius, bg: Theme.bg2, border: Theme.border)
        box.identifier = .init("group|\(name)")
        box.translatesAutoresizingMaskIntoConstraints = false
        let arrow = NSTextField(labelWithString: collapsed.contains(name) ? "▶" : "▼"); arrow.font = Theme.ui(10); arrow.textColor = Theme.muted
        let folder = NSTextField(labelWithString: "📁"); folder.font = Theme.ui(13)
        let title = NSTextField(labelWithString: name); title.font = Theme.ui(13, .semibold); title.textColor = Theme.text
        let count = Badge("\(hosts.count)", kind: .gray)
        let drag = dragHandle("拖动分组") { [weak self] event in
            guard let self = self else { return }
            let point = self.listStack.convert(event.locationInWindow, from: nil)
            guard let target = self.listStack.arrangedSubviews.first(where: { $0.frame.contains(point) }),
                  let raw = target.identifier?.rawValue, raw.hasPrefix("group|") else { return }
            self.onMoveGroupBefore?(name, String(raw.dropFirst(6))); self.reload()
        }
        // 分组重命名 / 删除（删除=把该组主机移回「默认」，不删主机）
        let renameBtn = PillButton("重命名", style: .ghost, hPad: 8, height: 20, target: self, action: #selector(renameGroup(_:)))
        renameBtn.identifier = .init(name)
        let delBtn = PillButton("删除", style: .ghost, hPad: 8, height: 20, target: self, action: #selector(deleteGroup(_:)))
        delBtn.identifier = .init(name)
        let head = NSStackView(views: [drag, arrow, folder, title, NSView(), count, renameBtn, delBtn]); head.spacing = 7; head.alignment = .centerY
        head.setCustomSpacing(4, after: arrow)
        head.setCustomSpacing(2, after: folder)
        head.translatesAutoresizingMaskIntoConstraints = false
        let inner = NSStackView(views: [head]); inner.orientation = .vertical; inner.alignment = .leading; inner.spacing = 6
        inner.translatesAutoresizingMaskIntoConstraints = false
        if !collapsed.contains(name) {
            // 分组按实际主机数量自然展开，不再用固定 140pt 的组内滚动区。
            // 主机较多时由连接管理器已有的外层滚动视图统一滚动。
            addHostRows(hosts, to: inner)
        }
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
            head.widthAnchor.constraint(equalTo: inner.widthAnchor),
        ])
        // 点击标题区域展开/收起；不再把点击手势挂到整个 head，避免拦截左侧排序手柄。
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleGroup(_:)))
        title.addGestureRecognizer(click); title.identifier = .init(name)
        return box
    }

    private func addHostRows(_ hosts: [Host], to stack: NSStackView) {
        for h in hosts {
            let row = hostRow(h)
            row.identifier = .init("host|\(h.id)")
            let drag = dragHandle("拖动主机") { [weak self, weak stack] event in
                guard let self = self, let stack = stack,
                      self.sortMode == .manual else { return }
                let point = stack.convert(event.locationInWindow, from: nil)
                guard let target = stack.arrangedSubviews.first(where: { $0.frame.contains(point) }),
                      let raw = target.identifier?.rawValue, raw.hasPrefix("host|") else { return }
                self.onMoveHostBefore?(h.id, String(raw.dropFirst(5))); self.reload()
            }
            if let content = row.subviews.first as? NSStackView { content.insertArrangedSubview(drag, at: 0) }
            stack.addArrangedSubview(row)
        }
    }

    private func dragHandle(_ tooltip: String, onDrop: @escaping (NSEvent) -> Void) -> NSView {
        let handle = DragHandleButton(onDrop: onDrop)
        handle.toolTip = tooltip
        handle.setContentHuggingPriority(.required, for: .horizontal)
        return handle
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
        let select = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleHostSelection(_:)))
        select.identifier = .init(h.id)
        select.state = selectedHostIDs.contains(h.id) ? .on : .off
        select.toolTip = "选择后可一次连接多台主机"
        let conn = PillButton("连接", style: .primary, hPad: 12, height: 24)
        conn.target = self; conn.action = #selector(connectRow(_:)); conn.identifier = .init(h.id)
        let edit = PillButton("编辑", style: .secondary, hPad: 10, height: 24)
        edit.target = self; edit.action = #selector(editRow(_:)); edit.identifier = .init(h.id)
        let del = PillButton("删除", style: .danger, hPad: 10, height: 24)
        del.target = self; del.action = #selector(deleteRow(_:)); del.identifier = .init(h.id)
        let btns = NSStackView(views: [conn, edit, del]); btns.spacing = 6
        let s = NSStackView(views: [select, info, NSView(), btns]); s.spacing = 10; s.alignment = .centerY
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

/// 只占用标题中间的空白区域，并交给 AppKit 完成无抖动的原生窗口拖动。
private final class WindowDragView: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// 使用真正的按钮作为排序手柄，确保 AppKit 会把按下、拖动和松开事件交给它。
private final class DragHandleButton: NSButton {
    private let onDrop: (NSEvent) -> Void

    init(onDrop: @escaping (NSEvent) -> Void) {
        self.onDrop = onDrop
        super.init(frame: .zero)
        title = "≡"
        isBordered = false
        bezelStyle = .inline
        font = Theme.ui(14, .medium)
        contentTintColor = Theme.muted
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 24) }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        var dragged = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseDragged {
                dragged = true
                NSCursor.closedHand.set()
            } else {
                NSCursor.arrow.set()
                if dragged { onDrop(next) }
                return
            }
        }
    }
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
