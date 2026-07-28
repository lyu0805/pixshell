import AppKit

/// SFTP「文件权限…」弹窗。
/// ~340×380，可拖、可缩放；Theme.bg / Theme.text，无杂色。
/// Owner/Group/Other 各 r/w/x（4/2/1）复选 + 实时八进制；递归 + 应用范围；OK 后走 chmod / chmod -R。
final class ChmodWindow: NSWindowController {

    private let card = NSView()
    private let pathLabel = NSTextField(wrappingLabelWithString: "")
    private let octalLabel = NSTextField(labelWithString: "0755")
    private var ownerBoxes: [NSButton] = []
    private var groupBoxes: [NSButton] = []
    private var otherBoxes: [NSButton] = []
    private let recursiveBox = NSButton(checkboxWithTitle: "递归设置子目录", target: nil, action: nil)
    private let modePopup = NSPopUpButton()

    private var paths: [String] = []
    private var initialMode: UInt32 = 0o755
    /// 执行 chmod 命令（宿主注入 ssh.exec）
    var execRunner: ((String, @escaping (String) -> Void) -> Void)?
    var onDone: ((String) -> Void)?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 380),
                         styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
                         backing: .buffered, defer: false)
        w.title = "文件权限"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 300, height: 320)
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: w)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 展示：paths 为远端绝对路径；mode 为 POSIX 权限位（可含文件类型高位，取低 9 位）。
    func show(paths: [String], mode: UInt32, execRunner: ((String, @escaping (String) -> Void) -> Void)?) {
        self.paths = paths
        self.execRunner = execRunner
        self.initialMode = mode & 0o777
        applyMode(initialMode)
        let shown = paths.prefix(3).joined(separator: "\n")
        let more = paths.count > 3 ? "\n…共 \(paths.count) 项" : ""
        pathLabel.stringValue = shown + more
        recursiveBox.state = .off
        modePopup.selectItem(at: 0)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() { window?.orderOut(nil) }

    private func build() {
        guard let w = window else { return }
        card.rounded(Theme.radiusLg, bg: Theme.bg, border: Theme.borderStrong)
        card.translatesAutoresizingMaskIntoConstraints = false

        let root = EscapableView()
        root.onEscape = { [weak self] in self?.cancel() }
        root.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: root.topAnchor),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        w.contentView = root

        let title = NSTextField(labelWithString: "文件权限…")
        title.font = Theme.ui(15, .semibold); title.textColor = Theme.text
        let closeBtn = PillButton("取消", style: .secondary, hPad: 10, target: self, action: #selector(cancel))
        let head = NSStackView(views: [title, NSView(), closeBtn]); head.spacing = 12; head.alignment = .centerY
        head.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.font = Theme.mono(11); pathLabel.textColor = Theme.muted
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.maximumNumberOfLines = 4

        ownerBoxes = makeTriad(title: "Owner（所有者）", bits: [4, 2, 1])
        groupBoxes = makeTriad(title: "Group（组）", bits: [4, 2, 1])
        otherBoxes = makeTriad(title: "Other（其他）", bits: [4, 2, 1])
        let ownerRow = triadRow("Owner", boxes: ownerBoxes)
        let groupRow = triadRow("Group", boxes: groupBoxes)
        let otherRow = triadRow("Other", boxes: otherBoxes)

        let octTitle = NSTextField(labelWithString: "权限值")
        octTitle.font = Theme.ui(11, .semibold); octTitle.textColor = Theme.text
        octalLabel.font = Theme.mono(18); octalLabel.textColor = Theme.accent
        octalLabel.alignment = .center
        let octRow = NSStackView(views: [octTitle, NSView(), octalLabel]); octRow.alignment = .centerY
        octRow.translatesAutoresizingMaskIntoConstraints = false

        recursiveBox.font = Theme.ui(12); recursiveBox.contentTintColor = Theme.text
        styleCheck(recursiveBox)
        recursiveBox.target = self; recursiveBox.action = #selector(recursiveToggled)

        modePopup.removeAllItems()
        modePopup.addItems(withTitles: [
            "应用到文件和目录",
            "只应用到文件",
            "只应用到目录",
        ])
        modePopup.font = Theme.ui(12)
        // 强制走 Theme，避免系统 control 与卡片底色错配
        modePopup.appearance = NSAppearance(named: Theme.dark ? .darkAqua : .aqua)
        modePopup.isEnabled = false
        modePopup.translatesAutoresizingMaskIntoConstraints = false
        modePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        let okBtn = PillButton("确定", style: .primary, hPad: 16, target: self, action: #selector(confirm))
        let cancelBtn = PillButton("取消", style: .secondary, hPad: 14, target: self, action: #selector(cancel))
        let foot = NSStackView(views: [NSView(), cancelBtn, okBtn]); foot.spacing = 8; foot.alignment = .centerY
        foot.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView(views: [
            head, pathLabel, ownerRow, groupRow, otherRow, octRow,
            recursiveBox, modePopup, foot,
        ])
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 12
        body.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            head.widthAnchor.constraint(equalTo: body.widthAnchor),
            pathLabel.widthAnchor.constraint(equalTo: body.widthAnchor),
            ownerRow.widthAnchor.constraint(equalTo: body.widthAnchor),
            groupRow.widthAnchor.constraint(equalTo: body.widthAnchor),
            otherRow.widthAnchor.constraint(equalTo: body.widthAnchor),
            octRow.widthAnchor.constraint(equalTo: body.widthAnchor),
            modePopup.widthAnchor.constraint(equalTo: body.widthAnchor),
            foot.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])
    }

    private func makeTriad(title: String, bits: [Int]) -> [NSButton] {
        bits.map { bit in
            let label: String
            switch bit {
            case 4: label = "读 (r=4)"
            case 2: label = "写 (w=2)"
            default: label = "执行 (x=1)"
            }
            let b = NSButton(checkboxWithTitle: label, target: self, action: #selector(bitChanged))
            b.tag = bit
            styleCheck(b)
            return b
        }
    }

    private func styleCheck(_ b: NSButton) {
        b.font = Theme.ui(12)
        b.contentTintColor = Theme.text
        // 强制标题色与 Theme 一致，避免系统控件浅色/深色错配
        b.attributedTitle = NSAttributedString(string: b.title, attributes: [
            .foregroundColor: Theme.text,
            .font: Theme.ui(12),
        ])
    }

    private func triadRow(_ name: String, boxes: [NSButton]) -> NSView {
        let lab = NSTextField(labelWithString: name)
        lab.font = Theme.ui(11, .semibold); lab.textColor = Theme.text
        lab.translatesAutoresizingMaskIntoConstraints = false
        lab.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let row = NSStackView(views: [lab] + boxes)
        row.spacing = 10; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    @objc private func bitChanged() { refreshOctal() }
    @objc private func recursiveToggled() {
        modePopup.isEnabled = recursiveBox.state == .on
    }

    private func currentMode() -> UInt32 {
        func sum(_ boxes: [NSButton]) -> UInt32 {
            boxes.reduce(0) { $0 + ($1.state == .on ? UInt32($1.tag) : 0) }
        }
        return (sum(ownerBoxes) << 6) | (sum(groupBoxes) << 3) | sum(otherBoxes)
    }

    private func applyMode(_ mode: UInt32) {
        let m = mode & 0o777
        func set(_ boxes: [NSButton], _ nibble: UInt32) {
            for b in boxes { b.state = (nibble & UInt32(b.tag)) != 0 ? .on : .off }
        }
        set(ownerBoxes, (m >> 6) & 0o7)
        set(groupBoxes, (m >> 3) & 0o7)
        set(otherBoxes, m & 0o7)
        refreshOctal()
    }

    private func refreshOctal() {
        let m = currentMode()
        octalLabel.stringValue = String(format: "0%03o", m)
        octalLabel.textColor = Theme.accent
    }

    @objc private func cancel() { hide() }

    @objc private func confirm() {
        guard !paths.isEmpty else { hide(); return }
        let mode = currentMode()
        let oct = String(format: "%03o", mode)
        let recursive = recursiveBox.state == .on
        let scope = modePopup.indexOfSelectedItem   // 0 both / 1 files / 2 dirs
        let quoted = paths.map { SFTPTransfer.quote($0) }.joined(separator: " ")

        let cmd: String
        if recursive {
            // find 按类型过滤后 chmod；both 时用 chmod -R
            switch scope {
            case 1:
                cmd = "find \(quoted) -type f -exec chmod \(oct) {} + 2>&1"
            case 2:
                cmd = "find \(quoted) -type d -exec chmod \(oct) {} + 2>&1"
            default:
                cmd = "chmod -R \(oct) \(quoted) 2>&1"
            }
        } else {
            cmd = "chmod \(oct) \(quoted) 2>&1"
        }

        guard let run = execRunner else {
            onDone?("需要 SSH 会话才能改权限")
            hide()
            return
        }
        Log.info("chmod \(oct)\(recursive ? " -R" : "") \(paths.count) 项", "sftp")
        run(cmd) { [weak self] out in
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = trimmed.isEmpty ? "已设置权限 \(String(format: "0%03o", mode))" : "chmod: \(trimmed)"
            self?.onDone?(msg)
            self?.hide()
        }
    }
}
