import AppKit

/// 工具浮窗（顶栏宫格图标 → 老仓库 `#toolsPanel` / `.flyout-panel`）。
///
/// **这是一个小浮窗，不是独立界面。** 老仓库 CSS：`width: min(360px, 92vw); padding: 12px;`
/// 固定在顶栏下方靠右，点图标呼出、再点收起。内容以「下载任务」为主：
///   [主机下拉]
///   [路由追踪][进程管理][网络监控][速度测试]
///   下载: <目录>  [选择目录][打开目录]
///   [下载任务列表]  ← 120pt，老仓库 .tools-dl-box
/// 工具按钮的**输出不在浮窗里显示**（老仓库是开成中央标签页），走 ToolResultWindow 独立窗口。
final class ToolsPanel: NSView {
    private let card = NSView()
    private let hostPopup = NSPopUpButton()
    private let dlPath = NSTextField(labelWithString: "-")
    private let dlList = NSStackView()
    private let dlEmpty = NSTextField(labelWithString: "下载任务将显示在这里")

    /// 工具输出的承载窗口（进程表/网络表/路由文本/测速文本）
    let result = ToolResultWindow()

    /// 结束进程回调：(pid, 信号) —— 转发自结果窗口
    var onKill: ((String, String) -> Void)? {
        get { result.onKill }
        set { result.onKill = newValue }
    }

    /// `ps -eo pid,user,rss,pcpu,comm,args` 一行 → 结构化
    struct ProcRow {
        let pid: String, user: String, mem: String, cpu: String, name: String, args: String
        static func parse(_ raw: String) -> [ProcRow] {
            raw.split(separator: "\n").dropFirst().compactMap { line in
                let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard f.count >= 5, Int(f[0]) != nil else { return nil }
                let rss = Double(f[2]) ?? 0
                let mem = rss >= 1024 ? String(format: "%.1fM", rss / 1024) : "\(Int(rss))K"
                let args = f.count > 5 ? f[5...].joined(separator: " ") : f[4]
                return ProcRow(pid: f[0], user: f[1], mem: mem, cpu: f[3] + "%", name: f[4], args: args)
            }
        }
    }
    /// `ss -tulnpH` 一行 → 结构化
    struct NetRow {
        let proto: String, state: String, local: String, port: String, process: String
        static func parse(_ raw: String) -> [NetRow] {
            raw.split(separator: "\n").compactMap { line in
                let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard f.count >= 5 else { return nil }
                let localFull = f[4]
                let port = localFull.contains(":") ? String(localFull.split(separator: ":").last ?? "") : ""
                let addr = localFull.contains(":") ? String(localFull.dropLast(port.count + 1)) : localFull
                let proc = f.count > 6 ? f[6...].joined(separator: " ") : ""
                return NetRow(proto: f[0], state: f[1], local: addr, port: port, process: proc)
            }
        }
    }

    /// 会话下拉数据源：(标题, 是否当前)
    var sessionsProvider: (() -> [(title: String, active: Bool)])?
    var onSelectSession: ((Int) -> Void)?
    /// 在当前会话执行远端命令，回调完整输出
    var onExec: ((String, @escaping (String) -> Void) -> Void)?
    var onPickDownloadDir: (() -> Void)?
    var onOpenDownloadDir: (() -> Void)?
    var onClose: (() -> Void)?

    // 与老仓库 ssh-engine 相同的采集命令
    static let cmdProcess = "ps -eo pid,user,rss,pcpu,comm,args --sort=-pcpu 2>/dev/null | head -n 80 || ps w 2>/dev/null | head -n 80"
    static let cmdNetwork = "ss -tulnpH 2>/dev/null || netstat -tulnp 2>/dev/null | tail -n +3"
    static func cmdRoute(_ host: String) -> String {
        "echo '=== PING ==='; ping -c 4 -W 2 \(host) 2>&1; echo; echo '=== TRACE ==='; traceroute -n -w 1 -q 1 -m 12 \(host) 2>&1 || tracepath \(host) 2>&1"
    }
    // 速度测试：优先 curl 计时下载，回退 wget
    static let cmdSpeed = """
    echo '下载 10MB 测速中…'
    curl -o /dev/null -s -w '下载速度: %{speed_download} B/s\\n耗时: %{time_total} s\\n' https://speed.cloudflare.com/__down?bytes=10000000 2>&1 \
      || wget -O /dev/null https://speed.cloudflare.com/__down?bytes=10000000 2>&1 | tail -3 \
      || echo '未找到 curl/wget'
    """

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        DownloadTasks.shared.onChange = { [weak self] in self?.reloadDownloads() }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 浮窗是否已显示（供顶栏图标做"再点一下收起"）
    var isOpen: Bool { !isHidden }

    func show() {
        isHidden = false
        reloadSessions()
        reloadDownloads()
    }

    func setDownloadPath(_ p: String) { dlPath.stringValue = p }

    // 工具输出统一进独立结果窗口（浮窗保持小尺寸）
    func showRunning(_ label: String) { result.showRunning(label) }
    func showOutput(_ text: String, label: String) {
        result.showText(text.isEmpty ? "\(label): 无输出（远端可能缺少该命令）" : text, label: label)
    }
    func showProcesses(_ raw: String) { result.showProcesses(raw) }
    func showNetwork(_ raw: String) { result.showNetwork(raw) }

    func reloadSessions() {
        hostPopup.removeAllItems()
        let list = sessionsProvider?() ?? []
        if list.isEmpty { hostPopup.addItem(withTitle: "选择主机…"); hostPopup.isEnabled = false; return }
        hostPopup.isEnabled = true
        for s in list { hostPopup.addItem(withTitle: s.title) }
        if let i = list.firstIndex(where: { $0.active }) { hostPopup.selectItem(at: i) }
    }

    /// 下载任务列表（浮窗主体内容）
    private func reloadDownloads() {
        dlList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let tasks = DownloadTasks.shared.tasks
        dlEmpty.isHidden = !tasks.isEmpty
        for t in tasks.prefix(20) {
            dlList.addArrangedSubview(downloadRow(t))
        }
    }

    private func downloadRow(_ t: DownloadTasks.Task) -> NSView {
        let dot: NSColor
        let stateText: String
        switch t.state {
        case .running: dot = Theme.accent; stateText = "下载中"
        case .done:    dot = Theme.ok;     stateText = "完成"
        case .failed:  dot = Theme.err;    stateText = t.detail.isEmpty ? "失败" : "失败 · " + t.detail
        }
        let d = Dot(dot, size: 6)
        let name = NSTextField(labelWithString: t.name)
        name.font = Theme.ui(11, .medium); name.textColor = Theme.text
        name.lineBreakMode = .byTruncatingMiddle
        let st = NSTextField(labelWithString: stateText)
        st.font = Theme.ui(10); st.textColor = Theme.muted
        st.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [d, name, NSView(), st])
        row.orientation = .horizontal; row.spacing = 6; row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func build() {
        // 关键：浮窗本体是**透明**的全区域捕获层（只为"点外面收起"），不再压一层半透明黑幕，
        // 否则整个 App 会像开了模态弹窗——那是之前"做成独立界面"的观感来源。
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        card.rounded(Theme.radius, bg: Theme.bg2, border: Theme.borderStrong)
        card.shadow = NSShadow()
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.35
        card.layer?.shadowRadius = 14
        card.layer?.shadowOffset = CGSize(width: 0, height: -4)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        // 主机下拉
        hostPopup.translatesAutoresizingMaskIntoConstraints = false
        hostPopup.target = self; hostPopup.action = #selector(hostChanged)
        hostPopup.font = Theme.ui(12)

        // 工具 chips（路由/进程/网络/测速）
        let row1 = NSStackView(views: [chip("路由追踪", #selector(toolRoute)),
                                       chip("进程管理", #selector(toolProcess)),
                                       chip("网络监控", #selector(toolNetwork))])
        let row2 = NSStackView(views: [chip("速度测试", #selector(toolSpeed)), NSView()])
        [row1, row2].forEach { $0.orientation = .horizontal; $0.spacing = 6; $0.alignment = .centerY }
        let chips = NSStackView(views: [row1, row2])
        chips.orientation = .vertical; chips.alignment = .leading; chips.spacing = 6
        chips.translatesAutoresizingMaskIntoConstraints = false

        // 下载目录行
        let dlLab = NSTextField(labelWithString: "下载:"); dlLab.font = Theme.ui(12, .semibold); dlLab.textColor = Theme.muted
        dlPath.font = Theme.mono(11); dlPath.textColor = Theme.text; dlPath.lineBreakMode = .byTruncatingHead
        dlPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let pick = IconButton(symbol: "folder", tooltip: "选择下载目录", size: NSSize(width: 26, height: 22), target: self, action: #selector(pickDir))
        let open = IconButton(symbol: "folder.badge.gearshape", tooltip: "打开下载目录", size: NSSize(width: 26, height: 22), target: self, action: #selector(openDir))
        let dlRow = NSStackView(views: [dlLab, dlPath, pick, open]); dlRow.spacing = 6; dlRow.alignment = .centerY
        dlRow.translatesAutoresizingMaskIntoConstraints = false

        // 下载任务框（老仓库 .tools-dl-box：高 120，bg + 边框 + 可滚动）
        dlEmpty.font = Theme.ui(11); dlEmpty.textColor = Theme.muted
        dlEmpty.translatesAutoresizingMaskIntoConstraints = false
        dlList.orientation = .vertical; dlList.alignment = .leading; dlList.spacing = 0
        dlList.translatesAutoresizingMaskIntoConstraints = false

        let box = NSScrollView()
        box.hasVerticalScroller = true
        box.drawsBackground = true; box.backgroundColor = Theme.bg
        box.rounded(Theme.radiusSm, border: Theme.border)
        box.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(dlList); doc.addSubview(dlEmpty)
        box.documentView = doc
        NSLayoutConstraint.activate([
            doc.widthAnchor.constraint(equalTo: box.widthAnchor),
            dlList.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            dlList.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            dlList.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            dlList.bottomAnchor.constraint(lessThanOrEqualTo: doc.bottomAnchor),
            dlEmpty.topAnchor.constraint(equalTo: doc.topAnchor, constant: 10),
            dlEmpty.centerXAnchor.constraint(equalTo: doc.centerXAnchor),
        ])

        card.addSubview(hostPopup); card.addSubview(chips); card.addSubview(dlRow); card.addSubview(box)
        NSLayoutConstraint.activate([
            // 定位：顶栏下方靠右（老仓库 top: menubar-h + 6; right: 40）
            card.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            card.widthAnchor.constraint(equalToConstant: 360),

            hostPopup.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            hostPopup.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            hostPopup.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),

            chips.topAnchor.constraint(equalTo: hostPopup.bottomAnchor, constant: 10),
            chips.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            chips.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -12),

            dlRow.topAnchor.constraint(equalTo: chips.bottomAnchor, constant: 12),
            dlRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            dlRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),

            box.topAnchor.constraint(equalTo: dlRow.bottomAnchor, constant: 8),
            box.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            box.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            box.heightAnchor.constraint(equalToConstant: 120),
            box.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
    }

    private func chip(_ t: String, _ a: Selector) -> PillButton {
        PillButton(t, style: .secondary, hPad: 10, height: 26, font: Theme.ui(11, .medium), target: self, action: a)
    }

    // MARK: 动作
    @objc private func hostChanged() { onSelectSession?(hostPopup.indexOfSelectedItem) }
    @objc private func pickDir() { onPickDownloadDir?() }
    @objc private func openDir() { onOpenDownloadDir?() }

    /// 点浮窗以外的地方 → 收起（老仓库 closeFlyouts 同样行为）
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !card.frame.contains(p) { onClose?() } else { super.mouseDown(with: event) }
    }
    /// 只在卡片内部吃事件，卡片外的点击交给这层自己处理（不挡住底下 UI 的 hover）
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : super.hitTest(point)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !isHidden, event.keyCode == 53 { onClose?(); return true }
        return super.performKeyEquivalent(with: event)
    }

    @objc private func toolProcess() {
        guard let exec = onExec else { result.showText("未连接会话", label: "进程管理"); return }
        result.showRunning("进程管理")
        exec(Self.cmdProcess) { [weak self] out in self?.result.showProcesses(out) }
    }
    @objc private func toolNetwork() {
        guard let exec = onExec else { result.showText("未连接会话", label: "网络监控"); return }
        result.showRunning("网络监控")
        exec(Self.cmdNetwork) { [weak self] out in self?.result.showNetwork(out) }
    }
    @objc private func toolSpeed() { run("速度测试", Self.cmdSpeed) }
    @objc private func toolRoute() {
        let a = NSAlert.pix(); a.messageText = "路由追踪"; a.informativeText = "输入目标主机 / IP"
        a.addButton(withTitle: "开始"); a.addButton(withTitle: "取消")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22)); tf.stringValue = "1.1.1.1"
        a.accessoryView = tf
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let host = tf.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        run("路由追踪 \(host)", Self.cmdRoute(host))
    }

    private func run(_ label: String, _ cmd: String) {
        guard let exec = onExec else { result.showText("未连接会话", label: label); return }
        result.showRunning(label)
        exec(cmd) { [weak self] out in
            self?.result.showText(out.isEmpty ? "\(label): 无输出（远端可能缺少该命令）" : out, label: label)
        }
    }
}
