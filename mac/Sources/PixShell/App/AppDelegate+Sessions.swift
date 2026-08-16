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
        s.delegate = self
        sess.ssh = s
        // creds 对 LocalSession 无用，填占位即可。
        let creds = SSHCredentials(host: "localhost", port: 0, username: sess.host.username)
        s.connectAndOpenShell(creds, term: "xterm-256color", cols: t.cols, rows: t.rows)
    }

    /// 在**已有会话**上建立 SSH 连接（不新开标签）。
    /// beginSession（新开标签）和 reconnectCurrent（原地重连）共用这段，
    /// 保证重连走的是同一套代理/私钥/覆盖层逻辑。
    /// 握手失败是不是"两边没有共同算法"（而不是密码不对）。
    /// nio-ssh 谈崩时抛的是 keyExchange/unsupported 一类错误；命中就该回落到系统 ssh。
    ///
    /// **关键坑（OpenWrt / Dropbear）**：服务端只给 `chacha20-poly1305` + `aes*-ctr`，
    /// 而 swift-nio-ssh 只实现 AES-GCM → 协商在 shell 打开前直接断 TCP，错误经常只是
    /// 裸 `End of file` / channel inactive，**没有** keyExchange 字样。若把这类 EOF 当认证失败，
    /// 会清掉钥匙串密码且永不回落系统 ssh —— mac 连不上、Windows(SSH.NET 算法全)却正常。
    static func looksLikeAlgorithmMismatch(_ error: Error?) -> Bool {
        guard let e = error else { return false }
        // 强类型优先（ErrorType 是 struct，用 == 而不是 enum switch）。
        if let nio = e as? NIOSSHError {
            let t = nio.type
            if t == .keyExchangeNegotiationFailure
                || t == .unknownPublicKey
                || t == .unknownSignature
                || t == .invalidHostKeyForKeyExchange
                || t == .invalidExchangeHashSignature {
                return true
            }
        }
        let s = "\(e) \(e.localizedDescription)".lowercased()
        for k in ["no matching", "keyexchange", "key exchange", "unsupported", "negotiat",
                  "algorithm", "nosuitable", "no common", "unknownpublickey", "invalidhostkey",
                  // 裸 EOF / 通道半关闭：Dropbear↔NIO 无共同 cipher 时的典型表象
                  "end of file", "nio.channel", "input/output error"] {
            if s.contains(k) { return true }
        }
        // IOError.End of file 的 description 有时就是 "End of file"
        if s.trimmingCharacters(in: .whitespacesAndNewlines) == "end of file" { return true }
        return false
    }

    /// 网络/代理/DNS/超时类失败 —— **禁止**清 Keychain、不要误导成「密码错了」。
    static func looksLikeNetworkFailure(_ error: Error?) -> Bool {
        guard let e = error else { return false }
        if e is ProxyDialError { return true }
        let ns = e as NSError
        if ns.domain == NSPOSIXErrorDomain { return true }
        if ns.domain == NSURLErrorDomain { return true }
        // 注意：NIOSSHError.tcpShutdown 在认证被拒时也很常见，不能单凭它当网络失败，
        // 否则错密不会弹重试。只认更明确的连通性错误。
        let s = "\(e) \(e.localizedDescription)".lowercased()
        let hint: String
        if let oe = e as? OpenSSHExitError { hint = oe.hint.lowercased() } else { hint = "" }
        let blob = s + " " + hint
        for k in [
            "connection refused", "connection reset", "timed out", "timeout",
            "nodename nor servname", "network is unreachable", "host is down",
            "no route to host", "could not resolve", "name or service not known",
            "broken pipe", "connect failed",
            "host unreachable", "network down",
            "socket not connected", "operation timed out", "i/o timeout",
            "nio connection", "connect() failed", "无法分配伪终端",
            "socks5", "socks4", "http connect", "network is down",
            "host key verification failed",
            "proxycommand", "proxy connect"
        ] {
            if blob.contains(k) { return true }
        }
        return false
    }

    /// 明确的认证失败（错密/拒公钥/无更多方法）。
    static func looksLikeAuthFailure(_ error: Error?) -> Bool {
        guard let e = error else { return false }
        if let oe = e as? OpenSSHExitError {
            return oe.authRejected
        }
        let s = "\(e) \(e.localizedDescription)".lowercased()
        for k in [
            "permission denied", "authentication failed", "auth fail",
            "invalid credentials", "access denied", "too many authentication",
            "no more authentication methods", "permission_denied",
            "wrong password", "invalid userauth", "not authorized"
        ] {
            if s.contains(k) { return true }
        }
        return false
    }

    /// 关闭原因分类：决定是否回落 OpenSSH / 是否弹密码。
    /// 任何失败路径都不删除已保存密码；删除只发生在用户删除主机或主动编辑凭据时。
    enum SSHCloseClass { case clean, algorithm, network, auth }

    static func classifyClose(_ error: Error?) -> SSHCloseClass {
        guard let error = error else { return .clean }
        // 算法/协议协商（含 Dropbear 无 AES-GCM 导致的裸 EOF）必须优先于 auth，
        // 否则会清密码且跳过 OpenSSH 回落。
        if looksLikeAlgorithmMismatch(error) { return .algorithm }
        // 网络/端口/DNS/超时优先于宽字符串认证判断，避免权限不足等网络错误被误报成密码错误。
        if looksLikeNetworkFailure(error) { return .network }
        if looksLikeAuthFailure(error) { return .auth }
        // 未知错误且 shell 从未打开：保守当算法协商失败先回落一次系统 ssh
        // （比误清密码更安全；已回落过仍失败时由调用方按 auth 处理）。
        return .algorithm
    }

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
        s.delegate = self; sess.ssh = s
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
        // 先摘掉 ssh 引用再关：这样旧连接回调走 session(forSSH:) 查不到会话，
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
            // 关掉的是当前标签时，侧栏/SFTP 先清，再由 selectSession 按新活动会话重连
            if wasActive { clearSessionSidePanels() }
            selectSession(min(i, sessions.count - 1))
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
    func session(forSSH s: SSHSession) -> TermSession? { sessions.first { $0.ssh === s } }

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
            selectSession(min(current, sessions.count - 1))
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

    // MARK: - SSHSessionDelegate（主线程）
    private func extractIncompleteANSI(from bytes: ArraySlice<UInt8>) -> (complete: [UInt8], incomplete: [UInt8]) {
        guard !bytes.isEmpty else { return ([], []) }
        let count = bytes.count
        let start = bytes.startIndex
        let maxLookback = min(count, 2048)

        func split(at relativeIndex: Int) -> (complete: [UInt8], incomplete: [UInt8]) {
            (Array(bytes.prefix(relativeIndex)), Array(bytes.dropFirst(relativeIndex)))
        }

        for relativeI in stride(from: count - 1, through: count - maxLookback, by: -1) {
            let value = bytes[bytes.index(start, offsetBy: relativeI)]
            guard value == 0x1B else { continue }
            guard relativeI + 1 < count else { return split(at: relativeI) }
            let next = bytes[bytes.index(start, offsetBy: relativeI + 1)]
            if next == 0x5B { // '['
                var complete = false
                if relativeI + 2 < count {
                    for relativeJ in (relativeI + 2)..<count {
                        let value = bytes[bytes.index(start, offsetBy: relativeJ)]
                        if value >= 0x40 && value <= 0x7E { complete = true; break }
                    }
                }
                if !complete { return split(at: relativeI) }
            } else if next == 0x5D { // ']'
                var complete = false
                if relativeI + 2 < count {
                    for relativeJ in (relativeI + 2)..<count {
                        let value = bytes[bytes.index(start, offsetBy: relativeJ)]
                        if value == 0x07 {
                            complete = true
                            break
                        }
                        if value == 0x1B, relativeJ + 1 < count,
                           bytes[bytes.index(start, offsetBy: relativeJ + 1)] == 0x5C {
                            complete = true
                            break
                        }
                    }
                }
                if !complete { return split(at: relativeI) }
            } else if next == 0x28 || next == 0x29 { // '(' or ')'
                if relativeI + 2 >= count { return split(at: relativeI) }
            }
            break // Found the last ESC and it was complete
        }
        return (Array(bytes), [])
    }

    private func scheduleFlush(for sess: TermSession) {
        guard !sess.flushScheduled else { return }
        sess.flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + sess.adaptiveFlushInterval) { [weak self, weak sess] in
            guard let self = self, let sess = sess else { return }
            guard self.sessions.contains(where: { $0 === sess }), !sess.closeHandled else {
                self.clearPendingOutput(for: sess)
                return
            }
            self.flushOutput(for: sess)
        }
    }

    private func clearPendingOutput(for sess: TermSession) {
        sess.pendingOutput.removeAll(keepingCapacity: true)
        sess.ansiBuffer.removeAll(keepingCapacity: true)
        sess.flushScheduled = false
        sess.drainingOutput.removeAll(keepingCapacity: true)
        sess.drainingOffset = 0
    }

    func sshSession(_ s: SSHSession, didReceive data: [UInt8]) {
        guard let sess = session(forSSH: s) else { return }
        guard !data.isEmpty else { return }

        // 帧级节流：只累积到会话的 pendingOutput，由 flushOutput 统一消化。
        // 高频输出时把「每数据块一次主线程 decode+染色+feed」合并成「每帧一次」
        // 显著降低主线程负担（卡顿根因）。同一 runloop 周期内的多次 append 合并成一次 flush。
        sess.pendingOutput.append(contentsOf: data)
        // 洪水兜底：远端持续高速输出时消化速率追不上，pendingOutput 会无界增长 → 内存暴涨。
        // 未消费积压 = draining 剩余 + pending，超过硬上限就丢最旧的（洪水刷屏时只有最新
        // 画面有意义）。常态下积压远低于上限，一字节不丢。
        let backlog = (sess.drainingOutput.count - sess.drainingOffset) + sess.pendingOutput.count
        if backlog > TermSession.maxBacklogBytes {
            dropOldestBacklog(for: sess, keepingNewest: TermSession.maxBacklogBytes)
        }
        scheduleFlush(for: sess)
    }

    /// 洪水兜底：把「draining 未消费部分 + pendingOutput」合起来只保留最新 `keepingNewest` 字节，
    /// 丢掉更旧的。合并后统一装回 pendingOutput，并清空 draining（下一帧重新 swap 出新批次）。
    /// ansiBuffer 一并清掉：残缺 ANSI 前缀所对应的后续字节已被丢弃，留着它反而会把下一批
    /// 正常数据错误粘连成畸形转义序列。
    private func dropOldestBacklog(for sess: TermSession, keepingNewest: Int) {
        var merged = Array(sess.drainingOutput[sess.drainingOffset...])
        merged.append(contentsOf: sess.pendingOutput)
        if merged.count > keepingNewest {
            merged.removeFirst(merged.count - keepingNewest)
        }
        sess.drainingOutput.removeAll(keepingCapacity: true)
        sess.drainingOffset = 0
        sess.pendingOutput = merged
        sess.ansiBuffer.removeAll(keepingCapacity: true)
    }

    /// 消化一个会话累积的输出：ANSI 分块 + 语义高亮 + feed 终端 + 写输出缓冲。
    /// 在帧节流下每帧最多调用一次；也保留了交互场景的即时性（16ms 内必处理）。
    private func flushOutput(for sess: TermSession) {
        sess.flushScheduled = false
        guard sessions.contains(where: { $0 === sess }), !sess.closeHandled else {
            clearPendingOutput(for: sess)
            return
        }

        // 双缓冲：drainingOutput 保存当前待处理批次，pendingOutput 继续接收新数据。
        // 只有批次耗尽时才交换，避免每帧 pendingOutput=[] + reserveCapacity 的分配。
        if sess.drainingOffset >= sess.drainingOutput.count {
            sess.drainingOutput.removeAll(keepingCapacity: true)
            sess.drainingOffset = 0
            guard !sess.pendingOutput.isEmpty else { return }
            swap(&sess.drainingOutput, &sess.pendingOutput)
        }

        let start = sess.drainingOffset
        let end = min(start + TermSession.maxFlushBytes, sess.drainingOutput.count)
        let bounded = sess.drainingOutput[start..<end]
        sess.drainingOffset = end
        let __f0 = CFAbsoluteTimeGetCurrent()
        var didProcess = false
        defer {
            // 不完整 ANSI 片段本次没有实际 feed，不应污染 flushCostEMA。
            if didProcess {
                let cost = CFAbsoluteTimeGetCurrent() - __f0
                sess.flushCostEMA = sess.flushCostEMA == 0 ? cost : sess.flushCostEMA * 0.7 + cost * 0.3
                sess.adaptiveFlushInterval = min(max(TermSession.flushInterval, sess.flushCostEMA * 6), 0.1)
                AppDelegate.perfNote(kind: "flush", ms: cost * 1000, bytes: bounded.count)
            }
        }

        // 每次最多 feed maxFlushBytes；超出的字节仍留在 draining，下一帧继续按原顺序处理。
        // 缓冲跨网络包的残缺 ANSI 序列，防止被 SemanticHighlight 破坏。
        let completeBytes: [UInt8]
        let incompleteBytes: [UInt8]
        if sess.ansiBuffer.isEmpty {
            (completeBytes, incompleteBytes) = extractIncompleteANSI(from: bounded)
        } else {
            var fullData = sess.ansiBuffer
            fullData.append(contentsOf: bounded)
            (completeBytes, incompleteBytes) = extractIncompleteANSI(from: fullData[...])
        }
        sess.ansiBuffer = incompleteBytes

        if completeBytes.isEmpty {
            if sess.drainingOffset < sess.drainingOutput.count || !sess.pendingOutput.isEmpty {
                scheduleFlush(for: sess)
            }
            return
        }
        didProcess = true

        // 语义高亮：仅对能完整 UTF-8 解码的块染色（保留已有转义），否则回退原始字节。
        // 关键：染色后仍走 termView.feed(byteArray:)（会触发视图重绘）——不要用
        // getTerminal().feed(text:)，那只更新终端模型、不刷新 NSView，导致画面空白。
        if highlightEnabled, let str = String(bytes: completeBytes, encoding: .utf8) {
            sess.appendOutput(str)          // 会话输出缓冲（上限 500KB，保留尾部）
            let __t0 = CFAbsoluteTimeGetCurrent()
            let decorated = SemanticHighlight.decorate(str, dark: darkTheme, activeColor: &sess.semanticActiveColor)
            AppDelegate.perfNote(kind: "decorate", ms: (CFAbsoluteTimeGetCurrent() - __t0) * 1000, bytes: completeBytes.count)
            sess.termView.feed(byteArray: ArraySlice(Array(decorated.utf8)))
        } else {
            if let str = String(bytes: completeBytes, encoding: .utf8) { sess.appendOutput(str) }
            sess.termView.feed(byteArray: ArraySlice(completeBytes))
        }

        if sess.drainingOffset < sess.drainingOutput.count || !sess.pendingOutput.isEmpty {
            scheduleFlush(for: sess)
        }
    }
    func sshSessionDidOpenShell(_ s: SSHSession) {
        guard let sess = session(forSSH: s) else { return }
        sess.connected = true
        sess.shellOpened = true     // 认证确实过了；之后任何关闭都不再算"认证失败"
        connectOverlay?.succeed()   // 连接动画收尾（绿点 + 淡出）
        detectRemoteOS(for: sess)   // 首次连上 → 认出发行版，主机图标换成对应系统标志
        rebuildTabs()
        if sessions.indices.contains(current), sessions[current] === sess {
            setStatus("已连接 \(sess.host.display)")
            expandChrome()   // 连上 → 展开侧栏 + 文件/命令坞（对齐老仓库）
            startMonitor(for: sess)
        }
        // 调试钩子：PIXSHELL_OPEN=sysinfo|tools|backup|conn|cmds 连上后自动打开对应面板，
        // 便于复现/截图排查 UI 问题（不影响正常使用）。
        if let want = ProcessInfo.processInfo.environment["PIXSHELL_OPEN"], !want.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self else { return }
                Log.info("调试钩子 PIXSHELL_OPEN=\(want)", "ui")
                switch want {
                case "sysinfo": self.openSysInfo()
                case "tools":   self.openTools()
                case "backup":  self.openBackup()
                case "conn":    self.openConnMgr()
                case "cmds":    self.showCmds()
                case "process": self.menuToolProcess()
                case "network": self.menuToolNetwork()
                case "editor":  // 等 SFTP 连上后打开一个远端文件到编辑器
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        self.sftpPanel?.openPathForEdit(ProcessInfo.processInfo.environment["PIXSHELL_EDIT"] ?? "/etc/os-release")
                    }
                default: Log.warn("未知 PIXSHELL_OPEN=\(want)", "ui")
                }
            }
        }
        // 演示：连上后自动执行一条命令(用于展示高亮/输出)。
        if let cmd = ProcessInfo.processInfo.environment["PIXSHELL_DEMOCMD"], !cmd.isEmpty {
            let bytes = Array((cmd + "\r\n").utf8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { sess.ssh?.send(bytes) }
        }
    }
    func sshSession(_ s: SSHSession, didCloseWith error: Error?) {
        guard let sess = session(forSSH: s), !sess.closeHandled else { return }
        sess.closeHandled = true
        // 清掉节流里还没 flush 的输出（会话已关，不再消化），同时清 ANSI 跨块状态。
        clearPendingOutput(for: sess)
        // 用 shellOpened（曾经认证成功过）判断，不用 connected —— 见 TermSession.shellOpened 注释。
        let wasUp = sess.shellOpened
        sess.connected = false
        let t = sess.termView.getTerminal()
        if !wasUp { t.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H") }
        // 认证前网络失败会写具体文案；末尾不要用笼统「连接失败」盖掉。
        var statusDetail: String? = nil
        if !wasUp {
            let kind = Self.classifyClose(error)
            switch kind {
            case .algorithm:
                // 内置实现算法太窄（含 Dropbear 无 AES-GCM 的裸 EOF）：不是密码问题，
                // 别动钥匙串、别弹密码框，回落系统 OpenSSH 一次。
                if !sess.triedOpenSSHFallback {
                    sess.triedOpenSSHFallback = true
                    Log.warn("算法/协议协商失败（\(error?.localizedDescription ?? "未知")），改用系统 ssh 重连 \(sess.host.subtitle)", "ssh")
                    let pw = sess.password ?? Keychain.password(for: sess.host.id) ?? ""
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.startSSH(for: sess, password: pw, forceOpenSSH: true)
                    }
                    return
                }
                // 已经回落过仍失败：再按认证/网络细分，避免永远卡在「协议不兼容」。
                // 注意：认证失败也保留旧密码；新密码只有在用户勾选记住并重新连接时才会覆盖。
                if Self.looksLikeAuthFailure(error) {
                    Log.warn("系统 ssh 回落后认证失败 \(sess.host.subtitle): \(error?.localizedDescription ?? "未知")（保留已保存密码）", "ssh")
                    t.feed(text: "\r\n\u{1b}[1;31m✗ 连接失败：认证被拒。\u{1b}[0m\r\n")
                    connectOverlay?.fail("认证失败")
                    if sess.host.keyPath.isEmpty { promptRetryPassword(for: sess.host) }
                } else if Self.looksLikeNetworkFailure(error) || LocalNetworkAuth.looksLikeLocalNetworkBlock(error) {
                    // 绝不自动弹本地网络 sheet：主机离线/断网也会 errno 65，弹窗会挡屏。
                    // 用户需要授权时走「帮助 → 授权本地网络…」。
                    let endpoint = "\(sess.host.host):\(sess.host.port)"
                    let detail: String
                    if LocalNetworkAuth.looksLikeLocalNetworkBlock(error) {
                        detail = "无法到达主机 (\(endpoint)) - 请检查网络连通性或本地网络权限"
                        // 静默 re-probe（身份变/重装后 TCC 丢）；不弹 sheet
                        LocalNetworkAuth.reprobeOnLikelyBlock()
                    } else {
                        detail = error?.localizedDescription ?? "网络不可达 (\(endpoint))"
                    }
                    Log.warn("系统 ssh 回落后网络失败 \(sess.host.subtitle): \(detail)（保留钥匙串）", "session")
                    connectOverlay?.fail("连接失败\n\(detail)", autoHide: false)
                    statusDetail = "✗ 连接失败：\(detail)"
                } else {
                    Log.warn("系统 ssh 回落后仍失败 \(sess.host.subtitle): \(error?.localizedDescription ?? "未知")", "ssh")
                    connectOverlay?.fail("连接失败\n算法/协议不兼容", autoHide: false)
                }
            case .network:
                // P0：网络/超时/DNS/代理失败 —— 保留 Keychain，禁止当认证失败清密码。
                // 禁止自动 presentGrantHelp：errno 65 / No route 常见于主机离线、Wi‑Fi 掉线，
                // 自动 sheet 会反复挡屏。本地网络授权仅由启动 NWBrowser + 帮助菜单手动触发。
                //
                // 关键：NIO 被本地网络 TCC 打成 errno 65 时，系统 /usr/bin/ssh 常仍可通
                // （独立代码身份）。先静默回落 OpenSSH 一次，避免「第一次失败后永远连不上」。
                if LocalNetworkAuth.looksLikeLocalNetworkBlock(error), !sess.triedOpenSSHFallback {
                    sess.triedOpenSSHFallback = true
                    LocalNetworkAuth.reprobeOnLikelyBlock()
                    Log.warn("NIO 疑似本地网络拦截，改用系统 ssh 重连 \(sess.host.subtitle)", "ssh")
                    let pw = sess.password ?? Keychain.password(for: sess.host.id) ?? ""
                    // 允许下一次 didClose 再处理（本轮交给 OpenSSH）
                    sess.closeHandled = false
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.startSSH(for: sess, password: pw, forceOpenSSH: true)
                    }
                    return
                }
                let endpoint = "\(sess.host.host):\(sess.host.port)"
                let detail: String
                if LocalNetworkAuth.looksLikeLocalNetworkBlock(error) {
                    detail = "无法到达主机 (\(endpoint)) - 请检查网络连通性或本地网络权限（帮助 → 授权本地网络…）"
                    LocalNetworkAuth.reprobeOnLikelyBlock()
                } else {
                    detail = error?.localizedDescription ?? "网络不可达 (\(endpoint))"
                }
                Log.warn("网络/连接失败 \(sess.host.subtitle): \(detail)（保留钥匙串）", "session")
                connectOverlay?.fail("连接失败\n\(detail)", autoHide: false)
                statusDetail = "✗ 连接失败：\(detail)"
            case .auth:
                // 认证失败只提示并（无 keyPath 时）弹密码重试，不删除 Keychain。
                // 网络/端口/算法协商误判也不得丢失用户已保存密码。
                Log.warn("认证失败 \(sess.host.subtitle)（保留已保存密码）", "session")
                t.feed(text: "\r\n\u{1b}[1;31m✗ 连接失败：认证被拒。\u{1b}[0m\r\n")
                connectOverlay?.fail("认证失败")
                let host = sess.host
                // 私钥登录失败不该弹密码框（那是 key 的问题）；仅密码登录路径重试。
                if host.keyPath.isEmpty { promptRetryPassword(for: host) }
            case .clean:
                // 用户取消/主动断开且从未 open：不动钥匙串。
                Log.info("连接在认证前结束 \(sess.host.subtitle)（干净关闭，保留钥匙串）", "session")
                connectOverlay?.fail("已取消")
            }
        } else {
            let msg = error.map { "\r\n\u{1b}[1;31m连接关闭: \($0.localizedDescription)\u{1b}[0m\r\n" } ?? "\r\n\u{1b}[90m连接已关闭。\u{1b}[0m\r\n"
            t.feed(text: msg)
        }
        rebuildTabs()
        if sessions.indices.contains(current), sessions[current] === sess {
            // P1：活动会话掉线 → 文件系统/系统信息跟着关，别留"连接关闭"后的僵尸面板
            clearSessionSidePanels()
            if wasUp {
                setStatus("已断开")
            } else {
                setStatus(statusDetail ?? "连接失败")
            }
        }
    }

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
