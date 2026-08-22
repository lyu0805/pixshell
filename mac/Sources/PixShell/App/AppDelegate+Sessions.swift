import AppKit
import SwiftTerm
@preconcurrency import NIOSSH

// 多会话开/切/关 + 顶栏 tab + SSH/终端 delegate。
extension AppDelegate {
    // MARK: - 会话（顶栏多 tab）
    @objc func connectSelected() {
        guard let tv = tableView, tv.selectedRow >= 0, tv.selectedRow < store.hosts.count else { connMgr?.show(); return }
        openSession(to: store.hosts[tv.selectedRow])
    }

    // 打开会话：解析凭据（env → 钥匙串 → 仅私钥直连 → 弹框密码），再真正建立连接。
    // key-only（配置了 keyPath、无密码）不得强制弹密码；空密码 + 无私钥才是 password-auth 闸门。
    func openSession(to host: Host) {
        // 本机终端：应用内 LocalSession，不弹外部 Terminal、不经 SSH/密码。
        if host.isLocal { openLocalTerminal(host: host); return }
        // RDP 类型不走 SSH：直接拉起系统远程桌面客户端（对齐老仓库 app.js connectionType===200 分支）。
        if host.isRdp { launchRdp(host); return }
        // Web 连接：和 SSH 同一入口（侧栏/连接管理器/快速连接），开应用内 Web 终端标签。
        if host.isWebSSH { openWebHostSession(host: host); return }
        if let envPass = ProcessInfo.processInfo.environment["PIXSHELL_PASS"], !envPass.isEmpty {
            beginSession(to: host, password: envPass); return
        }
        if let stored = Keychain.password(for: host.id), !stored.isEmpty {
            beginSession(to: host, password: stored); return
        }
        // 仅私钥：后端 SSHUserAuthDelegate / OpenSSH -i 已支持 key-first，UI 不再拦。
        if !host.keyPath.isEmpty {
            beginSession(to: host, password: ""); return
        }
        // 密码认证路径：无 key、无已存密码 → 留空直接连。若连通但认证失败，由 didCloseWith 触发 promptRetryPassword。
        beginSession(to: host, password: "")
    }

    /// Web 主机：开应用内 WKWebView 标签。
    /// - 外部 URL（webUrl / host 为 http(s)，如 noVNC `…/vnc`）→ 直接 Navigate，不经本地桥、不弹 SSH 密码
    /// - 否则 → 本地桥 `/webssh?host_id=`；先确保密码/私钥可用，页面再 connect 建底层 SSH
    /// **禁止** NSWorkspace 外开系统浏览器。
    func openWebHostSession(host: Host) {
        // 外部 Web/VNC：无 SSH 凭据闸门，直接开页
        if host.isExternalWeb {
            openWebHostSessionReady(host: host, externalURL: host.resolvedWebURL)
            return
        }
        // 本地桥 WebSSH：凭据闸门对齐 SSH
        if let envPass = ProcessInfo.processInfo.environment["PIXSHELL_PASS"], !envPass.isEmpty {
            Keychain.setPassword(envPass, for: host.id, label: host.host.isEmpty ? host.name : host.host)
            openWebHostSessionReady(host: host, externalURL: nil)
            return
        }
        if let stored = Keychain.password(for: host.id), !stored.isEmpty {
            openWebHostSessionReady(host: host, externalURL: nil)
            return
        }
        if !host.keyPath.isEmpty {
            openWebHostSessionReady(host: host, externalURL: nil)
            return
        }
        promptPassword(for: host, prefill: "") { [weak self] pw, remember in
            guard let self = self, let pw = pw, !pw.isEmpty else { return }
            // 桥 connect 只读 Keychain；本次即使不「记住」也要写一次，否则页面 connect 401
            Keychain.setPassword(pw, for: host.id, label: host.host.isEmpty ? host.name : host.host)
            self.openWebHostSessionReady(host: host, externalURL: nil)
        }
    }

    /// 真正开 Web 标签。`externalURL != nil` 时直接加载该页（允许同站跳转）；否则走本地桥。
    private func openWebHostSessionReady(host: Host, externalURL: URL?) {
        store.noteRecent(host.id)

        if let external = externalURL {
            let dummy = TerminalView(frame: .zero)
            dummy.terminalDelegate = self
            let web = WebSSHView(frame: termContainer.bounds)
            // 外部页：放行同 host 导航（登录跳转 / noVNC 资源），仍禁止外开系统浏览器
            web.allowExternalHosts = true
            web.allowedHost = external.host
            let sess = TermSession(host: host, termView: dummy, webSSHView: web)
            sess.title = host.display
            sess.connected = true
            sessions.append(sess)
            selectSession(sessions.count - 1)
            web.load(url: external)
            setStatus("已打开 Web · \(host.subtitle)")
            Log.info("Web 外部页 host_id=\(host.id) \(external.absoluteString)", "webssh")
            return
        }

        if agentBridge == nil || agentBridge?.isRunning != true {
            startAgentBridge()
        }
        guard let bridge = agentBridge else {
            setStatus("本地桥未启动，无法打开 Web 连接")
            return
        }
        func tryOpen(attempt: Int) {
            guard bridge.isRunning, let url = bridge.webSSHURL(hostId: host.id) else {
                if attempt >= 8 {
                    setStatus("本地桥未就绪，稍后重试 Web 连接")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    tryOpen(attempt: attempt + 1)
                }
                return
            }
            let dummy = TerminalView(frame: .zero)
            dummy.terminalDelegate = self
            let web = WebSSHView(frame: termContainer.bounds)
            // 本地桥：仅回环
            web.allowExternalHosts = false
            let sess = TermSession(host: host, termView: dummy, webSSHView: web)
            sess.title = host.display
            sess.connected = true   // Web 标签本身已挂上；底层 SSH 由页面 host_id 拉起
            sessions.append(sess)
            selectSession(sessions.count - 1)
            web.load(url: url)
            setStatus("已连接 Web · \(host.subtitle)")
            Log.info("Web 连接 host_id=\(host.id) \(host.subtitle)", "webssh")
        }
        tryOpen(attempt: 0)
    }

    /// RDP 主机：拉起 macOS 系统远程桌面（rdp:// 由「Microsoft 远程桌面」注册处理）。
    /// 对齐老仓库 darwin 分支 `rdp://full address=s:host:port`；端口默认 3389（主机端口是 22 时兜底）。
    func launchRdp(_ host: Host) {
        store.noteRecent(host.id)   // 也记入历史，快速连接落地页可见
        let port = (host.port == 22 || host.port == 0) ? 3389 : host.port
        let addr = "full address=s:\(host.host):\(port)"
        let query = addr.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? addr
        guard let url = URL(string: "rdp://\(query)") else {
            setStatus("RDP 地址无效：\(host.host)"); return
        }
        Log.info("拉起 RDP \(host.host):\(port)", "session")
        NSWorkspace.shared.open(url)
        setStatus("已启动 RDP：\(host.host):\(port)")
    }

    // 真正建立 SSH 连接并开一个终端 tab。
    func beginSession(to host: Host, password: String) {
        if host.isLocal { openLocalTerminal(host: host); return }
        let tv = PixTerminalView(frame: termContainer.bounds)
        tv.terminalDelegate = self
        TermTheme.apply(to: tv, dark: darkTheme)
        tv.menu = buildTerminalMenu()                 // 右键：复制/粘贴/清屏/设置背景/字号
        if !termBgOverride.isEmpty { tv.nativeBackgroundColor = TermTheme.ns(termBgOverride) }
        let sess = TermSession(host: host, termView: tv)
        sess.controller = TermSessionController(sess: sess, app: self)
        wireCursorReposition(tv, for: sess)
        // 密码要在 selectSession 之前赋值：selectSession 会触发 SFTP 面板用它连接。
        sess.password = password
        Log.info("打开会话 \(host.subtitle)", "session")
        store.noteRecent(host.id)   // 记入历史（供快速连接落地页）
        sessions.append(sess); selectSession(sessions.count - 1)
        startSSH(for: sess, password: password)
    }

    /// 单击移动 shell 光标：把列差换算成等量的左/右方向键转义序列发给远端。
    /// readline 收到方向键就挪光标 —— 与手敲 ←→ 完全同构，对 shell 零侵入。
    /// DECCKM 应用光标模式下转义序列不同（\eOA/\eOD），按终端当前模式选。
    private func wireCursorReposition(_ tv: PixTerminalView, for sess: TermSession) {
        tv.onCursorReposition = { [weak sess, weak tv] delta in
            guard let sess, let tv, let ssh = sess.ssh, sess.connected, delta != 0 else { return }
            let appCursor = tv.getTerminal().applicationCursor
            let seq = delta < 0 ? (appCursor ? "\u{1b}OD" : "\u{1b}[D")
                                : (appCursor ? "\u{1b}OC" : "\u{1b}[C")
            var bytes: [UInt8] = []
            bytes.reserveCapacity(abs(delta) * 3)
            for _ in 0..<abs(delta) { bytes.append(contentsOf: seq.utf8) }
            ssh.send(bytes)
        }
    }

    /// 快速连接 logo / 菜单：在软件内新开本机终端标签（forkpty 本地 shell）。
    /// **禁止** NSWorkspace 拉起 Terminal.app。
    func openLocalTerminal(host: Host? = nil) {
        let h = host ?? Host.localTerminal()
        let tv = PixTerminalView(frame: termContainer.bounds)
        tv.terminalDelegate = self
        TermTheme.apply(to: tv, dark: darkTheme)
        tv.menu = buildTerminalMenu()
        if !termBgOverride.isEmpty { tv.nativeBackgroundColor = TermTheme.ns(termBgOverride) }
        let sess = TermSession(host: h, termView: tv)
        sess.controller = TermSessionController(sess: sess, app: self)
        wireCursorReposition(tv, for: sess)
        sess.password = nil
        Log.info("打开本机终端 \(h.display)", "session")
        // 本机会话不记入「远程历史」列表，避免污染快速连接卡片。
        sessions.append(sess); selectSession(sessions.count - 1)
        startLocalShell(for: sess)
    }

    /// 在已有标签上启动本机 shell（LocalSession）。
    func startLocalShell(for sess: TermSession) {
        clearPendingOutput(for: sess)
        if let old = sess.ssh {
            sess.ssh = nil
            old.close()
        }
        sess.connected = false
        sess.shellOpened = false
        sess.closeHandled = false
        setStatus("启动本机终端 …")
        let t = sess.termView.getTerminal()
        // 本机启动几乎瞬时，仍走覆盖层保持 UX 一致。
        showConnectOverlay(for: sess.host)
        let s = LocalSession()
        s.delegate = sess.controller
        sess.ssh = s
        // creds 对 LocalSession 无用，填占位即可。
        let creds = SSHCredentials(host: "localhost", port: 0, username: sess.host.username)
        s.connectAndOpenShell(creds, term: "xterm-256color", cols: t.cols, rows: t.rows)
    }

    /// 在**已有会话**上建立 SSH 连接（不新开标签）。
    /// beginSession（新开标签）和 reconnectCurrent（原地重连）共用这段，
    /// 保证重连走的是同一套代理/私钥/覆盖层逻辑。

    /// 在**已有会话**上建立 SSH 连接（不新开标签）。
    /// beginSession（新开标签）和 reconnectCurrent（原地重连）共用这段，
    /// 保证重连走的是同一套代理/私钥/覆盖层逻辑。
    func startSSH(for sess: TermSession, password: String, forceOpenSSH: Bool = false) {
        if sess.host.isLocal {
            startLocalShell(for: sess)
            return
        }
        let host = sess.host
        sess.password = password
        // 先拆旧传输，避免 EventLoopGroup / 旧 pty 泄漏，也防止迟到回调串台。
        clearPendingOutput(for: sess)
        if let old = sess.ssh {
            sess.ssh = nil
            old.close()
        }
        // 复位一次性状态：这是一条全新的连接，别把上一条的"曾经连上过/已处理关闭"带过来。
        // 注意：triedOpenSSHFallback 故意不复位——同一次会话生命周期内只回落一次。
        sess.connected = false
        sess.shellOpened = false
        sess.closeHandled = false
        setStatus("连接 \(host.subtitle) …")
        let t = sess.termView.getTerminal()
        // 连接过程用覆盖层动画表达，不再往终端里 feed「连接中…」——终端只留远端真实输出。
        showConnectOverlay(for: host)
        // 代理：主机上配置了 proxyId 就带上（老仓库 h.proxyId → settings.proxyList 匹配）
        let proxy = host.proxyId.isEmpty ? nil : proxyStore.list().first { $0.id == host.proxyId }
        if let p = proxy { Log.info("经代理连接 \(p.type.rawValue) \(p.host):\(p.port)", "proxy") }
        let creds = SSHCredentials(host: host.host, port: host.port, username: host.username,
                                   password: password, keyPath: host.keyPath.isEmpty ? nil : host.keyPath,
                                   proxy: proxy)
        // 默认仍走 NIO（局域网体感更好）；但 NIO 无法加载 RSA/DSA/加密私钥。
        // 预检已配置私钥：加载失败时立即交给系统 OpenSSH，避免先等待 NIO 握手超时
        // 约两分钟后才回落。Ed25519/ECDSA 等 NIO 支持的私钥仍保留原快速路径。
        let keyRequiresOpenSSH = !host.keyPath.isEmpty
            && SSHPrivateKeyLoader.load(path: host.keyPath) == nil
        // forceOpenSSH / 已回落标记 / 私钥不兼容时直接 OpenSSH，避免 NIO 空转。
        let useOpenSSH = forceOpenSSH || sess.triedOpenSSHFallback || keyRequiresOpenSSH
        let s: SSHSession = useOpenSSH ? OpenSSHSession() : NIOSSHSession()
        Log.info("SSH 引擎=\(useOpenSSH ? "OpenSSH" : "NIO") \(host.subtitle)", "ssh")
        s.delegate = sess.controller; sess.ssh = s
        s.connectAndOpenShell(creds, term: "xterm-256color", cols: t.cols, rows: t.rows)
    }

    /// 原地重连当前标签：**复用同一个标签和同一个终端视图**。
    /// 之前是 closeSession + beginSession —— 那会关掉旧标签再 append 一个新的，
    /// 于是"断开→重连"每次都多出一个标签页，历史输出也丢了。
    func reconnectCurrent() {
        guard sessions.indices.contains(current) else { return }
        let sess = sessions[current]
        // 应用内 Web 终端：只 reload WKWebView，不建 SSH
        if sess.isWebSSH {
            sess.webSSHView?.reload()
            setStatus("Web 终端已刷新")
            return
        }
        // 先摘掉 ssh 引用再关：旧连接回调被控制器的 s === sess.ssh 身份校验挡掉，
        // 不会把"主动断开"当成异常关闭去刷终端/弹框。
        let old = sess.ssh
        clearPendingOutput(for: sess)
        sess.ssh = nil
        old?.close()
        // 用户显式重连 = 新生命周期：允许再走 NIO，也允许再回落一次 OpenSSH。
        // 否则首次局域网失败后 triedOpenSSHFallback/closeHandled 会把后续重连钉死。
        sess.triedOpenSSHFallback = false
        sess.closeHandled = false
        sess.connected = false
        sess.shellOpened = false

        if sess.host.isLocal {
            startLocalShell(for: sess)
            rebuildTabs()
            return
        }

        let pass = sess.password ?? Keychain.password(for: sess.host.id) ?? ""
        startSSH(for: sess, password: pass)
        rebuildTabs()
    }

    // 密码输入弹框（sheet）：安全输入 + 记住勾选。取消回调 (nil,false)。
    func promptPassword(for host: Host, prefill: String, completion: @escaping (String?, Bool) -> Void) {
        let alert = NSAlert.pix()
        alert.messageText = "连接 \(host.display)"
        alert.informativeText = "请输入 \(host.subtitle) 的密码"
        alert.addButton(withTitle: "连接")
        alert.addButton(withTitle: "取消")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = prefill
        let remember = NSButton(checkboxWithTitle: "记住密码（本地加密存储）", target: nil, action: nil)
        remember.state = .on
        let stack = NSStackView(views: [field, remember])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 58)
        alert.accessoryView = stack
        alert.beginSheetModal(for: window) { resp in
            if resp == .alertFirstButtonReturn { completion(field.stringValue, remember.state == .on) }
            else { completion(nil, false) }
        }
        DispatchQueue.main.async { alert.window.makeFirstResponder(field) }
    }

    /// 首次连接成功后识别远端系统，写回 host.osId —— 主机卡片图标随之变成该系统的标志
    /// （对齐老仓库：连过一次就认得这台机器是什么系统，不用用户手填）。
    /// 已经有 osId 的主机不覆盖：用户可能在表单里手动指定过。
    func detectRemoteOS(for sess: TermSession) {
        // 本机会话固定 osId，不跑远端探测。
        guard !sess.host.isLocal else { return }
        guard sess.host.osId.isEmpty, let ssh = sess.ssh else { return }
        // /etc/os-release 的 ID 最准（ubuntu/debian/centos/alpine/openwrt…），退回 uname。
        let cmd = ". /etc/os-release 2>/dev/null && printf '%s' \"$ID\" || uname -s 2>/dev/null"
        ssh.exec(cmd) { [weak self, weak sess] out in
            guard let self = self, let sess = sess else { return }
            let id = out.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").last.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard !id.isEmpty, id.count <= 32, !id.contains(" ") else { return }
            guard var h = self.store.hosts.first(where: { $0.id == sess.host.id }), h.osId.isEmpty else { return }
            h.osId = id
            self.store.upsert(h)
            sess.host = h
            Log.info("识别远端系统 \(sess.host.subtitle) → \(id)", "session")
            self.quickConnect?.reload()
            self.connMgr?.reload()
        }
    }

    /// 显示连接动画（覆盖终端区）。
    func showConnectOverlay(for host: Host) {
        let ov = connectOverlay ?? ConnectOverlay(frame: .zero)
        connectOverlay = ov
        ov.onCancel = { [weak self] in
            guard let self = self, self.sessions.indices.contains(self.current) else { return }
            self.closeSession(self.current)
        }
        ov.onRetry = { [weak self] in
            guard let self = self else { return }
            self.reconnectCurrent()
        }
        ov.show(in: termContainer, title: host.subtitle)
    }

    /// 认证失败后重新要密码并重连（勾选记住则写回钥匙串）。
    /// 延后一拍再弹：didCloseWith 还在 SSH 回调栈里，直接弹 sheet 会和正在关闭的会话打架。
    func promptRetryPassword(for host: Host) {
        guard !retryPrompting else { return }   // 防止连续失败叠出多个密码框
        retryPrompting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self else { return }
            self.promptPassword(for: host, prefill: "") { [weak self] pw, remember in
                guard let self = self else { return }
                self.retryPrompting = false
                guard let pw = pw, !pw.isEmpty else { return }
                if remember { Keychain.setPassword(pw, for: host.id, label: host.host.isEmpty ? host.name : host.host) }
                self.beginSession(to: host, password: pw)
            }
        }
    }

    func selectSession(_ i: Int) {
        guard i >= 0, i < sessions.count else { return }
        current = i
        // 先立刻藏 QC（返回箭头 / 点标签回会话），避免动画期间再点无效
        quickConnect?.isHidden = true
        quickConnect?.showsBack = false
        termContainer.subviews.forEach { if $0 !== placeholder { $0.removeFromSuperview() } }
        placeholder.isHidden = true

        // 从 QC 回来或同标签重选：短淡入即可，别用 0.6~0.85s ripple 卡点击
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.15
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        termContainer.layer?.add(transition, forKey: "sessionSwitch")

        // Web SSH 标签用 WKWebView；普通会话用 SwiftTerm
        let content = sessions[i].contentView
        content.frame = termContainer.bounds
        content.autoresizingMask = [.width, .height]
        termContainer.addSubview(content)
        window.makeFirstResponder(content)
        window.title = sessions[i].title
        rebuildTabs()
        if sessions[i].connected { expandChrome() }   // 切到已连接会话 → 展开 chrome
        // Web SSH 标签不挂 SFTP / 监控（它只是当前会话的网页镜像视图）
        if sessions[i].isWebSSH {
            stopMonitor()
        } else {
            if let sp = sftpPanel, !sp.isHidden { connectSFTPToActive() }
            if sessions[i].ssh != nil { startMonitor(for: sessions[i]) } else { stopMonitor() }
        }
    }

    func closeSession(_ i: Int) {
        guard i >= 0, i < sessions.count else { return }
        let wasActive = i == current
        let sess = sessions[i]
        clearPendingOutput(for: sess)
        sess.ssh?.close()
        sess.contentView.removeFromSuperview()
        sessions[i].webSSHView = nil
        sessions.remove(at: i)
        if sessions.isEmpty {
            current = -1
            clearSessionSidePanels()   // P1：关最后标签 → 清 SFTP + 系统信息
            window.title = "PixShell"; rebuildTabs(); showQuickConnect()   // 无会话 → 回到落地页
        } else {
            if wasActive {
                // 关掉的是当前标签：侧栏/SFTP 先清，再由 selectSession 按新活动会话重连
                clearSessionSidePanels()
                selectSession(min(i, sessions.count - 1))
            } else if i < current {
                // 关掉的是当前标签之前的后台标签：原活动会话整体前移一位，
                // 视图/标题/SFTP 都不该动（之前误走 selectSession 会切到无关会话）。
                current -= 1
                rebuildTabs()
            } else {
                // 关掉的是当前标签之后的后台标签：什么都不用切，只重建标签栏。
                rebuildTabs()
            }
        }
    }

    // 胶囊会话 tab：● 状态圆点 + 名称 + ×（对齐老仓库）。
    func rebuildTabs() {
        let __tb = CFAbsoluteTimeGetCurrent()
        defer { AppDelegate.perfNote(kind: "rebuildTabs", ms: (CFAbsoluteTimeGetCurrent() - __tb) * 1000, bytes: 0) }
        var pills: [NSView] = []
        for (idx, sess) in sessions.enumerated() {
            let active = idx == current
            let pill = NSView(); pill.rounded(Theme.radiusSm,
                bg: active ? Theme.bg2 : .clear,
                border: active ? Theme.accent : Theme.border, borderWidth: active ? 1.5 : 1)
            pill.translatesAutoresizingMaskIntoConstraints = false

            let dot = Dot(sess.connected ? Theme.ok : Theme.warn, size: 7)
            let name = NSButton(title: sess.tabTitle, target: self, action: #selector(tabClicked(_:)))
            name.tag = idx; name.isBordered = false; name.bezelStyle = .regularSquare
            name.toolTip = sess.title      // 完整标题（含 user@ 和路径）留在悬停提示里
            name.attributedTitle = NSAttributedString(string: sess.tabTitle, attributes: [
                .foregroundColor: active ? Theme.text : Theme.muted,
                .font: Theme.ui(12, active ? .semibold : .regular)])
            name.translatesAutoresizingMaskIntoConstraints = false
            let close = NSButton(title: "✕", target: self, action: #selector(tabClose(_:)))
            close.tag = idx; close.isBordered = false; close.bezelStyle = .regularSquare
            close.attributedTitle = NSAttributedString(string: "✕", attributes: [.foregroundColor: Theme.muted, .font: Theme.ui(10)])
            close.translatesAutoresizingMaskIntoConstraints = false

            pill.menu = tabMenu(for: idx)   // 右键：切换/重连/再开/关闭/关闭其他
            pill.addSubview(dot); pill.addSubview(name); pill.addSubview(close)
            NSLayoutConstraint.activate([
                pill.heightAnchor.constraint(equalToConstant: 26),
                dot.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 9),
                dot.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                name.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
                name.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                name.widthAnchor.constraint(lessThanOrEqualToConstant: 130),
                close.widthAnchor.constraint(equalToConstant: 24),
                close.heightAnchor.constraint(equalToConstant: 24),
                close.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 2),
                close.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -4),
                close.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            ])
            // 拖动标签：拖出足够距离才生效（见 TabDragGesture）
            pill.addGestureRecognizer(TabDragGesture(index: idx, target: self, action: #selector(tabDragged(_:))))
            pills.append(pill)
        }
        tabBar.setItems(pills)
    }
    @objc func tabClicked(_ sender: NSButton) {
        // 一次点击必须立刻回会话（尤其 QC 盖住终端时）；禁止要连点多次
        let idx = sender.tag
        guard sessions.indices.contains(idx) else { return }
        selectSession(idx)
    }
    @objc func tabClose(_ sender: NSButton) { closeSession(sender.tag) }

    /// 标签右键菜单（老仓库交互文档 §1：切换/重连/再开/关闭/关闭其他）
    func tabMenu(for idx: Int) -> NSMenu {
        let m = NSMenu()
        func add(_ t: String, _ a: Selector) {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: ""); i.target = self; i.tag = idx; m.addItem(i)
        }
        add("切换到此标签", #selector(tabMenuSwitch(_:)))
        add("重新连接", #selector(tabMenuReconnect(_:)))
        add("再开一个同主机会话", #selector(tabMenuDuplicate(_:)))
        m.addItem(.separator())
        add("关闭", #selector(tabMenuClose(_:)))
        add("关闭其他", #selector(tabMenuCloseOthers(_:)))
        return m
    }
    @objc func tabMenuSwitch(_ s: NSMenuItem) { selectSession(s.tag) }
    @objc func tabMenuClose(_ s: NSMenuItem) { closeSession(s.tag) }
    @objc func tabMenuReconnect(_ s: NSMenuItem) {
        guard sessions.indices.contains(s.tag) else { return }
        selectSession(s.tag); menuReconnect()
    }
    /// 同主机多开（老仓库 forceNew / Shift+双击）
    @objc func tabMenuDuplicate(_ s: NSMenuItem) {
        guard sessions.indices.contains(s.tag) else { return }
        let sess = sessions[s.tag]
        // Web 主机：再走一遍 openSession（和 SSH 同路径），不要退回菜单硬开空标签
        if sess.isWebSSH { openSession(to: sess.host); return }
        if let pw = sess.password, !pw.isEmpty { beginSession(to: sess.host, password: pw) }
        else { openSession(to: sess.host) }
    }
    @objc func tabMenuCloseOthers(_ s: NSMenuItem) {
        guard sessions.indices.contains(s.tag) else { return }
        let keep = sessions[s.tag]
        for sess in sessions where sess !== keep {
            clearPendingOutput(for: sess)
            sess.ssh?.close()
            sess.contentView.removeFromSuperview()
            sess.webSSHView = nil
        }
        sessions = [keep]
        selectSession(0)
    }

    func maybeSeedAndAutoConnect() {
        let env = ProcessInfo.processInfo.environment
        if store.hosts.isEmpty, let h = env["PIXSHELL_HOST"], !h.isEmpty {
            let host = Host(name: env["PIXSHELL_NAME"] ?? "Demo Host", host: h,
                            port: Int(env["PIXSHELL_PORT"] ?? "22") ?? 22, username: env["PIXSHELL_USER"] ?? "root")
            store.upsert(host); if let p = env["PIXSHELL_PASS"] { Keychain.setPassword(p, for: host.id, label: host.host.isEmpty ? host.name : host.host) }
            tableView.reloadData()
        }
        if env["PIXSHELL_AUTOCONNECT"] == "1", !store.hosts.isEmpty {
            openSession(to: store.hosts[0])
            if env["PIXSHELL_AUTOCONNECT2"] == "1" { openSession(to: store.hosts[0]) }
        }
    }

    func session(forTerm tv: TerminalView) -> TermSession? { sessions.first { $0.termView === tv } }

    // <<<PERF_BEGIN>>>
    /// 临时性能插桩：按类别累计耗时，每 2 秒汇总一次（验证完删除）
    nonisolated(unsafe) static var perfAcc: [String: (n: Int, ms: Double, bytes: Int)] = [:]
    nonisolated(unsafe) static var perfLast = CFAbsoluteTimeGetCurrent()

    static func perfNote(kind: String, ms: Double, bytes: Int) {
        var e = perfAcc[kind] ?? (0, 0, 0)
        e.n += 1; e.ms += ms; e.bytes += bytes
        perfAcc[kind] = e
        let now = CFAbsoluteTimeGetCurrent()
        if now - perfLast >= 2.0 {
            perfLast = now
            for (k, v) in perfAcc.sorted(by: { $0.value.ms > $1.value.ms }) {
                Log.info(String(format: "PERF %@ 次数=%d 累计=%.0fms 均值=%.2fms 字节=%d",
                                k, v.n, v.ms, v.ms / Double(max(v.n, 1)), v.bytes), "perf")
            }
            perfAcc.removeAll()
        }
    }

    // <<<PERF_END>>>
    // MARK: - 标签拖出 → 独立窗口
    /// 拖动标签：位移越过门槛才把会话分离到独立窗口（见 TabDragGesture 的注释）。
    @objc func tabDragged(_ g: TabDragGesture) {
        guard !g.fired, g.state == .changed || g.state == .ended else { return }
        guard g.passedThreshold(in: g.view?.superview) else { return }
        g.fired = true
        detachSession(g.index)
    }

    /// 把第 i 个会话搬到独立窗口：**同一个 termView、同一条 SSH 连接**，不重连。
    func detachSession(_ i: Int) {
        guard sessions.indices.contains(i) else { return }
        let sess = sessions[i]
        Log.info("分离会话到独立窗口：\(sess.title)", "session")

        // 从主窗里摘掉（它可能正挂在 termContainer 上）
        sess.termView.removeFromSuperview()

        let w = DetachedTermWindow(title: sess.title, termView: sess.termView)
        w.onClosed = { [weak self] in
            Log.info("独立窗口关闭 → 断开 \(sess.title)", "session")
            sess.ssh?.close()
            self?.detachedWindows.removeAll { $0 === w }
        }
        detachedWindows.append(w)
        w.makeKeyAndOrderFront(nil)

        // 从 sessions 里移除并修正 current，再重建标签/面板
        clearPendingOutput(for: sess)
        sessions.remove(at: i)
        if sessions.isEmpty {
            current = 0
            stopMonitor()
            placeholder.isHidden = false
            quickConnect?.isHidden = false      // 没会话了 → 回落地页
            collapseChrome()
        } else {
            if i == current {
                // 拖走的是当前标签：termContainer 已空，选下一个（或末位）会话补上
                selectSession(min(current, sessions.count - 1))
            } else if i < current {
                // 拖走的是当前标签之前的标签：原活动会话前移一位，视图不动。
                current -= 1
                rebuildTabs()
            } else {
                rebuildTabs()
            }
        }
        rebuildTabs()
    }

    // MARK: - 监控采集（定时 exec 监控命令 → 解析 → 刷新仪表盘侧栏）
    func startMonitor(for sess: TermSession) {
        monTimer?.invalidate()
        monitor?.setConnected(true, ip: sess.host.host)
        let poll: () -> Void = { [weak self, weak sess] in
            guard let self = self, let sess = sess, let ssh = sess.ssh,
                  self.sessions.indices.contains(self.current), self.sessions[self.current] === sess else { return }
            ssh.exec(Self.monitorCommand) { [weak self] out in
                guard let self = self, self.sessions.indices.contains(self.current), self.sessions[self.current] === sess else { return }
                if out.contains("===mon===") { self.monitor?.update(self.parseMonitor(out)) }
                // 本地 ping SSH 主机（本机→服务器延迟）
                self.pingHost(sess.host.host)
            }
        }
        poll()
        monTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in poll() }
    }
    func stopMonitor() { monTimer?.invalidate(); monTimer = nil; monitor?.setConnected(false, ip: "") }
    func pingHost(_ host: String) {
        let now = Date()
        if now.timeIntervalSince(lastPingAt) < 3 { return }
        lastPingAt = now
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let task = Process()
            task.launchPath = "/sbin/ping"
            task.arguments = ["-c", "1", "-t", "1", host]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            task.launch()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let out = String(data: data, encoding: .utf8),
               let range = out.range(of: "time=") {
                let rest = out[range.upperBound...]
                let msStr = rest.prefix { $0.isNumber || $0 == "." }
                if let ms = Double(msStr) {
                    DispatchQueue.main.async { self?.monitor?.pushPingMs(ms) }
                }
            }
        }
    }

    func parseMonitor(_ out: String) -> [String: String] {
        var m: [String: String] = [:]
        for line in out.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { m[k] = v }
        }
        return m
    }

    // Linux 监控一行命令：输出 KEY=value（uptime/load/cpu/mem/swap/disks/procs/net）。
    static let monitorCommand = """
    echo ===mon===
    awk '{printf "uptime=%dd%dh%dm\\n",$1/86400,($1%86400)/3600,($1%3600)/60}' /proc/uptime 2>/dev/null
    echo "load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null | tr ' ' ',')"
    c1=$(awk '/^cpu /{i=$5;t=0;for(x=2;x<=NF;x++)t+=$x;print i,t}' /proc/stat 2>/dev/null); sleep 1; c2=$(awk '/^cpu /{i=$5;t=0;for(x=2;x<=NF;x++)t+=$x;print i,t}' /proc/stat 2>/dev/null)
    echo "cpu=$(echo "$c1 $c2" | awk '{di=$3-$1;dt=$4-$2; if(dt>0)printf "%.0f",100-di*100/dt; else printf "0"}')"
    free -m 2>/dev/null | awk '/^Mem:/{printf "mem=%.0f|%.1fG/%.1fG\\n",$3*100/$2,$3/1024,$2/1024}'
    free -m 2>/dev/null | awk '/^Swap:/{if($2>0)printf "swap=%.0f|%.1fG/%.1fG\\n",$3*100/$2,$3/1024,$2/1024; else printf "swap=0|0/0\\n"}'
    printf "disks="; df -h 2>/dev/null | awk '$1 ~ /^\\/dev/{printf "%s|%s|%s;",$6,$4,$2}'; echo
    printf "procs="; ps aux 2>/dev/null | sed 1d | sort -rk4 | awk 'NR<=5{c=$11; sub(/.*\\//,"",c); printf "%dM|%s|%s;",$6/1024,$3,c}'; echo
    cat /proc/net/dev 2>/dev/null | tr ':' ' ' | awk 'NR>2 && $1!="lo" && $1 !~ /^(docker|veth|br-)/{print "netif="$1; print "netval="$2+$10; print "netrx="$2; print "nettx="$10; exit}'
    """

    // MARK: - SSH 会话事件（职责已下沉到 TermSessionController）
    // SSHSessionDelegate 的实现（收数据帧级合并/双缓冲 flush、didOpenShell、didCloseWith
    // 分类回落）搬到了 Session/TermSessionController.swift，每个会话一个实例直接当
    // `ssh.delegate`——AppDelegate 不再做 O(N) 反查路由。这里只保留清理转发。
    func clearPendingOutput(for sess: TermSession) { sess.controller?.clearPending() }

    // MARK: - TerminalViewDelegate
    func send(source: TerminalView, data: ArraySlice<UInt8>) { session(forTerm: source)?.ssh?.send(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { session(forTerm: source)?.ssh?.resize(cols: newCols, rows: newRows) }
    func scrolled(source: TerminalView, position: Double) {}
    func setTerminalTitle(source: TerminalView, title: String) {
        guard let sess = session(forTerm: source) else { return }
        if !title.isEmpty { sess.title = title }
        if sessions.indices.contains(current), sessions[current] === sess { window.title = sess.title }
        rebuildTabs()
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
