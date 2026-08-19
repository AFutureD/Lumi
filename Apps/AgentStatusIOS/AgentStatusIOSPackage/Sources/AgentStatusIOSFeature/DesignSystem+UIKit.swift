import AgentStatusDesignSystem
import UIKit

// UIKit adapters over the shared design system. The iOS app keeps system
// controls (table cells, navigation bars); only colours and fonts that must
// match the other surfaces come from `DesignSystem`.

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
}

extension UIFont {
    static func design(_ style: DesignTextStyle) -> UIFont {
        let weight: UIFont.Weight = switch style.weight {
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
        switch style.family {
        case .sans:
            return .systemFont(ofSize: style.size, weight: weight)
        case .mono:
            return .monospacedSystemFont(ofSize: style.size, weight: weight)
        }
    }
}
