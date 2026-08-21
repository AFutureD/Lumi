import AgentStatusDesignSystem
import AgentStatusTransport
import UIKit

/// Category tag (2.6): 10 / Semibold / .04em in a rounded rectangle with
/// the tier's fill, text and `.5px` ring. Padding and radius vary by place
/// (list row 1/5 r4, Activity row 2/7 r5, sheet 3/8 r5).
final class TagView: UIView {
    private let label = UILabel()
    private var tag_: TimelineTag?
    private var fixedStyle: DesignTagStyle?
    private var text = ""
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    private var top: NSLayoutConstraint!
    private var bottom: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .design(IOSDS.Typography.tag)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        addSubview(label)
        leading = label.leadingAnchor.constraint(equalTo: leadingAnchor)
        trailing = label.trailingAnchor.constraint(equalTo: trailingAnchor)
        top = label.topAnchor.constraint(equalTo: topAnchor)
        bottom = label.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([leading, trailing, top, bottom])
        layer.borderWidth = DS.Tag.ring
        layer.cornerCurve = .continuous
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: TagView, _) in
            self.applyColors()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// A fixed style (e.g. the filter chip) …
    func configure(
        label text: String,
        style: DesignTagStyle,
        verticalPadding: Double,
        horizontalPadding: Double,
        radius: Double
    ) {
        tag_ = nil
        fixedStyle = style
        apply(text: text, verticalPadding: verticalPadding, horizontalPadding: horizontalPadding, radius: radius)
    }

    /// … or the tag's own tier colours, re-resolved when the appearance flips.
    func configure(
        tag: TimelineTag,
        label text: String,
        verticalPadding: Double,
        horizontalPadding: Double,
        radius: Double
    ) {
        tag_ = tag
        fixedStyle = nil
        apply(text: text, verticalPadding: verticalPadding, horizontalPadding: horizontalPadding, radius: radius)
    }

    private func apply(text: String, verticalPadding: Double, horizontalPadding: Double, radius: Double) {
        self.text = text
        leading.constant = horizontalPadding
        trailing.constant = -horizontalPadding
        top.constant = verticalPadding
        bottom.constant = -verticalPadding
        layer.cornerRadius = radius
        applyColors()
    }

    private func applyColors() {
        guard let style = fixedStyle ?? tag_?.tagStyle(designAppearance) else { return }
        backgroundColor = style.fillColor
        layer.borderColor = style.ringColor.resolvedColor(with: traitCollection).cgColor
        label.attributedText = IOSDS.Typography.tag.attributed(text, color: style.textColor)
    }
}
