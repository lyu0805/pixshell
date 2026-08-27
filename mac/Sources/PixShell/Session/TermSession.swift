import AppKit
import SwiftTerm

/// 一个终端会话：独立的 TerminalView + NIOSSHSession + 所属主机 + 标题 + 凭据。
/// 也可为 **应用内 Web SSH**（`webSSHView != nil`）：内容区是 WKWebView，不经 NIO SSH。
final class TermSession {
    let id = UUID().uuidString
    var host: Host   // 可变：首次连上识别出系统后会回填 osId（见 AppDelegate.detectRemoteOS）
    let termView: TerminalView
    /// 非空 = 应用内 Web 终端标签（xterm.js via 本地桥）；`contentView` 优先用它。
    var webSSHView: WebSSHView?
    var ssh: SSHSession?
    var title: String
    var semanticActiveColor: Bool = false

    /// 工作区应显示的内容：Web SSH 用 WKWebView，其它用 SwiftTerm。
    var contentView: NSView { webSSHView ?? termView }
    /// 应用内 Web 终端会话：仅当本标签挂了 WKWebView 时为真。
    /// 注意：主机 connectionType==400 只表示「连接时走 Web 入口」；
    /// 桥 /connect 为 Web 主机拉起的底层 SSH 标签不应被当成 Web 标签。
    var isWebSSH: Bool { webSSHView != nil }

    /// 标签栏显示的名字：**用户在连接管理器里设的名字**（`host.display` = name 为空才回退到 IP）。
    ///
    /// 不能用 `title` —— 那个会被远端 OSC 标题覆盖成系统报的名（`root@ubuntu24: ~`），
    /// 于是用户明明把主机命名为「台湾宽屏」，标签上却显示 `ubuntu24`，几台机器还会重名到分不清。
    /// 完整的远端标题仍保留在 `title` 里（tooltip、独立窗口标题用它）。
    var tabTitle: String {
        if isWebSSH {
            let name = host.display.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? "Web 终端" : name
        }
        let name = host.display.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        // 兜底：连 display 都空（理论上不会）才退回远端标题，并去掉 user@ 和 : ~
        var t = title
        if let at = t.firstIndex(of: "@") { t = String(t[t.index(after: at)...]) }
        if let colon = t.firstIndex(of: ":") { t = String(t[..<colon]) }
        let trimmed = t.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }
    var password: String?   // 供 SFTP 面板复用同一凭据连接
    var connected = false   // shell 当前是否打开（tab 圆点用）

    /// shell **曾经**成功打开过。判断"认证失败"必须用它，不能用 `connected`：
    /// 手动断开会先把 connected 置 false，随后才收到 didCloseWith，
    /// 用 connected 判断会把「用户主动断开」误判成「认证被拒」，进而清掉钥匙串里的密码
    /// 并弹密码框 —— 表现就是"存了密码，断开再连还要重新输密码"。
    var shellOpened = false
    /// didCloseWith 去重：底层可能对同一次关闭回调多次。
    var closeHandled = false
    /// 是否已经因算法协商失败回落到系统 ssh 重试过（每条会话最多回落一次，防止来回打转）。
    var triedOpenSSHFallback = false

    /// 会话输出缓冲（对齐老仓库 termBuffers）：上限 ~500KB，超出保留尾部。
    /// 每个会话各自持有 TerminalView，后台标签同样在收数据；此缓冲用于诊断/导出与
    /// 将来「重置终端后回放」的能力，不影响实时渲染。
    ///
    /// **实现是「分块 + 惰性合并」**：高频 SSH 输出时只往 `_outputChunks` append（O(1)），
    /// 不在每次 `didReceive` 里做整串 `+=`（O(n²)）——那是主线程卡顿的直接来源
    /// （实测 5000 次追加 String 拼接 178ms vs 分块 0.3ms，慢 590 倍）。读取时才合并。
    private var _outputChunks: [String] = []
    /// 惰性合并缓存：有新增 chunk 后置 nil，下次读取再重建。
    private var _merged: String?
    /// 总字符数（chunks 里字符串长度之和），用于上限裁剪。
    private var _outputCount = 0
    static let maxBufferChars = 500_000

    /// 当前缓冲的完整文本（惰性合并 + 裁剪到上限）。仅低频读取（桥 screen / 诊断）调用。
    var outputBuffer: String {
        if _merged == nil {
            var s = _outputChunks.joined()
            if s.count > Self.maxBufferChars { s = String(s.suffix(Self.maxBufferChars)) }
            _merged = s
        }
        return _merged!
    }

    /// 用于跨块缓冲不完整的 ANSI 转义序列，防止被 SemanticHighlight 破坏
    var ansiBuffer: [UInt8] = []

    // MARK: 输出节流（帧级合并）
    /// 累积的待处理输出字节（didReceive 只 append 到这里，由 flushOutput 统一消化）。
    /// 高频输出（top / 日志流 / ping）时把「每数据块一次主线程 decode+染色+feed」合并成
    /// 「每帧最多一次」，避免主线程被每秒成百上千次小块处理占满 —— 卡顿的直接来源。
    var pendingOutput: [UInt8] = []
    /// 已调度 flush（同一 runloop 周期内多次 append 合并成一次处理）。
    var flushScheduled = false
    /// 会话控制器（SSHSessionDelegate + 输出管线的归属，见 TermSessionController）。
    /// **必须 strong**：控制器就是会话的 SSH delegate，而三个 SSHSession 实现的 `delegate`
    /// 都是 weak。若这里也用 weak，`sess.controller = TermSessionController(...)` 创建的实例
    /// 没有任何强引用者，ARC 会**当场释放**它 → `s.delegate = sess.controller` 拿到 nil →
    /// didOpenShell / didReceive / didCloseWith 回调全部丢失 → 连接遮罩永不淡出、终端无输出，
    /// 表现为"连所有服务器都卡在『打开会话…』连不上"。控制器内 `weak var app` 已断开反向环，
    /// 会话与控制器同生命周期释放，无循环引用。
    var controller: TermSessionController?
    /// 帧间隔：60fps 一帧，视觉无感且能聚合高频突发。
    static let flushInterval: TimeInterval = 1.0 / 60.0
    /// 单帧 feed 硬上限（字节）。输出洪水（seq/编译流）下不加封顶时，单帧会把
    /// 积压的几 MB 一次性 feed 渲染，占死主线程 1.5s+（实测）——这是「洪水时关标签/
    /// 点确定卡几秒」的根因。封顶后每帧 feed 有界（~15ms），主线程始终有余量响应交互。
    static let maxFlushBytes = 64 * 1024
    /// 单帧 feed 耗时的指数滑动平均（秒），驱动自适应帧间隔（feed 越贵，间隔越久）。
    var flushCostEMA: TimeInterval = 0
    /// 自适应帧间隔：常态 = flushInterval（60fps）；feed 贵时按 EMA 拉长（上限 100ms），
    /// 目标把主线程 feed 占用压到 ~15%（间隔 ≈ 代价×6）。feed 已封顶，拉长间隔只会
    /// 「更频繁空闲」，不会再让单帧 feed 变大。积压靠每帧整体 drain（swap 取出）清空，
    /// 不会无界增长。
    var adaptiveFlushInterval: TimeInterval = TermSession.flushInterval

    /// 双缓冲：`drainingOutput` 保存正在消化的批次，`drainingOffset` 是下一个待 feed 的位置。
    /// pendingOutput 继续接收新数据，批次耗尽时才 swap —— 避免每帧重新分配。
    /// **随会话对象持有**（早先是全局 `[ObjectIdentifier: …]` 字典）：随 TermSession 一起
    /// 释放，不再依赖每条销毁路径手动清理，也杜绝 ObjectIdentifier 地址复用导致的 key 碰撞。
    var drainingOutput: [UInt8] = []
    var drainingOffset = 0
    /// 输出洪水硬上限（字节）：pendingOutput + draining 未消费部分的总积压超过此值时，
    /// 丢弃最旧的积压、只保留最新（洪水刷屏时用户本来也只看得清最新画面）。防止远端持续
    /// 高速输出（`yes` / `cat 大文件` / `cat /dev/urandom | base64`）时积压无界增长 → 内存
    /// 暴涨甚至 OOM。消化速率 ≈ maxFlushBytes×60fps ≈ 3.75MB/s，远端更快时靠此上限兜底。
    static let maxBacklogBytes = 8 * 1024 * 1024

    func appendOutput(_ s: String) {
        guard !s.isEmpty else { return }
        _outputChunks.append(s)
        _outputCount += s.count
        _merged = nil
        // 惰性裁剪：累计超过上限 2 倍时一次性把旧 chunk 合并裁剪（避免每块都裁）
        if _outputCount > Self.maxBufferChars * 2 {
            let merged = outputBuffer       // 触发合并 + 裁剪
            _outputChunks = [merged]
            _outputCount = merged.count
            _merged = merged
        }
    }
    func clearOutput() {
        _outputChunks.removeAll()
        _outputCount = 0
        _merged = nil
    }

    init(host: Host, termView: TerminalView, webSSHView: WebSSHView? = nil) {
        self.host = host
        self.termView = termView
        self.webSSHView = webSSHView
        self.title = host.display
        if webSSHView != nil {
            self.connected = true
            self.shellOpened = true
        }
    }
}
