import AppKit

/// 工具结果窗口（路由追踪 / 进程管理 / 网络监控 / 速度测试的输出）。
///
/// 为什么单独开窗：老仓库里这几个动作是 `data-act="tab-route|tab-process|tab-network"`，
/// 结果开在**中央工作区的标签页**里，而不是塞在那个 360px 的工具浮窗内 —— 工具浮窗本身
/// 只放主机下拉/工具入口/下载任务。原生端没有"任务标签页"这层，用一个独立窗口承载等价角色。
final class ToolResultWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private var window: NSWindow?
    private var out: NSTextView!
    private var textScroll: NSScrollView!
    private let table = NSTableView()
    private var tableScroll: NSScrollView!
    private var killBtn: PillButton!
    private let titleLabel = NSTextField(labelWithString: "")

    private enum Mode { case text, process, network }
    private var mode: Mode = .text
    private var procRows: [ToolsPanel.ProcRow] = []
    private var netRows: [ToolsPanel.NetRow] = []

    /// 结束进程回调：(pid, 信号)
    var onKill: ((String, String) -> Void)?

    // MARK: 窗口
    private func ensureWindow() {
        if window != nil { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "工具"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 520, height: 320)
        // 浮在主窗终端之上，避免被 SwiftTerm 视图/主窗抢层级（截图 P0：工具框被终端遮挡）
        w.level = .floating
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.bg2.cgColor

        titleLabel.font = Theme.ui(12, .semibold); titleLabel.textColor = Theme.text
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        killBtn = PillButton("结束进程", style: .danger, hPad: 10, height: 22, target: self, action: #selector(killSelected))
        killBtn.isHidden = true

        let head = NSStackView(views: [titleLabel, NSView(), killBtn])
        head.spacing = 10; head.alignment = .centerY
        head.translatesAutoresizingMaskIntoConstraints = false

        let ts: NSScrollView
        (ts, out) = ScrollableText.make(font: Theme.mono(11), editable: false,
                                        bg: Theme.bg, border: Theme.border)
        textScroll = ts

        table.dataSource = self; table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20; table.gridStyleMask = []
        table.backgroundColor = Theme.bg
        table.allowsMultipleSelection = false
        let tbs = NSScrollView(); tbs.documentView = table
        tbs.hasVerticalScroller = true; tbs.drawsBackground = true; tbs.backgroundColor = Theme.bg
        tbs.rounded(Theme.radiusSm, border: Theme.border)
        tbs.translatesAutoresizingMaskIntoConstraints = false
        tbs.isHidden = true
        tableScroll = tbs

        root.addSubview(head); root.addSubview(ts); root.addSubview(tbs)
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            head.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            head.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            ts.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 10),
            ts.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            ts.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            ts.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            tbs.topAnchor.constraint(equalTo: ts.topAnchor),
            tbs.leadingAnchor.constraint(equalTo: ts.leadingAnchor),
            tbs.trailingAnchor.constraint(equalTo: ts.trailingAnchor),
            tbs.bottomAnchor.constraint(equalTo: ts.bottomAnchor),
        ])
        w.contentView = root
        w.center()
        window = w
    }

    private func present(_ label: String) {
        ensureWindow()
        titleLabel.stringValue = label
        if let main = NSApp.mainWindow, let w = window {
            // 相对主窗偏移一点，避免完全重叠；保证每次都在主窗之上
            let mf = main.frame
            if !w.isVisible {
                w.setFrameOrigin(NSPoint(x: mf.midX - w.frame.width / 2,
                                         y: mf.midY - w.frame.height / 2 + 40))
            }
        }
        window?.level = .floating
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 三种展示
    func showRunning(_ label: String) {
        present(label)
        showTextBody("\(label) 执行中…")
    }
    func showText(_ s: String, label: String = "工具") {
        present(label)
        showTextBody(s)
    }
    private func showTextBody(_ s: String) {
        mode = .text
        tableScroll.isHidden = true; killBtn.isHidden = true
        textScroll.isHidden = false
        out.string = s
    }

    func showProcesses(_ raw: String) {
        present("进程管理")
        procRows = ToolsPanel.ProcRow.parse(raw)
        netRows = []
        if procRows.isEmpty { showTextBody("进程管理：无输出（远端可能缺少 ps）"); return }
        mode = .process
        tableScroll.isHidden = false; textScroll.isHidden = true; killBtn.isHidden = false
        configureColumns(["PID", "用户", "内存", "CPU", "名称 | 命令行"], widths: [60, 90, 70, 55, 380])
        table.reloadData()
    }

    func showNetwork(_ raw: String) {
        present("网络监控")
        netRows = ToolsPanel.NetRow.parse(raw)
        procRows = []
        if netRows.isEmpty { showTextBody("网络监控：无输出（远端可能缺少 ss/netstat）"); return }
        mode = .network
        tableScroll.isHidden = false; textScroll.isHidden = true; killBtn.isHidden = true
        configureColumns(["协议", "状态", "监听地址", "端口", "进程"], widths: [60, 90, 190, 60, 240])
        table.reloadData()
    }

    private func configureColumns(_ titles: [String], widths: [CGFloat]) {
        table.tableColumns.forEach { table.removeTableColumn($0) }
        for (i, t) in titles.enumerated() {
            let c = NSTableColumn(identifier: .init("c\(i)")); c.title = t
            c.width = widths.indices.contains(i) ? widths[i] : 100
            table.addTableColumn(c)
        }
    }

    // MARK: 表格
    func numberOfRows(in tableView: NSTableView) -> Int {
        mode == .process ? procRows.count : (mode == .network ? netRows.count : 0)
    }
    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let idx = Int((col?.identifier.rawValue.dropFirst()).flatMap { Int($0) } ?? 0)
        var text = "", color = Theme.text
        if mode == .process, procRows.indices.contains(row) {
            let r = procRows[row]
            switch idx {
            case 0: text = r.pid; color = Theme.muted
            case 1: text = r.user; color = Theme.muted
            case 2: text = r.mem; color = Theme.accent
            case 3: text = r.cpu; color = Theme.err
            default: text = r.args
            }
        } else if mode == .network, netRows.indices.contains(row) {
            let r = netRows[row]
            switch idx {
            case 0: text = r.proto; color = Theme.accent
            case 1: text = r.state; color = Theme.muted
            case 2: text = r.local
            case 3: text = r.port; color = Theme.ok
            default: text = r.process; color = Theme.muted
            }
        }
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: text)
        tf.font = Theme.mono(10.5); tf.textColor = color; tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf); cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// 结束选中进程（老仓库：确认后发 SIGTERM）
    @objc private func killSelected() {
        let row = table.selectedRow
        guard mode == .process, procRows.indices.contains(row) else { showTextBody("请先选中一个进程"); return }
        let r = procRows[row]
        let a = NSAlert.pix(); a.messageText = "结束进程 PID \(r.pid)？"
        a.informativeText = "\(r.name)\n\(r.args)"
        a.addButton(withTitle: "结束(SIGTERM)"); a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        onKill?(r.pid, "TERM")
    }
}
