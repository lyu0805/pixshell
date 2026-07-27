import AppKit

/// 命令板（底部坞「命令」tab）。**布局照老仓库来，左右分栏**：
///
///   [📁默认分类 📁防火墙 📁系统 …(排满换行)]                        [＋新建]
///   ┌──────────────────────────────┬─┬─────────────────────────┐
///   │ 命令列表（带边框/换行/可滚动）  │ │ 命令编辑器        ⟩收起 │
///   │  名称⚙  名称⚙  名称⚙ …        │ │ ┌─────────────────────┐ │
///   ├──────────────────────────────┤ │ │ 多行文本            │ │
///   │ 发送到 [当前会话▾] [发送]      │ │ └─────────────────────┘ │
///   └──────────────────────────────┘ │ 发送到 [当前会话▾] [发送]│
///                                    └─────────────────────────┘
///
/// 之前做成了"分类 pill 一行 + 命令 chips 横向滚动一行 + 编辑器压在下面"，
/// 命令被裁掉半截根本点不到，用户反馈"完全不可用"。要点：
///  1. 分类是**文件夹样式**且**换行**（FlowView），不是单行 pill；
///  2. 命令列表在**带边框的盒子**里换行铺开，每条右边一个 ⚙（编辑/删除）；
///  3. 编辑器在**右栏**（不是压在下面），可收起成窄条；
///  4. 左右各有自己的 `发送到 + 发送`：左边发列表选中项，右边发编辑器内容。
final class CommandPanel: NSView {
    private let store = QuickCommandStore()
    private let groupFlow = FlowView()          // 分类文件夹（换行）
    private let cmdFlow = FlowView()            // 命令列表（换行）
    private let edTargetPopup = NSPopUpButton()     // 发送到目标选择
    private var editor: NSTextView!
    private var editorScroll: NSScrollView!
    private var rightCol: NSView!
    private var rightWidthC: NSLayoutConstraint!
    private var collapseBtn: PillButton!
    private var editorParts: [NSView] = []      // 展开态显示的三块（头/编辑器/发送条）
    private var expandStrip: PillButton!        // 收起态占满窄条的展开按钮
    private var editorCollapsed = false
    private var selectedGroup: String?
    private var selectedCmdId: String?          // 列表里被选中的那条（左栏「发送」用）

    /// 右栏展开宽度；收起后只留一个窄条。
    /// 320 → 213（收掉三分之一）：编辑器用不了那么宽，省下来的给左边命令列表多铺几列。
    private static let rightExpanded: CGFloat = 213
    private static let rightCollapsed: CGFloat = 30

    /// 发送回调：(命令文本, 目标)。文本已含换行。
    var onSendTo: ((String, SendTarget) -> Void)?
    var onShowHistory: ((NSView) -> Void)?
    /// 目标下拉数据源：已连接会话标题
    var sessionsProvider: (() -> [(title: String, connected: Bool)])?

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); build(); reload() }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 布局
    private func build() {
        wantsLayer = true; layer?.backgroundColor = Theme.bg.cgColor

        // ── 顶部：分类文件夹（换行）+ 新建 ──
        let addBtn = PillButton("＋ 新建", style: .secondary, hPad: 10, height: 22,
                                target: self, action: #selector(newCommand))
        addBtn.setContentHuggingPriority(.required, for: .horizontal)

        // ── 左栏：命令列表（带边框盒子 + 换行 + 可滚动）──
        let listBox = CardView(radius: Theme.radiusSm, bg: Theme.bg2, border: Theme.border)
        let listScroll = NSScrollView()
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.hasHorizontalScroller = false
        listScroll.autohidesScrollers = true
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        let listDoc = FlippedView(); listDoc.translatesAutoresizingMaskIntoConstraints = false
        cmdFlow.inset = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        listDoc.addSubview(cmdFlow)
        listScroll.documentView = listDoc
        listBox.addSubview(listScroll)
        NSLayoutConstraint.activate([
            listScroll.topAnchor.constraint(equalTo: listBox.topAnchor, constant: 1),
            listScroll.leadingAnchor.constraint(equalTo: listBox.leadingAnchor, constant: 1),
            listScroll.trailingAnchor.constraint(equalTo: listBox.trailingAnchor, constant: -1),
            listScroll.bottomAnchor.constraint(equalTo: listBox.bottomAnchor, constant: -1),
            listDoc.topAnchor.constraint(equalTo: listScroll.topAnchor),
            listDoc.leadingAnchor.constraint(equalTo: listScroll.leadingAnchor),
            listDoc.widthAnchor.constraint(equalTo: listScroll.widthAnchor),
            cmdFlow.topAnchor.constraint(equalTo: listDoc.topAnchor),
            cmdFlow.leadingAnchor.constraint(equalTo: listDoc.leadingAnchor),
            cmdFlow.trailingAnchor.constraint(equalTo: listDoc.trailingAnchor),
            listDoc.bottomAnchor.constraint(equalTo: cmdFlow.bottomAnchor),
        ])

        let leftCol = NSView(); leftCol.translatesAutoresizingMaskIntoConstraints = false
        leftCol.addSubview(listBox)
        NSLayoutConstraint.activate([
            listBox.topAnchor.constraint(equalTo: leftCol.topAnchor),
            listBox.leadingAnchor.constraint(equalTo: leftCol.leadingAnchor),
            listBox.trailingAnchor.constraint(equalTo: leftCol.trailingAnchor),
            listBox.bottomAnchor.constraint(equalTo: leftCol.bottomAnchor),
        ])

        // ── 右栏：命令编辑器（可收起）──
        collapseBtn = PillButton("⟩ 收起", style: .ghost, hPad: 8, height: 20,
                                 target: self, action: #selector(toggleEditor))
        let edLabel = NSTextField(labelWithString: "命令编辑器")
        edLabel.font = Theme.ui(11, .medium); edLabel.textColor = Theme.muted
        let optBtnTop = PillButton("选项", style: .ghost, hPad: 8, height: 20,
                                   font: Theme.ui(11), target: self, action: #selector(editorOptions))
        let edHead = NSStackView(views: [edLabel, NSView(), optBtnTop, collapseBtn])
        edHead.spacing = 8; edHead.alignment = .centerY
        edHead.translatesAutoresizingMaskIntoConstraints = false

        (editorScroll, editor) = ScrollableText.make(font: Theme.mono(12), editable: true,
                                                     bg: Theme.bg2, border: Theme.border)

        edTargetPopup.font = Theme.ui(11)
        edTargetPopup.translatesAutoresizingMaskIntoConstraints = false
        edTargetPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 160).isActive = true
        let edSendLab = small("发送到")
        let edHist = PillButton("历史", style: .secondary, hPad: 12, height: 24, target: self, action: #selector(showHistory))
        let edSend = PillButton("发送", style: .primary, hPad: 14, height: 24,
                                target: self, action: #selector(sendEditor))
        let edSendBar = NSStackView(views: [NSView(), edHist, edSendLab, edTargetPopup, edSend])
        edSendBar.spacing = 6; edSendBar.alignment = .centerY
        edSendBar.translatesAutoresizingMaskIntoConstraints = false

        // 收起态：占满窄栏的展开按钮（竖着的「‹ 编辑器」）
        expandStrip = PillButton("‹", style: .secondary, hPad: 2, height: 24,
                                 font: Theme.ui(11, .semibold), target: self, action: #selector(expandEditor))
        expandStrip.toolTip = "展开命令编辑器"
        expandStrip.isHidden = true
        expandStrip.translatesAutoresizingMaskIntoConstraints = false

        rightCol = NSView(); rightCol.translatesAutoresizingMaskIntoConstraints = false
        rightCol.addSubview(edHead); rightCol.addSubview(editorScroll); rightCol.addSubview(edSendBar)
        rightCol.addSubview(expandStrip)
        editorParts = [edHead, editorScroll, edSendBar]
        NSLayoutConstraint.activate([
            expandStrip.topAnchor.constraint(equalTo: rightCol.topAnchor),
            expandStrip.leadingAnchor.constraint(equalTo: rightCol.leadingAnchor),
            expandStrip.trailingAnchor.constraint(equalTo: rightCol.trailingAnchor),
            edHead.topAnchor.constraint(equalTo: rightCol.topAnchor),
            edHead.leadingAnchor.constraint(equalTo: rightCol.leadingAnchor),
            edHead.trailingAnchor.constraint(equalTo: rightCol.trailingAnchor),
            editorScroll.topAnchor.constraint(equalTo: edHead.bottomAnchor, constant: 4),
            editorScroll.leadingAnchor.constraint(equalTo: rightCol.leadingAnchor),
            editorScroll.trailingAnchor.constraint(equalTo: rightCol.trailingAnchor),
            edSendBar.topAnchor.constraint(equalTo: editorScroll.bottomAnchor, constant: 6),
            edSendBar.leadingAnchor.constraint(equalTo: rightCol.leadingAnchor),
            edSendBar.trailingAnchor.constraint(equalTo: rightCol.trailingAnchor),
            edSendBar.bottomAnchor.constraint(equalTo: rightCol.bottomAnchor),
        ])

        // ── 组装：顶部分类行 + [左栏 | 竖分隔 | 右栏] ──
        let divider = DividerView()
        divider.wantsLayer = true; divider.layer?.backgroundColor = Theme.border.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(groupFlow); addSubview(addBtn)
        addSubview(leftCol); addSubview(divider); addSubview(rightCol)

        rightWidthC = rightCol.widthAnchor.constraint(equalToConstant: Self.rightExpanded)
        NSLayoutConstraint.activate([
            groupFlow.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            groupFlow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            groupFlow.trailingAnchor.constraint(equalTo: addBtn.leadingAnchor, constant: -8),
            addBtn.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            addBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            leftCol.topAnchor.constraint(equalTo: groupFlow.bottomAnchor, constant: 8),
            leftCol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            leftCol.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            divider.leadingAnchor.constraint(equalTo: leftCol.trailingAnchor, constant: 8),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: leftCol.topAnchor),
            divider.bottomAnchor.constraint(equalTo: leftCol.bottomAnchor),

            rightCol.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 8),
            rightCol.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            rightCol.topAnchor.constraint(equalTo: leftCol.topAnchor),
            rightCol.bottomAnchor.constraint(equalTo: leftCol.bottomAnchor),
            rightWidthC,
        ])
    }

    private func small(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t); l.font = Theme.ui(11); l.textColor = Theme.muted
        return l
    }

    // MARK: 数据
    func reload() {
        reloadTargets()
        reloadGroups()
        reloadChips()
    }

    func reloadTargets() {
        for p in [edTargetPopup] {
            let keep = p.indexOfSelectedItem
            p.removeAllItems()
            p.addItem(withTitle: "当前会话")
            p.addItem(withTitle: "所有已连接会话")
            for s in (sessionsProvider?() ?? []) where s.connected {
                p.addItem(withTitle: s.title)
            }
            if keep >= 0, keep < p.numberOfItems { p.selectItem(at: keep) }
        }
    }
    private func currentTarget() -> SendTarget { target(of: edTargetPopup) }

    private func target(of popup: NSPopUpButton) -> SendTarget {
        switch popup.indexOfSelectedItem {
        case 0: return .current
        case 1: return .allConnected
        default:
            // 下标 2 起对应"已连接会话"顺序
            let connectedIdx = popup.indexOfSelectedItem - 2
            let all = sessionsProvider?() ?? []
            var seen = -1
            for (i, s) in all.enumerated() where s.connected {
                seen += 1
                if seen == connectedIdx { return .session(i) }
            }
            return .current
        }
    }

    /// 分类做成**文件夹样式**并自动换行（老仓库就是一排 📁 排满折行）
    private func reloadGroups() {
        var items: [NSView] = []
        let all = folderChip("全部", key: "", on: selectedGroup == nil)
        items.append(all)
        for g in store.groups() {
            items.append(folderChip(g, key: g, on: selectedGroup == g))
        }
        groupFlow.setItems(items)
    }

    /// 分组 chip。图标用 **SF Symbol 图片**而不是 🗀 之类的字形 ——
    /// 系统字体里没有那些码位，会渲染成"?"豆腐块（第一版就踩了）。
    private func folderChip(_ title: String, key: String, on: Bool) -> PillButton {
        let b = PillButton(title, style: on ? .primary : .secondary, hPad: 8, height: 22,
                           font: Theme.ui(11), target: self, action: #selector(pickGroup(_:)))
        b.image = NSImage(systemSymbolName: on ? "folder.fill" : "folder", accessibilityDescription: "分组")
        b.imagePosition = .imageLeading
        b.imageHugsTitle = true
        b.contentTintColor = on ? .white : Theme.muted
        b.identifier = .init(key)
        b.menu = groupMenu(key)       // 右键分组本身：重命名 / 删除
        return b
    }

    /// 分组 chip 的右键菜单
    private func groupMenu(_ key: String) -> NSMenu {
        let m = NSMenu()
        add(m, "新建分组…", #selector(newGroup))
        add(m, "添加命令…", #selector(newCommand))
        if !key.isEmpty {
            m.addItem(.separator())
            add(m, "重命名分组…", #selector(renameGroup(_:)), key)
            add(m, "删除分组", #selector(deleteGroup(_:)), key)
        }
        return m
    }

    /// 菜单项小工具：统一挂 target 并把 id 放进 representedObject
    private func add(_ m: NSMenu, _ title: String, _ sel: Selector, _ rep: Any? = nil) {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self; it.representedObject = rep
        m.addItem(it)
    }
    @objc private func pickGroup(_ sender: NSButton) {
        let g = sender.identifier?.rawValue ?? ""
        selectedGroup = g.isEmpty ? nil : g
        reloadGroups(); reloadChips()
    }

    /// 命令列表：每条 = [名称按钮][⚙]，整体换行铺开（老仓库的样子）
    private func reloadChips() {
        var items: [NSView] = []
        for c in store.list(group: selectedGroup) {
            let hasParam = !(c.params?.isEmpty ?? true) || CommandParams.hasUnresolved(c.command)
            let isSel = (selectedCmdId == c.id)
            let name = PillButton(hasParam ? "\(c.name) ⋯" : c.name,
                                  style: isSel ? .primary : .ghost, hPad: 8, height: 22,
                                  font: Theme.ui(11), target: self, action: #selector(chipClicked(_:)))
            name.identifier = .init(c.id)
            name.toolTip = c.command
            name.menu = chipMenu(c.id)

            // ⚙ = 这条命令的编辑/删除入口（老仓库每条命令后面都有个齿轮）
            let gear = PillButton("⚙", style: .ghost, hPad: 4, height: 22,
                                  font: Theme.ui(11), target: self, action: #selector(gearClicked(_:)))
            gear.identifier = .init(c.id)
            gear.toolTip = "编辑 / 删除"

            let cell = NSStackView(views: [name, gear])
            cell.orientation = .horizontal; cell.spacing = 0; cell.alignment = .centerY
            cell.translatesAutoresizingMaskIntoConstraints = false
            items.append(cell)
        }
        cmdFlow.setItems(items)
    }
    /// 命令的右键/齿轮菜单（项目对齐参考图；老仓库叫"文件夹"，这里统一叫**分组** —— 同一个东西）
    private func chipMenu(_ id: String) -> NSMenu {
        let m = NSMenu()
        add(m, "添加命令…", #selector(newCommand))
        add(m, "复制命令", #selector(copyCommandText(_:)), id)
        add(m, "编辑", #selector(editCommand(_:)), id)
        add(m, "删除", #selector(deleteCommand(_:)), id)
        m.addItem(.separator())
        add(m, "新建分组…", #selector(newGroup))

        // 移动到 ▸ <各分组>
        let moveItem = NSMenuItem(title: "移动到", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let cur = store.commands.first(where: { $0.id == id })?.group ?? "默认"
        for g in store.groups() {
            let it = NSMenuItem(title: g, action: #selector(moveCommand(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = ["id": id, "group": g]
            it.state = (g == cur) ? .on : .off      // 当前所在分组打勾
            sub.addItem(it)
        }
        moveItem.submenu = sub
        m.addItem(moveItem)
        return m
    }

    /// 命令列表**空白处**右键：只有"新建分组/添加命令"（对齐参考图第一张）
    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        add(m, "新建分组…", #selector(newGroup))
        add(m, "添加命令…", #selector(newCommand))
        return m
    }

    // MARK: 动作
    /// 单击 = 选中并载入编辑器；**双击 = 直接发送**。
    /// 分成两级是为了不误触：单击不该把命令打到服务器上。
    @objc private func chipClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let c = store.commands.first(where: { $0.id == id }) else { return }
        selectedCmdId = id
        editor.string = c.command
        // NSButton 不直接给双击回调，用当前事件的 clickCount 判断
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            sendCommand(c, to: target(of: edTargetPopup))
            return
        }
        reloadChips()
    }

    /// 发送一条命令（含 ${参数} 逐个询问）—— 双击和左栏「发送」共用
    private func sendCommand(_ c: QuickCommand, to tgt: SendTarget) {
        var text = store.render(c)
        if CommandParams.hasUnresolved(text) {
            var vals: [String: String] = [:]
            for n in CommandParams.parse(text) {
                guard let v = ask("参数 \(n)", "请输入 ${\(n)} 的值", defaultValue: "") else { return }
                vals[n] = v
            }
            text = CommandParams.render(text, values: vals)
        }
        onSendTo?(text + "\r", tgt)
    }

    @objc private func gearClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let m = chipMenu(id)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    // MARK: - 右侧栏动作

    @objc private func sendEditor() {
        let sel = editor.selectedRange()
        let ns = editor.string as NSString
        let text = sel.length > 0 ? ns.substring(with: sel) : editor.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        onSendTo?(text.hasSuffix("\n") ? text : text + "\n", target(of: edTargetPopup))
    }

    /// 右栏「选项」：编辑器上的一些顺手操作
    @objc private func editorOptions(_ sender: NSButton) {
        let m = NSMenu()
        func add(_ t: String, _ a: Selector) {
            let it = NSMenuItem(title: t, action: a, keyEquivalent: ""); it.target = self; m.addItem(it)
        }
        add("清空编辑器", #selector(clearEditor))
        add("把选中项载入编辑器", #selector(loadSelectedIntoEditor))
        m.addItem(.separator())
        add("存为新命令…", #selector(saveEditorAsCommand))
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }
    @objc private func clearEditor() { editor.string = "" }
    @objc private func loadSelectedIntoEditor() {
        guard let id = selectedCmdId, let c = store.commands.first(where: { $0.id == id }) else { return }
        editor.string = c.command
    }
    @objc private func saveEditorAsCommand() {
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { NSSound.beep(); return }
        guard let n = ask("存为新命令", "给它起个名字", defaultValue: "") , !n.isEmpty else { return }
        var item = QuickCommand(name: n, command: text)
        item.group = selectedGroup ?? "默认"
        store.upsert(item)
        reloadGroups(); reloadChips()
    }

    /// 收起 = 右栏缩成窄条（左栏顺势占满）。
    /// **坑**：第一版收起后就打不开了 —— 收起按钮本身在右栏头部，栏宽只剩 30pt 时
    /// 它连同标题一起被挤出可见区，没有任何可点的东西。所以收起态要换成一个
    /// **占满整条窄栏的展开按钮**（expandStrip），点它恢复。
    @objc private func toggleEditor() {
        setEditorCollapsed(!editorCollapsed)
    }
    @objc private func expandEditor() { setEditorCollapsed(false) }

    private func setEditorCollapsed(_ collapsed: Bool) {
        editorCollapsed = collapsed
        rightWidthC.constant = collapsed ? Self.rightCollapsed : Self.rightExpanded
        // 展开态的三块内容
        for v in editorParts { v.isHidden = collapsed }
        // 收起态的窄条按钮
        expandStrip.isHidden = !collapsed
        needsLayout = true
    }

    @objc private func newGroup() {
        guard let n = ask("新建分组", "分组名", defaultValue: ""), !n.isEmpty else { return }
        guard store.addGroup(n) else { NSSound.beep(); return }   // 同名already存在
        selectedGroup = n
        reloadGroups(); reloadChips()
    }
    @objc private func renameGroup(_ sender: NSMenuItem) {
        guard let old = sender.representedObject as? String,
              let n = ask("重命名分组", "把「\(old)」改成", defaultValue: old), !n.isEmpty else { return }
        store.renameGroup(old, to: n)
        if selectedGroup == old { selectedGroup = n }
        reloadGroups(); reloadChips()
    }
    @objc private func deleteGroup(_ sender: NSMenuItem) {
        guard let g = sender.representedObject as? String else { return }
        let a = NSAlert.pix()
        a.messageText = "删除分组「\(g)」？"
        a.informativeText = "里面的命令会移回「默认」分组，命令本身不会被删。"
        a.addButton(withTitle: "删除分组"); a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        store.removeGroup(g)
        if selectedGroup == g { selectedGroup = nil }
        reloadGroups(); reloadChips()
    }
    /// 复制命令 = 把**命令文本**丢进剪贴板（方便贴到别处），不是复制出一条新命令。
    @objc private func copyCommandText(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let c = store.commands.first(where: { $0.id == id }) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(c.command, forType: .string)
    }
    @objc private func moveCommand(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? [String: String],
              let id = d["id"], let g = d["group"] else { return }
        store.move(id, to: g)
        reloadGroups(); reloadChips()
    }

    @objc private func newCommand() { editCommand(nil) }
    @objc private func editCommand(_ sender: Any?) {
        let id = (sender as? NSMenuItem)?.representedObject as? String
        let existing = id.flatMap { i in store.commands.first(where: { $0.id == i }) }
        let a = NSAlert.pix()
        a.messageText = existing == nil ? "新建快捷命令" : "编辑快捷命令"
        a.addButton(withTitle: "保存"); a.addButton(withTitle: "取消")
        let name = NSTextField(string: existing?.name ?? "")
        let group = NSTextField(string: existing?.group ?? "默认")
        let cmd = NSTextField(string: existing?.command ?? "")
        for f in [name, group, cmd] { f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        let grid = NSGridView(numberOfColumns: 2, rows: 0); grid.rowSpacing = 8; grid.columnSpacing = 10
        grid.addRow(with: [NSTextField(labelWithString: "名称"), name])
        grid.addRow(with: [NSTextField(labelWithString: "分组"), group])
        grid.addRow(with: [NSTextField(labelWithString: "命令"), cmd])
        grid.addRow(with: [NSTextField(labelWithString: ""), NSTextField(labelWithString: "支持 ${参数}，发送时会提示填写")])
        grid.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        a.accessoryView = grid
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let n = name.stringValue.trimmingCharacters(in: .whitespaces)
        let c = cmd.stringValue.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !c.isEmpty else { return }
        var item = existing ?? QuickCommand(name: n, command: c)
        item.name = n; item.command = c
        item.group = group.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? "默认" : group.stringValue
        store.upsert(item)
        reloadGroups(); reloadChips()
    }
    @objc private func deleteCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        store.delete(id); reloadGroups(); reloadChips()
    }

    private func ask(_ title: String, _ info: String, defaultValue: String) -> String? {
        let a = NSAlert.pix(); a.messageText = title; a.informativeText = info
        a.addButton(withTitle: "确定"); a.addButton(withTitle: "取消")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        tf.stringValue = defaultValue
        a.accessoryView = tf; a.window.initialFirstResponder = tf
        return a.runModal() == .alertFirstButtonReturn ? tf.stringValue : nil
    }
}
