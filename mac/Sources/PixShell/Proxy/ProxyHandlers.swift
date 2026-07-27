import Foundation
import NIOCore

/// 代理握手统一超时：拨号阶段挂太久没有任何意义(用户宁愿看到一条明确报错，也不要界面卡死)。
private let proxyHandshakeTimeout: TimeAmount = .seconds(15)

/// 代理拨号相关错误——文案直接给日志/UI 展示，不含二进制细节。
enum ProxyDialError: Error, CustomStringConvertible {
    case timeout
    case connectionClosed
    case socks5MethodRejected
    case socks5AuthFailed(UInt8)
    case socks5ConnectFailed(UInt8)
    case socks5MalformedReply(String)
    case socks4ConnectFailed(UInt8)
    case socks4MalformedReply(String)
    case httpConnectFailed(Int, String)
    case httpMalformedReply(String)
    case unsupportedProxyType(String)

    var description: String {
        switch self {
        case .timeout: return "代理连接超时"
        case .connectionClosed: return "代理连接被对端关闭"
        case .socks5MethodRejected: return "SOCKS5 服务端不接受提供的认证方式"
        case .socks5AuthFailed(let s): return "SOCKS5 用户名/密码认证失败(status=\(s))"
        case .socks5ConnectFailed(let rep): return "SOCKS5 CONNECT 失败: \(ProxyDialError.socks5ReplyText(rep))"
        case .socks5MalformedReply(let m): return "SOCKS5 响应格式错误: \(m)"
        case .socks4ConnectFailed(let cd): return "SOCKS4 CONNECT 失败(code=0x\(String(cd, radix: 16)))"
        case .socks4MalformedReply(let m): return "SOCKS4 响应格式错误: \(m)"
        case .httpConnectFailed(let code, let line): return "HTTP CONNECT 失败: \(code) \(line)"
        case .httpMalformedReply(let m): return "HTTP CONNECT 响应格式错误: \(m)"
        case .unsupportedProxyType(let t): return "不支持的代理类型: \(t)"
        }
    }

    private static func socks5ReplyText(_ rep: UInt8) -> String {
        switch rep {
        case 0x01: return "一般性代理服务器故障"
        case 0x02: return "规则不允许连接"
        case 0x03: return "网络不可达"
        case 0x04: return "主机不可达"
        case 0x05: return "连接被拒绝"
        case 0x06: return "TTL 超时"
        case 0x07: return "不支持的命令"
        case 0x08: return "不支持的地址类型"
        default: return "未知错误(0x\(String(rep, radix: 16)))"
        }
    }
}

/// 三个代理握手处理器共用的"一次性完成"辅助：保证 promise 只 fulfill 一次、超时任务用完必取消，
/// 避免超时定时器和正常完成之间的竞态(比如已经成功了，超时任务才姗姗来迟触发误报)。
/// `succeed` 时会把处理器自身从 pipeline 摘除，并把"隧道建立那一刻已经多收到、但还没消费的字节"
/// (leftover)一并交回调用方——代理服务器把 CONNECT 回执和目标服务器的首包数据粘在同一个 TCP 包里
/// 是完全合法且常见的，如果直接丢弃这部分字节，SSH 握手会因为缺了开头几个字节而卡死或报错。
private final class ProxyHandshakeCompletion {
    private let promise: EventLoopPromise<ByteBuffer>
    private var timeoutTask: Scheduled<Void>?
    private var finished = false

    init(promise: EventLoopPromise<ByteBuffer>) { self.promise = promise }

    func armTimeout(context: ChannelHandlerContext) {
        timeoutTask = context.eventLoop.scheduleTask(in: proxyHandshakeTimeout) { [weak self] in
            self?.fail(context: context, ProxyDialError.timeout)
        }
    }

    func succeed(context: ChannelHandlerContext, leftover: ByteBuffer) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
        promise.succeed(leftover)
    }

    func fail(context: ChannelHandlerContext, _ error: Error) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        promise.fail(error)
        context.close(promise: nil)
    }
}

// MARK: - SOCKS5

/// SOCKS5 CONNECT 握手：问候(可选用户名/密码认证) → CONNECT(DOMAINNAME，让代理侧解析 DNS)。
/// 成功后自摘 pipeline，SSH 握手在同一个 channel 上继续。
final class SOCKS5ProxyHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Stage { case greeting, auth, connectReply }

    private let destHost: String
    private let destPort: Int
    private let username: String?
    private let password: String?
    private let completion: ProxyHandshakeCompletion
    private var stage: Stage = .greeting
    private var inbound: ByteBuffer!
    private var started = false

    init(destHost: String, destPort: Int, username: String?, password: String?, promise: EventLoopPromise<ByteBuffer>) {
        self.destHost = destHost
        self.destPort = destPort
        self.username = (username?.isEmpty == false) ? username : nil
        self.password = (password?.isEmpty == false) ? password : nil
        self.completion = ProxyHandshakeCompletion(promise: promise)
    }

    // 注意：真实拨号路径里这个 handler 是 TCP 连接**已经建立之后**才动态 addHandler 上去的
    // (先连代理，再在同一个 channel 上跑握手)，这时 channelActive 早就已经触发过、不会再重复触发。
    // 所以握手必须在 handlerAdded 里、发现 channel 已经 active 时就立刻发起，不能只等 channelActive；
    // 反过来如果哪天改成在 channelInitializer 里提前装(channel 还没 active)，channelActive 兜底触发。
    // `started` 防止两条路径都命中导致的重复发送。
    func handlerAdded(context: ChannelHandlerContext) {
        inbound = context.channel.allocator.buffer(capacity: 64)
        completion.armTimeout(context: context)
        if context.channel.isActive { start(context: context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        start(context: context)
        context.fireChannelActive()
    }

    private func start(context: ChannelHandlerContext) {
        guard !started else { return }
        started = true
        sendGreeting(context: context)
    }

    private func sendGreeting(context: ChannelHandlerContext) {
        var buf = context.channel.allocator.buffer(capacity: 4)
        buf.writeInteger(UInt8(0x05)) // VER
        if username != nil {
            buf.writeInteger(UInt8(2))
            buf.writeInteger(UInt8(0x00)) // 无认证
            buf.writeInteger(UInt8(0x02)) // 用户名/密码(RFC1929)
        } else {
            buf.writeInteger(UInt8(1))
            buf.writeInteger(UInt8(0x00))
        }
        context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
    }

    private func sendAuth(context: ChannelHandlerContext) {
        let uBytes = Array((username ?? "").utf8).prefix(255)
        let pBytes = Array((password ?? "").utf8).prefix(255)
        var buf = context.channel.allocator.buffer(capacity: 3 + uBytes.count + pBytes.count)
        buf.writeInteger(UInt8(0x01)) // 子协商 VER
        buf.writeInteger(UInt8(uBytes.count))
        buf.writeBytes(uBytes)
        buf.writeInteger(UInt8(pBytes.count))
        buf.writeBytes(pBytes)
        context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
    }

    private func sendConnect(context: ChannelHandlerContext) {
        let hostBytes = Array(destHost.utf8).prefix(255)
        var buf = context.channel.allocator.buffer(capacity: 7 + hostBytes.count)
        buf.writeInteger(UInt8(0x05)) // VER
        buf.writeInteger(UInt8(0x01)) // CMD=CONNECT
        buf.writeInteger(UInt8(0x00)) // RSV
        buf.writeInteger(UInt8(0x03)) // ATYP=DOMAINNAME
        buf.writeInteger(UInt8(hostBytes.count))
        buf.writeBytes(hostBytes)
        buf.writeInteger(UInt16(destPort))
        context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        inbound.writeBuffer(&incoming)
        process(context: context)
    }

    // TCP 可能把任意一条消息拆成多次到达，也可能把多条消息粘在一起——process 每次只在
    // "确定收够了当前阶段所需字节数"时才消费并推进 stage，否则原样等下一次 channelRead。
    private func process(context: ChannelHandlerContext) {
        switch stage {
        case .greeting:
            guard inbound.readableBytes >= 2, let bytes = inbound.getBytes(at: inbound.readerIndex, length: 2) else { return }
            inbound.moveReaderIndex(forwardBy: 2)
            guard bytes[0] == 0x05 else {
                completion.fail(context: context, ProxyDialError.socks5MalformedReply("VER=\(bytes[0])"))
                return
            }
            let method = bytes[1]
            if method == 0x00 {
                sendConnect(context: context)
                stage = .connectReply
            } else if method == 0x02, username != nil {
                sendAuth(context: context)
                stage = .auth
            } else {
                completion.fail(context: context, ProxyDialError.socks5MethodRejected)
                return
            }
            process(context: context)
        case .auth:
            guard inbound.readableBytes >= 2, let bytes = inbound.getBytes(at: inbound.readerIndex, length: 2) else { return }
            inbound.moveReaderIndex(forwardBy: 2)
            guard bytes[1] == 0x00 else {
                completion.fail(context: context, ProxyDialError.socks5AuthFailed(bytes[1]))
                return
            }
            sendConnect(context: context)
            stage = .connectReply
            process(context: context)
        case .connectReply:
            guard inbound.readableBytes >= 4, let head = inbound.getBytes(at: inbound.readerIndex, length: 4) else { return }
            let ver = head[0], rep = head[1], atyp = head[3]
            guard ver == 0x05 else {
                completion.fail(context: context, ProxyDialError.socks5MalformedReply("VER=\(ver)"))
                return
            }
            let addrLen: Int
            switch atyp {
            case 0x01: addrLen = 4   // IPv4
            case 0x04: addrLen = 16  // IPv6
            case 0x03: // DOMAINNAME：多一个长度前缀字节
                guard inbound.readableBytes >= 5, let lenByte = inbound.getBytes(at: inbound.readerIndex + 4, length: 1) else { return }
                addrLen = 1 + Int(lenByte[0])
            default:
                completion.fail(context: context, ProxyDialError.socks5MalformedReply("ATYP=\(atyp)"))
                return
            }
            let total = 4 + addrLen + 2 // 头 + 地址 + 端口
            guard inbound.readableBytes >= total else { return }
            inbound.moveReaderIndex(forwardBy: total)
            guard rep == 0x00 else {
                completion.fail(context: context, ProxyDialError.socks5ConnectFailed(rep))
                return
            }
            completion.succeed(context: context, leftover: inbound)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        completion.fail(context: context, ProxyDialError.connectionClosed)
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        completion.fail(context: context, error)
    }
}

// MARK: - SOCKS4 / SOCKS4a

/// SOCKS4a CONNECT：DSTIP 用保留地址 0.0.0.1 触发 4a 扩展，末尾追加以 \0 结尾的主机名，
/// 让代理服务器自己解析域名(而不是本地 resolve 后只发 IP)。
final class SOCKS4ProxyHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let destHost: String
    private let destPort: Int
    private let userId: String?
    private let completion: ProxyHandshakeCompletion
    private var inbound: ByteBuffer!
    private var started = false

    init(destHost: String, destPort: Int, userId: String?, promise: EventLoopPromise<ByteBuffer>) {
        self.destHost = destHost
        self.destPort = destPort
        self.userId = (userId?.isEmpty == false) ? userId : nil
        self.completion = ProxyHandshakeCompletion(promise: promise)
    }

    // 见 SOCKS5ProxyHandler 同名方法的注释：真实拨号路径里 channel 早已 active，
    // 握手必须在 handlerAdded 里主动检测并发起，不能只依赖 channelActive。
    func handlerAdded(context: ChannelHandlerContext) {
        inbound = context.channel.allocator.buffer(capacity: 16)
        completion.armTimeout(context: context)
        if context.channel.isActive { start(context: context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        start(context: context)
        context.fireChannelActive()
    }

    private func start(context: ChannelHandlerContext) {
        guard !started else { return }
        started = true
        let hostBytes = Array(destHost.utf8)
        let idBytes = Array((userId ?? "").utf8)
        var buf = context.channel.allocator.buffer(capacity: 9 + idBytes.count + hostBytes.count)
        buf.writeInteger(UInt8(0x04))              // VN
        buf.writeInteger(UInt8(0x01))              // CD=CONNECT
        buf.writeInteger(UInt16(destPort))         // DSTPORT
        buf.writeBytes([0x00, 0x00, 0x00, 0x01])   // DSTIP=0.0.0.1(触发 4a)
        buf.writeBytes(idBytes)                    // USERID
        buf.writeInteger(UInt8(0x00))               // USERID 结尾 \0
        buf.writeBytes(hostBytes)                  // 4a: 域名
        buf.writeInteger(UInt8(0x00))               // 域名结尾 \0
        context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        inbound.writeBuffer(&incoming)
        guard inbound.readableBytes >= 8, let bytes = inbound.getBytes(at: inbound.readerIndex, length: 8) else { return }
        inbound.moveReaderIndex(forwardBy: 8)
        let cd = bytes[1]
        guard cd == 0x5A else {
            completion.fail(context: context, ProxyDialError.socks4ConnectFailed(cd))
            return
        }
        completion.succeed(context: context, leftover: inbound)
    }

    func channelInactive(context: ChannelHandlerContext) {
        completion.fail(context: context, ProxyDialError.connectionClosed)
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        completion.fail(context: context, error)
    }
}

// MARK: - HTTP CONNECT

/// HTTP 隧道：发 `CONNECT host:port HTTP/1.1`，带 Host 头；有凭证则带 Basic 认证；
/// 等到完整响应头(直到空行)后校验 2xx 状态码。
final class HTTPConnectProxyHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private static let maxHeaderBytes = 16 * 1024 // 防止恶意/异常代理无限攒不带空行的数据

    private let destHost: String
    private let destPort: Int
    private let username: String?
    private let password: String?
    private let completion: ProxyHandshakeCompletion
    private var inbound: ByteBuffer!
    private var started = false

    init(destHost: String, destPort: Int, username: String?, password: String?, promise: EventLoopPromise<ByteBuffer>) {
        self.destHost = destHost
        self.destPort = destPort
        self.username = (username?.isEmpty == false) ? username : nil
        self.password = (password?.isEmpty == false) ? password : nil
        self.completion = ProxyHandshakeCompletion(promise: promise)
    }

    // 见 SOCKS5ProxyHandler 同名方法的注释：真实拨号路径里 channel 早已 active，
    // 握手必须在 handlerAdded 里主动检测并发起，不能只依赖 channelActive。
    func handlerAdded(context: ChannelHandlerContext) {
        inbound = context.channel.allocator.buffer(capacity: 128)
        completion.armTimeout(context: context)
        if context.channel.isActive { start(context: context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        start(context: context)
        context.fireChannelActive()
    }

    private func start(context: ChannelHandlerContext) {
        guard !started else { return }
        started = true
        let hostPort = "\(destHost):\(destPort)"
        var req = "CONNECT \(hostPort) HTTP/1.1\r\nHost: \(hostPort)\r\n"
        if let u = username {
            let token = Data("\(u):\(password ?? "")".utf8).base64EncodedString()
            req += "Proxy-Authorization: Basic \(token)\r\n"
        }
        req += "Proxy-Connection: Keep-Alive\r\n\r\n"
        var buf = context.channel.allocator.buffer(capacity: req.utf8.count)
        buf.writeString(req)
        context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        inbound.writeBuffer(&incoming)
        guard inbound.readableBytes <= Self.maxHeaderBytes else {
            completion.fail(context: context, ProxyDialError.httpMalformedReply("响应头过大，代理可能异常"))
            return
        }
        process(context: context)
    }

    private func process(context: ChannelHandlerContext) {
        guard let all = inbound.getBytes(at: inbound.readerIndex, length: inbound.readableBytes),
              let idx = Self.indexOfCRLFCRLF(all) else { return } // 还没收到完整响应头，继续等
        let headerLen = idx + 4
        guard let headerText = inbound.getString(at: inbound.readerIndex, length: headerLen) else {
            completion.fail(context: context, ProxyDialError.httpMalformedReply("响应头解码失败"))
            return
        }
        inbound.moveReaderIndex(forwardBy: headerLen)
        let statusLine = headerText.components(separatedBy: "\r\n").first ?? ""
        let comps = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard comps.count >= 2, let code = Int(comps[1]) else {
            completion.fail(context: context, ProxyDialError.httpMalformedReply("状态行解析失败: \(statusLine)"))
            return
        }
        guard (200..<300).contains(code) else {
            completion.fail(context: context, ProxyDialError.httpConnectFailed(code, statusLine))
            return
        }
        completion.succeed(context: context, leftover: inbound)
    }

    private static func indexOfCRLFCRLF(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        var i = 0
        while i <= bytes.count - 4 {
            if bytes[i] == 0x0d, bytes[i + 1] == 0x0a, bytes[i + 2] == 0x0d, bytes[i + 3] == 0x0a { return i }
            i += 1
        }
        return nil
    }

    func channelInactive(context: ChannelHandlerContext) {
        completion.fail(context: context, ProxyDialError.connectionClosed)
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        completion.fail(context: context, error)
    }
}
