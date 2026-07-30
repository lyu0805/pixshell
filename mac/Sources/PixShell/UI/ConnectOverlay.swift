import AppKit

/// 连接动画（覆盖在终端区上方）。
/// 取代老实现往终端里 feed 的那行「连接中 root@ip:22 …」—— 终端里应该只有远端的输出，
/// 连接过程属于 App 自己的 UI，用动画表达：脉冲圆点 + 主机名 + 分步状态。
///
/// 生命周期：beginSession 时 show() → 打开 shell 时 succeed() 淡出 → 失败时 fail() 显示红字后淡出。
final class ConnectOverlay: NSView {

    private let card = NSView()
    private let pulse = PulseDot()
    private let titleLabel = NSTextField(labelWithString: "")
    private let stepLabel = NSTextField(labelWithString: "")
    private let bar = IndeterminateBar()
    private var stepTimer: Timer?
    private var stepIndex = 0

    /// 分步文案（对齐真实 SSH 流程的观感；不是真进度，只表达"在动"）
    private static let steps = ["正在建立 TCP 连接…", "SSH 握手…", "身份认证…", "打开会话…"]

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); build() }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.withAlphaComponent(0.92).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        titleLabel.font = Theme.ui(15, .semibold); titleLabel.textColor = Theme.text
        titleLabel.alignment = .center
        stepLabel.font = Theme.ui(12); stepLabel.textColor = Theme.muted
        stepLabel.alignment = .center

        let stack = NSStackView(views: [pulse, titleLabel, stepLabel, bar])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            bar.widthAnchor.constraint(equalToConstant: 220),
        ])
    }

    /// 开始：贴满 host 视图并播放动画。
    func show(in host: NSView, title: String) {
        stepTimer?.invalidate()
        stepIndex = 0
        titleLabel.stringValue = title
        stepLabel.stringValue = Self.steps[0]
        stepLabel.textColor = Theme.muted
        alphaValue = 1
        isHidden = false

        if superview !== host {
            removeFromSuperview()
            host.addSubview(self)
            NSLayoutConstraint.activate([
                topAnchor.constraint(equalTo: host.topAnchor),
                bottomAnchor.constraint(equalTo: host.bottomAnchor),
                leadingAnchor.constraint(equalTo: host.leadingAnchor),
                trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ])
        }
        host.addSubview(self, positioned: .above, relativeTo: nil)   // 始终压在终端之上

        pulse.start(); bar.start()
        // 分步文案往前走；停在最后一步（真正连上/失败由外部调用收尾）
        stepTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.stepIndex = min(self.stepIndex + 1, Self.steps.count - 1)
            self.stepLabel.stringValue = Self.steps[self.stepIndex]
        }
    }

    /// 连上了：绿色对勾一闪即淡出。
    func succeed() {
        guard !isHidden else { return }
        stepTimer?.invalidate(); stepTimer = nil
        stepLabel.stringValue = "已连接"
        stepLabel.textColor = Theme.ok
        pulse.stop(ok: true); bar.stop()
        fadeOut(after: 0.28)
    }

    /// 失败：红字提示后淡出（密码重试框由调用方弹）。
    func fail(_ reason: String) {
        guard !isHidden else { return }
        stepTimer?.invalidate(); stepTimer = nil
        stepLabel.stringValue = reason
        stepLabel.textColor = Theme.err
        pulse.stop(ok: false); bar.stop()
        fadeOut(after: 0.9)
    }

    func hideNow() {
        stepTimer?.invalidate(); stepTimer = nil
        pulse.stop(ok: false); bar.stop()
        isHidden = true
        removeFromSuperview()
    }

    private func fadeOut(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, !self.isHidden else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.isHidden = true
                self?.removeFromSuperview()
                self?.alphaValue = 1
            })
        }
    }
}

/// 脉冲圆点：外圈一圈圈扩散（连接中的呼吸感）。
final class PulseDot: NSView {
    private let core = CALayer()
    private let ring = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 44).isActive = true
        heightAnchor.constraint(equalToConstant: 44).isActive = true
        ring.backgroundColor = Theme.accent.withAlphaComponent(0.35).cgColor
        core.backgroundColor = Theme.accent.cgColor
        layer?.addSublayer(ring); layer?.addSublayer(core)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let coreSize: CGFloat = 12, ringSize: CGFloat = 34
        core.frame = CGRect(x: c.x - coreSize/2, y: c.y - coreSize/2, width: coreSize, height: coreSize)
        core.cornerRadius = coreSize / 2
        ring.frame = CGRect(x: c.x - ringSize/2, y: c.y - ringSize/2, width: ringSize, height: ringSize)
        ring.cornerRadius = ringSize / 2
    }

    func start() {
        ring.removeAllAnimations()
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.45; scale.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.55; fade.toValue = 0.0
        let g = CAAnimationGroup()
        g.animations = [scale, fade]
        g.duration = 1.35
        g.repeatCount = .infinity
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(g, forKey: "pulse")
        core.backgroundColor = Theme.accent.cgColor
    }

    func stop(ok: Bool) {
        ring.removeAllAnimations()
        ring.opacity = 0
        core.backgroundColor = (ok ? Theme.ok : Theme.err).cgColor
    }
}

/// 不确定进度条：一段高亮来回滑动。
final class IndeterminateBar: NSView {
    private let track = CALayer()
    private let chunk = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 3).isActive = true
        track.backgroundColor = Theme.fill.cgColor
        chunk.backgroundColor = Theme.accent.cgColor
        layer?.addSublayer(track); layer?.addSublayer(chunk)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        chunk.frame = CGRect(x: 0, y: 0, width: bounds.width * 0.32, height: bounds.height)
        chunk.cornerRadius = bounds.height / 2
    }

    func start() {
        chunk.removeAllAnimations()
        chunk.isHidden = false
        layoutSubtreeIfNeeded()
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = -bounds.width * 0.16
        a.toValue = bounds.width * 1.16
        a.duration = 1.1
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        chunk.add(a, forKey: "slide")
    }

    func stop() { chunk.removeAllAnimations(); chunk.isHidden = true }
}
