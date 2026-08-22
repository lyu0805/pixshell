import Foundation

/// 无头模式（--headless）的桥宿主：**自己建 SSH/SFTP 会话**，不依赖任何 UI。
///
/// 与有头版（AppDelegate 实现 BridgeHost）的区别：有头复用已打开 Tab 的 TermSession，
/// 无头进程没有窗口，这里直接用零 UI 的 `SSHSession` / `SFTPService` 层
/// （NIOSSHSession / OpenSSHSession / NIOSFTPSession / OpenSSHSFTPSession 均无 UI 依赖，
/// 见 SSH/SSHSession.swift、SFTP/SFTPService.swift），每条会话自管一个输出缓冲，
/// 供 exec / screen 读。凭据路径与有头一致：HostStore.hosts + Keychain.password(for:)。
///
/// 会话生命周期随本进程：CLI 通过 /v1/app/connect 建会话 → exec/screen/sftp 操作 →
/// 进程退出（有头接管发 /v1/app/shutdown 或自然退出）时 close 全部。
final class HeadlessBridgeHost: BridgeHost {
    /// 无头桥只操作锁保护的 SSH 会话，不触碰 AppKit；请求可直接在桥队列处理。
    let bridgeRequiresMainThread = false

    /// 无头会话：逻辑 SSH 会话 + 自管输出缓冲 + 凭据快照。
    /// 非 private：文件底部 extension 里当自己的 SSHSessionDelegate。
    final class HeadlessSession {
        let title: String
        let host: Host
        /// 内部 SSH 会话：断开后可原地重建（自动重连），下标永不变。
        private(set) var ssh: SSHSession
        let password: String
        /// 交互 shell 的最近输出（exec 是独立通道不进这里；screen 读它）。
        private var output = ""
        private let stateLock = NSLock()
        private var connectedState = false
        private var reconnectingState = false
        private var reconnectWaiters: [(Bool) -> Void] = []
        private var serializedOperations: [(@escaping () -> Void) -> Void] = []
        private var runningOperations = 0
        private let maxConcurrentOperations = 4
        /// 半死 transport 自愈计数：TCP 通但 SSH 数据泵停时（对端 sshd 进程还在、只是不再
        /// 响应 channel 请求，TCP keepalive 检不出），交互 shell 通道收不到 inactive →
        /// connectedState 长期为 true → ensureConnected 每次都直接复用这条僵死连接，exec 一个个
        /// 空手超时返回空、永不重连（「连接死掉 / 重连无响应」在第 69 批 Fix A/B 之后仍残留的
        /// 真正根因）。连续「超时且零输出」累计到阈值即判定 transport 僵死，主动断开翻
        /// connectedState=false，下一个 exec 经 ensureConnected 自动重连自愈。tail -f 等持续产出
        /// 的长命令有输出（hadOutput=true）会清零，不误杀。
        private var staleExecStrikes = 0
        private static let staleExecStrikeLimit = 2

        /// 交互 PTY 最近一次收发与自愈探针状态。
        private var lastInboundAt = Date.distantPast
        private var lastWriteAt = Date.distantPast
        private var interactiveProbeInFlight = false
        private var interactiveProbeGeneration = 0
        private var probeConfirmedSinceWrite = true
        private var everOpenedShell = false
        private var resetNotice: String?
        private static let interactiveStaleGrace: TimeInterval = 10
        private static let interactiveProbeTimeout: TimeInterval = 6
        private static let contextResetNotice = "警告：SSH 交互连接曾中断（半死或掉线），当前已建立全新 shell；原有嵌套上下文全部丢失。断开后第一次 type_text 不会执行，只会触发重连并展示此提示。请先 read_screen，或执行 pwd && hostname && whoami 确认位置，再重新输入命令。"

        // MARK: PTY-exec（真人模式）与连接冷却
        /// OpenSSH 回落会话的 exec 一律通过**已认证的交互 PTY** 执行（敲命令→收输出直到
        /// marker）——绝不另起 ssh 进程重新认证：连续快速认证会被 fail2ban/防火墙当爆破
        /// 封禁；且命令跑在同一个 shell 里，cd/env/sudo 状态跨命令延续，与真人操作同构。
        /// PTY 是单字节流，天然串行（`ptySerial` + `ptyBusy` 挡并发）。
        private let ptySerial = DispatchQueue(label: "pixshell.bridge.ptyexec")
        private var ptyBusy = false
        private var ptyMarker: String?
        private var ptyCapture = ""
        private var ptyCaptureLimit = 512 * 1024
        private var ptyEchoPrefix = ""
        /// 最近一次连接失败时间：刚失败的主机在冷却窗内直接快速失败，防止 agent 疯狂
        /// 重试把「每次都完整认证」变成爆破被封。
        private var lastConnectFailAt = Date.distantPast
        private static let connectCooldown: TimeInterval = 8
        /// 跨读块残缺 UTF-8 尾部（只在会话的回调队列上触碰，无需加锁）。
        private var pendingTail: [UInt8] = []

        var connected: Bool {
            get { stateLock.lock(); defer { stateLock.unlock() }; return connectedState }
            set { stateLock.lock(); defer { stateLock.unlock() }; connectedState = newValue }
        }

        init(title: String, host: Host, ssh: SSHSession, password: String) {
            self.title = title
            self.host = host
            self.ssh = ssh
            self.password = password
        }

        func currentSSH() -> SSHSession {
            stateLock.lock(); defer { stateLock.unlock() }
            return ssh
        }

        /// 同一 SSH transport 上的 exec/type/SFTP 操作串行，跨 session 仍可并行。
        /// NIO SSH handler 对并发 createChannel/close 的支持不是无限制的；串行化避免
        /// 多个 agent 同时抢同一 transport 导致 ok:true 但 stdout 为空。
        func enqueueOperation(_ operation: @escaping (@escaping () -> Void) -> Void) {
            stateLock.lock()
            serializedOperations.append(operation)
            let shouldStart = runningOperations < maxConcurrentOperations
            if shouldStart { runningOperations += 1 }
            stateLock.unlock()
            if shouldStart { runNextOperation() }
        }

        private func runNextOperation() {
            stateLock.lock()
            guard !serializedOperations.isEmpty else {
                runningOperations = max(0, runningOperations - 1)
                stateLock.unlock()
                return
            }
            let operation = serializedOperations.removeFirst()
            stateLock.unlock()
            operation { [weak self] in
                guard let self else { return }
                self.runNextOperation()
            }
        }

        func appendOutput(_ text: String, from session: SSHSession? = nil) {
            stateLock.lock(); defer { stateLock.unlock() }
            if let session, session !== ssh { return }
            lastInboundAt = Date()
            if ptyMarker != nil {
                ptyCapture += text
                if ptyCapture.count > ptyCaptureLimit {
                    ptyCapture = String(ptyCapture.suffix(ptyCaptureLimit))
                }
            }
            output += text
            // 防无限增长：只保留最近 512 KiB
            if output.count > 512 * 1024 {
                output = String(output.dropFirst(output.count - 512 * 1024))
            }
        }

        func recentOutput(lines: Int) -> String {
            stateLock.lock(); defer { stateLock.unlock() }
            let n = lines > 0 ? lines : 200
            let rows = output.split(separator: "\n", omittingEmptySubsequences: false)
            let recent = rows.suffix(n)
                .filter {
                    let t = $0.trimmingCharacters(in: .whitespaces)
                    return !t.hasPrefix("__PIX_DONE_") && !t.hasPrefix("__PIX_FLUSH_")
                }
                .joined(separator: "\n")
            guard let notice = resetNotice else { return recent }
            resetNotice = nil
            return recent.isEmpty ? notice : notice + "\n" + recent
        }

        /// 记录一次交互输入；新的写入需要重新等待 shell 回显或探针确认。
        func noteInteractiveWrite() {
            stateLock.lock(); defer { stateLock.unlock() }
            lastWriteAt = Date()
            probeConfirmedSinceWrite = false
        }

        func hasPendingResetNotice() -> Bool {
            stateLock.lock(); defer { stateLock.unlock() }
            return resetNotice != nil
        }

        /// 记录一次连接失败（冷却计时用；防 agent 高频重试触发爆破封禁）。
        func markConnectFailed() {
            stateLock.lock(); defer { stateLock.unlock() }
            lastConnectFailAt = Date()
        }

        /// 交互 shell 最近写入后长时间无输入时，用独立 exec 通道探测 transport 是否仍活着。
        func maybeProbeInteractiveLiveness() {
            let now = Date()
            stateLock.lock()
            guard everOpenedShell, connectedState, resetNotice == nil,
                  lastWriteAt > lastInboundAt,
                  now.timeIntervalSince(lastWriteAt) >= Self.interactiveStaleGrace,
                  !probeConfirmedSinceWrite,
                  !interactiveProbeInFlight else {
                stateLock.unlock()
                return
            }
            interactiveProbeInFlight = true
            interactiveProbeGeneration &+= 1
            let generation = interactiveProbeGeneration
            let probeSSH = ssh
            stateLock.unlock()

            Log.info("exec/探针：交互 shell 写入后超过 \(Int(Self.interactiveStaleGrace))s 无输入，开始 liveness probe", "ssh")
            probeResponsive(probeSSH, timeout: Self.interactiveProbeTimeout) { [weak self, weak probeSSH] alive in
                guard let self, let probeSSH else { return }
                self.stateLock.lock()
                guard self.interactiveProbeInFlight,
                      self.interactiveProbeGeneration == generation else {
                    self.stateLock.unlock()
                    return
                }
                let isCurrent = probeSSH === self.ssh
                self.interactiveProbeInFlight = false
                if isCurrent && alive {
                    self.probeConfirmedSinceWrite = true
                }
                self.stateLock.unlock()
                guard isCurrent else { return }
                Log.info("exec/探针：liveness probe \(alive ? "确认" : "超时")", "ssh")
                // 探针超时按「空手超时」计 strike（hadOutput=false）；确认活着则清零。
                self.noteExecResult(timedOut: !alive, hadOutput: false)
            }
        }

        // MARK: PTY-exec（真人模式）

        /// 通过**已认证的交互 PTY** 执行一次性命令：敲 `{ cmd; }; echo <marker>` 进同一个
        /// shell，收集输出直到 marker。零新连接、零重新认证（防爆破封禁的关键路径），
        /// cd/env/sudo 状态跨命令延续。PTY 单流天然串行：`ptyBusy` 挡住并发，等待者稍后重排。
        func execViaPTY(_ s: SSHSession, _ command: String, timeout: TimeInterval,
                        maxBytes: Int, completion: @escaping (String, Bool) -> Void) {
            ptySerial.async { [weak self, weak s] in
                guard let self, let s else { completion("", false); return }
                self.stateLock.lock()
                if self.ptyBusy {
                    self.stateLock.unlock()
                    // 前一条命令还在 PTY 里跑：稍后重排（串行语义，不并发交错）。
                    self.ptySerial.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.execViaPTY(s, command, timeout: timeout, maxBytes: maxBytes, completion: completion)
                    }
                    return
                }
                guard self.connectedState, s === self.ssh else {
                    self.stateLock.unlock(); completion("", false); return
                }
                self.ptyBusy = true
                self.stateLock.unlock()
                // 排空阶段：上一条超时命令可能仍在远端跑、残留输出还在流入。先发一条
                // flush marker，丢弃到它为止的一切（残留输出/提示符），再开始正式捕获，
                // 否则下一条命令的结果会混入上一条的尾巴。
                self.drainPty(s) { [weak self] in
                    guard let self = self else { completion("", false); return }
                    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                    let cmd = trimmed.isEmpty ? "true" : trimmed
                    let nonce = String(format: "%08x", UInt32.random(in: 1...UInt32.max))
                    let marker = "__PIX_DONE_\(nonce)__"
                    let line = "{ \(cmd); }; echo \(marker)\n"
                    self.stateLock.lock()
                    guard self.ptyBusy, self.connectedState, s === self.ssh else {
                        self.ptyBusy = false
                        self.stateLock.unlock(); completion("", false); return
                    }
                    self.ptyMarker = marker
                    self.ptyCapture = ""
                    self.ptyCaptureLimit = maxBytes > 0 ? maxBytes : 512 * 1024
                    self.ptyEchoPrefix = String(cmd.prefix(40))
                    self.stateLock.unlock()
                    s.send(Array(line.utf8))
                    self.pollPty(s, myMarker: marker, deadline: Date().addingTimeInterval(timeout), completion: completion)
                }
            }
        }

        /// 排空交互 PTY：发一条 flush marker，丢弃到它为止的历史输出（最多 3s——
        /// flush 排不上队说明远端仍被占，尽力而为继续）。
        private func drainPty(_ s: SSHSession, done: @escaping () -> Void) {
            let nonce = String(format: "%08x", UInt32.random(in: 1...UInt32.max))
            let flush = "__PIX_FLUSH_\(nonce)__"
            stateLock.lock()
            guard ptyBusy, connectedState, s === ssh else {
                stateLock.unlock(); done(); return
            }
            ptyMarker = flush
            ptyCapture = ""
            stateLock.unlock()
            s.send(Array("echo \(flush)\n".utf8))
            pollDrain(s, myFlush: flush, deadline: Date().addingTimeInterval(3), done: done)
        }

        private func pollDrain(_ s: SSHSession, myFlush: String, deadline: Date, done: @escaping () -> Void) {
            var complete = false
            stateLock.lock()
            if ptyMarker == myFlush {
                if ptyCapture.contains(myFlush) || Date() >= deadline || !connectedState || s !== ssh {
                    ptyMarker = nil; ptyCapture = ""
                    complete = true
                }
            } else {
                complete = true   // 被外部清理（断线/重连）：直接进入下一步（会被入口 guard 拦）
            }
            stateLock.unlock()
            if complete { done(); return }
            ptySerial.asyncAfter(deadline: .now() + 0.05) { [weak self, weak s] in
                guard let self, let s else { done(); return }
                self.pollDrain(s, myFlush: myFlush, deadline: deadline, done: done)
            }
        }

        /// PTY 收口轮询（跑在 ptySerial 上）：marker 出现 → 截取输出并剥掉命令回显行；
        /// 超时/断线/被外部清理 → 返回已收集的部分 + timedOut=true（**绝不**伪报成功——
        /// 把「命令被断线打断」报成正常完成会误导 agent，还会错误清零僵死 strike）。
        /// 超时先发 Ctrl-C 终止远端命令，防止它继续产出污染下一条 exec。
        private func pollPty(_ s: SSHSession, myMarker: String, deadline: Date, completion: @escaping (String, Bool) -> Void) {
            var done: (String, Bool)?
            var interruptRemote = false
            stateLock.lock()
            if let marker = ptyMarker, marker == myMarker {
                if let range = ptyCapture.range(of: marker) {
                    var out = String(ptyCapture[..<range.lowerBound])
                    let echoPrefix = ptyEchoPrefix
                    if !echoPrefix.isEmpty, let nl = out.firstIndex(of: "\n") {
                        let firstLine = String(out[..<nl])
                        if firstLine.contains(echoPrefix) {
                            out = String(out[out.index(after: nl)...])
                        }
                    }
                    ptyMarker = nil; ptyCapture = ""; ptyBusy = false
                    done = (out, false)
                } else if Date() >= deadline || !connectedState || s !== ssh {
                    let partial = ptyCapture
                    ptyMarker = nil; ptyCapture = ""; ptyBusy = false
                    interruptRemote = Date() >= deadline
                    done = (partial, true)
                }
            } else if ptyMarker == nil {
                // 被外部清理（断线/重连）：命令被硬打断，按失败上报（含已收集部分）。
                let partial = ptyCapture
                ptyCapture = ""; ptyBusy = false
                done = (partial, true)
            } else {
                // ptyMarker 已换成别的（异常路径）：同样按中断处理。
                done = ("", true)
            }
            stateLock.unlock()
            if interruptRemote { s.send([0x03]) }   // Ctrl-C：终止远端仍在跑的命令
            if let d = done { completion(d.0, d.1); return }
            ptySerial.asyncAfter(deadline: .now() + 0.06) { [weak self, weak s] in
                guard let self, let s else { return }
                self.pollPty(s, myMarker: myMarker, deadline: deadline, completion: completion)
            }
        }

        /// 传输活性探测：**必须独立于交互 PTY**——PTY 可能正被慢命令占着（探针在
        /// stdin 排队等不到 marker），会把活连接误判成僵死而误杀。OpenSSH 会话用
        /// 进程 exec：经 ControlMaster 复用已认证连接（master 由交互会话常驻），
        /// 零重新认证；NIO 走同连接子通道，本就零认证成本。
        func probeResponsive(_ target: SSHSession, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
            target.exec("true", timeout: timeout, maxBytes: 0) { _, timedOut in
                completion(!timedOut)
            }
        }

        /// 确保 shell 已连接。并发调用在同一次重连上排队，绝不让第二个请求瞬时失败。
        func ensureConnected(creds: SSHCredentials, keyNeedsOpenSSH: Bool,
                             onReady: @escaping (Bool) -> Void) {
            stateLock.lock()
            if connectedState {
                stateLock.unlock()
                onReady(true)
                return
            }
            // 连接失败冷却：刚失败过的主机不立刻重新认证（防 agent 高频重试触发爆破封禁）。
            if Date().timeIntervalSince(lastConnectFailAt) < Self.connectCooldown {
                stateLock.unlock()
                Log.warn("连接冷却中（距上次失败不足 \(Int(Self.connectCooldown))s），本次不重新认证", "ssh")
                onReady(false)
                return
            }
            reconnectWaiters.append(onReady)
            if reconnectingState {
                stateLock.unlock()
                return
            }
            reconnectingState = true
            let old = ssh
            connectedState = false
            ptyMarker = nil; ptyCapture = ""; ptyBusy = false
            interactiveProbeInFlight = false
            interactiveProbeGeneration &+= 1
            lastInboundAt = .distantPast
            lastWriteAt = .distantPast
            probeConfirmedSinceWrite = true
            let newSsh: SSHSession = keyNeedsOpenSSH ? OpenSSHSession() : NIOSSHSession()
            ssh = newSsh
            newSsh.delegate = self
            // 无头桥：回调走 IO 线程，不切主线程。否则有头 GUI 下 agent 请求共用 main queue，
            // GUI 一卡就拖住 connected 翻转与 poll → 「重连无响应」。见 SSHSession.deliversOnMainThread。
            newSsh.deliversOnMainThread = false
            stateLock.unlock()

            // 旧 transport 只异步收口；新连接不会阻塞调用线程。
            old.close()
            newSsh.connectAndOpenShell(creds, term: "xterm-256color", cols: 100, rows: 30)
            var waited = 0.0
            func poll() {
                if self.connected {
                    self.finishReconnect(true)
                    return
                }
                waited += 0.25
                if waited > 20 {
                    newSsh.close()
                    self.finishReconnect(false)
                    return
                }
                // 不依赖 GUI 主线程：无头桥的重连不能被 GUI 卡顿拖死。
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25, execute: poll)
            }
            poll()
        }

        private func finishReconnect(_ ok: Bool) {
            stateLock.lock()
            reconnectingState = false
            if ok { lastConnectFailAt = .distantPast } else { lastConnectFailAt = Date() }
            let waiters = reconnectWaiters
            reconnectWaiters.removeAll(keepingCapacity: false)
            stateLock.unlock()
            for waiter in waiters { waiter(ok) }
        }

        /// 记录一次 exec 结果；连续「超时且零输出」达到阈值后**先复核再断开**。
        /// 调用点：`bridgeExec` 的 exec completion（IO 线程）。
        /// - timedOut：exec 走满命令级 / createChannel 超时才为 true（正常返回即使空也是 false）。
        /// - hadOutput：本次 exec 收到过任何字节（tail -f 等持续产出会命中，用于清零不误杀）。
        /// 复核的原因：`timedOut && 空输出` 对「transport 僵死」和「活 transport 上的静默慢命令」
        /// （如 sleep 超过 timeout、慢编译静默段）不可区分。直接断开会丢掉用户的嵌套上下文
        /// （cd/sudo/tmux）。达阈值后用一条独立 6s `exec true` 探针复核：探针通过 → 只清
        /// 计数不动连接；探针也无响应 → 才判定僵死，翻 connected 并锁外 close 触发重连。
        func noteExecResult(timedOut: Bool, hadOutput: Bool) {
            var needsConfirm = false
            stateLock.lock()
            if timedOut && !hadOutput {
                staleExecStrikes += 1
            } else {
                staleExecStrikes = 0
            }
            if staleExecStrikes >= Self.staleExecStrikeLimit {
                staleExecStrikes = 0
                needsConfirm = true
            }
            let target: SSHSession? = needsConfirm ? ssh : nil
            stateLock.unlock()
            guard let target else { return }
            probeResponsive(target, timeout: Self.interactiveProbeTimeout) { [weak self, weak target] probeTimedOut in
                guard let self else { return }
                guard let target else { return }
                var victim: SSHSession?
                self.stateLock.lock()
                guard target === self.ssh else {
                    // 复核期间 transport 已被换掉（并发重连）：无需处理。
                    self.stateLock.unlock()
                    return
                }
                if probeTimedOut {
                    self.connectedState = false   // 让下一个 exec 的 ensureConnected 触发重连
                    if self.everOpenedShell && self.resetNotice == nil {
                        self.resetNotice = Self.contextResetNotice
                    }
                    victim = target
                }
                self.stateLock.unlock()
                if let victim {
                    Log.warn("exec/探针：连续 \(Self.staleExecStrikeLimit) 次空手超时且复核探针无响应，判定 SSH transport 僵死，主动断开触发重连", "ssh")
                    // 锁外 close：本地 close 立即触发交互通道 inactive → didCloseWith（幂等，connected 已置 false）。
                    victim.close()
                } else {
                    Log.info("exec/探针：连续空手超时后复核通过，transport 存活（静默慢命令），不断开", "ssh")
                }
            }
        }
    }

    private var sessions: [HeadlessSession] = []
    private var currentIndex: Int = -1
    /// 主线程互斥：桥请求在主线程路由，会话操作也在主线程完成。
    private let lock = NSLock()

    /// 无头进程退出回调：全部会话 close 后调用（App 退出）。由 AppDelegate 设置。
    var onShutdown: (() -> Void)?

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    // MARK: - BridgeHost

    func bridgeHosts() -> [[String: Any]] {
        HostStore().hosts.map { h in
            ["id": h.id, "name": h.display, "host": h.host,
             "port": h.port, "username": h.username, "group": h.group]
        }
    }

    func bridgeSessions() -> [[String: Any]] {
        withLock {
            sessions.enumerated().map { (i, s) in
                ["session": i, "title": s.title, "host": s.host.host,
                 "host_id": s.host.id, "username": s.host.username, "connected": s.connected,
                 // active 必须是「当前会话且仍连接」——死会话不得再报 active，
                 // 否则 agent 拿到 active:true disconnected:false 的误导状态反复重连。
                 "active": i == currentIndex && s.connected]
            }
        }
    }

    func bridgeConnect(hostId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        // 解析顺序：id → 地址 → 名称 → 唯一包含（agent 常传名字/IP，不只传内部 id）。
        let allHosts = HostStore().hosts
        guard let h = Host.match(hostId, in: allHosts) else {
            completion(.failure(NSError(domain: "PixShell", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "未找到主机「\(hostId)」。可按 id / 地址 / 名称 匹配；当前主机：\(Host.bridgeListing(allHosts))"]))); return
        }
        let hostId = h.id
        guard !h.isRdp && !h.isLocal else {
            completion(.failure(NSError(domain: "PixShell", code: 400,
                userInfo: [NSLocalizedDescriptionKey: "RDP/本机终端不能经桥连接"]))); return
        }
        // 复用：同主机已有活跃会话 → 直接返回，不重复建连/不重认证（持久化交互关键）。
        if let idx = withLock({ sessions.firstIndex { $0.host.id == hostId && $0.connected } }) {
            withLock { currentIndex = idx }
            completion(.success(["session": idx, "title": sessions[idx].title])); return
        }
        // 同主机已有**死**会话 → 原地重连（复用下标，不新增堆积）。
        // 否则每次 connect 都 append 新会话，死会话永不清理 → 数组无限膨胀
        // （用户实测 26 个会话 25 个 disconnected，agent 拿到 stale 下标反复 410）。
        if let idx = withLock({ sessions.firstIndex { $0.host.id == hostId } }) {
            let s = sessions[idx]
            withLock { currentIndex = idx }
            ensureSessionReady(s) { ok in
                if ok {
                    completion(.success(["session": idx, "title": s.title]))
                } else {
                    // 保留死会话，下一次 connect/exec 继续复用同一下标重试。
                    completion(.failure(NSError(domain: "PixShell", code: 504,
                        userInfo: [NSLocalizedDescriptionKey: "会话 \(idx) 重连失败（保留死会话待下次重试）"])))
                }
            }
            return
        }
        let pw = Keychain.password(for: h.id) ?? ""
        guard !pw.isEmpty || !h.keyPath.isEmpty else {
            completion(.failure(NSError(domain: "PixShell", code: 401,
                userInfo: [NSLocalizedDescriptionKey: "该主机没有保存的密码或私钥，请先在有头界面连接一次"]))); return
        }
        // 代理：主机配置 proxyId → ProxyStore 匹配（与 startSSH 一致）。
        let proxy = h.proxyId.isEmpty ? nil : ProxyStore().list().first { $0.id == h.proxyId }
        let creds = SSHCredentials(host: h.host, port: h.port, username: h.username,
                                   password: pw, keyPath: h.keyPath.isEmpty ? nil : h.keyPath,
                                   proxy: proxy)
        // NIO 无法加载 RSA/DSA/加密私钥 → 预检失败直接用系统 OpenSSH（与有头一致）。
        let keyNeedsOpenSSH = !h.keyPath.isEmpty && SSHPrivateKeyLoader.load(path: h.keyPath) == nil
        let sess = HeadlessSession(title: h.display, host: h, ssh: keyNeedsOpenSSH ? OpenSSHSession() : NIOSSHSession(), password: pw)
        let idx = withLock { () -> Int in
            sessions.append(sess)
            currentIndex = sessions.count - 1
            return sessions.count - 1
        }
        sess.currentSSH().delegate = sess
        // 无头桥：回调走 IO 线程（同 ensureConnected 重连路径），避免共用主线程被 GUI 卡顿拖死。
        sess.currentSSH().deliversOnMainThread = false
        sess.currentSSH().connectAndOpenShell(creds, term: "xterm-256color", cols: 100, rows: 30)
        // 等 shell 打开再回（与有头 bridgeConnect 的 poll 语义一致，最多 20s）。
        var waited = 0.0
        func poll() {
            if sess.connected {
                completion(.success(["session": idx, "title": sess.title])); return
            }
            waited += 0.25
            if waited > 20 {
                sess.markConnectFailed()
                sess.currentSSH().close()
                // 保留数组槽位，绝不 remove：session 是外部句柄，删除前项会让所有后续
                // session 编号整体漂移，造成 agent 复用旧号时命中另一台主机。
                completion(.failure(NSError(domain: "PixShell", code: 504,
                    userInfo: [NSLocalizedDescriptionKey: "连接超时（保留 session 编号，稍后可重试）"]))); return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25, execute: poll)
        }
        poll()
    }

    func bridgeWrite(session: Int, text: String) -> Bool {
        guard let s = withLock({ sessions.indices.contains(session) ? sessions[session] : nil }) else {
            return false
        }
        guard !s.hasPendingResetNotice(), s.connected else { return false }
        s.noteInteractiveWrite()
        s.currentSSH().send(Array(text.utf8))
        return true
    }

    func bridgeWrite(session: Int, text: String, completion: @escaping (Bool) -> Void) {
        guard let s = withLock({ sessions.indices.contains(session) ? sessions[session] : nil }) else {
            completion(false)
            return
        }
        s.enqueueOperation { [weak self, weak s] next in
            guard let self, let s else { completion(false); next(); return }
            if s.hasPendingResetNotice() {
                // 提示尚未被 screen 消费：先恢复 transport，但绝不吞掉/发送这次输入。
                self.ensureSessionReady(s) { _ in
                    completion(true)
                    next()
                }
                return
            }
            self.ensureSessionReady(s) { ok in
                guard ok else { completion(false); next(); return }
                // 重连期间可能刚产生了 resetNotice；调用方应先读取提示，再重发输入。
                if s.hasPendingResetNotice() {
                    completion(true)
                    next()
                    return
                }
                s.noteInteractiveWrite()
                s.currentSSH().send(Array(text.utf8))
                completion(true)
                next()
            }
        }
    }

    /// 获取凭据并把重连请求合并到同一个 HeadlessSession 的等待队列。
    private func ensureSessionReady(_ s: HeadlessSession, done: @escaping (Bool) -> Void) {
        let h = s.host
        let pw = s.password.isEmpty ? (Keychain.password(for: h.id) ?? "") : s.password
        guard !pw.isEmpty || !h.keyPath.isEmpty else {
            done(false)
            return
        }
        let proxy = h.proxyId.isEmpty ? nil : ProxyStore().list().first { $0.id == h.proxyId }
        let creds = SSHCredentials(host: h.host, port: h.port, username: h.username,
                                   password: pw, keyPath: h.keyPath.isEmpty ? nil : h.keyPath,
                                   proxy: proxy)
        let keyNeedsOpenSSH = !h.keyPath.isEmpty && SSHPrivateKeyLoader.load(path: h.keyPath) == nil
        s.ensureConnected(creds: creds, keyNeedsOpenSSH: keyNeedsOpenSSH, onReady: done)
    }

    func bridgeExec(session: Int, cmd: String, completion: @escaping (String) -> Void) {
        bridgeExec(session: session, cmd: cmd, timeout: 30, maxBytes: 0) { out, _ in completion(out) }
    }

    func bridgeExec(session: Int, cmd: String, timeout: Double, maxBytes: Int,
                    completion: @escaping (String, Bool) -> Void) {
        guard let s = withLock({ sessions.indices.contains(session) ? sessions[session] : nil }) else {
            completion("", false)
            return
        }
        s.enqueueOperation { [weak self, weak s] next in
            guard let self, let s else { completion("", false); next(); return }
            self.ensureSessionReady(s) { ok in
                guard ok else { completion("", false); next(); return }
                let runner = s.currentSSH()
                if runner is OpenSSHSession {
                    // 真人模式：OpenSSH 回落会话的 exec 走交互 PTY——不另起 ssh 进程
                    // 重新认证（防爆破封禁关键路径），cd/env 状态跨命令延续。
                    s.execViaPTY(runner, cmd, timeout: timeout, maxBytes: maxBytes) { out, timedOut in
                        s.noteExecResult(timedOut: timedOut, hadOutput: !out.isEmpty)
                        completion(out, timedOut)
                        next()
                    }
                } else {
                    runner.exec(cmd, timeout: timeout, maxBytes: maxBytes) { out, timedOut in
                        s.noteExecResult(timedOut: timedOut, hadOutput: !out.isEmpty)
                        completion(out, timedOut)
                        next()
                    }
                }
            }
        }
    }

    func bridgeScreen(session: Int, lines: Int) -> String {
        guard let s = withLock({ sessions.indices.contains(session) ? sessions[session] : nil }) else {
            return ""
        }
        s.maybeProbeInteractiveLiveness()
        return s.recentOutput(lines: lines)
    }

    // MARK: - SFTP（独立 SFTP 连接，复用 SFTPService 零 UI 层）

    private func sftp(for session: Int, completion: @escaping (Result<(SFTPService, String), Error>) -> Void) {
        withLock {
            guard sessions.indices.contains(session) else {
                completion(.failure(NSError(domain: "PixShell", code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "会话不存在"]))); return
            }
            let s = sessions[session]
            let proxy = s.host.proxyId.isEmpty ? nil : ProxyStore().find(s.host.proxyId)
            let creds = SSHCredentials(host: s.host.host, port: s.host.port, username: s.host.username,
                                       password: s.password, keyPath: s.host.keyPath.isEmpty ? nil : s.host.keyPath,
                                       proxy: proxy)
            // 三层回落（NIO → 系统 ssh sftp → SCP+shell）：Dropbear 等无 sftp-server
            // 的目标也能列目录/传文件（对齐 win 端与 GUI 面板）。
            let keyIncompatible = !s.host.keyPath.isEmpty && SSHPrivateKeyLoader.load(path: s.host.keyPath) == nil
            SFTPBackend.connect(creds: creds, skipNIO: keyIncompatible) { r in
                switch r {
                case .failure(let e): completion(.failure(e))
                case .success(let svc): completion(.success((svc, s.password)))
                }
            }
        }
    }

    func bridgeSFTPList(session: Int, path: String, completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
        sftp(for: session) { r in
            switch r {
            case .failure(let e): completion(.failure(e))
            case .success(let pair):
                let svc = pair.0
                svc.listDirectory(path) { lr in
                    switch lr {
                    case .failure(let e): completion(.failure(e)); svc.close()
                    case .success(let entries):
                        completion(.success(entries.map { e in
                            ["name": e.name, "isDir": e.isDir, "size": Int(e.size),
                             "mtime": ISO8601DateFormatter().string(from: e.mtime)]
                        }))
                        svc.close()
                    }
                }
            }
        }
    }

    func bridgeSFTPDownload(session: Int, remote: String, local: String, completion: @escaping (Result<String, Error>) -> Void) {
        sftp(for: session) { r in
            switch r {
            case .failure(let e): completion(.failure(e))
            case .success(let pair):
                let svc = pair.0
                svc.download(remote: remote, local: local) { dr in
                    switch dr {
                    case .failure(let e): completion(.failure(e))
                    case .success: completion(.success(local))
                    }
                    svc.close()
                }
            }
        }
    }

    func bridgeSFTPUpload(session: Int, local: String, remote: String, completion: @escaping (Result<String, Error>) -> Void) {
        sftp(for: session) { r in
            switch r {
            case .failure(let e): completion(.failure(e))
            case .success(let pair):
                let svc = pair.0
                svc.upload(local: local, remote: remote) { ur in
                    switch ur {
                    case .failure(let e): completion(.failure(e))
                    case .success: completion(.success(remote))
                    }
                    svc.close()
                }
            }
        }
    }

    // MARK: - 关闭

    /// 有头接管：`POST /v1/app/shutdown` 到达时关闭全部会话并退出让位。
    func bridgeShutdown() {
        closeAll()
    }

    /// 关闭全部会话并触发退出回调（有头接管 / 无头自然退出用）。
    func closeAll() {
        let all = withLock { () -> [SSHSession] in
            let list = sessions.map { $0.currentSSH() }
            sessions.removeAll()
            currentIndex = -1
            return list
        }
        for s in all { s.close() }
        onShutdown?()
    }
}

/// 让 HeadlessSession 直接当自己的 SSHSessionDelegate：收字节进缓冲、记录打开/关闭。
extension HeadlessBridgeHost.HeadlessSession: SSHSessionDelegate {
    func sshSession(_ s: SSHSession, didReceive data: [UInt8]) {
        // 字节级拼接：8KB 读块边界常切在多字节 UTF-8 序列中间，整块 String(bytes:)
        // 会直接丢 8KB（中文画面缺段、marker 落坏块则 PTY exec 假超时）。把残缺
        // 尾部（≤4 字节）留给下一块拼接；整块都解不动（二进制流）才走有损解码。
        var combined = pendingTail + data
        pendingTail = []
        var text = ""
        if let decoded = String(bytes: combined, encoding: .utf8) {
            text = decoded
        } else {
            for drop in 1...4 where combined.count - drop > 0 {
                if let decoded = String(bytes: combined[0..<(combined.count - drop)], encoding: .utf8) {
                    text = decoded
                    pendingTail = Array(combined[(combined.count - drop)...])
                    break
                }
            }
            if text.isEmpty {
                text = String(decoding: combined, as: UTF8.self)
                pendingTail = []
            }
        }
        if !text.isEmpty { appendOutput(text, from: s) }
    }
    func sshSession(_ s: SSHSession, didCloseWith error: Error?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard s === ssh else { return }
        let wasConnected = connectedState
        connectedState = false
        output = ""
        if everOpenedShell && wasConnected && resetNotice == nil {
            resetNotice = Self.contextResetNotice
        }
        interactiveProbeInFlight = false
        interactiveProbeGeneration &+= 1
        lastInboundAt = .distantPast
        lastWriteAt = .distantPast
        probeConfirmedSinceWrite = true
        ptyMarker = nil; ptyCapture = ""; ptyBusy = false
    }
    func sshSessionDidOpenShell(_ s: SSHSession) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard s === ssh else { return }
        connectedState = true
        everOpenedShell = true
        lastInboundAt = Date()
        lastWriteAt = .distantPast
        interactiveProbeInFlight = false
        probeConfirmedSinceWrite = true
    }
}
