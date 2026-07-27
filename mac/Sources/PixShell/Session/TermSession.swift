import AppKit
import SwiftTerm

/// 一个终端会话：独立的 TerminalView + NIOSSHSession + 所属主机 + 标题 + 凭据。
final class TermSession {
    let id = UUID().uuidString
    var host: Host   // 可变：首次连上识别出系统后会回填 osId（见 AppDelegate.detectRemoteOS）
    let termView: TerminalView
    var ssh: SSHSession?
    var title: String

    /// 标签栏显示的名字：**用户在连接管理器里设的名字**（`host.display` = name 为空才回退到 IP）。
    ///
    /// 不能用 `title` —— 那个会被远端 OSC 标题覆盖成系统报的名（`root@ubuntu24: ~`），
    /// 于是用户明明把主机命名为「台湾宽屏」，标签上却显示 `ubuntu24`，几台机器还会重名到分不清。
    /// 完整的远端标题仍保留在 `title` 里（tooltip、独立窗口标题用它）。
    var tabTitle: String {
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
    private(set) var outputBuffer = ""
    static let maxBufferChars = 500_000

    func appendOutput(_ s: String) {
        outputBuffer += s
        if outputBuffer.count > Self.maxBufferChars {
            outputBuffer = String(outputBuffer.suffix(Self.maxBufferChars))
        }
    }
    func clearOutput() { outputBuffer = "" }

    init(host: Host, termView: TerminalView) {
        self.host = host; self.termView = termView; self.title = host.display
    }
}
