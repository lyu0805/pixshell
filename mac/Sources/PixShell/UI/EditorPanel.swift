import AppKit

/// 文本编辑器弹层：文件名/语言徽标/保存/关闭 头部 + 查找替换工具条 +
/// 32pt 行号槽 + 文本区 + 状态栏。对齐老仓库 packages/editor（语言探测/高亮/
/// 查找替换/保存/脏检查/32px 行号槽），仿 SysInfoPanel 的卡片弹窗结构
/// （遮罩 + 圆角卡片、HeaderPanGesture 拖动、点遮罩/Esc 关闭）。
final class EditorPanel: NSView, NSTextViewDelegate, NSTextStorageDelegate {

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
        head = NSStackView(views: [headerTitle, NSView(), saveStatus, saveBtn, closeBtn])
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

        lineNumberCheck = NSButton(checkboxWithTitle: "行号", target: self, action: #selector(toggleLineNumbers(_:)))
        lineNumberCheck.state = .on
        lineNumberCheck.font = Theme.ui(11)
        wrapCheck = NSButton(checkboxWithTitle: "自动换行", target: self, action: #selector(toggleWrap(_:)))
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
                self.setSaveStatus("保存失败：\(e)", color: Theme.err)
                Log.warn("编辑器保存失败 \(self.filePath): \(e)", "editor")
                return
            }
            self.isDirty = false
            self.setSaveStatus("已保存 " + Self.stamp(), color: Theme.ok)
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
        alert.messageText = "文件已修改"
        alert.informativeText = "是否保存对“\((filePath as NSString).lastPathComponent)”的更改？"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "放弃")
        alert.addButton(withTitle: "取消")
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
    // Esc 关闭——同样过脏检查
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !isHidden, event.keyCode == 53 { requestClose(); return true }
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
