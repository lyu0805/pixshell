import AppKit

/// 机器人图标（坞里「对话」按钮用）。
///
/// 为什么自己画：SF Symbols 里没有机器人这个符号（brain/sparkles 都不是那个意思）；
/// emoji 🤖 是彩色的，跟不了主题。这里画成 **template image**（只有形状+alpha），
/// AppKit 会用 `contentTintColor` 给它上色 —— 深色/浅色/水墨/复古四套主题下都自动搭配，
/// 不用为每套主题各准备一张图。
enum RobotIcon {

    /// size 为画布边长（点）。返回的是模板图，调用方用 contentTintColor 控制颜色。
    static func image(size: CGFloat = 15) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            draw(size)
            return true
        }
        img.isTemplate = true    // 关键：交给 AppKit 按 tint 着色
        return img
    }

    private static func draw(_ s: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldAntialias(true)
        NSColor.black.setFill()      // 模板图只看形状，颜色随便

        let lw = max(1, s * 0.085)   // 线宽随尺寸缩放，小尺寸也不糊

        // 天线：中间一根竖线 + 顶上一个小圆点
        let antH = s * 0.16
        let dotR = s * 0.075
        ctx.fill(CGRect(x: s/2 - lw/2, y: s * 0.70, width: lw, height: antH))
        ctx.fillEllipse(in: CGRect(x: s/2 - dotR, y: s * 0.70 + antH - dotR * 0.4,
                                   width: dotR * 2, height: dotR * 2))

        // 头：圆角矩形描边（描边而非实心，小尺寸下更透气、也更像"标志"）
        let head = CGRect(x: s * 0.16, y: s * 0.24, width: s * 0.68, height: s * 0.46)
        let r = s * 0.14
        let path = CGPath(roundedRect: head.insetBy(dx: lw/2, dy: lw/2),
                          cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.addPath(path)
        ctx.setLineWidth(lw)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.strokePath()

        // 两只眼睛
        let eyeR = s * 0.062
        let eyeY = head.midY - eyeR + s * 0.02
        ctx.fillEllipse(in: CGRect(x: head.minX + head.width * 0.26 - eyeR, y: eyeY, width: eyeR * 2, height: eyeR * 2))
        ctx.fillEllipse(in: CGRect(x: head.minX + head.width * 0.74 - eyeR, y: eyeY, width: eyeR * 2, height: eyeR * 2))

        // 两侧的耳朵/天线座
        let earW = s * 0.06, earH = s * 0.14
        ctx.fill(CGRect(x: head.minX - earW * 0.6, y: head.midY - earH/2, width: earW, height: earH))
        ctx.fill(CGRect(x: head.maxX - earW * 0.4, y: head.midY - earH/2, width: earW, height: earH))
    }
}
