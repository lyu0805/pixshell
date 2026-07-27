import AppKit

/// 标签拖动手势：**拖出足够距离才生效**。
///
/// 为什么要门槛：标签上还有"点击切换 / 点 ✕ 关闭 / 右键菜单"，
/// 手一抖就把会话甩到新窗口去是很烦的。所以只有拖动位移超过 `threshold` 才触发分离，
/// 手一抖就把会话甩到新窗口去是很烦的。所以只有拖动位移超过 `threshold` 才触发分离，
/// 而且一次手势只触发一次（`fired`），不会拖着走的过程中反复弹窗口。
final class TabDragGesture: NSPanGestureRecognizer, NSGestureRecognizerDelegate {
    /// 触发分离所需的最小拖动距离（点）。取值偏大是刻意的 —— 宁可要多拖一点，也别误触。
    static let threshold: CGFloat = 70

    let index: Int
    /// 本次手势是否已经触发过分离
    var fired = false

    init(index: Int, target: AnyObject?, action: Selector?) {
        self.index = index
        super.init(target: target, action: action)
        self.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        if let view = gestureRecognizer.view,
           let hitView = view.hitTest(event.locationInWindow) {
            if hitView is NSControl { return false }
        }
        return true
    }

    /// 位移是否已经越过门槛
    func passedThreshold(in view: NSView?) -> Bool {
        let t = translation(in: view)
        return (t.x * t.x + t.y * t.y).squareRoot() >= Self.threshold
    }
}

/// 被拖出来的会话所在的独立窗口。
///
/// **范围说明（别误解成完整主窗）**：它只承载**终端本体**（活的 SSH 连接 + 同一个 termView，
/// 连接不会断、不会重连）。侧栏监控 / 文件面板 / 命令板这些 chrome 不跟过来 ——
/// 那些要每窗口一份，等于把整套界面抽成 WindowController，是另一个量级的重构。
/// 关闭本窗口 = 断开该会话。
final class DetachedTermWindow: NSWindow {
    /// 关闭时回调宿主（让它释放会话）
    var onClosed: (() -> Void)?

    init(title: String, termView: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        minSize = NSSize(width: 420, height: 260)
        appearance = NSAppearance(named: Theme.dark ? .darkAqua : .aqua)

        let host = NSView(frame: contentRect(forFrameRect: frame))
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = Theme.term.cgColor
        termView.frame = host.bounds
        termView.autoresizingMask = [.width, .height]
        host.addSubview(termView)
        contentView = host
        center()
    }

    override func close() {
        onClosed?()
        super.close()
    }
}
