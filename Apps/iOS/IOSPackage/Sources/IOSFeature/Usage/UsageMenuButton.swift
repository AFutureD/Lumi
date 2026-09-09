import DesignSystem
import UIKit

/// A tint title with a small `chevron.down` that opens a `UIMenu` on tap —
/// the range, scope and agent choosers of Usage › History. The title is
/// 18pt tall on screen; taps count anywhere in a 44pt box around it, so
/// the row holding it must be a `UsageMenuRow` (a plain row stops the
/// touch at its own 22pt bounds first).
final class UsageMenuButton: UIButton {
    private let style: DesignTextStyle

    init(style: DesignTextStyle) {
        self.style = style
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        configuration.imagePlacement = .trailing
        configuration.imagePadding = IOSDS.Usage.menuChevronGap
        configuration.baseForegroundColor = .tintColor
        configuration.image = UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: IOSDS.Usage.menuChevron + 4, weight: .semibold)
        )
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [style] incoming in
            var outgoing = incoming
            outgoing.font = UIFont.design(style)
            return outgoing
        }
        self.configuration = configuration
        showsMenuAsPrimaryAction = true
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// Hit test extended to the HIG minimum, centred on the visible title.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let minimum = IOSDS.Layout.minimumTapTarget
        let dx = min(0, (bounds.width - minimum) / 2)
        let dy = min(0, (bounds.height - minimum) / 2)
        return bounds.insetBy(dx: dx, dy: dy).contains(point)
    }

    var title: String {
        get { configuration?.title ?? "" }
        set { configuration?.title = newValue }
    }

    /// Single-selection menu; the chosen row carries a checkmark.
    func setChoices(_ titles: [String], selected: Int, onSelect: @escaping (Int) -> Void) {
        let actions = titles.enumerated().map { offset, title in
            UIAction(title: title, state: offset == selected ? .on : .off) { _ in onSelect(offset) }
        }
        menu = UIMenu(options: .singleSelection, children: actions)
        if selected < titles.count { self.title = titles[selected] }
    }
}

/// A horizontal row whose menu buttons' extended hit boxes reach past the
/// row's own bounds: the touch is offered to each arranged subview before
/// the row's bounds are checked.
final class UsageMenuRow: UIStackView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, isUserInteractionEnabled, alpha > 0.01 else { return nil }
        for subview in arrangedSubviews.reversed() where !subview.isHidden {
            let converted = subview.convert(point, from: self)
            if subview.point(inside: converted, with: event), let hit = subview.hitTest(converted, with: event) {
                return hit
            }
        }
        return super.hitTest(point, with: event)
    }
}
