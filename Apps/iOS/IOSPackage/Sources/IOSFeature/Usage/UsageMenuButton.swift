import DesignSystem
import UIKit

/// A tint title with a small `chevron.down` that opens a `UIMenu` on tap —
/// the range, scope and agent choosers of Usage › History.
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
