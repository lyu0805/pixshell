import Foundation
import SwiftTerm
@preconcurrency import NIOSSH

/// 单会话控制器：从 AppDelegate 下沉的 `SSHSessionDelegate` + 终端输出管线。
/// 每个会话一个实例；SSH 事件不再经 AppDelegate 做 O(N) 反查路由，
/// 用 `s === sess.ssh` 身份校验替代（重连换 transport 后旧连接的迟到回调直接丢弃）。
/// UI 侧动作（覆盖层/标签/监控/SFTP/回落重连）通过弱引用 `app` 回调 AppDelegate。
final class TermSessionController: SSHSessionDelegate {
    /// 反向引用会话。**必须 unowned（不能 strong）**：会话 strong 持有本控制器（见
    /// TermSession.controller 的注释——它必须 strong，否则控制器建好即被 ARC 释放，SSH
    /// delegate 全丢导致连不上）。若这里再 strong 持会话，session↔controller 形成强环，
    /// 会话从 AppDelegate.sessions 移除后二者互持成孤岛泄漏（app 是 weak、SSH delegate 是
    /// weak，都不构成外部强引用）。控制器是会话的从属对象、生命周期 ⊆ 会话：会话是控制器
    /// 的唯一强引用者，所以"控制器存活 ⟹ 会话存活"，unowned 访问始终安全（SSH 回调经 weak
    /// delegate、异步 flush 经 [weak self]、clearPending 经仍活跃的 sess 调用，无一会在会话
    /// 释放后触达）。
    unowned let sess: TermSession
    weak var app: AppDelegate?

    init(sess: TermSession, app: AppDelegate?) {
        self.sess = sess
        self.app = app
    }

    // MARK: - SSHSessionDelegate

    func sshSession(_ s: SSHSession, didReceive data: [UInt8]) {
        guard s === sess.ssh else { return }
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
            dropOldestBacklog(keepingNewest: TermSession.maxBacklogBytes)
        }
        scheduleFlush()
    }

    func sshSessionDidOpenShell(_ s: SSHSession) {
        guard s === sess.ssh else { return }
        // 会话存活校验：closeSession 移除标签后不置 ssh=nil，迟到的 open 回调若只验
        // transport 身份会对已删会话继续建连/探测（幽灵重连）。旧反查天然含此语义。
        guard let app = app, app.sessions.contains(where: { $0 === sess }) else { return }
        let isCurrent = app.sessions.indices.contains(app.current) && app.sessions[app.current] === sess
        sess.connected = true
        sess.shellOpened = true     // 认证确实过了；之后任何关闭都不再算"认证失败"
        if isCurrent { app.connectOverlay?.succeed() }
        app.detectRemoteOS(for: sess)   // 首次连上 → 认出发行版，主机图标换成对应系统标志
        app.rebuildTabs()
        if isCurrent {
            app.setStatus("已连接 \(sess.host.display)")
            app.expandChrome()   // 连上 → 展开侧栏 + 文件/命令坞（对齐老仓库）
            app.startMonitor(for: sess)
        }
        // 调试钩子：PIXSHELL_OPEN=sysinfo|tools|backup|conn|cmds 连上后自动打开对应面板，
        // 便于复现/截图排查 UI 问题（不影响正常使用）。
        if let want = ProcessInfo.processInfo.environment["PIXSHELL_OPEN"], !want.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak app] in
                guard let app = app else { return }
                Log.info("调试钩子 PIXSHELL_OPEN=\(want)", "ui")
                switch want {
                case "sysinfo": app.openSysInfo()
                case "tools":   app.openTools()
                case "backup":  app.openBackup()
                case "conn":    app.openConnMgr()
                case "cmds":    app.showCmds()
                case "process": app.menuToolProcess()
                case "network": app.menuToolNetwork()
                case "editor":  // 等 SFTP 连上后打开一个远端文件到编辑器
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        app.sftpPanel?.openPathForEdit(ProcessInfo.processInfo.environment["PIXSHELL_EDIT"] ?? "/etc/os-release")
                    }
                default: Log.warn("未知 PIXSHELL_OPEN=\(want)", "ui")
                }
            }
        }
        // 演示：连上后自动执行一条命令(用于展示高亮/输出)。
        if let cmd = ProcessInfo.processInfo.environment["PIXSHELL_DEMOCMD"], !cmd.isEmpty {
            let bytes = Array((cmd + "\r\n").utf8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.sess.ssh?.send(bytes)
            }
        }
    }

    func sshSession(_ s: SSHSession, didCloseWith error: Error?) {
        guard s === sess.ssh else { return }
        // 同上：已从 sessions 移除的会话不再走分类/回落/提示（否则会对幽灵会话
        // 自动重连 + 把覆盖层盖到当前活动会话上）。
        guard let app = app, app.sessions.contains(where: { $0 === sess }) else { return }
        let isCurrent = app.sessions.indices.contains(app.current) && app.sessions[app.current] === sess
        guard !sess.closeHandled else { return }
        sess.closeHandled = true
        // 清掉节流里还没 flush 的输出（会话已关，不再消化），同时清 ANSI 跨块状态。
        clearPending()
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
                        self.app?.startSSH(for: self.sess, password: pw, forceOpenSSH: true)
                    }
                    return
                }
                // 已经回落过仍失败：再按认证/网络细分，避免永远卡在「协议不兼容」。
                // 注意：认证失败也保留旧密码；新密码只有在用户勾选记住并重新连接时才会覆盖。
                if Self.looksLikeAuthFailure(error) {
                    Log.warn("系统 ssh 回落后认证失败 \(sess.host.subtitle): \(error?.localizedDescription ?? "未知")（保留已保存密码）", "ssh")
                    t.feed(text: "\r\n\u{1b}[1;31m✗ 连接失败：认证被拒。\u{1b}[0m\r\n")
                    if isCurrent { app.connectOverlay?.fail("认证失败") }
                    if isCurrent && sess.host.keyPath.isEmpty { app.promptRetryPassword(for: sess) }
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
                    if isCurrent { app.connectOverlay?.fail("连接失败\n\(detail)", autoHide: false) }
                    statusDetail = "✗ 连接失败：\(detail)"
                } else {
                    Log.warn("系统 ssh 回落后仍失败 \(sess.host.subtitle): \(error?.localizedDescription ?? "未知")", "ssh")
                    if isCurrent { app.connectOverlay?.fail("连接失败\n算法/协议不兼容", autoHide: false) }
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
                        self.app?.startSSH(for: self.sess, password: pw, forceOpenSSH: true)
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
                if isCurrent { app.connectOverlay?.fail("连接失败\n\(detail)", autoHide: false) }
                statusDetail = "✗ 连接失败：\(detail)"
            case .auth:
                // 认证失败只提示并（无 keyPath 时）弹密码重试，不删除 Keychain。
                // 网络/端口/算法协商误判也不得丢失用户已保存密码。
                // 配置了私钥且 NIO 认证被拒：NIO 的公钥实现有覆盖不到的场景（服务器端
                // 算法限制、agent/FIDO2 语义等），先回落系统 OpenSSH 一次——它支持完整
                // key 矩阵（RSA / 加密私钥 pty 交互输 passphrase / sk-* 安全密钥），
                // 这是「key 方式登录不生效」的主要缺口。回落过仍失败才认输。
                if !sess.host.keyPath.isEmpty, !sess.triedOpenSSHFallback {
                    sess.triedOpenSSHFallback = true
                    Log.warn("私钥认证被 NIO 拒绝（\(error?.localizedDescription ?? "未知")），改用系统 ssh 以私钥重连 \(sess.host.subtitle)", "ssh")
                    let pw = sess.password ?? Keychain.password(for: sess.host.id) ?? ""
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.app?.startSSH(for: self.sess, password: pw, forceOpenSSH: true)
                    }
                    return
                }
                Log.warn("认证失败 \(sess.host.subtitle)（保留已保存密码）", "session")
                t.feed(text: "\r\n\u{1b}[1;31m✗ 连接失败：认证被拒。\u{1b}[0m\r\n")
                if isCurrent { app.connectOverlay?.fail("认证失败") }
                let host = sess.host
                // 私钥登录失败不该弹密码框（那是 key 的问题）；仅密码登录路径重试。
                if isCurrent && host.keyPath.isEmpty { app.promptRetryPassword(for: sess) }
            case .clean:
                // 用户取消/主动断开且从未 open：不动钥匙串。
                Log.info("连接在认证前结束 \(sess.host.subtitle)（干净关闭，保留钥匙串）", "session")
                if isCurrent { app.connectOverlay?.fail("已取消") }
            }
        } else {
            let msg = error.map { "\r\n\u{1b}[1;31m连接关闭: \($0.localizedDescription)\u{1b}[0m\r\n" } ?? "\r\n\u{1b}[90m连接已关闭。\u{1b}[0m\r\n"
            t.feed(text: msg)
        }
        app.rebuildTabs()
        if app.sessions.indices.contains(app.current), app.sessions[app.current] === sess {
            // P1：活动会话掉线 → 文件系统/系统信息跟着关，别留"连接关闭"后的僵尸面板
            app.clearSessionSidePanels()
            if wasUp {
                app.setStatus("已断开")
            } else {
                app.setStatus(statusDetail ?? "连接失败")
            }
        }
    }

    // MARK: - 输出管线（帧级合并 / 双缓冲 / 洪水兜底）

    private func scheduleFlush() {
        guard !sess.flushScheduled else { return }
        sess.flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + sess.adaptiveFlushInterval) { [weak self] in
            guard let self = self else { return }
            guard self.app?.sessions.contains(where: { $0 === self.sess }) == true, !self.sess.closeHandled else {
                self.clearPending()
                return
            }
            self.flushOutput()
        }
    }

    func clearPending() {
        sess.pendingOutput.removeAll(keepingCapacity: true)
        sess.ansiBuffer.removeAll(keepingCapacity: true)
        sess.flushScheduled = false
        sess.drainingOutput.removeAll(keepingCapacity: true)
        sess.drainingOffset = 0
    }

    /// 洪水兜底：把「draining 未消费部分 + pendingOutput」合起来只保留最新 `keepingNewest` 字节，
    /// 丢掉更旧的。合并后统一装回 pendingOutput，并清空 draining（下一帧重新 swap 出新批次）。
    /// ansiBuffer 一并清掉：残缺 ANSI 前缀所对应的后续字节已被丢弃，留着它反而会把下一批
    /// 正常数据错误粘连成畸形转义序列。
    private func dropOldestBacklog(keepingNewest: Int) {
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
    private func flushOutput() {
        sess.flushScheduled = false
        guard app?.sessions.contains(where: { $0 === sess }) == true, !sess.closeHandled else {
            clearPending()
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
            (completeBytes, incompleteBytes) = Self.extractIncompleteANSI(from: bounded)
        } else {
            var fullData = sess.ansiBuffer
            fullData.append(contentsOf: bounded)
            (completeBytes, incompleteBytes) = Self.extractIncompleteANSI(from: fullData[...])
        }
        sess.ansiBuffer = incompleteBytes

        if completeBytes.isEmpty {
            if sess.drainingOffset < sess.drainingOutput.count || !sess.pendingOutput.isEmpty {
                scheduleFlush()
            }
            return
        }
        didProcess = true

        // 语义高亮：仅对能完整 UTF-8 解码的块染色（保留已有转义），否则回退原始字节。
        // 关键：染色后仍走 termView.feed(byteArray:)（会触发视图重绘）——不要用
        // getTerminal().feed(text:)，那只更新终端模型、不刷新 NSView，导致画面空白。
        if app?.highlightEnabled == true, let str = String(bytes: completeBytes, encoding: .utf8) {
            sess.appendOutput(str)          // 会话输出缓冲（上限 500KB，保留尾部）
            let __t0 = CFAbsoluteTimeGetCurrent()
            let decorated = SemanticHighlight.decorate(str, dark: app?.darkTheme ?? true, activeColor: &sess.semanticActiveColor)
            AppDelegate.perfNote(kind: "decorate", ms: (CFAbsoluteTimeGetCurrent() - __t0) * 1000, bytes: completeBytes.count)
            sess.termView.feed(byteArray: ArraySlice(Array(decorated.utf8)))
        } else {
            if let str = String(bytes: completeBytes, encoding: .utf8) { sess.appendOutput(str) }
            sess.termView.feed(byteArray: ArraySlice(completeBytes))
        }

        if sess.drainingOffset < sess.drainingOutput.count || !sess.pendingOutput.isEmpty {
            scheduleFlush()
        }
    }

    // MARK: - 关闭分类（决定回落 OpenSSH / 弹密码；绝不清钥匙串）

    /// 握手失败是不是"两边没有共同算法"（而不是密码不对）。
    /// nio-ssh 谈崩时抛的是 keyExchange/unsupported 一类错误；命中就该回落到系统 ssh。
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

    // MARK: - ANSI 分帧

    /// 检测尾部不完整的 ANSI 转义序列，切出（完整, 不完整）两段；不完整的留到下一批。
    static func extractIncompleteANSI(from bytes: ArraySlice<UInt8>) -> (complete: [UInt8], incomplete: [UInt8]) {
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
}
