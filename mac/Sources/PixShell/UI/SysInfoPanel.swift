import AppKit

/// 系统信息页（弹窗）：exec 一段采集命令，把 KEY=value 文本解析成结构化卡片/表格展示。
final class SysInfoPanel: NSView {
    private let card = NSView()
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let grid = NSStackView()
    private var cardX: NSLayoutConstraint!
    private var cardY: NSLayoutConstraint!
    var onClose: (() -> Void)?
    var onRefresh: (() -> Void)?

    // 采集命令：busybox ash 安全（无 bashism/local/数组/base64），输出简单 KEY=value 行。
    static let command = """
    HN=`hostname 2>/dev/null || uname -n 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null`
    echo "hostname=${HN:-}"
    DISTRO=""
    if [ -f /etc/openwrt_release ]; then
      DISTRO=`awk -F"'" '/DISTRIB_DESCRIPTION/{print $2; exit}' /etc/openwrt_release 2>/dev/null`
      [ -z "$DISTRO" ] && DISTRO=`awk -F"'" '/DISTRIB_ID/{id=$2} /DISTRIB_RELEASE/{r=$2} END{if(id!="")print id" "r}' /etc/openwrt_release 2>/dev/null`
    elif [ -f /etc/os-release ]; then
      DISTRO=`awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null`
    fi
    echo "distro=${DISTRO:-}"
    echo "kernel=`uname -r 2>/dev/null`"
    echo "arch=`uname -m 2>/dev/null`"
    if [ -f /proc/uptime ]; then
      U=`cut -d. -f1 /proc/uptime 2>/dev/null`
      D=`expr $U / 86400 2>/dev/null`
      H=`expr \\( $U % 86400 \\) / 3600 2>/dev/null`
      M=`expr \\( $U % 3600 \\) / 60 2>/dev/null`
      echo "uptime=${D}d${H}h${M}m"
    else
      echo "uptime="
    fi
    if [ -f /proc/loadavg ]; then
      LA=`cat /proc/loadavg 2>/dev/null`
      set -- $LA
      echo "load=$1,$2,$3"
    else
      echo "load="
    fi
    IP=""
    if command -v ip >/dev/null 2>&1; then
      IP=`ip -o -4 addr show br-lan 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}'`
      if [ -z "$IP" ]; then
        IP=`ip -o -4 addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | grep -v '^127\\.' | grep -E '^10\\.|^172\\.(1[6-9]|2[0-9]|3[0-1])\\.|^192\\.168\\.' | head -n1`
      fi
    fi
    echo "ip=${IP:-}"
    CPU_MODEL=`awk -F: '/^model name/{gsub(/^[ \\t]+/,"",$2);print $2;exit} /^Hardware/{gsub(/^[ \\t]+/,"",$2);print $2;exit} /^cpu model/{gsub(/^[ \\t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null`
    echo "cpu_model=${CPU_MODEL:-}"
    CPU_CORES=`grep -c '^processor' /proc/cpuinfo 2>/dev/null`
    if [ -z "$CPU_CORES" ] || [ "$CPU_CORES" = "0" ]; then CPU_CORES=`nproc 2>/dev/null`; fi
    echo "cpu_cores=${CPU_CORES:-}"
    CPU_MHZ=`awk -F: '/^cpu MHz/{gsub(/^[ \\t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null`
    echo "cpu_mhz=${CPU_MHZ:-}"
    CPU_CACHE=`awk -F: '/^cache size/{gsub(/^[ \\t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null`
    echo "cpu_cache=${CPU_CACHE:-}"
    CPU_BOGO=`awk -F: '/^[Bb]ogo[Mm][Ii][Pp][Ss]/{gsub(/^[ \\t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null`
    echo "cpu_bogomips=${CPU_BOGO:-}"
    S1=`grep '^cpu ' /proc/stat 2>/dev/null`
    sleep 1
    S2=`grep '^cpu ' /proc/stat 2>/dev/null`
    if [ -n "$S1" ] && [ -n "$S2" ]; then
      set -- $S1
      U1=$2; N1=$3; SY1=$4; ID1=$5; IO1=$6; IRQ1=$7; SIRQ1=$8; ST1=$9
      set -- $S2
      U2=$2; N2=$3; SY2=$4; ID2=$5; IO2=$6; IRQ2=$7; SIRQ2=$8; ST2=$9
      awk -v u1=$U1 -v n1=$N1 -v s1=$SY1 -v i1=$ID1 -v w1=$IO1 -v q1=$IRQ1 -v r1=$SIRQ1 -v t1=$ST1 \\
          -v u2=$U2 -v n2=$N2 -v s2=$SY2 -v i2=$ID2 -v w2=$IO2 -v q2=$IRQ2 -v r2=$SIRQ2 -v t2=$ST2 '
      BEGIN{
        du=u2-u1; dn=n2-n1; ds=s2-s1; di=i2-i1; dw=w2-w1; dq=q2-q1; dr=r2-r1; dst=t2-t1
        tot = du+dn+ds+di+dw+dq+dr+dst
        if(tot<=0) tot=1
        printf "cpu_busy=%.1f\\n", (tot-di)*100/tot
        printf "cpu_user=%.1f\\n", (du+dn)*100/tot
        printf "cpu_system=%.1f\\n", ds*100/tot
        printf "cpu_idle=%.1f\\n", di*100/tot
        printf "cpu_iowait=%.1f\\n", dw*100/tot
      }'
    else
      echo "cpu_busy="
      echo "cpu_user="
      echo "cpu_system="
      echo "cpu_idle="
      echo "cpu_iowait="
    fi
    awk '
      /^MemTotal:/{t=$2+0}
      /^MemAvailable:/{a=$2+0}
      /^MemFree:/{f=$2+0}
      /^Buffers:/{b=$2+0}
      /^Cached:/{c=$2+0}
      /^SReclaimable:/{s=$2+0}
      /^SwapTotal:/{st=$2+0}
      /^SwapFree:/{sf=$2+0}
      END{
        if(t>0){
          if(a<=0) a=f+b+c+s
          u=t-a; if(u<0) u=0
          pct=int(u*100/t+0.5)
          printf "mem_pct=%d\\n", pct
          printf "mem_used_mb=%d\\n", int(u/1024)
          printf "mem_total_mb=%d\\n", int(t/1024)
        } else {
          print "mem_pct="
          print "mem_used_mb="
          print "mem_total_mb="
        }
        if(st>0){
          su=st-sf; if(su<0) su=0
          sp=int(su*100/st+0.5)
          printf "swap_pct=%d\\n", sp
          printf "swap_used_mb=%d\\n", int(su/1024)
          printf "swap_total_mb=%d\\n", int(st/1024)
        } else {
          print "swap_pct=0"
          print "swap_used_mb=0"
          print "swap_total_mb=0"
        }
      }
    ' /proc/meminfo 2>/dev/null
    for NDIR in /sys/class/net/*; do
      [ -d "$NDIR" ] || continue
      NAME=`basename "$NDIR"`
      [ "$NAME" = "lo" ] && continue
      MAC=`cat "$NDIR/address" 2>/dev/null`
      RXTX=`awk -v want="$NAME:" 'index($1,want)==1{print $2" "$10}' /proc/net/dev 2>/dev/null`
      set -- $RXTX
      RX=$1; TX=$2
      IFIP=""
      if command -v ip >/dev/null 2>&1; then
        IFIP=`ip -o -4 addr show "$NAME" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}'`
      fi
      printf 'net_row=%s\\t%s\\t%s\\t%s\\t%s\\n' "$NAME" "${IFIP:-}" "${MAC:-}" "${RX:-0}" "${TX:-0}"
    done
    df -h 2>/dev/null | awk 'NR>1 {
      fs=$1
      if(fs ~ /^(tmpfs|devtmpfs|sysfs)$/) next
      if($5 ~ /%$/){
        size=$2; used=$3; avail=$4; pct=$5; mnt=$6
        for(i=7;i<=NF;i++) mnt=mnt" "$i
      } else next
      print mnt"|"size"|"used"|"avail"|"pct"|"fs
    }' | awk -F'|' '!seen[$1]++ {printf "disk_row=%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n", $1,$2,$3,$4,$5,$6}'
    """

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); build() }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        wantsLayer = true; layer?.backgroundColor = NSColor(white: 0, alpha: 0.35).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        card.rounded(Theme.radiusLg, bg: Theme.bg, border: Theme.borderStrong)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        // 原来这里画了一组红/黄/绿假红绿灯，点了没任何反应；右侧已有真正的「关闭」按钮，去掉假的。
        let title = NSTextField(labelWithString: "系统信息"); title.font = Theme.ui(15, .semibold); title.textColor = Theme.text
        let refresh = PillButton("刷新", style: .secondary, hPad: 12, target: self, action: #selector(refreshAction))
        let close = PillButton("关闭", style: .secondary, hPad: 12, target: self, action: #selector(closeAction))
        let head = NSStackView(views: [title, NSView(), refresh, close]); head.spacing = 12; head.alignment = .centerY
        head.translatesAutoresizingMaskIntoConstraints = false
        head.addGestureRecognizer(HeaderPanGesture(target: self, action: #selector(dragCard(_:))))

        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        doc.translatesAutoresizingMaskIntoConstraints = false
        grid.orientation = .vertical; grid.alignment = .leading; grid.spacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(grid)
        scroll.documentView = doc

        card.addSubview(head); card.addSubview(scroll)
        cardX = card.centerXAnchor.constraint(equalTo: centerXAnchor)
        cardY = card.topAnchor.constraint(equalTo: topAnchor, constant: 40)
        NSLayoutConstraint.activate([
            cardX, cardY,
            card.widthAnchor.constraint(equalToConstant: 700),
            card.heightAnchor.constraint(equalToConstant: 600),
            head.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            head.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            head.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            doc.topAnchor.constraint(equalTo: scroll.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            grid.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            grid.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 4),
            grid.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -4),
            grid.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -4),
        ])

        showPlaceholder("采集中…")
    }
    @objc private func closeAction() { onClose?() }
    @objc private func refreshAction() { onRefresh?() }
    // 点遮罩(卡片外)关闭
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !card.frame.contains(p) { onClose?() } else { super.mouseDown(with: event) }
    }
    // Esc 关闭
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !isHidden, event.keyCode == 53 { onClose?(); return true }
        return super.performKeyEquivalent(with: event)
    }
    @objc private func dragCard(_ g: NSPanGestureRecognizer) {
        let t = g.translation(in: self)
        cardX.constant += t.x; cardY.constant += t.y
        g.setTranslation(.zero, in: self)
    }

    // MARK: - 数据入口

    func show(_ text: String) {
        isHidden = false
        clearGrid()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "采集中…" {
            showPlaceholder("采集中…")
            return
        }
        let info = SysInfoParser.parse(text)
        buildCards(info)
    }

    private func clearGrid() { grid.arrangedSubviews.forEach { $0.removeFromSuperview() } }

    private func showPlaceholder(_ text: String) {
        clearGrid()
        let l = NSTextField(labelWithString: text)
        l.font = Theme.ui(13); l.textColor = Theme.muted
        grid.addArrangedSubview(l)
    }

    // MARK: - 卡片构建

    private func buildCards(_ info: SysInfoParser.SysInfo) {
        addFullWidth(basicCard(info))
        addFullWidth(cpuCard(info))
        addFullWidth(memCard(info))
        if !info.net.isEmpty { addFullWidth(netCard(info.net)) }
        if !info.disks.isEmpty { addFullWidth(diskCard(info.disks)) }
    }

    /// 必须**先加入 grid**（建立共同父视图）再激活等宽约束；
    /// 否则 NSLayoutConstraint 会因"没有共同祖先"抛异常直接崩溃。
    private func addFullWidth(_ v: NSView) {
        grid.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
    }

    private func cardTitle(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text); l.font = Theme.ui(13, .bold); l.textColor = Theme.text
        return l
    }
    private func labelRow(_ k: String, _ v: String) -> NSView {
        let kl = NSTextField(labelWithString: k); kl.font = Theme.ui(11.5); kl.textColor = Theme.muted
        kl.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let vl = NSTextField(labelWithString: v); vl.font = Theme.mono(11.5); vl.textColor = Theme.text
        vl.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [kl, vl]); row.orientation = .horizontal; row.alignment = .top; row.spacing = 8
        return row
    }
    private func str(_ v: String?) -> String { v?.isEmpty == false ? v! : "-" }

    private func card(_ views: [NSView]) -> NSView {
        let c = CardView()
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: c.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -12),
        ])
        views.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return c
    }

    private func basicCard(_ info: SysInfoParser.SysInfo) -> NSView {
        card([
            cardTitle("基本"),
            labelRow("主机名", str(info.hostname)),
            labelRow("发行版", str(info.distro)),
            labelRow("内核", str(info.kernel)),
            labelRow("架构", str(info.arch)),
            labelRow("运行时长", str(info.uptime)),
            labelRow("负载", str(info.load)),
            labelRow("主 IP", str(info.ip)),
        ])
    }

    private func cpuCard(_ info: SysInfoParser.SysInfo) -> NSView {
        let cpu = info.cpu
        var rows: [NSView] = [
            cardTitle("CPU"),
            labelRow("型号", str(cpu.model)),
            labelRow("核心数", cpu.cores.map(String.init) ?? "-"),
        ]
        if let mhz = cpu.mhz { rows.append(labelRow("频率", "\(mhz) MHz")) }
        if let cache = cpu.cache { rows.append(labelRow("缓存", cache)) }
        if let bogo = cpu.bogomips { rows.append(labelRow("BogoMIPS", bogo)) }
        if let busy = cpu.busyPct {
            rows.append(PillBar(pct: busy, kind: .cpu))
            let detail = [
                cpu.userPct.map { "用户 \(fmt1($0))%" },
                cpu.systemPct.map { "系统 \(fmt1($0))%" },
                cpu.idlePct.map { "空闲 \(fmt1($0))%" },
                cpu.iowaitPct.map { "等待 \(fmt1($0))%" },
            ].compactMap { $0 }.joined(separator: "  ")
            if !detail.isEmpty {
                let dl = NSTextField(labelWithString: detail); dl.font = Theme.mono(10.5); dl.textColor = Theme.muted
                rows.append(dl)
            }
        }
        return card(rows)
    }

    private func memCard(_ info: SysInfoParser.SysInfo) -> NSView {
        var rows: [NSView] = [cardTitle("内存 · 交换")]
        if let pct = info.memPct {
            rows.append(PillBar(pct: Double(pct), kind: .mem))
            rows.append(labelRow("内存", "\(info.memUsedMB ?? 0) / \(info.memTotalMB ?? 0) MB"))
        } else {
            rows.append(labelRow("内存", "-"))
        }
        if let spct = info.swapPct {
            rows.append(PillBar(pct: Double(spct), kind: .swap))
            rows.append(labelRow("交换", "\(info.swapUsedMB ?? 0) / \(info.swapTotalMB ?? 0) MB"))
        } else {
            rows.append(labelRow("交换", "-"))
        }
        return card(rows)
    }

    private func netCard(_ rows: [SysInfoParser.NetRow]) -> NSView {
        var views: [NSView] = [cardTitle("网卡")]
        views.append(tableHeader(["网卡", "IP", "MAC", "收/发"], widths: [70, 110, 130, 140]))
        for (i, r) in rows.enumerated() {
            let rx = SysInfoParser.formatBytes(r.rxBytes)
            let tx = SysInfoParser.formatBytes(r.txBytes)
            views.append(tableRow([r.name, str(r.ip), str(r.mac), "\(rx) / \(tx)"], widths: [70, 110, 130, 140], even: i % 2 == 1))
        }
        return card(views)
    }

    private func diskCard(_ rows: [SysInfoParser.DiskRow]) -> NSView {
        var views: [NSView] = [cardTitle("磁盘")]
        views.append(tableHeader(["挂载点", "容量", "已用", "可用", "使用率"], widths: [140, 70, 70, 70, 110]))
        for (i, r) in rows.enumerated() {
            let rowViews: [String] = [r.mount, str(r.size), str(r.used), str(r.avail)]
            let row = tableRow(rowViews, widths: [140, 70, 70, 70], even: i % 2 == 1)
            let bar = PillBar(pct: Double(r.pct ?? 0), kind: .disk)
            bar.widthAnchor.constraint(equalToConstant: 110).isActive = true
            row.addArrangedSubview(bar)
            views.append(row)
        }
        return card(views)
    }

    // MARK: - 小表格

    private func tableHeader(_ cols: [String], widths: [CGFloat]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
        row.wantsLayer = true; row.layer?.backgroundColor = Theme.bg3.cgColor
        for (i, t) in cols.enumerated() {
            let l = NSTextField(labelWithString: t); l.font = Theme.ui(10.5, .semibold); l.textColor = Theme.muted
            l.widthAnchor.constraint(equalToConstant: widths[i]).isActive = true
            row.addArrangedSubview(l)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor, constant: -4),
            row.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -4),
        ])
        return wrap
    }

    @discardableResult
    private func tableRow(_ cols: [String], widths: [CGFloat], even: Bool) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
        row.wantsLayer = true; row.layer?.backgroundColor = (even ? Theme.bg3 : Theme.bg2).cgColor
        for (i, t) in cols.enumerated() {
            let l = NSTextField(labelWithString: t); l.font = Theme.mono(10.5); l.textColor = Theme.text
            l.lineBreakMode = .byTruncatingTail
            l.widthAnchor.constraint(equalToConstant: i < widths.count ? widths[i] : 80).isActive = true
            row.addArrangedSubview(l)
        }
        return row
    }
}

// MARK: - 药丸进度条（局部实现，照抄 MonitorSidebar.Bar 的观感，不改那个文件）

private final class PillBar: NSView {
    enum Kind { case cpu, mem, swap, disk }
    private let track = NSView()
    private let fillV = NSView()
    private let grad = CAGradientLayer()
    private let pctLabel = NSTextField(labelWithString: "0%")
    private var fillW: NSLayoutConstraint!

    init(pct: Double, kind: Kind) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 14).isActive = true
        track.wantsLayer = true; track.layer?.cornerRadius = 7; track.layer?.backgroundColor = Theme.fill.cgColor
        track.layer?.borderColor = Theme.border.cgColor; track.layer?.borderWidth = 1
        track.translatesAutoresizingMaskIntoConstraints = false
        fillV.wantsLayer = true; fillV.layer?.cornerRadius = 7; fillV.layer?.masksToBounds = true
        fillV.translatesAutoresizingMaskIntoConstraints = false
        grad.startPoint = CGPoint(x: 0, y: 0.5); grad.endPoint = CGPoint(x: 1, y: 0.5)
        fillV.layer?.addSublayer(grad)
        track.addSubview(fillV)
        pctLabel.font = Theme.ui(9.5, .semibold); pctLabel.textColor = Theme.text
        pctLabel.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(pctLabel)
        addSubview(track)
        fillW = fillV.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            track.topAnchor.constraint(equalTo: topAnchor),
            track.bottomAnchor.constraint(equalTo: bottomAnchor),
            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            fillV.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fillV.topAnchor.constraint(equalTo: track.topAnchor),
            fillV.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fillW,
            pctLabel.leadingAnchor.constraint(equalTo: track.leadingAnchor, constant: 6),
            pctLabel.centerYAnchor.constraint(equalTo: track.centerYAnchor),
        ])
        set(pct: pct, kind: kind)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); grad.frame = fillV.bounds; refreshFill() }

    private var lastPct: CGFloat = 0
    private func refreshFill() {
        let trackW = track.bounds.width
        guard trackW > 0 else { return }
        fillW.constant = trackW * lastPct
    }

    func set(pct: Double, kind: Kind) {
        let c = max(0, min(100, pct))
        lastPct = CGFloat(c / 100)
        pctLabel.stringValue = String(format: "%.0f%%", c)
        let colors: [NSColor]
        if c >= 90 { colors = [Theme.c("#ff9f0a"), Theme.c("#ff453a")] }
        else if c >= 75 { colors = [Theme.c("#ffd60a"), Theme.c("#ff9f0a")] }
        else {
            switch kind {
            case .cpu: colors = [Theme.c("#30d158"), Theme.c("#64d2ff")]
            case .mem: colors = [Theme.c("#64d2ff"), Theme.c("#0a84ff")]
            case .swap: colors = [Theme.c("#bf5af2"), Theme.c("#5e5ce6")]
            case .disk: colors = [Theme.c("#30d158"), Theme.c("#0a84ff")]
            }
        }
        grad.colors = colors.map { $0.cgColor }
        needsLayout = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshFill()
            self.grad.frame = self.fillV.bounds
        }
    }
}

private func fmt1(_ d: Double) -> String { String(format: "%.1f", d) }
