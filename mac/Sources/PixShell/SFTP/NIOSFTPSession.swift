import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH

/// 基于 apple/swift-nio-ssh 自研的 SFTP v3 后端（零新依赖）。
///
/// 链路：ClientBootstrap 连接 → NIOSSHHandler(client) 握手（密码认证 + 接受所有 host key）
/// → createChannel 建 session 子通道 → SFTPChannelHandler 发 `subsystem "sftp"` 请求
/// → 发 SSH_FXP_INIT，收到 SSH_FXP_VERSION 即握手完成
/// → 之后所有操作按 request-id 关联收发 SFTP v3 报文。
///
/// 所有 completion 回调都切回主线程。文件读写（本地）在会话专属 EventLoop 上顺序执行。
public final class NIOSFTPSession: SFTPService {
    private var group: EventLoopGroup?
    private var tcpChannel: Channel?
    private var childChannel: Channel?
    private var handler: SFTPChannelHandler?

    public init() {}

    // MARK: - 连接与握手

    public func connect(_ creds: SSHCredentials, completion: @escaping (Result<Void, Error>) -> Void) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        // 认证与 SSH 通道**共用** SSHUserAuthDelegate：私钥优先 → 密码兜底，各只提交一次。
        // （之前这里只支持密码，导致「只配私钥」的主机 SSH 能连、SFTP 却连不上。）
        let hasPassword = !(creds.password ?? "").isEmpty
        let hasKey = !(creds.keyPath ?? "").isEmpty
        guard hasPassword || hasKey else {
            self.finishOnMain(completion, .failure(SFTPError.unsupportedAuth))
            return
        }
        let authDelegate = SSHUserAuthDelegate(username: creds.username,
                                               password: creds.password,
                                               keyPath: creds.keyPath)
        // 与 NIOSSHSession 一致：显式挂库内 transport（当前仅 AES-GCM）。
        // Dropbear/OpenWrt 无 GCM 时会在握手期失败，由 SFTPPanel 回落 OpenSSHSFTPSession。
        // SSHClientConfiguration / NIOSSHHandler 非 Sendable；NIO 回调跨线程只读传递，用 box 消警告。
        let clientConfig = NIOSSHClientConfigBox(SSHClientConfiguration(
            userAuthDelegate: authDelegate,
            serverAuthDelegate: SFTPAcceptAllHostKeysDelegate(),
            transportProtectionSchemes: Constants.bundledTransportProtectionSchemes
        ))

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                // NIOSSHHandler 库侧标记 Sendable unavailable；用 syncOperations 在本 event loop 同步装。
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

        bootstrap.connect(host: creds.host, port: creds.port).whenComplete { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.finishOnMain(completion, .failure(SFTPError.connectFailed("\(error)")))
            case .success(let channel):
                self.tcpChannel = channel
                self.openSFTP(on: channel, completion: completion)
            }
        }
    }

    private func openSFTP(on channel: Channel, completion: @escaping (Result<Void, Error>) -> Void) {
        let sftpHandler = SFTPChannelHandler(onClose: { [weak self] _ in
            // 通道关闭：清理引用（不必回调 UI，UI 通过各操作的 completion 感知错误）。
            self?.childChannel = nil
        })
        self.handler = sftpHandler
        // 握手完成回调：VERSION 到达时触发，切主线程返回。
        sftpHandler.onReady = { [weak self] result in
            self?.finishOnMain(completion, result)
        }

        let promise = channel.eventLoop.makePromise(of: Channel.self)
        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
            switch result {
            case .failure(let error):
                self.finishOnMain(completion, .failure(SFTPError.connectFailed("\(error)")))
            case .success(let sshHandler):
                sshHandler.createChannel(promise) { childChannel, channelType in
                    guard channelType == .session else {
                        return childChannel.eventLoop.makeFailedFuture(SFTPError.connectFailed("invalid channel type"))
                    }
                    return childChannel.pipeline.addHandler(sftpHandler)
                }
            }
        }
        promise.futureResult.whenComplete { [weak self] result in
            switch result {
            case .failure(let error):
                self?.finishOnMain(completion, .failure(SFTPError.connectFailed("\(error)")))
            case .success(let child):
                self?.childChannel = child
            }
        }
    }

    // MARK: - 目录 / 元数据操作

    public func listDirectory(_ path: String, completion: @escaping (Result<[SFTPEntry], Error>) -> Void) {
        withHandler(completion) { handler, channel in
            // OPENDIR → 反复 READDIR 直到 EOF → CLOSE
            handler.request(SFTP.OPENDIR) { $0.writeSFTPString(path) }
                .flatMap { resp -> EventLoopFuture<[SFTPName]> in
                    guard case .handle(let h) = resp else {
                        return channel.eventLoop.makeFailedFuture(SFTPError.unsupportedResponse)
                    }
                    return self.readDirLoop(handler, channel: channel, handle: h, acc: [])
                        .always { _ in _ = handler.request(SFTP.CLOSE) { $0.writeSFTPBytes(h) } }
                }
                .map { names -> [SFTPEntry] in
                    names.filter { $0.filename != "." && $0.filename != ".." }
                         .map { $0.toEntry() }
                }
        }
    }

    private func readDirLoop(_ handler: SFTPChannelHandler, channel: Channel,
                             handle: [UInt8], acc: [SFTPName]) -> EventLoopFuture<[SFTPName]> {
        handler.request(SFTP.READDIR) { $0.writeSFTPBytes(handle) }.flatMap { resp in
            switch resp {
            case .name(let names):
                return self.readDirLoop(handler, channel: channel, handle: handle, acc: acc + names)
            case .status(let code, let msg):
                if code == SFTP.FX_EOF { return channel.eventLoop.makeSucceededFuture(acc) }
                return channel.eventLoop.makeFailedFuture(SFTPError.status(code: code, message: msg))
            default:
                return channel.eventLoop.makeFailedFuture(SFTPError.unsupportedResponse)
            }
        }
    }

    public func makeDirectory(_ path: String, completion: @escaping (Result<Void, Error>) -> Void) {
        withHandler(completion) { handler, channel in
            handler.request(SFTP.MKDIR) { buf in
                buf.writeSFTPString(path)
                // ATTRS：设置权限 0755
                buf.writeInteger(SFTP.ATTR_PERMISSIONS, endianness: .big)
                buf.writeInteger(UInt32(0o755), endianness: .big)
            }.flatMap { self.expectOK($0, channel: channel) }
        }
    }

    public func remove(_ path: String, completion: @escaping (Result<Void, Error>) -> Void) {
        withHandler(completion) { handler, channel in
            // 先 STAT 判定是否目录，再选择 REMOVE / RMDIR
            handler.request(SFTP.STAT) { $0.writeSFTPString(path) }.flatMap { resp -> EventLoopFuture<Void> in
                let isDir: Bool
                if case .attrs(let a) = resp { isDir = a.isDir } else { isDir = false }
                let op = isDir ? SFTP.RMDIR : SFTP.REMOVE
                return handler.request(op) { $0.writeSFTPString(path) }
                    .flatMap { self.expectOK($0, channel: channel) }
            }
        }
    }

    public func rename(from: String, to: String, completion: @escaping (Result<Void, Error>) -> Void) {
        withHandler(completion) { handler, channel in
            handler.request(SFTP.RENAME) { buf in
                buf.writeSFTPString(from)
                buf.writeSFTPString(to)
            }.flatMap { self.expectOK($0, channel: channel) }
        }
    }

    public func realpath(_ path: String, completion: @escaping (Result<String, Error>) -> Void) {
        withHandler(completion) { handler, channel in
            handler.request(SFTP.REALPATH) { $0.writeSFTPString(path) }.flatMap { resp -> EventLoopFuture<String> in
                switch resp {
                case .name(let names) where !names.isEmpty:
                    return channel.eventLoop.makeSucceededFuture(names[0].filename)
                case .status(let code, let msg):
                    return channel.eventLoop.makeFailedFuture(SFTPError.status(code: code, message: msg))
                default:
                    return channel.eventLoop.makeFailedFuture(SFTPError.unsupportedResponse)
                }
            }
        }
    }

    public func home(completion: @escaping (Result<String, Error>) -> Void) {
        realpath(".", completion: completion)
    }

    // MARK: - 下载 / 上传

    public func download(remote: String, local: String, completion: @escaping (Result<Void, Error>) -> Void) {
        withHandler(completion) { handler, channel in
            // 建本地文件并打开写句柄
            FileManager.default.createFile(atPath: local, contents: nil)
            guard let fh = FileHandle(forWritingAtPath: local) else {
                return channel.eventLoop.makeFailedFuture(SFTPError.localFileError("cannot open local file for write: \(local)"))
            }
            // OPEN(read) → 循环 READ 写盘 → CLOSE
            return handler.request(SFTP.OPEN) { buf in
                buf.writeSFTPString(remote)
                buf.writeInteger(SFTP.FXF_READ, endianness: .big)
                buf.writeInteger(UInt32(0), endianness: .big)  // ATTRS flags = 0
            }.flatMap { resp -> EventLoopFuture<Void> in
                guard case .handle(let h) = resp else {
                    try? fh.close()
                    return channel.eventLoop.makeFailedFuture(SFTPError.unsupportedResponse)
                }
                return self.downloadLoop(handler, channel: channel, handle: h, offset: 0, fh: fh)
                    .always { _ in
                        try? fh.close()
                        _ = handler.request(SFTP.CLOSE) { $0.writeSFTPBytes(h) }
                    }
            }
        }
    }

    private func downloadLoop(_ handler: SFTPChannelHandler, channel: Channel,
                             handle: [UInt8], offset: UInt64, fh: FileHandle) -> EventLoopFuture<Void> {
        handler.request(SFTP.READ) { buf in
            buf.writeSFTPBytes(handle)
            buf.writeInteger(offset, endianness: .big)
            buf.writeInteger(UInt32(SFTP.chunkSize), endianness: .big)
        }.flatMap { resp -> EventLoopFuture<Void> in
            switch resp {
            case .data(let bytes):
                if bytes.isEmpty { return channel.eventLoop.makeSucceededFuture(()) }
                fh.write(Data(bytes))
                return self.downloadLoop(handler, channel: channel, handle: handle,
                                         offset: offset + UInt64(bytes.count), fh: fh)
            case .status(let code, let msg):
                if code == SFTP.FX_EOF { return channel.eventLoop.makeSucceededFuture(()) }
                return channel.eventLoop.makeFailedFuture(SFTPError.status(code: code, message: msg))
            default:
                return channel.eventLoop.makeFailedFuture(SFTPError.unsupportedResponse)
            }
        }
    }

    public func upload(local: String, remote: String, completion: @escaping (Result<Void, Error>) -> Void) {
        withHandler(completion) { handler, channel in
            guard let fh = FileHandle(forReadingAtPath: local) else {
                return channel.eventLoop.makeFailedFuture(SFTPError.localFileError("cannot open local file for read: \(local)"))
            }
            // OPEN(write|creat|trunc) → 循环读本地 + WRITE → CLOSE
            return handler.request(SFTP.OPEN) { buf in
                buf.writeSFTPString(remote)
                buf.writeInteger(SFTP.FXF_WRITE | SFTP.FXF_CREAT | SFTP.FXF_TRUNC, endianness: .big)
                buf.writeInteger(UInt32(0), endianness: .big)  // ATTRS flags = 0
            }.flatMap { resp -> EventLoopFuture<Void> in
                guard case .handle(let h) = resp else {
                    try? fh.close()
                    return channel.eventLoop.makeFailedFuture(SFTPError.unsupportedResponse)
                }
                return self.uploadLoop(handler, channel: channel, handle: h, offset: 0, fh: fh)
                    .always { _ in
                        try? fh.close()
                        _ = handler.request(SFTP.CLOSE) { $0.writeSFTPBytes(h) }
                    }
            }
        }
    }

    private func uploadLoop(_ handler: SFTPChannelHandler, channel: Channel,
                           handle: [UInt8], offset: UInt64, fh: FileHandle) -> EventLoopFuture<Void> {
        let chunk = fh.readData(ofLength: SFTP.chunkSize)
        if chunk.isEmpty { return channel.eventLoop.makeSucceededFuture(()) }
        return handler.request(SFTP.WRITE) { buf in
            buf.writeSFTPBytes(handle)
            buf.writeInteger(offset, endianness: .big)
            buf.writeSFTPBytes([UInt8](chunk))
        }.flatMap { resp -> EventLoopFuture<Void> in
            switch resp {
            case .status(let code, let msg):
                if code == SFTP.FX_OK {
                    return self.uploadLoop(handler, channel: channel, handle: handle,
                                           offset: offset + UInt64(chunk.count), fh: fh)
                }
                return channel.eventLoop.makeFailedFuture(SFTPError.status(code: code, message: msg))
            default:
                return channel.eventLoop.makeFailedFuture(SFTPError.unsupportedResponse)
            }
        }
    }

    public func close() {
        childChannel?.close(promise: nil)
        tcpChannel?.close(promise: nil)
        try? group?.syncShutdownGracefully()
        group = nil
        handler = nil
        childChannel = nil
        tcpChannel = nil
    }

    // MARK: - 内部辅助

    /// 统一入口：确保通道就绪，在 EventLoop 上执行 body，结果切主线程回调。
    private func withHandler<T>(_ completion: @escaping (Result<T, Error>) -> Void,
                               _ body: @escaping (SFTPChannelHandler, Channel) -> EventLoopFuture<T>) {
        guard let handler = self.handler, let channel = self.childChannel else {
            finishOnMain(completion, .failure(SFTPError.notConnected))
            return
        }
        channel.eventLoop.flatSubmit {
            body(handler, channel)
        }.whenComplete { [weak self] result in
            self?.finishOnMain(completion, result)
        }
    }

    /// 把 STATUS 响应折叠成 Void：OK → 成功，其余 → 错误。
    private func expectOK(_ resp: SFTPRawResponse, channel: Channel) -> EventLoopFuture<Void> {
        if case .status(let code, let msg) = resp {
            if code == SFTP.FX_OK { return channel.eventLoop.makeSucceededFuture(()) }
            return channel.eventLoop.makeFailedFuture(SFTPError.status(code: code, message: msg))
        }
        return channel.eventLoop.makeFailedFuture(SFTPError.unsupportedResponse)
    }

    private func finishOnMain<T>(_ completion: @escaping (Result<T, Error>) -> Void, _ result: Result<T, Error>) {
        DispatchQueue.main.async { completion(result) }
    }
}

// MARK: - SFTP 报文响应（内部）

/// 一个已解析的 SFTP 响应（按类型分派）。
enum SFTPRawResponse {
    case status(code: UInt32, message: String)
    case handle([UInt8])
    case data([UInt8])
    case name([SFTPName])
    case attrs(SFTPAttributes)
}

// MARK: - 子通道处理器

/// SFTP 子通道处理器：负责 subsystem 请求、INIT/VERSION 握手、报文重组与 request-id 关联。
/// 所有状态仅在本通道的 EventLoop 上访问，无需额外加锁。
final class SFTPChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    /// 握手完成回调（VERSION 到达或失败时触发一次）。允许在 channelActive 前设置。
    var onReady: ((Result<Void, Error>) -> Void)? {
        didSet {
            if let pending = pendingReady, let cb = onReady {
                pendingReady = nil
                cb(pending)
            }
        }
    }
    private var pendingReady: Result<Void, Error>?
    private var readySignalled = false

    private let onClose: (Error?) -> Void

    private var channel: Channel?
    private var accumulator: ByteBuffer?
    private var pending: [UInt32: EventLoopPromise<SFTPRawResponse>] = [:]
    private var nextRequestId: UInt32 = 0

    init(onClose: @escaping (Error?) -> Void) {
        self.onClose = onClose
    }

    // MARK: 发送请求（须在 EventLoop 上调用；经 withHandler 的 flatSubmit 保证）

    /// 发送一个带 request-id 的 SFTP 请求，返回其响应 future。
    func request(_ type: UInt8, _ buildArgs: (inout ByteBuffer) -> Void) -> EventLoopFuture<SFTPRawResponse> {
        guard let channel = self.channel else {
            // 没有可用通道；用一个已失败的 future 返回。
            let loop = self.pending.first?.value.futureResult.eventLoop
            if let loop = loop { return loop.makeFailedFuture(SFTPError.notConnected) }
            fatalError("SFTPChannelHandler.request called before channelActive")
        }
        let id = nextRequestId
        nextRequestId &+= 1
        let promise = channel.eventLoop.makePromise(of: SFTPRawResponse.self)
        pending[id] = promise

        var inner = channel.allocator.buffer(capacity: 64)
        inner.writeInteger(type)                        // byte type
        inner.writeInteger(id, endianness: .big)        // uint32 request-id
        buildArgs(&inner)                               // 具体参数
        writeFrame(inner)
        return promise.futureResult
    }

    /// 发送不带 request-id 的 SSH_FXP_INIT。
    private func sendInit() {
        guard let channel = self.channel else { return }
        var inner = channel.allocator.buffer(capacity: 5)
        inner.writeInteger(SFTP.INIT)
        inner.writeInteger(SFTP.version, endianness: .big)
        writeFrame(inner)
    }

    /// 给 payload 加 uint32 长度前缀并作为 SSHChannelData 写出。
    private func writeFrame(_ inner: ByteBuffer) {
        guard let channel = self.channel else { return }
        var frame = channel.allocator.buffer(capacity: inner.readableBytes + 4)
        frame.writeInteger(UInt32(inner.readableBytes), endianness: .big)
        var payload = inner
        frame.writeBuffer(&payload)
        let sshData = SSHChannelData(type: .channel, data: .byteBuffer(frame))
        // 直接在 channel 级写出原始 SSHChannelData（与 NIOSSHSession.send 一致），
        // 不用 wrapOutboundOut，避免二次包装成 NIOAny 导致下游类型不符。
        channel.writeAndFlush(sshData, promise: nil)
    }

    // MARK: 通道生命周期

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelActive(context: ChannelHandlerContext) {
        self.channel = context.channel
        self.accumulator = context.channel.allocator.buffer(capacity: 4096)
        // 请求 sftp 子系统 → 成功后发 INIT
        let subsystem = SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)
        context.triggerUserOutboundEvent(subsystem).whenComplete { [weak self] result in
            switch result {
            case .success:
                self?.sendInit()
            case .failure(let error):
                self?.signalReady(.failure(SFTPError.connectFailed("subsystem sftp rejected: \(error)")))
            }
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = channelData.data else { return }
        if accumulator == nil { accumulator = context.channel.allocator.buffer(capacity: 4096) }
        accumulator!.writeBuffer(&buffer)
        processBuffer(context: context)
    }

    /// 从累积缓冲区中切出所有完整报文并分派。
    private func processBuffer(context: ChannelHandlerContext) {
        guard accumulator != nil else { return }
        while accumulator!.readableBytes >= 4 {
            let len = accumulator!.getInteger(at: accumulator!.readerIndex, as: UInt32.self) ?? 0
            let total = 4 + Int(len)
            guard accumulator!.readableBytes >= total else { break }
            accumulator!.moveReaderIndex(forwardBy: 4)
            guard var packet = accumulator!.readSlice(length: Int(len)) else { break }
            handlePacket(&packet)
        }
        accumulator!.discardReadBytes()
    }

    /// 解析并分派单条报文（type 已在 payload 首字节）。
    private func handlePacket(_ packet: inout ByteBuffer) {
        guard let type: UInt8 = packet.readInteger() else { return }

        if type == SFTP.VERSION {
            // uint32 version + 可选扩展（忽略）
            _ = packet.readInteger(endianness: .big) as UInt32?
            signalReady(.success(()))
            return
        }

        guard let reqId: UInt32 = packet.readInteger(endianness: .big) else { return }
        guard let promise = pending.removeValue(forKey: reqId) else { return }

        switch type {
        case SFTP.STATUS:
            let code = (packet.readInteger(endianness: .big) as UInt32?) ?? SFTP.FX_OK
            let msg = packet.readSFTPString() ?? ""
            promise.succeed(.status(code: code, message: msg))
        case SFTP.HANDLE:
            if let h = packet.readSFTPBytes() { promise.succeed(.handle(h)) }
            else { promise.fail(SFTPError.malformedPacket) }
        case SFTP.DATA:
            if let d = packet.readSFTPBytes() { promise.succeed(.data(d)) }
            else { promise.fail(SFTPError.malformedPacket) }
        case SFTP.NAME:
            guard let count: UInt32 = packet.readInteger(endianness: .big) else {
                promise.fail(SFTPError.malformedPacket); return
            }
            var names: [SFTPName] = []
            names.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let filename = packet.readSFTPString(),
                      let longname = packet.readSFTPString(),
                      let attrs = packet.readSFTPAttributes() else {
                    promise.fail(SFTPError.malformedPacket); return
                }
                names.append(SFTPName(filename: filename, longname: longname, attrs: attrs))
            }
            promise.succeed(.name(names))
        case SFTP.ATTRS:
            if let a = packet.readSFTPAttributes() { promise.succeed(.attrs(a)) }
            else { promise.fail(SFTPError.malformedPacket) }
        default:
            promise.fail(SFTPError.unsupportedResponse)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAllPending(SFTPError.notConnected)
        signalReady(.failure(SFTPError.notConnected))
        onClose(nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failAllPending(error)
        signalReady(.failure(error))
        onClose(error)
        context.close(promise: nil)
    }

    private func failAllPending(_ error: Error) {
        let all = pending
        pending.removeAll()
        for (_, p) in all { p.fail(error) }
    }

    /// 触发一次握手结果（去重）。若 onReady 尚未设置则缓存，待设置时补发。
    private func signalReady(_ result: Result<Void, Error>) {
        guard !readySignalled else { return }
        readySignalled = true
        if let cb = onReady {
            cb(result)
        } else {
            pendingReady = result
        }
    }
}

// MARK: - 认证 / host key（SFTP 专用，避免改动 SSH/ 目录）


/// 接受所有主机公钥（与 NIOSSHSession 行为一致；后续可换 known_hosts 校验）。
final class SFTPAcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}
