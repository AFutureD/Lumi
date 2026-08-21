import AgentStatusCore
import AgentStatusDesignSystem
import UIKit

/// The session status dot (§4.1): tone colour, breathing while the tier
/// wants the human (Running / Waiting / Unreviewed), a halo only while
/// Running (blue). Ended tiers are still.
final class StatusDotView: UIView {
    private let haloLayer = CALayer()
    private let dotLayer = CALayer()
    private let size: CGFloat
    private var tone: SessionStatusTone = .gray
    private var animates = true

    init(size: CGFloat) {
        self.size = size
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        isUserInteractionEnabled = false
        layer.addSublayer(haloLayer)
        layer.addSublayer(dotLayer)
        haloLayer.cornerRadius = size / 2
        dotLayer.cornerRadius = size / 2
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: StatusDotView, _) in
            self.applyColors()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(restartAnimations),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize { CGSize(width: size, height: size) }

    /// `animates: false` keeps the dot still regardless of tone (subagent chips).
    func configure(tone: SessionStatusTone, animates: Bool = true) {
        self.tone = tone
        self.animates = animates
        applyColors()
        restartAnimations()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frame = CGRect(x: 0, y: 0, width: size, height: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        haloLayer.bounds = frame
        haloLayer.position = CGPoint(x: size / 2, y: size / 2)
        dotLayer.bounds = frame
        dotLayer.position = CGPoint(x: size / 2, y: size / 2)
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        restartAnimations()
    }

    private func applyColors() {
        let color = tone.uiKitColor.resolvedColor(with: traitCollection).cgColor
        dotLayer.backgroundColor = color
        haloLayer.backgroundColor = color
    }

    @objc private func restartAnimations() {
        dotLayer.removeAllAnimations()
        haloLayer.removeAllAnimations()
        haloLayer.opacity = 0
        dotLayer.opacity = 1
        guard window != nil, animates, tone.dotForm == .breathing else { return }
        let period = IOSDS.Motion.period

        let breatheOpacity = CABasicAnimation(keyPath: "opacity")
        breatheOpacity.fromValue = 1
        breatheOpacity.toValue = IOSDS.Motion.breatheOpacity
        let breatheScale = CABasicAnimation(keyPath: "transform.scale")
        breatheScale.fromValue = 1
        breatheScale.toValue = IOSDS.Motion.breatheScale
        let breathe = CAAnimationGroup()
        breathe.animations = [breatheOpacity, breatheScale]
        breathe.duration = period / 2
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dotLayer.add(breathe, forKey: "breathe")

        guard tone == .blue else { return }
        let haloOpacity = CABasicAnimation(keyPath: "opacity")
        haloOpacity.fromValue = IOSDS.Motion.haloOpacity
        haloOpacity.toValue = 0
        let haloScale = CABasicAnimation(keyPath: "transform.scale")
        haloScale.fromValue = 1
        haloScale.toValue = IOSDS.Motion.haloScale
        let halo = CAAnimationGroup()
        halo.animations = [haloOpacity, haloScale]
        halo.duration = period
        halo.repeatCount = .infinity
        halo.timingFunction = CAMediaTimingFunction(name: .easeOut)
        haloLayer.add(halo, forKey: "halo")
    }
}
