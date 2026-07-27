import AppKit

final class CommandHistoryVC: NSViewController {
    var items: [String] = []
    
    var onSelect: ((String) -> Void)?
    var onRun: ((String) -> Void)?
    var onCopy: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    var onClear: (() -> Void)?
    
    private let stack = NSStackView()
    
    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.bg.cgColor
        
        // Scroll View
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor)
        ])
        
        // Populate items
        for cmd in items {
            let row = HistoryRowView(cmd: cmd)
            row.onSelect = { [weak self] in self?.onSelect?(cmd) }
            row.onRun = { [weak self] in self?.onRun?(cmd) }
            row.onCopy = { [weak self] in self?.onCopy?(cmd) }
            row.onDelete = { [weak self] in
                self?.onDelete?(cmd)
                row.removeFromSuperview()
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        
        if items.isEmpty {
            let empty = NSTextField(labelWithString: "暂无历史记录")
            empty.textColor = Theme.muted
            empty.font = Theme.ui(12)
            empty.translatesAutoresizingMaskIntoConstraints = false
            let wrap = NSView()
            wrap.addSubview(empty)
            empty.centerXAnchor.constraint(equalTo: wrap.centerXAnchor).isActive = true
            empty.centerYAnchor.constraint(equalTo: wrap.centerYAnchor).isActive = true
            wrap.heightAnchor.constraint(equalToConstant: 80).isActive = true
            stack.addArrangedSubview(wrap)
            wrap.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        
        // Divider
        let div = NSView()
        div.wantsLayer = true
        div.layer?.backgroundColor = Theme.border.cgColor
        div.translatesAutoresizingMaskIntoConstraints = false
        div.heightAnchor.constraint(equalToConstant: 1).isActive = true
        
        // Footer (Clear List button)
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        
        let clearBtn = PillButton("清空列表", style: .secondary, hPad: 10, height: 22, font: Theme.ui(11, .medium))
        clearBtn.target = self
        clearBtn.action = #selector(clearAction)
        clearBtn.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(clearBtn)
        
        let hint = NSTextField(labelWithString: "按 ↑ ↓ 选择记录")
        hint.font = Theme.ui(11)
        hint.textColor = Theme.muted
        hint.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(hint)
        
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            hint.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            
            clearBtn.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
            clearBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            footer.heightAnchor.constraint(equalToConstant: 36)
        ])
        
        root.addSubview(scroll)
        root.addSubview(div)
        root.addSubview(footer)
        
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            
            div.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            div.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            div.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            
            footer.topAnchor.constraint(equalTo: div.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        
        // Dynamic sizing based on item count
        let rowHeight: CGFloat = 26
        let maxVisibleRows: CGFloat = 12
        let contentHeight = min(CGFloat(max(1, items.count)) * rowHeight, maxVisibleRows * rowHeight)
        
        root.frame = NSRect(x: 0, y: 0, width: 420, height: contentHeight + 37)
        self.view = root
    }
    
    @objc private func clearAction() {
        onClear?()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }
}

final class HistoryRowView: NSView {
    var onSelect: (() -> Void)?
    var onRun: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDelete: (() -> Void)?
    
    private let cmdText: String
    private let actionBox = NSStackView()
    private var trackingArea: NSTrackingArea?
    
    init(cmd: String) {
        self.cmdText = cmd
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        
        let label = NSTextField(labelWithString: cmd)
        label.font = Theme.mono(12)
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        
        actionBox.orientation = .horizontal
        actionBox.spacing = 6
        actionBox.translatesAutoresizingMaskIntoConstraints = false
        actionBox.isHidden = true
        
        // We use system symbols for the buttons: play.fill, doc.on.doc, xmark
        let runBtn = NSButton(image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil) ?? NSImage(), target: self, action: #selector(runAction))
        runBtn.isBordered = false
        runBtn.contentTintColor = NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1) // Green play button
        runBtn.toolTip = "直接运行"
        
        let copyBtn = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil) ?? NSImage(), target: self, action: #selector(copyAction))
        copyBtn.isBordered = false
        copyBtn.contentTintColor = Theme.accent
        copyBtn.toolTip = "复制"
        
        let delBtn = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil) ?? NSImage(), target: self, action: #selector(deleteAction))
        delBtn.isBordered = false
        delBtn.contentTintColor = Theme.err
        delBtn.toolTip = "删除"
        
        for btn in [runBtn, copyBtn, delBtn] {
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(equalToConstant: 16).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 16).isActive = true
            actionBox.addArrangedSubview(btn)
        }
        
        addSubview(label)
        addSubview(actionBox)
        
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: actionBox.leadingAnchor, constant: -8),
            
            actionBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            actionBox.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }
    
    override func mouseEntered(with event: NSEvent) {
        wantsLayer = true
        layer?.backgroundColor = Theme.controlHover.cgColor
        actionBox.isHidden = false
    }
    
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        actionBox.isHidden = true
    }
    
    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }
    
    @objc private func runAction() { onRun?() }
    @objc private func copyAction() { onCopy?() }
    @objc private func deleteAction() { onDelete?() }
}
