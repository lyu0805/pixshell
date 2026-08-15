import AppKit
import CoreText
import SwiftTerm

/// 单击移动 shell 光标的终端视图。
///
/// 经典终端里鼠标点击不影响 readline 光标 —— 只能用键盘 ←→ 一个个挪，
/// 长命令改中间一段极痛苦（用户原话：「只能用键盘➡️箭头来移动」）。
/// 现代终端（WindTerm / Tabby / iTerm2 shell 集成）通行的做法：
/// **单击落在当前光标行**时按列差发送对应数量的左/右方向键转义序列，
/// readline 收到后把光标移过去。对 shell 完全无侵入（方向键本来就合法）。
///
/// 安全边界（宁可不动，绝不错动）：
///  - 纯单击（非拖拽、非双击选词）才触发；
///  - 备用屏（vim/htop/less 全屏程序）不触发；
///  - 远端开了鼠标上报（mouseMode != .off，如 tmux 鼠标模式）不触发；
///  - 视口不在最底部（正在回看滚回区）不触发；
///  - 只在当前光标所在行内移动（跨行 ↑↓ 在 readline 里是翻历史，绝不能发）。
final class PixTerminalView: TerminalView {
    /// 列差回调（负=左移，正=右移）。宿主负责把方向键字节真正下发到 SSH。
    var onCursorReposition: ((Int) -> Void)?

    private var downPoint: NSPoint?
    private var downWasDrag = false
    /// mouseUp 排队的移动触发；下一次 mouseDown 若紧随而来（双击）会取消它。
    private var pendingReposition: DispatchWorkItem?
    /// 本次 mouseUp 是否被 SwiftTerm 判定为「点了链接」。
    /// super.mouseUp 命中链接时会 requestOpenLink 后直接 return（MacTerminalView.swift:2506），
    /// 子类无从感知；不拦这一下就会在浏览器弹出的同时把 shell 光标也挪走。
    /// linkForClick 是 internal 拿不到，只能靠覆盖这个委托方法打标记。
    fileprivate var openedLinkThisClick = false
    private lazy var delegateProxy = PixTerminalDelegateProxy(owner: self)

    private func ensureDelegateProxy() {
        if let current = terminalDelegate, current !== delegateProxy {
            delegateProxy.delegate = current
            terminalDelegate = delegateProxy
        }
    }

    override func mouseDown(with event: NSEvent) {
        // 紧接上一击的这次按下若是双击第二下，取消上一击排队的移动，避免选词前误移光标。
        ensureDelegateProxy()
        pendingReposition?.cancel()
        pendingReposition = nil
        downPoint = convert(event.locationInWindow, from: nil)
        downWasDrag = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let d = downPoint {
            let p = convert(event.locationInWindow, from: nil)
            if abs(p.x - d.x) + abs(p.y - d.y) > 4 { downWasDrag = true }
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let down = downPoint, wasDrag = downWasDrag
        downPoint = nil; downWasDrag = false
        openedLinkThisClick = false
        super.mouseUp(with: event)   // 保留链接点击 / 选择收尾等原行为
        // super 打开了链接就到此为止：那一下的语义是「点链接」，不是「移光标」。
        guard !openedLinkThisClick else { return }
        guard event.clickCount < 2, down != nil, !wasDrag else { return }

        let t = getTerminal()
        guard !t.isCurrentBufferAlternate, t.mouseMode == .off else { return }
        let buf = t.buffer
        // 判据是「视口停在最底部」，不是「yDisp == 0」：SwiftTerm 每输出一行都在
        // Terminal.scroll() 里让 yBase 与 yDisp 同步 +1，真实会话输出超过一屏后 yDisp
        // 恒 > 0 —— 用 yDisp==0 会让功能在任何实际会话里彻底失效；反过来回看到最顶部时
        // yDisp 又恰好 ==0，那时看的是历史行，会对当前 readline 误发方向键。真正该判断的
        // yBase / userScrolling 在 SwiftTerm 里是 internal 拿不到，只能用 public 的
        // canScroll + scrollPosition 组合还原语义：
        //  - 缓冲不足一屏：canScroll==false → 通过（此时 yDisp==yBase==0）；
        //  - 未回看且缓冲已满：scrollPosition==1 → 通过；
        //  - 回看到顶部：canScroll==true 且 scrollPosition==0 → 拒绝；
        //  - 回看到中间：0<scrollPosition<1 → 拒绝。
        guard !canScroll || scrollPosition >= 1 else { return }
        guard let (cw, ch) = cellMetrics() else { return }

        let up = convert(event.locationInWindow, from: nil)
        let col = max(0, min(t.cols - 1, Int(up.x / cw)))
        let row = max(0, Int((bounds.height - up.y) / ch))
        guard row == buf.y else { return }
        // 不能在这里立即触发：双击序列 down(1)/up(1)/down(2)/up(2) 的第一次 up 的
        // clickCount 仍是 1，会赶在选词前先发方向键。把触发挂成 pending 工作项延迟到双击
        // 间隔之后，若期间来了新的 mouseDown（第二击）就在那里 cancel 掉。
        //
        // 差值必须在**触发时刻**重算，不能捕获此刻的值：延迟的这段时间里终端仍在收数据
        // （提示符重绘、后台任务输出、用户继续打字都会挪动 buffer.x），拿陈旧差值发方向键
        // 会把光标移到错误的列。同理要重新校验行与回看状态。
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let t = self.getTerminal()
            guard !t.isCurrentBufferAlternate, t.mouseMode == .off else { return }
            guard !self.canScroll || self.scrollPosition >= 1 else { return }
            let buf = t.buffer
            guard row == buf.y else { return }
            // buffer.x 处于 pending-wrap 时可等于 cols（Buffer.swift 注释明示 x 有时越界）：
            // 命令敲满整行时 buf.x==cols，而点击列被钳到 cols-1，直接相减会凭空多出一个 ←
            // 把光标左移一格。先把光标列也钳进可见范围再算差值。
            let cursorCol = min(buf.x, t.cols - 1)
            let delta = col - cursorCol
            guard delta != 0 else { return }
            self.onCursorReposition?(delta)
        }
        pendingReposition = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    /// 视图被移出窗口（关标签 / 切会话 / 分离）时丢掉排队中的移动：
    /// 那一下的目标会话已经不在眼前了，延迟触发只会把方向键发给一个用户没在看的 shell。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            pendingReposition?.cancel()
            pendingReposition = nil
        }
    }

    /// 与 SwiftTerm computeFontDimensions（AppleTerminalView.swift:249）逐项对齐：
    /// 宽 = "W" 字形步进；高 = ceil((ascent+descent+leading) × lineSpacing)；
    /// 再 snap 到像素网格（Retina 下 7.83→8.0）。缺 lineSpacing 乘数或缺 snap 都会
    /// 让单击换算的列坐标与真实渲染累积偏移（尤其 Retina 屏整列错位）。
    private func cellMetrics() -> (CGFloat, CGFloat)? {
        let f = font
        let w = f.advancement(forGlyph: f.glyph(withName: "W")).width
        let h = ceil((CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)) * lineSpacing)
        guard w > 0, h > 0 else { return nil }
        // 三级回退与 SwiftTerm backingScaleFactor()（MacTerminalView.swift:756）完全一致：
        // 视图尚未加入窗口时（后台 / 离屏 / 初始化）window 为 nil，若只回退到 1 而 SwiftTerm
        // 按屏幕的 2 做像素 snap，Retina 下换算出的列坐标会与真实渲染整列错位。
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let snappedW = ceil(w * scale) / scale
        let snappedH = ceil(h * scale) / scale
        return (max(1, snappedW), max(1, snappedH))
    }
}

private final class PixTerminalDelegateProxy: TerminalViewDelegate {
    weak var delegate: TerminalViewDelegate?
    weak var owner: PixTerminalView?

    init(owner: PixTerminalView) {
        self.owner = owner
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        delegate?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        delegate?.setTerminalTitle(source: source, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        delegate?.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        delegate?.send(source: source, data: data)
    }

    func scrolled(source: TerminalView, position: Double) {
        delegate?.scrolled(source: source, position: position)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        owner?.openedLinkThisClick = true
        delegate?.requestOpenLink(source: source, link: link, params: params)
    }

    func bell(source: TerminalView) {
        delegate?.bell(source: source)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        delegate?.clipboardCopy(source: source, content: content)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        delegate?.clipboardRead(source: source)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        delegate?.iTermContent(source: source, content: content)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        delegate?.rangeChanged(source: source, startY: startY, endY: endY)
    }
}
