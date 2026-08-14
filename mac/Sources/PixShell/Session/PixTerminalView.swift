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
///  - 正在回看滚回区（yDisp != 0）不触发；
///  - 只在当前光标所在行内移动（跨行 ↑↓ 在 readline 里是翻历史，绝不能发）。
final class PixTerminalView: TerminalView {
    /// 列差回调（负=左移，正=右移）。宿主负责把方向键字节真正下发到 SSH。
    var onCursorReposition: ((Int) -> Void)?

    private var downPoint: NSPoint?
    private var downWasDrag = false

    override func mouseDown(with event: NSEvent) {
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
        super.mouseUp(with: event)   // 保留链接点击 / 选择收尾等原行为
        guard event.clickCount < 2, down != nil, !wasDrag else { return }

        let t = getTerminal()
        guard !t.isCurrentBufferAlternate, t.mouseMode == .off else { return }
        let buf = t.buffer
        guard buf.yDisp == 0 else { return }
        guard let (cw, ch) = cellMetrics() else { return }

        let up = convert(event.locationInWindow, from: nil)
        let col = max(0, min(t.cols - 1, Int(up.x / cw)))
        let row = max(0, Int((bounds.height - up.y) / ch))
        guard row == buf.y else { return }
        let delta = col - buf.x
        guard delta != 0 else { return }
        onCursorReposition?(delta)
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
        let scale = window?.backingScaleFactor ?? 1
        let snappedW = ceil(w * scale) / scale
        let snappedH = ceil(h * scale) / scale
        return (max(1, snappedW), max(1, snappedH))
    }
}
