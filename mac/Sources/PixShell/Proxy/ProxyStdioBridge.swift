import Foundation
import NIOCore
import NIOPosix
import Darwin

/// OpenSSH `ProxyCommand` 使用的隐藏字节桥。macOS 自带 nc 不支持需要
/// 用户名/密码的 SOCKS5；这里复用应用内代理握手并原样桥接 stdin/stdout。
enum ProxyStdioBridge {
    static let flag = "--proxy-stdio"
    static let usernameEnv = "PIXSHELL_PROXY_USERNAME"
    static let passwordEnv = "PIXSHELL_PROXY_PASSWORD"

    static var requested: Bool { CommandLine.arguments.dropFirst().first == flag }

    static func run() -> Int32 {
        let args = CommandLine.arguments
        guard args.count == 7,
              let type = ProxyType(rawValue: args[2]),
              let proxyPort = Int(args[4]),
              let destinationPort = Int(args[6]),
              type != .sshJump else {
            writeError("PixShell proxy bridge: invalid arguments\n")
            return 64
        }
        let proxy = ProxyConfig(name: "openssh-bridge", type: type, host: args[3], port: proxyPort,
                                username: ProcessInfo.processInfo.environment[usernameEnv] ?? "",
                                password: ProcessInfo.processInfo.environment[passwordEnv] ?? "")
        let destinationHost = args[5]
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        do {
            let bootstrap = ClientBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                .channelOption(ChannelOptions.connectTimeout, value: .seconds(12))
            let channel = try bootstrap.connect(host: proxy.host, port: proxy.port).wait()
            let promise = channel.eventLoop.makePromise(of: ByteBuffer.self)
            let handler: ChannelHandler & RemovableChannelHandler
            switch proxy.type {
            case .socks5:
                handler = SOCKS5ProxyHandler(destHost: destinationHost, destPort: destinationPort,
                                              username: proxy.username, password: proxy.password, promise: promise)
            case .socks4:
                handler = SOCKS4ProxyHandler(destHost: destinationHost, destPort: destinationPort,
                                              userId: proxy.username, promise: promise)
            case .http:
                handler = HTTPConnectProxyHandler(destHost: destinationHost, destPort: destinationPort,
                                                   username: proxy.username, password: proxy.password, promise: promise)
            case .sshJump:
                throw ProxyDialError.unsupportedProxyType("ssh-jump")
            }

            let leftover = try channel.pipeline.addHandler(handler).flatMap { promise.futureResult }.wait()
            try channel.pipeline.addHandler(ProxyStdoutHandler()).wait()
            if leftover.readableBytes > 0 {
                channel.pipeline.fireChannelRead(leftover)
                channel.pipeline.fireChannelReadComplete()
            }

            let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO,
                                                       queue: .global(qos: .userInitiated))
            input.setEventHandler {
                var bytes = [UInt8](repeating: 0, count: 16 * 1024)
                let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
                if count > 0 {
                    channel.eventLoop.execute {
                        var buffer = channel.allocator.buffer(capacity: count)
                        buffer.writeBytes(bytes[0..<count])
                        channel.writeAndFlush(buffer, promise: nil)
                    }
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    channel.close(promise: nil)
                }
            }
            input.resume()
            try channel.closeFuture.wait()
            input.cancel()
            return 0
        } catch {
            writeError("PixShell proxy bridge: \(error)\n")
            return 1
        }
    }

    private static func writeError(_ message: String) {
        let bytes = Array(message.utf8)
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.write(STDERR_FILENO, base, raw.count)
        }
    }
}

private final class ProxyStdoutHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let count = Darwin.write(STDOUT_FILENO, pointer, remaining)
                if count > 0 {
                    remaining -= count
                    pointer = pointer.advanced(by: count)
                } else if errno != EINTR {
                    context.close(promise: nil)
                    break
                }
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
