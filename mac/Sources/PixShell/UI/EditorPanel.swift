import AppKit

/// 文本编辑器弹层：文件名/语言徽标/保存/关闭 头部 + 查找替换工具条 +
/// 32pt 行号槽 + 文本区 + 状态栏。对齐老仓库 packages/editor（语言探测/高亮/
/// 查找替换/保存/脏检查/32px 行号槽），仿 SysInfoPanel 的卡片弹窗结构
/// （遮罩 + 圆角卡片、HeaderPanGesture 拖动、点遮罩/Esc 关闭）。
final class EditorPanel: NSView, NSTextViewDelegate, NSTextStorageDelegate {

    // MARK: LSP（rust-analyzer）
    private var lsp: LSPClient?
    private var lspUri = ""
    private var lspAvailable = false
    /// 诊断波浪线所在行 → 首个错误信息（悬停提示用）
    private var diagnosticLines: [Int: (range: NSRange, message: String, isError: Bool)] = [:]
    private var lspChangeDebounce: DispatchWorkItem?
    private let lspBadge = NSTextField(labelWithString: "")   // 头部语言徽章右侧：LSP 状态
    private var completionPopup: NSPopover?
    private var completionItems: [(label: String, detail: String)] = []
    private var completionIndex = 0
    private var lspHoverTimer: Timer?
    private var lspMenuItems: (hover: NSMenuItem, goto: NSMenuItem, complete: NSMenuItem)?


    // MARK: 对外 API

    /// 保存回调：调用方写回（远端/本地）后，**必须**通过 completion 回报结果
    /// （nil = 成功，非 nil = 错误信息）。本视图据此显示提示、决定是否清脏标记/关闭。
    /// 早期版本是 fire-and-forget，结果：写失败也照样清脏标记并关窗，用户的修改静默丢掉。
    var onSave: ((String, @escaping (String?) -> Void) -> Void)?
    /// 关闭回调：脏检查通过（或用户选择放弃/保存）后触发。
    var onClose: (() -> Void)?

    private(set) var isDirty = false {
        didSet { footerDirty.isHidden = !isDirty }
    }

    // MARK: 子视图

    private let card = NSView()
    private var head: NSStackView!
    private let headerTitle = NSTextField(labelWithString: "")
    private var langBadge: Badge?
    private var saveBtn: PillButton!
    /// 保存结果就地提示。主窗底部状态栏被本弹层整个盖住，写在那儿用户根本看不见。
    private let saveStatus = NSTextField(labelWithString: "")
    private var saving = false
    private var closeBtn: PillButton!

    private let findField = NSTextField()
    private let replaceField = NSTextField()
    private var lineNumberCheck: NSButton!
    private var wrapCheck: NSButton!

    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private var gutter: LineNumberGutter?

    private let footerPos = NSTextField(labelWithString: "行 1:列 1")
    private let footerChars = NSTextField(labelWithString: "0 字符")
    private let footerEncoding = NSTextField(labelWithString: "UTF-8")
    private let footerDirty = NSTextField(labelWithString: "● 已修改")

    private var cardX: NSLayoutConstraint!
    private var cardY: NSLayoutConstraint!

    // MARK: 状态

    private var filePath: String = ""
    private var lang: EditorLang = .plain
    private var wrapEnabled = false
    /// 程序化设置文本期间（open 加载文档）屏蔽脏标记 / 重复高亮。
    private var isLoadingDocument = false

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); build() }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 布局搭建

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.35).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        card.rounded(Theme.radiusLg, bg: Theme.bg, border: Theme.borderStrong)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        buildHeader()
        let toolbar = buildToolbar()
        buildBody()
        let footer = buildFooter()

        card.addSubview(head)
        card.addSubview(toolbar)
        card.addSubview(scrollView)
        card.addSubview(footer)

        // 卡片**填满**面板：编辑器现在是独立窗口，尺寸由窗口决定。
        // 原来是固定 860×620 + 居中（弹层时代的设计），窗口一缩小内容就被裁掉。
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            head.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            head.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            head.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),

            toolbar.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 10),
            toolbar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            footer.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])

        applyWrapSetting()
    }

    private func buildHeader() {
        headerTitle.font = Theme.ui(14, .semibold)
        headerTitle.textColor = Theme.text
        headerTitle.lineBreakMode = .byTruncatingMiddle
        saveBtn = PillButton("保存", style: .primary, hPad: 14, target: self, action: #selector(saveAction))
        closeBtn = PillButton("关闭", style: .secondary, hPad: 12, target: self, action: #selector(closeAction))

        saveStatus.font = Theme.ui(11)
        saveStatus.textColor = Theme.muted
        saveStatus.lineBreakMode = .byTruncatingTail
        lspBadge.font = Theme.mono(10)
        lspBadge.textColor = Theme.muted
        head = NSStackView(views: [headerTitle, lspBadge, NSView(), saveStatus, saveBtn, closeBtn])
        head.orientation = .horizontal; head.spacing = 10; head.alignment = .centerY
        head.translatesAutoresizingMaskIntoConstraints = false

        updateLanguageBadge()
    }

    private func buildToolbar() -> NSStackView {
        findField.placeholderString = "查找"   // 查找条默认收起，⌘F 才展开（见 toggleFindBar）
        findField.font = Theme.ui(12)
        findField.target = self; findField.action = #selector(findNextAction)
        findField.translatesAutoresizingMaskIntoConstraints = false
        findField.widthAnchor.constraint(equalToConstant: 140).isActive = true

        let prevBtn = IconButton(symbol: "chevron.up", tooltip: "上一个", target: self, action: #selector(findPrevAction))
        let nextBtn = IconButton(symbol: "chevron.down", tooltip: "下一个", target: self, action: #selector(findNextAction))

        replaceField.placeholderString = "替换为"
        replaceField.font = Theme.ui(12)
        replaceField.target = self; replaceField.action = #selector(replaceOneAction)
        replaceField.translatesAutoresizingMaskIntoConstraints = false
        replaceField.widthAnchor.constraint(equalToConstant: 140).isActive = true

        let replaceBtn = PillButton("替换", style: .secondary, hPad: 10, height: 24,
                                     target: self, action: #selector(replaceOneAction))
        let replaceAllBtn = PillButton("全部替换", style: .secondary, hPad: 10, height: 24,
                                        target: self, action: #selector(replaceAllAction))

        lineNumberCheck = NSButton(checkboxWithTitle: L10n.t("editor.lineNumbers"), target: self, action: #selector(toggleLineNumbers(_:)))
        lineNumberCheck.state = .on
        lineNumberCheck.font = Theme.ui(11)
        wrapCheck = NSButton(checkboxWithTitle: L10n.t("editor.wrap"), target: self, action: #selector(toggleWrap(_:)))
        wrapCheck.state = .off
        wrapCheck.font = Theme.ui(11)

        let toolbar = NSStackView(views: [
            findField, prevBtn, nextBtn, replaceField, replaceBtn, replaceAllBtn,
            NSView(), lineNumberCheck, wrapCheck,
        ])
        toolbar.orientation = .horizontal; toolbar.spacing = 8; toolbar.alignment = .centerY
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        return toolbar
    }

    private func buildBody() {
        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.isEditable = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.allowsUndo = true
        textView.font = Theme.mono(12)
        textView.textColor = Theme.text
        textView.backgroundColor = Theme.bg2
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        buildEditorContextMenu()
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.bg2
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.rounded(Theme.radiusSm, border: Theme.border)

        let gutterView = LineNumberGutter(textView: textView, scrollView: scrollView)
        gutter = gutterView
        scrollView.hasVerticalRuler = true
        scrollView.verticalRulerView = gutterView
        scrollView.rulersVisible = true
    }

    /// 编辑器右键菜单：标准编辑项 + LSP（仅 .rs 显示悬停/跳转）
    private func buildEditorContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let hover = NSMenuItem(title: "LSP 悬停（⌘Space）", action: #selector(lspHoverAction), keyEquivalent: "")
        hover.target = self
        hover.isHidden = true
        let goto = NSMenuItem(title: "跳转到定义（⌘⇧G）", action: #selector(lspGoToDefinition), keyEquivalent: "")
        goto.target = self
        goto.isHidden = true
        let complete = NSMenuItem(title: "补全（⌃Space）", action: #selector(lspCompletionAction), keyEquivalent: "")
        complete.target = self
        complete.isHidden = true
        menu.addItem(hover); menu.addItem(goto); menu.addItem(complete)
        lspMenuItems = (hover, goto, complete)
        textView.menu = menu
    }

    private func buildFooter() -> NSStackView {
        for f in [footerPos, footerChars, footerEncoding, footerDirty] {
            f.font = Theme.ui(11); f.textColor = Theme.muted
        }
        footerDirty.textColor = Theme.warn
        footerDirty.isHidden = true
        let footer = NSStackView(views: [footerPos, footerChars, footerEncoding, NSView(), footerDirty])
        footer.orientation = .horizontal; footer.spacing = 14; footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false
        return footer
    }

    /// 语言徽标没有可写属性，只能整体替换：把旧 Badge 移出 head，插入新的到相同位置。
    private func updateLanguageBadge() {
        if let old = langBadge {
            head.removeArrangedSubview(old)
            old.removeFromSuperview()
        }
        let badge = Badge(lang.displayName, kind: .accent)
        head.insertArrangedSubview(badge, at: 1)
        langBadge = badge
    }

    // MARK: - 打开文档

    /// 加载文件内容：探测语言、跑一次高亮、复位脏标记/撤销栈/查找框。
    func open(path: String, text: String) {
        isHidden = false          // 打开即显示（否则调用方看不到面板）
        filePath = path
        lang = EditorSyntax.detect(path: path)
        headerTitle.stringValue = (path as NSString).lastPathComponent
        headerTitle.toolTip = path
        updateLanguageBadge()
        findField.stringValue = ""
        replaceField.stringValue = ""

        isLoadingDocument = true
        let attributed = EditorSyntax.highlight(text, lang: lang, dark: Theme.dark)
        textView.textStorage?.setAttributedString(attributed)
        isLoadingDocument = false

        isDirty = false
        setSaveStatus("", color: Theme.muted)
        textView.undoManager?.removeAllActions()
        gutter?.needsDisplay = true
        updateFooter()

        startLSPIfNeeded(path: path, text: text)
    }

    // MARK: - LSP（rust-analyzer）

    /// 仅 .rs 文件启用。rust-analyzer 不存在时优雅降级（无 LSP 能力，编辑不受影响）。
    private func startLSPIfNeeded(path: String, text: String) {
        stopLSP()
        guard (path as NSString).pathExtension.lowercased() == "rs" else { return }
        guard LSPClient.locate() != nil else {
            Log.info("rust-analyzer 未安装，编辑器 LSP 不可用（仅 .rs）", "lsp")
            lspBadge.stringValue = "LSP 未装"
            lspBadge.textColor = Theme.warn
            return
        }
        let dir = (path as NSString).deletingLastPathComponent
        lspUri = "file://\(path)"
        let client = LSPClient()
        lsp = client
        client.onReadyChange = { [weak self] ok in
            self?.lspAvailable = ok
            self?.lspBadge.stringValue = ok ? "● LSP" : "LSP 失败"
            self?.lspBadge.textColor = ok ? Theme.ok : Theme.err
            if let m = self?.lspMenuItems {
                m.hover.isHidden = !ok
                m.goto.isHidden = !ok
                m.complete.isHidden = !ok
            }
        }
        client.onDiagnostics = { [weak self] diags in
            self?.applyDiagnostics(diags)
        }
        client.start(rootPath: dir, uri: lspUri, text: text)
        lspBadge.stringValue = "LSP…"
        lspBadge.textColor = Theme.muted
        lspBadge.toolTip = "rust-analyzer（⌃Space 补全 · ⌘悬停 · 右键跳转定义）"
    }

    private func stopLSP() {
        lsp?.shutdown()
        lsp = nil
        lspUri = ""
        lspAvailable = false
        lspBadge.stringValue = ""
        clearDiagnostics()
    }

    /// 编辑器关闭时调用（宿主 orderOut 时）
    func lspClose() { stopLSP() }

    /// 防抖后的全文变更 → didChange
    private func scheduleLSPChange(_ text: String) {
        guard lspAvailable else { return }
        lspChangeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.lsp?.didChange(text: text)
        }
        lspChangeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// 请求前 flush 未决 didChange：防抖 work 还没执行说明服务器文本不是最新，
    /// 先结算再发查询，避免 -32801 content modified（客户端重试是兜底，这里才是正路）。
    private func flushPendingLspChange() {
        guard lspAvailable else { return }
        if let work = lspChangeDebounce {
            work.cancel()
            lspChangeDebounce = nil
            lsp?.didChange(text: textView.textStorage?.string ?? "")
        }
    }

    /// 应用诊断：错误红色波浪线、警告黄色。悬停/状态栏提示。
    private func applyDiagnostics(_ diags: [LSPClient.Diagnostic]) {
        clearDiagnostics()
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        for d in diags {
            let range = d.range
            guard range.location + range.length <= storage.length else { continue }
            storage.addAttribute(.underlineStyle,
                                 value: NSUnderlineStyle.thick.rawValue,
                                 range: range)
            storage.addAttribute(.underlineColor,
                                 value: d.isError ? Theme.err : Theme.warn,
                                 range: range)
            let ns = storage.string as NSString
            let line = ns.substring(to: range.location).components(separatedBy: "\n").count - 1
            diagnosticLines[line] = (range, d.message, d.isError)
        }
        storage.endEditing()
        // 状态栏汇总
        let errs = diags.filter(\.isError).count
        let warns = diags.count - errs
        if errs + warns > 0 {
            setSaveStatus("\(errs) 错误 · \(warns) 警告", color: errs > 0 ? Theme.err : Theme.warn)
        } else {
            setSaveStatus("", color: Theme.muted)
        }
    }

    private func clearDiagnostics() {
        diagnosticLines.removeAll()
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        let full = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.underlineStyle, range: full)
        storage.removeAttribute(.underlineColor, range: full)
        storage.endEditing()
    }

    /// LSP 悬停：光标处诊断信息，否则请求 rust-analyzer hover
    @objc private func lspHoverAction() {
        let sel = textView.selectedRange()
        guard sel.length == 0, let ns = textView.textStorage?.string as NSString? else { return }
        let line = ns.substring(to: sel.location).components(separatedBy: "\n").count - 1
        // 先查诊断
        if let diag = diagnosticLines[line] {
            showHoverTooltip(diag.message)
            return
        }
        guard lspAvailable else { return }
        flushPendingLspChange()
        let (l, _) = lineColumn(at: sel.location, in: ns)
        let ch = utf16Col(in: ns, line: l - 1, offset: sel.location)
        lsp?.hover(uri: lspUri, line: l - 1, character: ch) { [weak self] text in
            if let t = text, !t.isEmpty { self?.showHoverTooltip(t) }
        }
    }

    private func showHoverTooltip(_ text: String) {
        guard let window = window else { return }
        let tooltip = NSPopover()
        let vc = NSViewController()
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Theme.mono(11)
        label.textColor = Theme.text
        label.maximumNumberOfLines = 0
        let wrap = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 120))
        label.frame = NSRect(x: 8, y: 8, width: 364, height: 104)
        wrap.addSubview(label)
        vc.view = wrap
        tooltip.contentViewController = vc
        tooltip.behavior = .transient
        let rect = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        tooltip.show(relativeTo: textView.bounds, of: textView, preferredEdge: .minY)
        _ = (window, rect)
    }

    /// LSP 跳转定义：光标移到目标位置
    @objc private func lspGoToDefinition() {
        guard lspAvailable, let ns = textView.textStorage?.string as NSString? else { return }
        flushPendingLspChange()
        let sel = textView.selectedRange()
        let (l, _) = lineColumn(at: sel.location, in: ns)
        let ch = utf16Col(in: ns, line: l - 1, offset: sel.location)
        lsp?.definition(uri: lspUri, line: l - 1, character: ch) { [weak self] pos in
            guard let self, let pos else { return }
            let ns = self.textView.textStorage?.string as NSString? ?? ""
            var offset = 0
            var li = 0
            while li < pos.line && offset < ns.length {
                let r = ns.range(of: "\n", options: [], range: NSRange(location: offset, length: ns.length - offset))
                if r.location == NSNotFound { return }
                offset = r.location + 1; li += 1
            }
            let target = min(offset + pos.character, ns.length)
            self.textView.setSelectedRange(NSRange(location: target, length: 0))
            self.textView.scrollRangeToVisible(NSRange(location: target, length: 0))
        }
    }

    /// LSP 补全：⌃Space 弹出列表（Esc 关闭，↑↓ 选择，回车/单击插入）
    @objc private func lspCompletionAction() {
        guard lspAvailable, let ns = textView.textStorage?.string as NSString? else { return }
        flushPendingLspChange()
        let sel = textView.selectedRange()
        guard sel.length == 0 else { return }
        let (l, _) = lineColumn(at: sel.location, in: ns)
        let ch = utf16Col(in: ns, line: l - 1, offset: sel.location)
        lsp?.completion(uri: lspUri, line: l - 1, character: ch) { [weak self] items in
            guard let self, !items.isEmpty else { return }
            self.completionItems = items
            self.completionIndex = 0
            self.showCompletionPopup()
        }
    }

    private func showCompletionPopup() {
        completionPopup?.close()
        let pop = NSPopover()
        let vc = CompletionListVC(items: completionItems) { [weak self] idx in
            guard let self else { return }
            self.insertCompletion(at: idx)
        }
        vc.onSelectionChange = { [weak self] idx in self?.completionIndex = idx }
        pop.contentViewController = vc
        pop.behavior = .transient
        completionPopup = pop
        let rect = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        pop.show(relativeTo: textView.bounds, of: textView, preferredEdge: .minY)
        _ = rect
    }

    private func insertCompletion(at index: Int) {
        guard index >= 0, index < completionItems.count else { return }
        let item = completionItems[index]
        guard let ns = textView.textStorage?.string as NSString? else { return }
        let sel = textView.selectedRange()
        // 从光标往前找单词边界（标识符字符），替换之
        var start = sel.location
        while start > 0 {
            let c = ns.character(at: start - 1)
            let isIdent = c >= 0x30 && c <= 0x39 || c >= 0x41 && c <= 0x5A || c >= 0x61 && c <= 0x7A || c == 0x5F
            if !isIdent { break }
            start -= 1
        }
        if start < sel.location {
            textView.textStorage?.replaceCharacters(in: NSRange(location: start, length: sel.location - start), with: item.label)
            textView.didChangeText()
        } else {
            textView.insertText(item.label, replacementRange: sel)
        }
        completionPopup?.close()
        completionPopup = nil
    }

    private func utf16Col(in ns: NSString, line: Int, offset: Int) -> Int {
        var lineStart = 0
        var li = 0
        while li < line && lineStart < ns.length {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: lineStart, length: ns.length - lineStart))
            if r.location == NSNotFound { break }
            lineStart = r.location + 1; li += 1
        }
        return offset - lineStart
    }

    // MARK: - 头部动作

    @objc private func saveAction() { performSave(thenClose: false) }

    /// 统一的保存流程：保存中禁用按钮 → 拿到结果再决定清脏标记 / 关闭 / 报错。
    private func performSave(thenClose: Bool) {
        guard !saving else { return }                 // 防连点重复写
        guard let onSave = onSave else { return }
        saving = true
        saveBtn.isEnabled = false
        setSaveStatus("保存中…", color: Theme.muted)

        onSave(textView.string) { [weak self] err in
            guard let self = self else { return }
            self.saving = false
            self.saveBtn.isEnabled = true
            if let e = err {
                // 失败：**不清脏标记、不关闭**，把错误就地显示出来
                self.setSaveStatus(L10n.t("editor.saveFailed") + "：\(e)", color: Theme.err)
                Log.warn("编辑器保存失败 \(self.filePath): \(e)", "editor")
                return
            }
            self.isDirty = false
            self.setSaveStatus(L10n.t("editor.saved") + " " + Self.stamp(), color: Theme.ok)
            if thenClose { self.onClose?() }
        }
    }

    private func setSaveStatus(_ text: String, color: NSColor) {
        saveStatus.stringValue = text
        saveStatus.textColor = color
        saveStatus.toolTip = text
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }



    @objc private func closeAction() { requestClose() }

    private func requestClose() {
        guard isDirty else { onClose?(); return }
        let alert = NSAlert.pix()
        alert.messageText = L10n.t("editor.modifiedTitle")
        alert.informativeText = String(format: L10n.t("editor.modifiedBody"), (filePath as NSString).lastPathComponent)
        alert.addButton(withTitle: L10n.t("common.save"))
        alert.addButton(withTitle: L10n.t("editor.discard"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // 保存成功才关；失败时留在编辑器里（否则改动就丢了）
            performSave(thenClose: true)
        case .alertSecondButtonReturn:
            onClose?()
        default:
            break
        }
    }

    @objc private func dragCard(_ g: NSPanGestureRecognizer) {
        let t = g.translation(in: self)
        cardX.constant += t.x; cardY.constant += t.y
        g.setTranslation(.zero, in: self)
    }

    // 点遮罩(卡片外)关闭——同样过脏检查
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !card.frame.contains(p) { requestClose() } else { super.mouseDown(with: event) }
    }
    // Esc 关闭——同样过脏检查；⌃Space 补全、⌘悬停、⌘⇧G 跳转定义
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !isHidden, event.keyCode == 53 { requestClose(); return true }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .control, event.charactersIgnoringModifiers == " " {
            lspCompletionAction(); return true
        }
        if mods == .command, event.charactersIgnoringModifiers == " " {
            lspHoverAction(); return true
        }
        if mods == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "g" {
            lspGoToDefinition(); return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - 工具条：行号/自动换行

    @objc private func toggleLineNumbers(_ sender: NSButton) {
        scrollView.rulersVisible = sender.state == .on
    }

    @objc private func toggleWrap(_ sender: NSButton) {
        wrapEnabled = sender.state == .on
        applyWrapSetting()
    }

    private func applyWrapSetting() {
        guard let tc = textView.textContainer else { return }
        if wrapEnabled {
            tc.widthTracksTextView = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            tc.containerSize = NSSize(width: max(scrollView.contentSize.width, 10), height: CGFloat.greatestFiniteMagnitude)
            scrollView.hasHorizontalScroller = false
        } else {
            tc.widthTracksTextView = false
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            tc.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            scrollView.hasHorizontalScroller = true
        }
        gutter?.needsDisplay = true
    }

    // MARK: - 查找 / 替换

    @objc private func findNextAction() { performFind(backwards: false) }
    @objc private func findPrevAction() { performFind(backwards: true) }

    private func performFind(backwards: Bool) {
        let query = findField.stringValue
        guard !query.isEmpty else { return }
        let ns = textView.string as NSString
        guard ns.length > 0 else { return }
        let sel = textView.selectedRange()
        var options: NSString.CompareOptions = [.caseInsensitive]
        if backwards { options.insert(.backwards) }

        let primaryRange: NSRange = backwards
            ? NSRange(location: 0, length: sel.location)
            : NSRange(location: NSMaxRange(sel), length: ns.length - NSMaxRange(sel))
        var found = ns.range(of: query, options: options, range: primaryRange)
        if found.location == NSNotFound {
            // 回绕：从头/尾重新找一遍
            found = ns.range(of: query, options: options, range: NSRange(location: 0, length: ns.length))
        }
        guard found.location != NSNotFound else { NSSound.beep(); return }
        textView.setSelectedRange(found)
        textView.scrollRangeToVisible(found)
        textView.showFindIndicator(for: found)
        updateFooter()
    }

    @objc private func replaceOneAction() {
        let query = findField.stringValue
        guard !query.isEmpty else { return }
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        if sel.length > 0, ns.substring(with: sel).caseInsensitiveCompare(query) == .orderedSame,
           textView.shouldChangeText(in: sel, replacementString: replaceField.stringValue) {
            textView.replaceCharacters(in: sel, with: replaceField.stringValue)
            textView.didChangeText()
        }
        performFind(backwards: false)
    }

    @objc private func replaceAllAction() {
        let query = findField.stringValue
        guard !query.isEmpty else { return }
        let ns = textView.string as NSString
        guard ns.length > 0 else { return }
        let full = NSRange(location: 0, length: ns.length)
        let replaced = ns.replacingOccurrences(of: query, with: replaceField.stringValue, options: [.caseInsensitive], range: full)
        guard replaced != (ns as String) else { return }
        guard textView.shouldChangeText(in: full, replacementString: replaced) else { return }
        textView.replaceCharacters(in: full, with: replaced)
        textView.didChangeText()
    }

    // MARK: - NSTextViewDelegate / NSTextStorageDelegate

    func textViewDidChangeSelection(_ notification: Notification) {
        updateFooter()
    }

    /// 只在「真的改了字符」时才重新染色/置脏——避免我们自己在这里改属性又把自己触发一遍。
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                      range editedRange: NSRange, changeInLength delta: Int) {
        guard !isLoadingDocument, editedMask.contains(.editedCharacters) else { return }
        isDirty = true
        rehighlight(textStorage)
        gutter?.needsDisplay = true
        updateFooter()
        scheduleLSPChange(textStorage.string)   // LSP：防抖 0.4s 后全文同步
    }

    private func rehighlight(_ textStorage: NSTextStorage) {
        guard lang != .plain else { return }
        let highlighted = EditorSyntax.highlight(textStorage.string, lang: lang, dark: Theme.dark)
        guard highlighted.length == textStorage.length else { return } // 安全兜底，长度不一致就不动属性
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.beginEditing()
        textStorage.removeAttribute(.foregroundColor, range: full)
        highlighted.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: highlighted.length)) { value, range, _ in
            if let v = value { textStorage.addAttribute(.foregroundColor, value: v, range: range) }
        }
        textStorage.addAttribute(.font, value: Theme.mono(12), range: full)
        textStorage.endEditing()
    }

    // MARK: - 状态栏

    private func updateFooter() {
        let ns = textView.string as NSString
        footerChars.stringValue = "\(ns.length) 字符"
        let sel = textView.selectedRange()
        let (line, col) = lineColumn(at: sel.location, in: ns)
        footerPos.stringValue = "行 \(line):列 \(col)"
    }

    private func lineColumn(at index: Int, in ns: NSString) -> (Int, Int) {
        guard ns.length > 0, index > 0 else { return (1, 1) }
        let clamped = min(index, ns.length)
        var line = 1
        var lastLineStart = 0
        var searchLoc = 0
        while searchLoc < clamped {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: searchLoc, length: clamped - searchLoc))
            if r.location == NSNotFound { break }
            line += 1
            lastLineStart = r.location + 1
            searchLoc = lastLineStart
        }
        let col = clamped - lastLineStart + 1
        return (line, col)
    }
}

// MARK: - 32pt 行号槽

/// 行号槽：NSRulerView 官方机制，随 NSTextView 滚动/换行自动对齐，
/// 不需要自己监听滚动事件——挂到 scrollView.verticalRulerView 后系统会在
/// 内容区域滚动/尺寸变化时自动重绘；文本变化时由 EditorPanel 手动 needsDisplay。
final class LineNumberGutter: NSRulerView {
    private weak var target: NSTextView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        target = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 32
    }
    required init(coder: NSCoder) { fatalError() }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = target, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        Theme.bg2.setFill(); bounds.fill()
        Theme.border.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()

        let content = tv.string as NSString
        let font = Theme.mono(10.5)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.muted]
        let inset = tv.textContainerInset

        guard content.length > 0 else {
            drawNumber("1", y: inset.height, height: font.boundingRectForFont.height, attrs: attrs)
            return
        }

        let visible = tv.visibleRect
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        let firstChar = lm.characterIndexForGlyph(at: glyphRange.location)
        var lineNo = lineNumber(upTo: firstChar, in: content)

        var glyphIndex = glyphRange.location
        let maxGlyph = NSMaxRange(glyphRange)
        while glyphIndex < maxGlyph {
            let charIndex = lm.characterIndexForGlyph(at: glyphIndex)
            let lineCharRange = content.lineRange(for: NSRange(location: charIndex, length: 0))
            let lineGlyphRange = lm.glyphRange(forCharacterRange: lineCharRange, actualCharacterRange: nil)

            var effective = NSRange(location: 0, length: 0)
            let lineRect = lm.lineFragmentRect(forGlyphAt: lineGlyphRange.location, effectiveRange: &effective,
                                                withoutAdditionalLayout: true)
            drawNumber("\(lineNo)", y: lineRect.minY + inset.height, height: lineRect.height, attrs: attrs)

            guard lineGlyphRange.length > 0 else { break } // 防御：避免死循环
            glyphIndex = NSMaxRange(lineGlyphRange)
            lineNo += 1
        }
    }

    private func drawNumber(_ text: String, y: CGFloat, height: CGFloat, attrs: [NSAttributedString.Key: Any]) {
        guard let tv = target else { return }
        let str = text as NSString
        let size = str.size(withAttributes: attrs)
        let originInRuler = convert(NSPoint(x: 0, y: y), from: tv)
        let rect = NSRect(x: bounds.width - size.width - 6,
                           y: originInRuler.y + (height - size.height) / 2,
                           width: size.width, height: size.height)
        str.draw(in: rect, withAttributes: attrs)
    }

    /// 数一遍 index 之前有多少个换行符，得到该位置所在的行号（从 1 开始）。
    private func lineNumber(upTo index: Int, in content: NSString) -> Int {
        guard index > 0 else { return 1 }
        var line = 1
        var searchLoc = 0
        while searchLoc < index {
            let r = content.range(of: "\n", options: [], range: NSRange(location: searchLoc, length: index - searchLoc))
            if r.location == NSNotFound { break }
            line += 1
            searchLoc = r.location + 1
        }
        return line
    }
}

/// 补全列表弹窗（NSPopover 内容）。↑↓ 选择、回车插入、单击插入。
private final class CompletionListVC: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let items: [(label: String, detail: String)]
    private let onPick: (Int) -> Void
    var onSelectionChange: ((Int) -> Void)?
    private var tableView: NSTableView!

    init(items: [(label: String, detail: String)], onPick: @escaping (Int) -> Void) {
        self.items = items
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
        scroll.hasVerticalScroller = true
        tableView = NSTableView(frame: scroll.bounds)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        col.width = 300
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 22
        scroll.documentView = tableView
        view = scroll
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: items[row].label)
        label.font = Theme.mono(12)
        label.textColor = Theme.text
        label.frame = NSRect(x: 6, y: 2, width: 170, height: 18)
        let detail = NSTextField(labelWithString: items[row].detail)
        detail.font = Theme.ui(10)
        detail.textColor = Theme.muted
        detail.frame = NSRect(x: 180, y: 2, width: 130, height: 18)
        detail.lineBreakMode = .byTruncatingTail
        cell.addSubview(label); cell.addSubview(detail)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?(tableView.selectedRow)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if NSApp.currentEvent?.clickCount == 2 { onPick(row); return false }
        return true
    }

    /// 键盘：↑↓ 选择、回车插入（由 popover key 事件处理）
    func moveSelection(delta: Int) {
        let r = min(max(tableView.selectedRow + delta, 0), items.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        tableView.scrollRowToVisible(r)
    }
    func pickSelected() {
        let r = tableView.selectedRow
        if r >= 0 { onPick(r) }
    }
}
