import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import CryptoKit

/// swift-nio-ssh 实现的交互式 PTY shell 会话。
/// 链路：ClientBootstrap 连接 → NIOSSHHandler(client) 握手(私钥/密码认证 + 接受所有 host key)
/// → createChannel 建 session 子通道 → 发 PseudoTerminalRequest + ShellRequest
/// → SSHChannelData 收发字节。所有 delegate 回调切主线程。
/// 认证：优先私钥（Host.keyPath 配置且能解析成功时），失败/未配置则回退密码——见 SSHUserAuthDelegate。
///
/// **算法能力（库硬限制，应用层无法再扩）**：
/// - 加密：`aes256-gcm@openssh.com` / `aes128-gcm@openssh.com`（`Constants.bundledTransportProtectionSchemes`）
/// - KEX：curve25519-sha256(+@libssh.org) / ecdh-sha2-nistp{256,384,521}
/// - HostKey：ssh-ed25519 / ecdsa-sha2-nistp{256,384,521}（**无 RSA/DSS/DH-group**）
/// 老设备（RSA host key + aes-ctr + dh-group*）会在 shell 打开前协商失败，由上层回落到
/// `OpenSSHSession`（系统 `/usr/bin/ssh` 最大兼容参数）。
public final class NIOSSHSession: SSHSession {
    public weak var delegate: SSHSessionDelegate?

    /// 事件回调投递线程开关：true（默认，UI 会话）走主线程供 SwiftTerm 直接用；
    /// false（无头/桥会话）直接在 NIO event loop 线程回调，让 `connected` 翻转与后台 poll
    /// 彻底脱离主线程/GUI 卡顿 ——「重连无响应 / 连接死掉」的直接根因。桥的 delegate
    /// （HeadlessSession）内部自带锁，IO 线程回调安全。
    public var deliversOnMainThread: Bool = true

    /// exec 命令级总超时（秒）。远端命令不退出（tail -f / 挂起 / 网络黑洞）时兜底收口，
    /// 避免 completion 永不回调 → HTTP 永不返回 → 后续工具调用排队超时。
    static let execTimeout: TimeInterval = 30

    private var group: EventLoopGroup?
    private var tcpChannel: Channel?
    private var childChannel: Channel?

    /// 这三个引用跨线程读写（event loop 写、调用线程/桥线程读），裸访问是 Swift 内存
    /// 模型下的数据竞争 UB（arm64e 撕裂指针即崩溃）。所有读写经此锁的短临界区完成；
    /// channel 的实际 IO 操作（write/close）留锁外，本来就 hop 回各自 eventLoop。
    private let channelStateLock = NSLock()
    private func setTCPChannel(_ c: Channel?) {
        channelStateLock.lock(); tcpChannel = c; channelStateLock.unlock()
    }
    private func setChildChannel(_ c: Channel?) {
        channelStateLock.lock(); childChannel = c; channelStateLock.unlock()
    }
    private func currentTCPChannel() -> Channel? {
        channelStateLock.lock(); defer { channelStateLock.unlock() }; return tcpChannel
    }
    private func currentChildChannel() -> Channel? {
        channelStateLock.lock(); defer { channelStateLock.unlock() }; return childChannel
    }
    private func takeGroupAndChannels() -> (EventLoopGroup?, Channel?, Channel?) {
        channelStateLock.lock(); defer { channelStateLock.unlock() }
        let g = group; group = nil
        return (g, tcpChannel, childChannel)
    }

    public init() {}

    public func connectAndOpenShell(_ creds: SSHCredentials, term: String, cols: Int, rows: Int) {
        Log.info("连接 \(creds.username)@\(creds.host):\(creds.port) term=\(term) \(cols)x\(rows)", "ssh")
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        channelStateLock.lock(); self.group = group; channelStateLock.unlock()

        let authDelegate = SSHUserAuthDelegate(username: creds.username, password: creds.password, keyPath: creds.keyPath)
        // 显式挂上库内全部 transport protection（当前仅 AES-GCM 两档）。
        // KEX / HostKey 列表由 NIOSSH 内部写死，无法在 ClientConfiguration 再扩。
        // SSHClientConfiguration / NIOSSHHandler 非 Sendable；NIO 回调跨线程只读传递，用 box 消警告。
        let clientConfig = NIOSSHClientConfigBox(SSHClientConfiguration(
            userAuthDelegate: authDelegate,
            serverAuthDelegate: AcceptAllHostKeysDelegate(),
            transportProtectionSchemes: Constants.bundledTransportProtectionSchemes
        ))

        // 代理：ssh-jump(跳板机) 本版本未实现真正的跳板逻辑——退化为直连，只记一条警告，
        // 绝不假装能走通导致连接卡死。见 Proxy/ProxyConfig.swift 里 ProxyType.sshJump 的注释。
        var proxy = creds.proxy
        if let p = proxy, p.type == .sshJump {
            Log.warn("代理「\(p.name)」类型为 ssh-jump(跳板机)，当前版本未实现，跳过代理直接连接 \(creds.host):\(creds.port)", "proxy")
            proxy = nil
        }

        if let proxy, !proxy.host.isEmpty {
            connectViaProxy(proxy, creds: creds, group: group, clientConfig: clientConfig, term: term, cols: cols, rows: rows)
        } else {
            connectDirect(creds, group: group, clientConfig: clientConfig, term: term, cols: cols, rows: rows)
        }
    }

    /// 无代理：老的直连路径，字节不动——bootstrap 的 channelInitializer 里直接装 NIOSSHHandler。
    private func connectDirect(_ creds: SSHCredentials, group: EventLoopGroup,
                                clientConfig: NIOSSHClientConfigBox, term: String, cols: Int, rows: Int) {
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // TCP_NODELAY：交互式 shell 小包立即发，别被 Nagle 攒着（局域网体感延迟）
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(12))
            // 半开连接探测：静默断网（无 FIN/RST）时 OS 默认 2 小时才检测，connected 长期为 true，
            // exec/type_text 全部静默失败（会话"active 但 disconnected"的 Phase-A 根因）。
            // 开 SO_KEEPALIVE + 30s 探测间隔 + 3 次重探（对齐 OpenSSH ServerAliveInterval=30）。
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_KEEPALIVE), value: 30_000)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_KEEPINTVL), value: 10)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_KEEPCNT), value: 3)
            .channelInitializer { channel in
                // NIOSSHHandler 库侧标记 Sendable unavailable；用 syncOperations 在本 event loop 同步装，避开 @Sendable 捕获。
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(
                            role: .client(clientConfig.value),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                    )
                }
            }

        // macOS 15+ 本地网络隐私偶发把首连打成 EHOSTUNREACH(65)；短延迟重试一次，
        // 仍失败则 emitClose，上层会归类为 network 并保留钥匙串。
        func attemptConnect(remaining: Int) {
            bootstrap.connect(host: creds.host, port: creds.port).whenComplete { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .failure(let error):
                    let msg = "\(error)"
                    let noRoute = msg.contains("No route to host")
                        || msg.contains("errno: 65")
                        || msg.lowercased().contains("host is down")
                    if noRoute && remaining > 0 {
                        Log.warn("TCP 连接 \(creds.host):\(creds.port) 暂不可达（可能是本地网络权限），\(remaining) 次重试… → \(error)", "ssh")
                        group.next().scheduleTask(in: .milliseconds(350)) {
                            attemptConnect(remaining: remaining - 1)
                        }
                        return
                    }
                    Log.error("TCP 连接失败 \(creds.host):\(creds.port) → \(error)", "ssh")
                    self.emitClose(error)
                case .success(let channel):
                    self.setTCPChannel(channel)
                    self.openShell(on: channel, term: term, cols: cols, rows: rows)
                }
            }
        }
        attemptConnect(remaining: 2)
    }

    /// 有代理：先 TCP 连到代理，再在裸 TCP 通道上跑对应协议握手把隧道打通，
    /// 隧道建立后才在**同一个 channel** 上装 NIOSSHHandler，继续走跟直连一样的 openShell 流程。
    private func connectViaProxy(_ proxy: ProxyConfig, creds: SSHCredentials, group: EventLoopGroup,
                                  clientConfig: NIOSSHClientConfigBox, term: String, cols: Int, rows: Int) {
        Log.info("经代理 \(proxy.type.rawValue) \(proxy.host):\(proxy.port) 连接 \(creds.host):\(creds.port)", "proxy")
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        bootstrap.connect(host: proxy.host, port: proxy.port).whenComplete { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                Log.error("代理 TCP 连接失败 \(proxy.host):\(proxy.port) → \(error)", "proxy")
                self.emitClose(error)
            case .success(let channel):
                self.setTCPChannel(channel)
                self.performProxyHandshake(proxy, on: channel, creds: creds, clientConfig: clientConfig,
                                            term: term, cols: cols, rows: rows)
            }
        }
    }

    private func performProxyHandshake(_ proxy: ProxyConfig, on channel: Channel, creds: SSHCredentials,
                                        clientConfig: NIOSSHClientConfigBox, term: String, cols: Int, rows: Int) {
        let promise = channel.eventLoop.makePromise(of: ByteBuffer.self)
        let handler: ChannelHandler & RemovableChannelHandler
        switch proxy.type {
        case .socks5:
            handler = SOCKS5ProxyHandler(destHost: creds.host, destPort: creds.port,
                                          username: proxy.username, password: proxy.password, promise: promise)
        case .socks4:
            handler = SOCKS4ProxyHandler(destHost: creds.host, destPort: creds.port,
                                          userId: proxy.username, promise: promise)
        case .http:
            handler = HTTPConnectProxyHandler(destHost: creds.host, destPort: creds.port,
                                               username: proxy.username, password: proxy.password, promise: promise)
        case .sshJump:
            // 上层 connectAndOpenShell 已经把 sshJump 过滤掉了，这里只是防御性兜底，绝不静默挂起。
            Log.error("内部错误：ssh-jump 不应该进入代理握手路径", "proxy")
            channel.close(promise: nil)
            emitClose(ProxyDialError.unsupportedProxyType("ssh-jump"))
            return
        }

        channel.pipeline.addHandler(handler).flatMap {
            promise.futureResult
        }.whenComplete { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                Log.error("代理握手失败 \(proxy.host):\(proxy.port) → \(error)", "proxy")
                self.emitClose(error)
            case .success(let leftover):
                Log.info("代理握手成功: \(proxy.type.rawValue) \(proxy.host):\(proxy.port) → 隧道已建立，继续 SSH 握手", "proxy")
                // syncOperations：在本 event loop 同步装 NIOSSHHandler，避开 Sendable 不可用警告。
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(
                            role: .client(clientConfig.value),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                    )
                }.whenComplete { result in
                    switch result {
                    case .failure(let error):
                        self.emitClose(error)
                    case .success:
                        // 代理服务器可能把 CONNECT 回执和目标服务器首包数据粘在同一个 TCP 包里发过来，
                        // 这部分字节在握手阶段已经被代理处理器缓冲下来，这里补投进新装的 SSH handler。
                        if leftover.readableBytes > 0 {
                            channel.pipeline.fireChannelRead(leftover)
                            channel.pipeline.fireChannelReadComplete()
                        }
                        self.openShell(on: channel, term: term, cols: cols, rows: rows)
                    }
                }
            }
        }
    }

    private func openShell(on channel: Channel, term: String, cols: Int, rows: Int) {
        let shellHandler = ShellChannelHandler(
            term: term, cols: cols, rows: rows,
            onData: { [weak self] bytes in self?.emitData(bytes) },
            onOpen: { [weak self] in self?.emitOpen() },
            onClose: { [weak self] err in self?.emitClose(err) }
        )
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
            switch result {
            case .failure(let error):
                self.emitClose(error)
            case .success(let sshHandler):
                sshHandler.createChannel(promise) { childChannel, channelType in
                    guard channelType == .session else {
                        return childChannel.eventLoop.makeFailedFuture(SSHClientError.invalidChannelType)
                    }
                    return childChannel.pipeline.addHandler(shellHandler)
                }
            }
        }
        promise.futureResult.whenComplete { [weak self] result in
            switch result {
            case .failure(let error): self?.emitClose(error)
            case .success(let child): self?.setChildChannel(child)
            }
        }
    }

    public func send(_ data: [UInt8]) {
        guard let child = currentChildChannel() else { return }
        child.eventLoop.execute {
            var buffer = child.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let sshData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            child.writeAndFlush(sshData, promise: nil)
        }
    }

    public func resize(cols: Int, rows: Int) {
        guard let child = currentChildChannel() else { return }
        child.eventLoop.execute {
            let event = SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: cols, terminalRowHeight: rows,
                terminalPixelWidth: 0, terminalPixelHeight: 0
            )
            child.triggerUserOutboundEvent(event, promise: nil)
        }
    }

    public func exec(_ command: String, completion: @escaping (String) -> Void) {
        exec(command, timeout: Self.execTimeout, maxBytes: 0) { out, _ in completion(out) }
    }

    public func exec(_ command: String, timeout: TimeInterval, maxBytes: Int,
                     completion: @escaping (String, Bool) -> Void) {
        let completionLock = NSLock()
        var completed = false
        func finish(_ output: String, _ timedOut: Bool) {
            completionLock.lock()
            guard !completed else { completionLock.unlock(); return }
            completed = true
            completionLock.unlock()
            // 与事件回调同源：桥会话下 exec completion 若走 main，GUI 卡顿会拖住结果写回
            // HTTP + 操作队列 next() 推进 → 「exec 无响应」。deliver 让无头会话直接在 IO 线程收口。
            deliver { completion(output, timedOut) }
        }
        guard let channel = currentTCPChannel() else { finish("", false); return }
        // 命令级总超时：远端命令不退出时兜底收口，避免 HTTP 永挂 → 后续工具调用排队超时。
        let handler = ExecCollectHandler(command: command, timeout: timeout, maxBytes: maxBytes) { out, timedOut in
            finish(out, timedOut)
        }
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        // 建通道独立超时(≤15s)：half-open TCP 时 createChannel 的 promise 可能既不 succeed
        // 也不 fail（whenFailure 永不触发）→ completion 永挂 → 同一 session 操作队列堵死、
        // 后续 exec/type 全部排队超时（「连接死掉 / 重连无响应」的直接根因之一）。定时器到点
        // 收口(timedOut=true)让队列的 next() 得以推进；正常命令的超时仍由 ExecCollectHandler 负责。
        let channelDeadline = min(max(timeout, 1), 15)
        let timeoutTask = channel.eventLoop.scheduleTask(in: .milliseconds(Int64(channelDeadline * 1000))) {
            finish("", true)
        }
        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
            switch result {
            case .failure:
                finish("", false)
            case .success(let sshHandler):
                sshHandler.createChannel(promise) { childChannel, channelType in
                    guard channelType == .session else {
                        return childChannel.eventLoop.makeFailedFuture(SSHClientError.invalidChannelType)
                    }
                    return childChannel.pipeline.addHandler(handler)
                }
            }
        }
        promise.futureResult.whenComplete { result in
            timeoutTask.cancel()   // 建通道已定论：撤掉建通道定时器，命令级超时交给 ExecCollectHandler
            switch result {
            case .failure:
                finish("", false)
            case .success(let child):
                // 已因建通道超时收口 → 关掉迟到建成的子通道，防泄漏（幂等锁挡住二次 finish）。
                completionLock.lock(); let already = completed; completionLock.unlock()
                if already { child.close(promise: nil) }
            }
        }
    }

    public func close() {
        // 锁内一次性取走三个引用快照；close 留在锁外（channel close 本身 hop 回 eventLoop）。
        let (g, tcp, child) = takeGroupAndChannels()
        child?.close(promise: nil)
        tcp?.close(promise: nil)
        // 异步关 EventLoopGroup：syncShutdownGracefully 会等所有 pending IO 收尾，
        // 在慢网络/挂起连接下阻塞主线程数百 ms 到数秒（关闭标签/切会话时 UI 卡顿 P0 根因）。
        // 改回调式：立即返回，event loop 在后台自然收口。
        if let g {
            DispatchQueue.global(qos: .utility).async {
                g.shutdownGracefully { _ in }
            }
        }
    }

    // MARK: - 事件回调投递
    /// 按 `deliversOnMainThread` 选择投递线程：true（UI 会话）切主线程供 SwiftTerm 直接用；
    /// false（无头/桥会话）直接在 NIO event loop 线程回调，让 `connected` 翻转与后台 poll
    /// 脱离主线程/GUI 卡顿。桥的 delegate 内部自带锁，IO 线程回调安全。
    private func deliver(_ block: @escaping () -> Void) {
        if deliversOnMainThread {
            DispatchQueue.main.async(execute: block)
        } else {
            block()
        }
    }
    private func emitData(_ bytes: [UInt8]) {
        deliver { self.delegate?.sshSession(self, didReceive: bytes) }
    }
    private func emitOpen() {
        Log.info("shell 已打开", "ssh")
        deliver { self.delegate?.sshSessionDidOpenShell(self) }
    }
    private func emitClose(_ error: Error?) {
        // Dropbear/OpenWrt 等无 AES-GCM 时，NIO 常在 shell 打开前以裸 EOF 断连。
        // 包装成带 algorithm 语义的错误，方便上层 looksLikeAlgorithmMismatch 命中并回落 OpenSSH，
        // 避免被当成认证失败清密码。
        let out: Error?
        if let e = error {
            let s = "\(e) \(e.localizedDescription)".lowercased()
            if s.contains("end of file") || s.trimmingCharacters(in: .whitespacesAndNewlines) == "end of file" {
                out = NSError(
                    domain: "PixShell.nio-ssh",
                    code: 1001,
                    userInfo: [NSLocalizedDescriptionKey:
                        "SSH 算法协商失败（End of file）：对端可能仅支持 chacha20/aes-ctr，内置 NIO 仅 AES-GCM"]
                )
                Log.warn("连接关闭(异常→算法协商): \(e)", "ssh")
            } else {
                out = e
                Log.warn("连接关闭(异常): \(e)", "ssh")
            }
        } else {
            out = nil
            Log.info("连接关闭", "ssh")
        }
        deliver { self.delegate?.sshSession(self, didCloseWith: out) }
    }
}

enum SSHClientError: Error { case invalidChannelType }

/// 一次性 exec：发 ExecRequest，收集 stdout 直到通道关闭，回调完整输出。
/// 含命令级总超时：远端命令不退出（tail -f / 挂起 / 网络黑洞）时定时兜底收口，
/// 否则 completion 永不回调 → HTTP 永不返回 → 下一个工具调用排队超时（P0 根因）。
final class ExecCollectHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    private let command: String
    private let onDone: (String, Bool) -> Void
    private let timeout: TimeInterval
    private let maxBytes: Int
    private var buffer = ""
    private var done = false
    /// 记录是否因超时收口（区别于正常通道关闭），供上层区分。
    private(set) var timedOut = false
    /// 保存 context 以便超时主动 close 子通道。
    private var context: ChannelHandlerContext?
    init(command: String, timeout: TimeInterval, maxBytes: Int = 0,
         onDone: @escaping (String, Bool) -> Void) {
        self.command = command; self.timeout = timeout
        self.maxBytes = maxBytes; self.onDone = onDone
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
        // 命令级总超时：到期强制收口，避免 completion 永不回调。
        let amount = TimeAmount.seconds(Int64(timeout))
        context.eventLoop.scheduleTask(in: amount) { [weak self] in
            self?.finish(timedOut: true)
        }
    }
    func channelActive(context: ChannelHandlerContext) {
        let req = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(req, promise: nil)
        context.fireChannelActive()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let d = unwrapInboundIn(data)
        guard case .byteBuffer(let buf) = d.data else { return }
        if d.type == .channel, let s = buf.getString(at: buf.readerIndex, length: buf.readableBytes) {
            buffer += s
            // 输出上限：防止 cat 大文件/yes 这类命令攒出 GB 级内存 OOM 杀进程。
            // 到上限即收口（不再等待通道关闭），保证 completion 必然回调。
            if maxBytes > 0, buffer.count >= maxBytes {
                finish(timedOut: false)
            }
        }
    }
    func channelInactive(context: ChannelHandlerContext) { finish() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { finish(); context.close(promise: nil) }
    private func finish(timedOut: Bool = false) {
        if !done {
            done = true
            self.timedOut = timedOut
            if timedOut {
                // 超时收口：主动关掉子通道，避免资源悬挂。
                self.context?.close(promise: nil)
                Log.warn("exec 命令超时被强制收口（\(Int(timeout))s）：\(command.prefix(80))", "ssh")
            }
            onDone(buffer, self.timedOut)
        }
    }
}

/// 认证委托：依次尝试私钥、密码。
/// 顺序：keyPath 配置且解析成功 → 先offer私钥；被拒或未配置/解析失败 → 退回密码（如果有）。
/// 每种方式只提交一次——被拒即干净失败，不重试，避免反复尝试触发服务器端账号锁定。
final class SSHUserAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String?
    private let privateKey: NIOSSHPrivateKey?
    private var offeredKey = false
    private var offeredPassword = false

    init(username: String, password: String?, keyPath: String?) {
        self.username = username
        self.password = (password?.isEmpty == false) ? password : nil
        if let keyPath, !keyPath.isEmpty {
            self.privateKey = SSHPrivateKeyLoader.load(path: keyPath)
        } else {
            self.privateKey = nil
        }
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // 第一轮：有私钥且服务器支持 publickey → offer 私钥（只一次）。
        if let key = privateKey, !offeredKey {
            offeredKey = true
            if availableMethods.contains(.publicKey) {
                Log.info("尝试私钥认证 \(username)", "ssh")
                nextChallengePromise.succeed(
                    NIOSSHUserAuthenticationOffer(
                        username: username, serviceName: "",
                        offer: .privateKey(.init(privateKey: key))
                    )
                )
                return
            }
            Log.warn("服务器不支持公钥认证，回退密码 \(username)", "ssh")
        }
        // 第二轮：密码（只一次）。
        if let pw = password, !offeredPassword {
            offeredPassword = true
            guard availableMethods.contains(.password) else {
                nextChallengePromise.succeed(nil)
                return
            }
            Log.info("尝试密码认证 \(username)", "ssh")
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username, serviceName: "",
                    offer: .password(.init(password: pw))
                )
            )
            return
        }
        // 两种方式都已用尽或都不可用 → 放弃，触发认证失败关闭。
        nextChallengePromise.succeed(nil)
    }
}

/// 从磁盘加载私钥文件并构造 NIOSSHPrivateKey。
/// 支持：OpenSSH 新格式（ssh-keygen 默认输出，ed25519 / ecdsa-sha2-nistp256/384/521，未加密）、
///      PKCS8 PEM（"BEGIN PRIVATE KEY"，ecdsa 系）。
/// 不支持（识别到即跳过，绝不崩溃、绝不阻塞密码路径）：RSA/DSA、加密私钥（需要口令）、
///      传统 SEC1 "BEGIN EC PRIVATE KEY" PEM。
enum SSHPrivateKeyLoader {
    static func load(path: String) -> NIOSSHPrivateKey? {
        guard !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded) else {
            Log.warn("私钥文件不存在或不可读: \(expanded)", "ssh")
            return nil
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            Log.warn("私钥文件不是有效文本: \(expanded)", "ssh")
            return nil
        }
        if text.contains("BEGIN OPENSSH PRIVATE KEY") {
            return parseOpenSSH(text, path: expanded)
        }
        if text.contains("BEGIN PRIVATE KEY") {
            return parsePKCS8PEM(text, path: expanded)
        }
        if text.contains("BEGIN RSA PRIVATE KEY") {
            Log.warn("私钥是传统 RSA PEM 格式，swift-nio-ssh 不支持 RSA，跳过公钥认证: \(expanded)", "ssh")
            return nil
        }
        if text.contains("BEGIN EC PRIVATE KEY") {
            Log.warn("私钥是传统 SEC1 EC PEM 格式，暂不支持（可用 ssh-keygen -p 转成新格式），跳过: \(expanded)", "ssh")
            return nil
        }
        if text.contains("BEGIN DSA PRIVATE KEY") {
            Log.warn("不支持 DSA 私钥，跳过公钥认证: \(expanded)", "ssh")
            return nil
        }
        if text.contains("BEGIN ENCRYPTED PRIVATE KEY") {
            Log.warn("私钥已加密（需要口令），暂不支持自动解密，跳过公钥认证: \(expanded)", "ssh")
            return nil
        }
        Log.warn("无法识别的私钥格式: \(expanded)", "ssh")
        return nil
    }

    // MARK: - OpenSSH 新格式（"openssh-key-v1"）

    private static func parseOpenSSH(_ text: String, path: String) -> NIOSSHPrivateKey? {
        let b64 = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        guard let raw = Data(base64Encoded: b64) else {
            Log.warn("私钥 base64 解码失败: \(path)", "ssh")
            return nil
        }
        let bytes = [UInt8](raw)
        let magic = Array("openssh-key-v1\0".utf8)
        guard bytes.count > magic.count, Array(bytes[0..<magic.count]) == magic else {
            Log.warn("私钥缺少 OpenSSH 魔数: \(path)", "ssh")
            return nil
        }
        var r = ByteReader(Array(bytes[magic.count...]))
        guard let cipherBytes = r.readString(), let kdfBytes = r.readString(), r.readString() != nil,
              let nkeys = r.readUInt32(), nkeys >= 1 else {
            Log.warn("私钥格式解析失败(header): \(path)", "ssh")
            return nil
        }
        let cipher = String(bytes: cipherBytes, encoding: .utf8) ?? ""
        let kdf = String(bytes: kdfBytes, encoding: .utf8) ?? ""
        guard cipher == "none", kdf == "none" else {
            Log.warn("私钥已加密（需要口令），暂不支持自动解密，跳过公钥认证: \(path)", "ssh")
            return nil
        }
        for _ in 0..<nkeys {
            guard r.readString() != nil else {
                Log.warn("私钥格式解析失败(public keys): \(path)", "ssh")
                return nil
            }
        }
        guard let priv = r.readString() else {
            Log.warn("私钥格式解析失败(private section): \(path)", "ssh")
            return nil
        }
        var pr = ByteReader(priv)
        guard let c1 = pr.readUInt32(), let c2 = pr.readUInt32(), c1 == c2 else {
            Log.warn("私钥校验失败(可能已加密或已损坏): \(path)", "ssh")
            return nil
        }
        guard let keytypeBytes = pr.readString(), let keytype = String(bytes: keytypeBytes, encoding: .utf8) else {
            Log.warn("私钥缺少 key type 字段: \(path)", "ssh")
            return nil
        }
        switch keytype {
        case "ssh-ed25519":
            guard pr.readString() != nil, let sk = pr.readString(), sk.count == 64 else {
                Log.warn("ed25519 私钥字段异常: \(path)", "ssh")
                return nil
            }
            do {
                let seed = Array(sk[0..<32])
                let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
                Log.info("已加载 ed25519 私钥: \(path)", "ssh")
                return NIOSSHPrivateKey(ed25519Key: key)
            } catch {
                Log.warn("ed25519 私钥解析失败 \(path): \(error)", "ssh")
                return nil
            }
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            guard let curveBytes = pr.readString(), let curve = String(bytes: curveBytes, encoding: .utf8),
                  pr.readString() != nil, let dRaw = pr.readString() else {
                Log.warn("ecdsa 私钥字段异常: \(path)", "ssh")
                return nil
            }
            let fieldSize: Int
            switch curve {
            case "nistp256": fieldSize = 32
            case "nistp384": fieldSize = 48
            case "nistp521": fieldSize = 66
            default:
                Log.warn("不支持的 ECDSA 曲线 \(curve): \(path)", "ssh")
                return nil
            }
            var d = dRaw
            while d.count > fieldSize && d.first == 0 { d.removeFirst() }
            while d.count < fieldSize { d.insert(0, at: 0) }
            guard d.count == fieldSize else {
                Log.warn("ecdsa 私钥标量长度异常: \(path)", "ssh")
                return nil
            }
            do {
                switch curve {
                case "nistp256":
                    let key = try P256.Signing.PrivateKey(rawRepresentation: d)
                    Log.info("已加载 P256 私钥: \(path)", "ssh")
                    return NIOSSHPrivateKey(p256Key: key)
                case "nistp384":
                    let key = try P384.Signing.PrivateKey(rawRepresentation: d)
                    Log.info("已加载 P384 私钥: \(path)", "ssh")
                    return NIOSSHPrivateKey(p384Key: key)
                default: // nistp521
                    let key = try P521.Signing.PrivateKey(rawRepresentation: d)
                    Log.info("已加载 P521 私钥: \(path)", "ssh")
                    return NIOSSHPrivateKey(p521Key: key)
                }
            } catch {
                Log.warn("ECDSA 私钥解析失败 \(path): \(error)", "ssh")
                return nil
            }
        default:
            Log.warn("不支持的私钥类型 \(keytype)(如 RSA/DSA)，跳过公钥认证: \(path)", "ssh")
            return nil
        }
    }

    // MARK: - PKCS8 PEM("BEGIN PRIVATE KEY")：CryptoKit 原生支持，仅 ecdsa 系（ed25519 的 PKCS8 CryptoKit 无解析入口）。

    private static func parsePKCS8PEM(_ text: String, path: String) -> NIOSSHPrivateKey? {
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: text) {
            Log.info("已加载 P256 私钥(PEM): \(path)", "ssh")
            return NIOSSHPrivateKey(p256Key: key)
        }
        if let key = try? P384.Signing.PrivateKey(pemRepresentation: text) {
            Log.info("已加载 P384 私钥(PEM): \(path)", "ssh")
            return NIOSSHPrivateKey(p384Key: key)
        }
        if let key = try? P521.Signing.PrivateKey(pemRepresentation: text) {
            Log.info("已加载 P521 私钥(PEM): \(path)", "ssh")
            return NIOSSHPrivateKey(p521Key: key)
        }
        Log.warn("PEM 私钥解析失败(可能是 RSA/已加密/不支持的曲线): \(path)", "ssh")
        return nil
    }
}

/// SSH 二进制协议里的 "string"(uint32 长度前缀) / "uint32" 读取器，带边界检查，绝不越界崩溃。
private struct ByteReader {
    let data: [UInt8]
    var offset = 0
    init(_ d: [UInt8]) { data = d }

    mutating func readUInt32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let n = UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
        offset += 4
        return n
    }

    mutating func readString() -> [UInt8]? {
        guard let n = readUInt32() else { return nil }
        let len = Int(n)
        guard len >= 0, offset + len <= data.count else { return nil }
        let s = Array(data[offset..<offset + len])
        offset += len
        return s
    }
}

/// 接受所有主机公钥（后续可换成 known_hosts 校验）。
final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

/// 子通道处理器：开 PTY + shell，桥接字节收发。
final class ShellChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let term: String
    private let cols: Int
    private let rows: Int
    private let onData: ([UInt8]) -> Void
    private let onOpen: () -> Void
    private let onClose: (Error?) -> Void
    private var openSignalled = false

    init(term: String, cols: Int, rows: Int,
         onData: @escaping ([UInt8]) -> Void,
         onOpen: @escaping () -> Void,
         onClose: @escaping (Error?) -> Void) {
        self.term = term; self.cols = cols; self.rows = rows
        self.onData = onData; self.onOpen = onOpen; self.onClose = onClose
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelActive(context: ChannelHandlerContext) {
        // 请求 PTY
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: term,
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(ptyRequest).flatMap {
            // 再请求 shell
            let shellRequest = SSHChannelRequestEvent.ShellRequest(wantReply: true)
            return context.triggerUserOutboundEvent(shellRequest)
        }.whenComplete { [weak self] result in
            switch result {
            case .success:
                if let self = self, !self.openSignalled {
                    self.openSignalled = true
                    self.onOpen()
                }
            case .failure(let error):
                self?.onClose(error)
            }
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        if !bytes.isEmpty { onData(bytes) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClose(nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onClose(error)
        context.close(promise: nil)
    }
}
