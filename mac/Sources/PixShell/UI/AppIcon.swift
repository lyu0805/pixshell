import AppKit

/// 应用图标（程序化绘制，无需资源文件）。
///
/// 为什么要有：这个二进制不是 .app bundle，没有图标资源，于是所有 NSAlert（新建连接 / 设置 /
/// 密码框…）左上角都显示成系统的**蓝色文件夹**占位图，很出戏。设置 `NSApp.applicationIconImage`
/// 之后，所有系统弹窗、Dock、⌘Tab 都会用这张图。
///
/// 造型沿用老仓库 `renderer/icons/app-icon.png` 的概念——终端屏幕 + `>` 提示符 + 光标块 + 底部三键，
/// 但按新版 macOS 的观感重做：**扁平化 + 圆角方块（squircle 近似）**，去掉老图那圈生硬的纯黑描边，
/// 改用深靛蓝渐变机身 + 更亮的屏幕，像素块保留（那是 PixShell 的"Pix"）。
enum AppIcon {

    /// 生成图标。size 为画布边长（点）。
    static func make(size: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            draw(size: size)
            return true
        }
    }

    /// 安装为 App 图标（Dock / ⌘Tab）。
    static func install() {
        NSApp.applicationIconImage = make(size: 512)
    }

    /// 弹窗用的小尺寸图标（缓存一份，别每个弹窗都重画）。
    static let alertIcon: NSImage = make(size: 128)

    // MARK: - 绘制
    private static func draw(size s: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldAntialias(true)

        // ── 机身：圆角方块（macOS 的 squircle 比例约 22.4% 圆角）
        let inset = s * 0.055
        let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let bodyRadius = body.width * 0.224
        let bodyPath = CGPath(roundedRect: body, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil)

        ctx.saveGState()
        ctx.addPath(bodyPath); ctx.clip()
        drawVerticalGradient(ctx, rect: body,
                             top: NSColor(srgbRed: 0.20, green: 0.25, blue: 0.38, alpha: 1),
                             bottom: NSColor(srgbRed: 0.09, green: 0.11, blue: 0.18, alpha: 1))
        ctx.restoreGState()

        // 顶部一道极淡的高光，扁平但不死板（新版 macOS 图标常见处理）
        ctx.saveGState()
        ctx.addPath(bodyPath); ctx.clip()
        let glare = CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2)
        drawVerticalGradient(ctx, rect: glare,
                             top: NSColor(white: 1, alpha: 0.10),
                             bottom: NSColor(white: 1, alpha: 0.0))
        ctx.restoreGState()

        // ── 屏幕：内嵌深色圆角矩形
        let sw = body.width * 0.70
        let sh = body.height * 0.50
        let screen = CGRect(x: body.midX - sw / 2, y: body.midY - sh / 2 + body.height * 0.07,
                            width: sw, height: sh)
        let scrRadius = sw * 0.075
        let scrPath = CGPath(roundedRect: screen, cornerWidth: scrRadius, cornerHeight: scrRadius, transform: nil)
        ctx.saveGState()
        ctx.addPath(scrPath); ctx.clip()
        ctx.setFillColor(NSColor(srgbRed: 0.043, green: 0.055, blue: 0.094, alpha: 1).cgColor)
        ctx.fill(screen)
        // 扫描线（老图那几条横纹的现代化版本：极淡）
        ctx.setFillColor(NSColor(white: 1, alpha: 0.035).cgColor)
        var y = screen.minY + sh * 0.16
        while y < screen.maxY {
            ctx.fill(CGRect(x: screen.minX, y: y, width: screen.width, height: max(1, s * 0.006)))
            y += sh * 0.20
        }
        ctx.restoreGState()

        // ── `>` 提示符：两段像素块拼出的箭头（PixShell 的"像素"意象）
        let px = sw * 0.088                       // 像素块边长
        let gap = px * 0.14
        let originX = screen.minX + sw * 0.14
        // 三块竖向跨度是 [originY-px-gap, originY+2px+gap]，几何中心在 originY+px/2；
        // 想让整组落在屏幕正中，originY 要往下让半块。
        let originY = screen.midY - px * 0.5
        let blue = NSColor(srgbRed: 0.29, green: 0.66, blue: 1.0, alpha: 1)
        // 上行 ↘、下行 ↗，形成 ">"
        pixel(ctx, x: originX, y: originY + px + gap, side: px, color: blue)
        pixel(ctx, x: originX + px + gap, y: originY, side: px, color: blue)
        pixel(ctx, x: originX, y: originY - px - gap, side: px, color: blue)

        // ── 光标块：绿色实心方块（老图里那块绿）
        let green = NSColor(srgbRed: 0.24, green: 0.85, blue: 0.50, alpha: 1)
        let cursorSide = px * 1.75
        pixel(ctx, x: originX + (px + gap) * 2.6, y: screen.midY - cursorSide / 2,
              side: cursorSide, color: green, radiusRatio: 0.16)

        // ── 底部三个键：粉 / 杏 / 绿（老图底部那排彩色小块）
        let keyW = body.width * 0.135
        let keyH = body.height * 0.055
        let keyY = body.minY + body.height * 0.115
        let keyGap = body.width * 0.065
        let totalW = keyW * 3 + keyGap * 2
        var keyX = body.midX - totalW / 2
        for c in [NSColor(srgbRed: 1.0, green: 0.45, blue: 0.58, alpha: 1),
                  NSColor(srgbRed: 1.0, green: 0.83, blue: 0.55, alpha: 1),
                  NSColor(srgbRed: 0.60, green: 0.88, blue: 0.55, alpha: 1)] {
            let r = CGRect(x: keyX, y: keyY, width: keyW, height: keyH)
            let p = CGPath(roundedRect: r, cornerWidth: keyH * 0.42, cornerHeight: keyH * 0.42, transform: nil)
            ctx.addPath(p); ctx.setFillColor(c.cgColor); ctx.fillPath()
            keyX += keyW + keyGap
        }
    }

    private static func pixel(_ ctx: CGContext, x: CGFloat, y: CGFloat, side: CGFloat,
                              color: NSColor, radiusRatio: CGFloat = 0.22) {
        let r = CGRect(x: x, y: y, width: side, height: side)
        let rad = side * radiusRatio
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }

    private static func drawVerticalGradient(_ ctx: CGContext, rect: CGRect, top: NSColor, bottom: NSColor) {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let g = CGGradient(colorsSpace: cs,
                                 colors: [top.cgColor, bottom.cgColor] as CFArray,
                                 locations: [0, 1]) else { return }
        ctx.drawLinearGradient(g,
                               start: CGPoint(x: rect.midX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.minY),
                               options: [])
    }
}

extension NSAlert {
    /// 统一入口：建一个带 PixShell 图标的弹窗。
    ///
    /// 直接 `NSAlert()` 的话，图标取的是 **bundle 里的应用图标**；这个二进制不是 .app bundle，
    /// 系统就回退成一张通用的**蓝色文件夹**图，于是"新建连接/设置/输密码"等所有对话框都顶着它，很出戏。
    /// 光设 `NSApp.applicationIconImage` 不够——那只改 Dock 图标，NSAlert 不跟着走，必须显式赋 `icon`。
    static func pix() -> NSAlert {
        let a = NSAlert()
        a.icon = AppIcon.alertIcon
        return a
    }
}
