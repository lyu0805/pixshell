import AppKit

/// 自动换行的流式布局容器（AppKit 没有现成的 —— NSStackView 只会挤在一行/一列，不换行）。
///
/// 命令板需要它：老仓库的分类文件夹和命令列表都是**排满一行就折到下一行**，
/// 之前用 NSStackView + 横向滚动条硬凑，结果是命令被裁掉半截、根本没法点。
///
/// 高度靠自管的 `heightC` 约束回报给父视图 —— 流式布局的高度取决于**宽度**，
/// 而 `intrinsicContentSize` 拿不到最终宽度，所以只能在 layout() 里算完再写回约束。
final class FlowView: NSView {
    var hGap: CGFloat = 6
    var vGap: CGFloat = 6
    /// 左右内缩（放进带边框的盒子里时留点呼吸）
    var inset = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

    private var heightC: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightC = heightAnchor.constraint(equalToConstant: 0)
        heightC.priority = .defaultHigh   // 别和外部的等宽/贴边约束打架
        heightC.isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 内容从**顶部**开始排（否则会沉底）
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let maxW = bounds.width - inset.left - inset.right
        guard maxW > 1 else { return }

        var x = inset.left
        var y = inset.top
        var rowH: CGFloat = 0

        for v in subviews where !v.isHidden {
            let s = v.fittingSize
            // 一行放不下就折行（行首那个即使超宽也不折，否则会死循环）
            if x > inset.left, x + s.width > maxW + inset.left {
                x = inset.left
                y += rowH + vGap
                rowH = 0
            }
            v.frame = NSRect(x: x, y: y, width: s.width, height: s.height)
            x += s.width + hGap
            rowH = max(rowH, s.height)
        }

        let total = y + rowH + inset.bottom
        // 只在真的变了才写回，避免 layout 抖动/递归
        if abs(heightC.constant - total) > 0.5 {
            heightC.constant = total
        }
    }

    /// 换内容后调用：清空并重排。
    ///
    /// **关键**：子视图必须切回 `translatesAutoresizingMaskIntoConstraints = true`（frame 布局）。
    /// 流式布局是我们自己算 frame 的，子视图若还是 false，Auto Layout 会把我们设的 frame 覆盖掉；
    /// 而它们又没有相对本容器的位置约束 → 全塌到原点互相重叠（标签栏实测：9 个标签只画出 1 个、
    /// 圆点和文字叠在一起）。
    /// 子视图**内部**的约束不受影响 —— 外层 frame 由我们定，内部照旧 Auto Layout，这是标准配合方式。
    func setItems(_ views: [NSView]) {
        subviews.forEach { $0.removeFromSuperview() }
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = true
            addSubview(v)
        }
        needsLayout = true
    }
}
