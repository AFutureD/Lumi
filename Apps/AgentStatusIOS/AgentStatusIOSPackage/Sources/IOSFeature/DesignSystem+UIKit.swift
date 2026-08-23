import DesignSystem
import UIKit

// UIKit adapters over the shared design system. System controls keep their
// system metrics and colours; the product's own rows, chips, tags and lanes
// read every value from `DesignSystem.IOS`.

typealias DS = DesignSystem
typealias IOSDS = DesignSystem.IOS

extension UIColor {
    convenience init(_ design: DesignColor) {
        self.init(red: design.red, green: design.green, blue: design.blue, alpha: design.alpha)
    }

    /// Trait-aware colour: `light` in light mode, `dark` in dark mode.
    convenience init(_ design: AdaptiveDesignColor) {
        self.init { traits in
            UIColor(traits.userInterfaceStyle == .dark ? design.dark : design.light)
        }
    }

    /// The hue's base on the current appearance (light ramp / dark ramp).
    convenience init(hue: DesignHue) {
        self.init(AdaptiveDesignColor(light: hue.base, dark: hue.darkBase))
    }
}

extension DesignFontWeight {
    var uiKit: UIFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
    }
}

extension UIFont {
    /// System font for a design text style. Mono styles use the monospaced
    /// system font; `tabular` asks the sans font for tabular numerals.
    static func design(_ style: DesignTextStyle, tabular: Bool = false) -> UIFont {
        switch style.family {
        case .sans:
            return tabular
                ? .monospacedDigitSystemFont(ofSize: style.size, weight: style.weight.uiKit)
                : .systemFont(ofSize: style.size, weight: style.weight.uiKit)
        case .mono:
            return .monospacedSystemFont(ofSize: style.size, weight: style.weight.uiKit)
        }
    }
}

extension DesignTextStyle {
    /// Font + kern + fixed line height, for multi-line labels.
    func attributes(color: UIColor, tabular: Bool = false) -> [NSAttributedString.Key: Any] {
        let font = UIFont.design(self, tabular: tabular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = .byTruncatingTail
        // Centre the glyphs in the line box the way CSS line-height does.
        let baselineOffset = (lineHeight - font.lineHeight) / 2
        return [
            .font: font,
            .foregroundColor: color,
            .kern: tracking,
            .paragraphStyle: paragraph,
            .baselineOffset: baselineOffset,
        ]
    }

    func attributed(_ text: String, color: UIColor, tabular: Bool = false) -> NSAttributedString {
        NSAttributedString(string: text, attributes: attributes(color: color, tabular: tabular))
    }
}

extension UILabel {
    /// Applies a design style as the label's font and (for multi-line text)
    /// its line height and tracking.
    func setText(_ text: String, style: DesignTextStyle, color: UIColor, tabular: Bool = false) {
        font = .design(style, tabular: tabular)
        textColor = color
        attributedText = style.attributed(text, color: color, tabular: tabular)
    }
}

extension DesignTagStyle {
    var fillColor: UIColor { UIColor(fill) }
    var textColor: UIColor { UIColor(text) }
    var ringColor: UIColor { UIColor(ring) }
}

extension DesignStatusPillStyle {
    var fillColor: UIColor { UIColor(fill) }
    var ringColor: UIColor { UIColor(ring) }
    var dotColor: UIColor { UIColor(dot) }
    var textColor: UIColor { UIColor(text) }
}

extension UIView {
    /// The light or dark design appearance of the view's trait collection.
    var designAppearance: DesignAppearance {
        traitCollection.userInterfaceStyle == .dark ? .dark : .light
    }
}

/// A hairline that stays one device pixel on every scale.
extension UIView {
    static func hairline(color: UIColor) -> UIView {
        let view = UIView()
        view.backgroundColor = color
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: DS.Stroke.hairline).isActive = true
        return view
    }
}

/// Chevron `7 × 11` in `Ink.chevron`, used at the end of rows.
final class ChevronView: UIImageView {
    init() {
        let configuration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        super.init(image: UIImage(systemName: "chevron.right", withConfiguration: configuration))
        tintColor = UIColor(DS.Ink.chevron)
        contentMode = .scaleAspectFit
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: IOSDS.Layout.chevronWidth + 2),
            heightAnchor.constraint(equalToConstant: IOSDS.Layout.chevronHeight + 2),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }
}
