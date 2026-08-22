import AppKit

/// 服务器监控仪表盘侧栏 —— 严格照抄老仓库 shell.css 的 .sidebar/.lm-* 样式。
/// 密集布局 + 分隔线;满宽药丸渐变条(% 叠条内);进程表(内存蓝/CPU红/隔行);磁盘表。
final class MonitorSidebar: NSView {
    private let connDot = Dot(Theme.muted, size: 8)
    private let connText = NSTextField(labelWithString: "未连接")
    private let ipValue = NSTextField(labelWithString: "-")
    private let uptime = MonitorSidebar.val()
    private let load = MonitorSidebar.val()
    private let cpuBar = Bar(kind: .cpu)
    private let memBar = Bar(kind: .mem)
    private let swapBar = Bar(kind: .swap)
    private let procBody = NSStackView()
    private let diskBody = NSStackView()
    private let netTitle = MonitorSidebar.val()
    private let pingTitle = MonitorSidebar.val()
    private let netChart = NetworkChart()
    private let pingChart = LatencyChart()
    private let stack = NSStackView()
    private var copyBtn: NSButton?

    init() {
        super.init(frame: .zero)
        build()
    }

    var onCopyIP: (() -> Void)?
    var onSysInfo: (() -> Void)?
    /// 点状态行的按钮：已连接 → 手动断开；未连接 → 重新连接。
    var onToggleConnection: (() -> Void)?

    private var connBtn: PillButton!
    private var isConnected = false
    private var lastIP = ""
    // 网卡累计字节 → 速率：上一拍计数与时间戳
    private var lastRx: Double?
    private var lastTx: Double?
    private var lastNetAt: CFAbsoluteTime?
    private var netInited = false

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); build() }
    required init?(coder: NSCoder) { fatalError() }

    private static func val() -> NSTextField { let l = NSTextField(labelWithString: "-"); l.font = Theme.ui(11); l.textColor = Theme.text; return l }

    override var wantsUpdateLayer: Bool { return true }
    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = Theme.side.cgColor
    }

    private func build() {
        wantsLayer = true

        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = OverlayScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.verticalScroller = InvisibleScroller()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false   // 内容顶到最上
        doc.addSubview(stack); scroll.documentView = doc
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])

        // 头部：● 红绿灯 + 连接状态 + 断开/连接按钮（状态行本身是可操作的，不只是个标签）
        connText.font = Theme.ui(12, .semibold); connText.textColor = Theme.text
        connBtn = PillButton("连接", style: .secondary, hPad: 10, height: 22,
                             font: Theme.ui(11, .medium), target: self, action: #selector(toggleConn))
        addRow(pad(hstack([connDot, connText, spacer(), connBtn], gap: 6), 8, 10, 6, 10), border: true)
        // IP 行：复制必须贴右且留足边距，避免和侧栏右边框叠字（截图 P0）
        // 单击 IP 文本本身也要复制（用户：点 192.168.x.x 就该复制，不只点「复制」二字）
        ipValue.font = Theme.ui(12, .bold); ipValue.textColor = Theme.text
        ipValue.lineBreakMode = .byTruncatingTail
        ipValue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ipValue.isSelectable = false
        ipValue.toolTip = "单击复制 IP"
        // NSTextField(label) 默认不吃鼠标；包一层可点按钮区域
        let ipHit = NSButton(title: "", target: self, action: #selector(copyIP))
        ipHit.isBordered = false; ipHit.bezelStyle = .regularSquare
        ipHit.setButtonType(.momentaryChange)
        ipHit.toolTip = "单击复制 IP"
        ipHit.translatesAutoresizingMaskIntoConstraints = false
        let ipWrap = NSView(); ipWrap.translatesAutoresizingMaskIntoConstraints = false
        ipValue.translatesAutoresizingMaskIntoConstraints = false
        ipWrap.addSubview(ipValue); ipWrap.addSubview(ipHit)
        NSLayoutConstraint.activate([
            ipValue.leadingAnchor.constraint(equalTo: ipWrap.leadingAnchor),
            ipValue.trailingAnchor.constraint(equalTo: ipWrap.trailingAnchor),
            ipValue.topAnchor.constraint(equalTo: ipWrap.topAnchor),
            ipValue.bottomAnchor.constraint(equalTo: ipWrap.bottomAnchor),
            ipHit.leadingAnchor.constraint(equalTo: ipWrap.leadingAnchor),
            ipHit.trailingAnchor.constraint(equalTo: ipWrap.trailingAnchor),
            ipHit.topAnchor.constraint(equalTo: ipWrap.topAnchor),
            ipHit.bottomAnchor.constraint(equalTo: ipWrap.bottomAnchor),
        ])
        let ipLab = small("IP")
        let copy = PillButton("复制", style: .secondary, hPad: 8, height: 20, target: self, action: #selector(copyIP))
        copy.setContentHuggingPriority(.required, for: .horizontal)
        copy.setContentCompressionResistancePriority(.required, for: .horizontal)
        copyBtn = copy
        let ipRow = hstack([ipLab, ipWrap, spacer(), copy], gap: 6)
        // pad 默认 trailing 是 ≤，spacer 撑不开；IP 行改成 = 才能把「复制」顶到右侧并吃到右内边距
        addRow(padEqual(ipRow, 6, 10, 6, 12), border: true)
        // 系统信息按钮
        let sysBtn = PillButton("系统信息", style: .secondary, hPad: 12, height: 28, target: self, action: #selector(sysInfoTap))
        sysBtn.attributedTitle = NSAttributedString(string: "系统信息", attributes: [.foregroundColor: Theme.accent, .font: Theme.ui(12, .semibold)])
        sysBtn.rounded(Theme.radiusSm, bg: Theme.accentSoft)
        addRow(padCenter(sysBtn, 8, 8), border: false)

        // 实时监控
        secTitle("实时监控", first: true)
        let m = NSStackView(views: [line("运行", uptime), line("负载", load), cpuBar, memBar, swapBar])
        m.orientation = .vertical; m.alignment = .leading; m.spacing = 5
        addRow(pad(m, 6, 10, 8, 10), border: true)

        // 进程 TOP
        secTitle("进程 TOP")
        procBody.orientation = .vertical; procBody.alignment = .leading; procBody.spacing = 0
        addRow(pad(vstackFull([procHeader(), procBody]), 0, 0, 0, 0), border: true)

        // 网络
        secTitle("网络")
        netTitle.font = Theme.ui(10); netTitle.textColor = Theme.text; netTitle.alignment = .right
        let netHeaderRow = hstack([small("网卡流量"), spacer(), netTitle], gap: 4)
        addRow(pad(vstack([netHeaderRow, netChart], gap: 4), 6, 8, 6, 8), border: true)
        netChart.widthAnchor.constraint(equalToConstant: 184).isActive = true
        netChart.heightAnchor.constraint(equalToConstant: 50).isActive = true

        // 延迟
        secTitle("延迟")
        pingTitle.font = Theme.ui(10); pingTitle.textColor = Theme.text; pingTitle.alignment = .right
        let pingHeaderRow = hstack([small("本机网络延迟"), spacer(), pingTitle], gap: 4)
        addRow(pad(vstack([pingHeaderRow, pingChart], gap: 4), 6, 8, 6, 8), border: true)
        pingChart.widthAnchor.constraint(equalToConstant: 184).isActive = true
        pingChart.heightAnchor.constraint(equalToConstant: 50).isActive = true

        // 磁盘
        secTitle("磁盘")
        diskBody.orientation = .vertical; diskBody.alignment = .leading; diskBody.spacing = 0
        addRow(pad(vstackFull([diskHeader(), diskBody]), 0, 0, 0, 0), border: false)
    }

    // MARK: 布局辅助
    private func addRow(_ v: NSView, border: Bool) {
        v.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if border {
            let line = NSView(); line.wantsLayer = true; line.layer?.backgroundColor = Theme.border.cgColor
            line.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(line)
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
    private func secTitle(_ t: String, first: Bool = false) {
        let l = NSTextField(labelWithString: t); l.font = Theme.ui(10, .bold); l.textColor = Theme.muted
        addRow(pad(l, first ? 4 : 6, 10, 2, 10), border: false)
    }
    private func line(_ k: String, _ v: NSTextField) -> NSView {
        let lab = small(k); v.font = Theme.ui(11); v.textColor = Theme.muted
        return hstack([lab, v], gap: 6)
    }
    private func small(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.font = Theme.ui(11); l.textColor = Theme.muted; return l }
    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }
    private func linkBtn(_ t: String, _ a: Selector) -> NSButton {
        let b = NSButton(title: t, target: self, action: a); b.isBordered = false; b.bezelStyle = .regularSquare
        b.attributedTitle = NSAttributedString(string: t, attributes: [.foregroundColor: Theme.accent, .font: Theme.ui(11)])
        // 文字按钮给一点可点区域，避免贴边被裁
        b.controlSize = .small
        return b
    }
    private func hstack(_ v: [NSView], gap: CGFloat) -> NSStackView {
        let s = NSStackView(views: v); s.orientation = .horizontal; s.spacing = gap; s.alignment = .centerY
        s.distribution = .fill
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }
    private func vstack(_ v: [NSView], gap: CGFloat) -> NSStackView { let s = NSStackView(views: v); s.orientation = .vertical; s.alignment = .leading; s.spacing = gap; return s }
    private func vstackFull(_ v: [NSView]) -> NSStackView {
        let s = NSStackView(views: v); s.orientation = .vertical; s.alignment = .leading; s.spacing = 0; s.distribution = .fill
        for child in v {
            child.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        }
        return s
    }
    private func pad(_ v: NSView, _ t: CGFloat, _ l: CGFloat, _ b: CGFloat, _ r: CGFloat) -> NSView {
        let c = NSView(); c.translatesAutoresizingMaskIntoConstraints = false; v.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: c.topAnchor, constant: t), v.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: l),
            v.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -b), v.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -r),
        ]); return c
    }
    private func padCenter(_ v: NSView, _ t: CGFloat, _ b: CGFloat) -> NSView {
        let c = NSView(); c.translatesAutoresizingMaskIntoConstraints = false; v.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: c.topAnchor, constant: t), v.centerXAnchor.constraint(equalTo: c.centerXAnchor),
            v.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -b),
        ]); return c
    }
    /// 满宽内边距（trailing 用 =）：侧栏「IP · 复制」这种需要 spacer 顶右的行必须用这个
    private func padEqual(_ v: NSView, _ t: CGFloat, _ l: CGFloat, _ b: CGFloat, _ r: CGFloat) -> NSView {
        let c = NSView(); c.translatesAutoresizingMaskIntoConstraints = false; v.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: c.topAnchor, constant: t),
            v.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: l),
            v.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -b),
            v.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -r),
        ]); return c
    }

    // 进程表头/行（内存48 蓝 | CPU40 红居中 | 命令）
    private func procHeader() -> NSView {
        let h = tableRow("内存", "CPU", "命令", memC: Theme.muted, cpuC: Theme.muted, cmdC: Theme.muted, bg: Theme.bg2, bold: true)
        return h
    }
    private func procRow(_ mem: String, _ cpu: String, _ cmd: String, even: Bool) -> NSView {
        tableRow(mem, cpu, cmd, memC: Theme.accent, cpuC: Theme.err, cmdC: Theme.text, bg: even ? Theme.bg3 : Theme.side, bold: false)
    }
    private func tableRow(_ a: String, _ b: String, _ c: String, memC: NSColor, cpuC: NSColor, cmdC: NSColor, bg: NSColor, bold: Bool) -> NSView {
        let row = NSView(); row.wantsLayer = true; row.layer?.backgroundColor = bg.cgColor
        let f = Theme.mono(10)
        let aL = NSTextField(labelWithString: a); aL.font = f; aL.textColor = memC
        let bL = NSTextField(labelWithString: b); bL.font = f; bL.textColor = cpuC; bL.alignment = .center
        let cL = NSTextField(labelWithString: c); cL.font = f; cL.textColor = cmdC; cL.lineBreakMode = .byTruncatingTail
        [aL, bL, cL].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        row.addSubview(aL); row.addSubview(bL); row.addSubview(cL)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 22),
            aL.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10), aL.centerYAnchor.constraint(equalTo: row.centerYAnchor), aL.widthAnchor.constraint(equalToConstant: 52),
            bL.leadingAnchor.constraint(equalTo: aL.trailingAnchor, constant: 2), bL.centerYAnchor.constraint(equalTo: row.centerYAnchor), bL.widthAnchor.constraint(equalToConstant: 46),
            cL.leadingAnchor.constraint(equalTo: bL.trailingAnchor, constant: 6), cL.centerYAnchor.constraint(equalTo: row.centerYAnchor), cL.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -18),
        ])
        return row
    }
    private func diskHeader() -> NSView { diskRowV("路径", "可用/大小", header: true, even: false) }
	    private func diskRowV(_ p: String, _ s: String, header: Bool, even: Bool) -> NSView {
        let bg = header ? Theme.bg2 : (even ? Theme.bg3 : Theme.side)
	        let row = NSView(); row.wantsLayer = true; row.layer?.backgroundColor = bg.cgColor
	        let pL = NSTextField(labelWithString: p); pL.font = header ? Theme.ui(10) : Theme.mono(11); pL.textColor = header ? Theme.muted : Theme.text; pL.lineBreakMode = .byTruncatingTail
	        let sL = NSTextField(labelWithString: s); sL.font = header ? Theme.ui(10) : Theme.mono(11); sL.textColor = header ? Theme.muted : Theme.text; sL.alignment = .right
	        [pL, sL].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
	        row.addSubview(pL); row.addSubview(sL)
	        NSLayoutConstraint.activate([
	            row.heightAnchor.constraint(equalToConstant: header ? 22 : 24),
	            pL.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10), pL.centerYAnchor.constraint(equalTo: row.centerYAnchor), pL.widthAnchor.constraint(equalToConstant: 82),
	            sL.leadingAnchor.constraint(equalTo: pL.trailingAnchor, constant: 4), sL.centerYAnchor.constraint(equalTo: row.centerYAnchor), sL.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -18),
	        ])
	        return row
	    }
    @objc private func copyIP() {
        onCopyIP?()
        guard let btn = copyBtn else { return }
        let origTitle = btn.title
        let origColor = btn.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor ?? Theme.text
        btn.wantsLayer = true
        func setTitled(_ title: String, color: NSColor, weight: NSFont.Weight) {
            // 标题切换加 0.15s 淡入淡出，避免 ✓ 瞬间硬切。
            let t = CATransition()
            t.type = .fade
            t.duration = 0.15
            btn.layer?.add(t, forKey: "copyFeedback")
            btn.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: color, .font: Theme.ui(12, weight)])
        }
        setTitled("✓", color: Theme.c("#30d158"), weight: .semibold)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            _ = self
            setTitled(origTitle, color: origColor, weight: .regular)
        }
    }
    @objc private func sysInfoTap() { onSysInfo?() }

    // MARK: 数据更新
    func setConnected(_ on: Bool, ip: String) {
        isConnected = on
        connDot.setColor(on ? Theme.ok : Theme.err)      // 红绿灯：绿=已连接 / 红=已断开
        connText.stringValue = on ? "已连接" : "已断开"
        connBtn.title = on ? "断开" : "连接"
        connBtn.style = on ? .danger : .primary          // 触发重绘配色
        ipValue.stringValue = ip.isEmpty ? "-" : ip
        if !on {
            lastRx = nil
            lastTx = nil
            lastNetAt = nil
            netInited = false
            lastIP = ""
            netTitle.stringValue = "-"
        }
    }
    @objc private func toggleConn() { onToggleConnection?() }
    func update(_ m: [String: String]) {
        uptime.stringValue = formatUptime(m["uptime"] ?? "-")
        load.stringValue = formatLoad(m["load"] ?? "-")
        cpuBar.set(pct: dbl(m["cpu"]), size: "")
        if let mem = m["mem"] { let p = parts(mem); memBar.set(pct: p.0, size: p.1) }
        if let sw = m["swap"] { let p = parts(sw); swapBar.set(pct: p.0, size: p.1) }
        procBody.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, ln) in (m["procs"] ?? "").split(separator: ";").prefix(5).enumerated() {
            let f = ln.split(separator: "|", maxSplits: 2).map(String.init)
            if f.count == 3 { let r = procRow(f[0], f[1], f[2], even: i % 2 == 1); procBody.addArrangedSubview(r); r.widthAnchor.constraint(equalTo: procBody.widthAnchor).isActive = true }
        }
        diskBody.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, ln) in (m["disks"] ?? "").split(separator: ";").prefix(6).enumerated() {
            let f = ln.split(separator: "|").map(String.init)
            if f.count >= 3 { let r = diskRowV(f[0], "\(f[1])/\(f[2])", header: false, even: i % 2 == 1); diskBody.addArrangedSubview(r); r.widthAnchor.constraint(equalTo: diskBody.widthAnchor).isActive = true }
        }
        // 网络：iface + 实时上下行。netrx/nettx 为 /proc/net/dev 累计字节，速率 = Δbytes/Δt。
        let iface = m["netif"] ?? "-"
        let currentIP = ipValue.stringValue
        if currentIP != lastIP {
            lastIP = currentIP
            lastRx = nil
            lastTx = nil
            lastNetAt = nil
            netInited = false
        }

        let now = CFAbsoluteTimeGetCurrent()
        var rxRate: Double = 0
        var txRate: Double = 0
        var totalRate: Double = 0
        var hasRate = false

        if let rxStr = m["netrx"], let txStr = m["nettx"],
           let rxVal = Double(rxStr), let txVal = Double(txStr) {
            if netInited, let prevRx = lastRx, let prevTx = lastTx, let prevTime = lastNetAt {
                let dt = now - prevTime
                if dt > 0.2 {
                    rxRate = max(0, rxVal - prevRx) / dt
                    txRate = max(0, txVal - prevTx) / dt
                    totalRate = rxRate + txRate
                    hasRate = true
                }
            }
            lastRx = rxVal
            lastTx = txVal
            lastNetAt = now
            netInited = true
            // 与 Win 一致：↑ 上行(tx)  ↓ 下行(rx)
            if hasRate {
                netTitle.stringValue = "\(iface)  ↑ \(formatRate(txRate))  ↓ \(formatRate(rxRate))"
                netChart.push(rx: rxRate, tx: txRate)
            } else {
                netTitle.stringValue = "\(iface)  ↑ 0 B/s  ↓ 0 B/s"
                netChart.push(rx: 0, tx: 0)
            }
        } else {
            netTitle.stringValue = "\(iface)  ↑ 0 B/s  ↓ 0 B/s"
            if let v = m["netval"], let d = Double(v) {
                netChart.push(rx: d, tx: 0)
            }
        }

        // 延迟：本机→SSH 服务器（由本地 ping 填入）
        if let ms = m["pingms"], let d = Double(ms) {
            pingTitle.stringValue = String(format: "%.1f ms", d)
            pingChart.push(val: d)
        } else if _lastPingMs > 0 {
            pingTitle.stringValue = String(format: "%.1f ms", _lastPingMs)
        } else {
            pingTitle.stringValue = "-"
        }
    }
    private var _lastPingMs: Double = 0
    func pushPingMs(_ ms: Double) { _lastPingMs = ms; pingChart.push(val: ms); pingTitle.stringValue = String(format: "%.1f ms", ms) }
    private func formatRate(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 0 || bytesPerSec.isNaN || bytesPerSec.isInfinite { return "0 B/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var v = bytesPerSec
        var i = 0
        while v >= 1024 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        if i == 0 {
            return String(format: "%.0f B/s", v)
        } else if v < 10 {
            return String(format: "%.1f %@", v, units[i])
        } else {
            return String(format: "%.0f %@", v, units[i])
        }
    }
    private func dbl(_ s: String?) -> Double { Double((s ?? "").replacingOccurrences(of: "%", with: "")) ?? 0 }
    private func parts(_ s: String) -> (Double, String) { let f = s.split(separator: "|").map(String.init); return (Double(f.first ?? "0") ?? 0, f.count > 1 ? f[1] : "") }

    /// "175d18h18m" → "175d  18h  18m"
    private func formatUptime(_ raw: String) -> String {
        raw.replacingOccurrences(of: "d", with: "d  ")
            .replacingOccurrences(of: "h", with: "h  ")
            .replacingOccurrences(of: "m", with: "m  ")
            .trimmingCharacters(in: .whitespaces)
    }
    /// "0.00,0.18,0.16" → "0.00  0.18  0.16"
    private func formatLoad(_ raw: String) -> String {
        raw.replacingOccurrences(of: ",", with: "  ")
    }
}

/// 满宽药丸渐变进度条(% 叠在条内左侧) —— 照抄 .lm-bar / .lm-bar-row。
final class Bar: NSView {
    enum Kind { case cpu, mem, swap }
    private let kind: Kind
    private let track = NSView()
    private let fill = NSView()
    private let grad = CAGradientLayer()
    private let pct = NSTextField(labelWithString: "0%")
    private let sizeL = NSTextField(labelWithString: "")
    private var fillW: NSLayoutConstraint!

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false
        let labText = kind == .cpu ? "CPU" : kind == .mem ? "内存" : "交换"
        let lab = NSTextField(labelWithString: labText); lab.font = Theme.ui(11); lab.textColor = Theme.text
        lab.translatesAutoresizingMaskIntoConstraints = false
        track.wantsLayer = true; track.layer?.cornerRadius = 7; track.layer?.backgroundColor = Theme.fill.cgColor
        track.layer?.borderColor = Theme.border.cgColor; track.layer?.borderWidth = 1
        track.translatesAutoresizingMaskIntoConstraints = false
        fill.wantsLayer = true; fill.layer?.cornerRadius = 7; fill.layer?.masksToBounds = true
        fill.translatesAutoresizingMaskIntoConstraints = false
        grad.startPoint = CGPoint(x: 0, y: 0.5); grad.endPoint = CGPoint(x: 1, y: 0.5)
        fill.layer?.addSublayer(grad)
        track.addSubview(fill)
        pct.font = Theme.ui(10, .semibold); pct.textColor = Theme.text; pct.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(pct)
        sizeL.font = Theme.mono(10); sizeL.textColor = Theme.muted; sizeL.alignment = .right; sizeL.translatesAutoresizingMaskIntoConstraints = false

        addSubview(lab); addSubview(track); addSubview(sizeL)
        fillW = fill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 16),
            widthAnchor.constraint(equalToConstant: 184),
            lab.leadingAnchor.constraint(equalTo: leadingAnchor), lab.centerYAnchor.constraint(equalTo: centerYAnchor), lab.widthAnchor.constraint(equalToConstant: 34),
            track.leadingAnchor.constraint(equalTo: lab.trailingAnchor, constant: 6), track.centerYAnchor.constraint(equalTo: centerYAnchor),
            track.heightAnchor.constraint(equalToConstant: 14), sizeL.leadingAnchor.constraint(equalTo: track.trailingAnchor, constant: 6),
            track.trailingAnchor.constraint(equalTo: sizeL.leadingAnchor, constant: -6),
            sizeL.trailingAnchor.constraint(equalTo: trailingAnchor), sizeL.centerYAnchor.constraint(equalTo: centerYAnchor), sizeL.widthAnchor.constraint(equalToConstant: 60),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor), fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor), fillW,
            pct.leadingAnchor.constraint(equalTo: track.leadingAnchor, constant: 6), pct.centerYAnchor.constraint(equalTo: track.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); grad.frame = fill.bounds }

    func set(pct p: Double, size: String) {
        let c = max(0, min(100, p))
        layoutSubtreeIfNeeded()
        let trackW = track.bounds.width
        fillW.constant = trackW * CGFloat(c / 100)
        pct.stringValue = String(format: "%.0f%%", c)
        sizeL.stringValue = size
        let colors: [NSColor]
        if c >= 90 { colors = [Theme.c("#ff9f0a"), Theme.c("#ff453a")] }
        else if c >= 75 { colors = [Theme.c("#ffd60a"), Theme.c("#ff9f0a")] }
        else {
            switch kind {
            case .cpu: colors = [Theme.c("#30d158"), Theme.c("#64d2ff")]
            case .mem: colors = [Theme.c("#64d2ff"), Theme.c("#0a84ff")]
            case .swap: colors = [Theme.c("#bf5af2"), Theme.c("#5e5ce6")]
            }
        }
        grad.colors = colors.map { $0.cgColor }
        DispatchQueue.main.async { self.grad.frame = self.fill.bounds }
    }
}

/// 重叠双柱状图，带左侧Y轴刻度。用于网络监控。
final class NetworkChart: NSView {
    private var rxValues: [Double] = []
    private var txValues: [Double] = []
    private let maxCount = 60
    
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    
    func push(rx: Double, tx: Double) {
        rxValues.append(rx)
        txValues.append(tx)
        if rxValues.count > maxCount {
            rxValues.removeFirst()
            txValues.removeFirst()
        }
        needsDisplay = true
    }
    
    private func formatLabel(_ v: Double) -> String {
        if v < 1000 { return "\(Int(v))" }
        if v < 1000_000 { return String(format: "%.1fK", v / 1000).replacingOccurrences(of: ".0K", with: "K") }
        if v < 1000_000_000 { return String(format: "%.1fM", v / 1000_000).replacingOccurrences(of: ".0M", with: "M") }
        return String(format: "%.1fG", v / 1000_000_000).replacingOccurrences(of: ".0G", with: "G")
    }
    
    override func draw(_ dirty: NSRect) {
        guard !rxValues.isEmpty else { return }
        let w = bounds.width
        let h = bounds.height
        
        var mx: Double = 1
        for i in 0..<rxValues.count {
            mx = max(mx, rxValues[i], txValues[i])
        }
        mx = mx * 1.1 // Add a little headroom
        
        let steps = 3
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.mono(9),
            .foregroundColor: Theme.muted,
            .paragraphStyle: paragraphStyle
        ]
        
        let labelWidth: CGFloat = 28
        let chartX = labelWidth + 4
        let chartW = w - chartX
        
        for i in 1...steps {
            let val = mx * Double(i) / Double(steps)
            let y = h * CGFloat(i) / CGFloat(steps)
            
            let path = NSBezierPath()
            path.move(to: NSPoint(x: chartX, y: y))
            path.line(to: NSPoint(x: w, y: y))
            let dashes: [CGFloat] = [2, 2]
            path.setLineDash(dashes, count: 2, phase: 0)
            Theme.border.setStroke()
            path.stroke()
            
            let text = formatLabel(val)
            let str = NSAttributedString(string: text, attributes: attrs)
            let strSize = str.size()
            str.draw(in: NSRect(x: 0, y: y - strSize.height/2, width: labelWidth, height: strSize.height))
        }
        
        let unit = chartW / CGFloat(maxCount)
        let barW = max(unit * 0.85, 1)
        let gap = unit * 0.15
        let maxH = h * 0.95
        
        let rxColor = Theme.c("#30d158").withAlphaComponent(0.6)
        let txColor = Theme.c("#ff9f0a").withAlphaComponent(0.6)
        
        for i in 0..<rxValues.count {
            let x = chartX + CGFloat(i) * (barW + gap)
            
            let rxH = maxH * CGFloat(rxValues[i] / mx)
            let txH = maxH * CGFloat(txValues[i] / mx)
            
            if txH > 0 {
                txColor.setFill()
                NSBezierPath(rect: NSRect(x: x, y: 0, width: barW, height: max(1, txH))).fill()
            }
            if rxH > 0 {
                rxColor.setFill()
                NSBezierPath(rect: NSRect(x: x, y: 0, width: barW, height: max(1, rxH))).fill()
            }
        }
    }
}

/// 单柱状图，带左侧Y轴刻度。用于延迟监控。
final class LatencyChart: NSView {
    private var values: [Double] = []
    private let maxCount = 60
    
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    
    func push(val: Double) {
        values.append(val)
        if values.count > maxCount { values.removeFirst() }
        needsDisplay = true
    }
    
    private func formatLabel(_ v: Double) -> String {
        return String(format: "%.0f", v)
    }
    
    override func draw(_ dirty: NSRect) {
        guard !values.isEmpty else { return }
        let w = bounds.width
        let h = bounds.height
        
        var mx: Double = 10 // min 10ms
        for v in values { mx = max(mx, v) }
        mx = mx * 1.1 
        
        let steps = 3
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.mono(9),
            .foregroundColor: Theme.muted,
            .paragraphStyle: paragraphStyle
        ]
        
        let labelWidth: CGFloat = 20
        let chartX = labelWidth + 4
        let chartW = w - chartX
        
        for i in 1...steps {
            let val = mx * Double(i) / Double(steps)
            let y = h * CGFloat(i) / CGFloat(steps)
            
            let path = NSBezierPath()
            path.move(to: NSPoint(x: chartX, y: y))
            path.line(to: NSPoint(x: w, y: y))
            let dashes: [CGFloat] = [2, 2]
            path.setLineDash(dashes, count: 2, phase: 0)
            Theme.border.setStroke()
            path.stroke()
            
            let text = formatLabel(val)
            let str = NSAttributedString(string: text, attributes: attrs)
            let strSize = str.size()
            str.draw(in: NSRect(x: 0, y: y - strSize.height/2, width: labelWidth, height: strSize.height))
        }
        
        let unit = chartW / CGFloat(maxCount)
        let barW = max(unit * 0.85, 1)
        let gap = unit * 0.15
        let maxH = h * 0.95
        
        let cGreen = Theme.c("#30d158").withAlphaComponent(0.8)
        let cYellow = Theme.c("#ff9f0a").withAlphaComponent(0.8)
        let cRed = Theme.c("#ff453a").withAlphaComponent(0.8)
        
        for i in 0..<values.count {
            let x = chartX + CGFloat(i) * (barW + gap)
            let val = values[i]
            let barH = maxH * CGFloat(val / mx)
            if barH > 0 {
                let col = val < 100 ? cGreen : (val < 200 ? cYellow : cRed)
                col.setFill()
                NSBezierPath(rect: NSRect(x: x, y: 0, width: barW, height: max(1, barH))).fill()
            }
        }
    }
}

/// 迷你图（滚动窗口）：barMode=true 画柱状，false 画折线。
final class Sparkline: NSView {
    private var values: [Double] = []
    private let color: NSColor
    var barMode = false
    init(color: NSColor) { self.color = color; super.init(frame: .zero); wantsLayer = true; translatesAutoresizingMaskIntoConstraints = false }
    required init?(coder: NSCoder) { fatalError() }
    func push(_ v: Double) { values.append(v); if values.count > 60 { values.removeFirst() }; needsDisplay = true }
    override func draw(_ dirty: NSRect) {
        guard values.count > 1 else { return }
        let mn = values.min() ?? 0, mx = values.max() ?? 1
        let span = max(mx - mn, 1)
        let w = bounds.width, h = bounds.height
        if barMode {
            let unit = w / CGFloat(values.count)
            let barW = unit * 0.85
            let gap = unit * 0.15
            let maxH = h * 0.85
            let barColor = color.withAlphaComponent(0.8)
            barColor.setFill()
            for (i, v) in values.enumerated() {
                let ratio = CGFloat((v - mn) / span)
                let barH = max(maxH * ratio, 1)
                let x = CGFloat(i) * (barW + gap)
                let y: CGFloat = 0
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barW, height: barH), xRadius: 1, yRadius: 1).fill()
            }
        } else {
            let path = NSBezierPath(); path.lineWidth = 1.5
            for (i, v) in values.enumerated() {
                let x = w * CGFloat(i) / CGFloat(values.count - 1)
                let y = 3 + (h - 6) * CGFloat((v - mn) / span)
                if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
            }
            color.setStroke(); path.stroke()
        }
    }
}
