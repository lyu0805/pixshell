import AppKit

/// 状态栏品牌前的 GitHub Mark；点击打开仓库主页。
final class GitHubMarkButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        wantsLayer = true
        bezelStyle = .regularSquare
        focusRingType = .none
        toolTip = "在浏览器打开 GitHub 仓库"
        title = ""
        image = Self.makeMarkImage(size: 14)
        contentTintColor = Theme.muted
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// 官方 GitHub Mark（Simple Icons path，viewBox 0 0 24 24），template 染色。
    static func makeMarkImage(size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            NSColor.black.setFill()
            if let cg = SVGPath.parse(Self.markPath, scale: size / 24.0, flipY: true, viewBox: 24),
               let bez = Self.bezier(from: cg) {
                bez.fill()
            } else {
                // 兜底：圆角方块
                NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                             xRadius: size * 0.2, yRadius: size * 0.2).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// CGPath → NSBezierPath（兼容 macOS 13，不依赖 macOS 14 的 init(cgPath:)）
    private static func bezier(from cg: CGPath) -> NSBezierPath? {
        let bez = NSBezierPath()
        cg.applyWithBlock { ptr in
            let e = ptr.pointee
            switch e.type {
            case .moveToPoint:
                bez.move(to: e.points[0])
            case .addLineToPoint:
                bez.line(to: e.points[0])
            case .addQuadCurveToPoint:
                let c = e.points[0], p = e.points[1]
                let cur = bez.currentPoint
                // 二次 → 三次近似
                let c1 = NSPoint(x: cur.x + 2.0/3.0 * (c.x - cur.x), y: cur.y + 2.0/3.0 * (c.y - cur.y))
                let c2 = NSPoint(x: p.x   + 2.0/3.0 * (c.x - p.x),   y: p.y   + 2.0/3.0 * (c.y - p.y))
                bez.curve(to: p, controlPoint1: c1, controlPoint2: c2)
            case .addCurveToPoint:
                bez.curve(to: e.points[2], controlPoint1: e.points[0], controlPoint2: e.points[1])
            case .closeSubpath:
                bez.close()
            @unknown default:
                break
            }
        }
        return bez
    }

    private static let markPath =
        "M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"
}

/// 极简 SVG path 解析（覆盖 GitHub mark 的 M/c/C/z）。
enum SVGPath {
    static func parse(_ d: String, scale s: CGFloat, flipY: Bool, viewBox: CGFloat) -> CGPath? {
        let path = CGMutablePath()
        var i = d.startIndex
        var cur = CGPoint.zero
        var start = CGPoint.zero
        func skipWS() {
            while i < d.endIndex, d[i].isWhitespace || d[i] == "," { i = d.index(after: i) }
        }
        func readNum() -> CGFloat? {
            skipWS()
            guard i < d.endIndex else { return nil }
            let begin = i
            if d[i] == "-" || d[i] == "+" { i = d.index(after: i) }
            while i < d.endIndex, d[i].isNumber || d[i] == "." || d[i] == "e" || d[i] == "E" {
                i = d.index(after: i)
            }
            guard begin < i, let v = Double(String(d[begin..<i])) else { return nil }
            return CGFloat(v)
        }
        func map(_ p: CGPoint) -> CGPoint {
            flipY ? CGPoint(x: p.x * s, y: (viewBox - p.y) * s) : CGPoint(x: p.x * s, y: p.y * s)
        }
        var cmd: Character = "M"
        while i < d.endIndex {
            skipWS()
            guard i < d.endIndex else { break }
            if d[i].isLetter {
                cmd = d[i]
                i = d.index(after: i)
            }
            switch cmd {
            case "M", "m":
                guard let x = readNum(), let y = readNum() else { return nil }
                let abs = cmd == "M"
                cur = abs ? CGPoint(x: x, y: y) : CGPoint(x: cur.x + x, y: cur.y + y)
                path.move(to: map(cur)); start = cur
                while let x2 = readNum(), let y2 = readNum() {
                    cur = abs ? CGPoint(x: x2, y: y2) : CGPoint(x: cur.x + x2, y: cur.y + y2)
                    path.addLine(to: map(cur))
                }
            case "C", "c":
                let abs = cmd == "C"
                while true {
                    guard let x1 = readNum(), let y1 = readNum(),
                          let x2 = readNum(), let y2 = readNum(),
                          let x = readNum(), let y = readNum() else { break }
                    let c1 = abs ? CGPoint(x: x1, y: y1) : CGPoint(x: cur.x + x1, y: cur.y + y1)
                    let c2 = abs ? CGPoint(x: x2, y: y2) : CGPoint(x: cur.x + x2, y: cur.y + y2)
                    let p  = abs ? CGPoint(x: x, y: y) : CGPoint(x: cur.x + x, y: cur.y + y)
                    path.addCurve(to: map(p), control1: map(c1), control2: map(c2))
                    cur = p
                }
            case "Z", "z":
                path.closeSubpath(); cur = start
            default:
                _ = readNum()
            }
        }
        return path
    }
}
