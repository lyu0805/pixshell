import Foundation
import NIOSSH

/// 把非 Sendable 的 `SSHClientConfiguration` 包一层，供 NIO `channelInitializer` /
/// `whenComplete` 等 `@Sendable` 闭包捕获。配置本身只在建连阶段只读使用，
/// 真正的 handler 生命周期仍由 NIO event loop 约束——这是消 Sendable 警告的标准手法，
/// 不是把配置变成可跨线程可变共享。
struct NIOSSHClientConfigBox: @unchecked Sendable {
    let value: SSHClientConfiguration
    init(_ value: SSHClientConfiguration) { self.value = value }
}

/// 终端会话所需的最小 SSH 接口。SwiftTerm 的 TerminalView 通过它收发字节。
/// 关键路径由本文件的协议锁定：任何实现（Citadel / swift-nio-ssh / libssh2 封装）
/// 只要满足此协议即可被 TerminalPane 集成，互不影响。
public struct SSHCredentials: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    public var privateKeyPEM: String?     // 可选：私钥内容（非路径）
    public var privateKeyPassphrase: String?
    public var keyPath: String?           // 可选：私钥文件路径（~ 会展开），对应 Host.keyPath
    /// 可选：出站代理（SOCKS5/SOCKS4/HTTP CONNECT）。nil 表示直连。见 Proxy/ProxyConfig.swift。
    /// 新参数放在末尾且带默认值，保证老调用点（如 AppDelegate+Sessions.swift）不用改就能继续编译。
    public var proxy: ProxyConfig?
    public init(host: String, port: Int = 22, username: String,
                password: String? = nil, privateKeyPEM: String? = nil,
                privateKeyPassphrase: String? = nil, keyPath: String? = nil,
                proxy: ProxyConfig? = nil) {
        self.host = host; self.port = port; self.username = username
        self.password = password; self.privateKeyPEM = privateKeyPEM
        self.privateKeyPassphrase = privateKeyPassphrase
        self.keyPath = keyPath
        self.proxy = proxy
    }
}

/// 会话事件回调（都在主线程投递，供 UI 直接用）。
public protocol SSHSessionDelegate: AnyObject {
    /// 远端 shell 输出的原始字节（直接 feed 给 SwiftTerm）。
    func sshSession(_ s: SSHSession, didReceive data: [UInt8])
    /// 会话关闭 / 出错（error 为 nil 表示正常关闭）。
    func sshSession(_ s: SSHSession, didCloseWith error: Error?)
    /// 连接就绪（PTY shell 已打开，可以开始 IO）。
    func sshSessionDidOpenShell(_ s: SSHSession)
}

/// 一个交互式 PTY shell 会话。实现方负责：TCP 连接、SSH 握手（密码/公钥）、
/// 开 PTY、请求 shell、把远端输出经 delegate 抛回、把本地输入写进去、窗口尺寸变更、关闭。
public protocol SSHSession: AnyObject {
    var delegate: SSHSessionDelegate? { get set }
    /// 异步连接并打开一个 PTY shell（term 如 "xterm-256color"）。
    func connectAndOpenShell(_ creds: SSHCredentials, term: String, cols: Int, rows: Int)
    /// 把本地键入的字节写给远端 shell。
    func send(_ data: [UInt8])
    /// 终端尺寸变化时同步给远端（SIGWINCH）。
    func resize(cols: Int, rows: Int)
    /// 一次性执行命令并收集 stdout（用于监控采集等，与交互 shell 并行、独立通道）。
    /// completion 在主线程回调，返回完整 stdout 文本（失败返回空串）。
    func exec(_ command: String, completion: @escaping (String) -> Void)
    /// 带超时/输出上限的 exec（桥/MCP 用，支持长任务）。
    /// - timeout：命令总超时秒（默认 30；长任务可调大）
    /// - maxBytes：stdout 收集上限（默认 0=不限制；防大输出 OOM）
    /// - completion：(output, timedOut) —— timedOut 标记命令是否被超时收口（区别于正常完成）
    func exec(_ command: String, timeout: TimeInterval, maxBytes: Int,
              completion: @escaping (String, Bool) -> Void)
    /// 主动断开。
    func close()
}

extension SSHSession {
    /// 旧签名 exec 默认走带参版（30s / 不限制输出），行为不变。
    public func exec(_ command: String, completion: @escaping (String) -> Void) {
        exec(command, timeout: Self.execTimeout, maxBytes: 0) { out, _ in completion(out) }
    }
    static var execTimeout: TimeInterval { 30 }
}
