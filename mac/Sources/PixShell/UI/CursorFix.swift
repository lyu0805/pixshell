import AppKit

/// 全局鼠标指针修正。
///
/// 问题：SwiftTerm 的 `MacTerminalView` 里有
/// ```
/// public override func cursorUpdate(with event: NSEvent) { NSCursor.iBeam.set() }
/// ```
/// 这是**无条件**把指针设成 I 型。它是命令式 `set()`，不参与任何还原机制，
/// 所以鼠标离开终端后 I 型一路粘着走 —— 侧栏、顶栏、按钮全变成输入框光标。
///
/// **为什么不用 cursor rect（第一版和第二版都栽在这上面）**：
///  - v1 只在根视图铺一块 `.arrow` 的 cursor rect 当兜底 → 副作用是**文本输入区也被兜成箭头**，
///    编辑器里不显示 I 型；
///  - v2 又给文本视图补一块 `.iBeam` rect → I 型**离开文本区后照样粘着**，等于把老 bug 带回来。
/// 根子上：cursor rect 是**静态区域**，和别人命令式 `NSCursor.set()` 混用必然打架。
///
/// **现在的做法**：用 `cursorUpdate` + 覆盖全窗的 tracking area。
/// `cursorUpdate` 由 AppKit 按**指针下最深的那个装了 cursorUpdate 追踪区的视图**分发，
/// 且**每次鼠标移动都重新分发**，所以不会粘滞：
///  - 指针在终端/文本视图上 → 它们自己的 cursorUpdate 赢，显示 I 型；
///  - 指针在其它 chrome 上 → 落到根视图这里，设回箭头。
final class ArrowRootView: NSView {

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // .inVisibleRect 让区域随视图尺寸自动跟随，不用手动重建
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .cursorUpdate, .inVisibleRect],
            owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        // 不调 super：父类会把事件继续往下传，这里就是兜底的最后一站
        NSCursor.arrow.set()
    }
}
