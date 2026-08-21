import AgentStatusDesignSystem
import UIKit

/// The four ink roles and the accent text, light / dark, as UIKit colours.
extension UIColor {
    static let inkPrimary = UIColor(AdaptiveDesignColor(light: DS.Ink.primary, dark: DS.InkDark.primary))
    static let inkSecondary = UIColor(AdaptiveDesignColor(light: DS.Ink.secondary, dark: DS.InkDark.secondary))
    static let inkTertiary = UIColor(AdaptiveDesignColor(light: DS.Ink.tertiary, dark: DS.InkDark.tertiary))
    static let inkQuaternary = UIColor(AdaptiveDesignColor(light: DS.Ink.quaternary, dark: DS.InkDark.quaternary))
    /// Blue 700 on light (`#0069D7`), Blue D400 on dark — text above a blue tint.
    static let accentText = UIColor(AdaptiveDesignColor(light: DS.Palette.blue.s700, dark: DS.InkDark.accentText))
    static let rowSeparator = UIColor(IOSDS.Color.rowSeparator)
    static let blockSeparator = UIColor(IOSDS.Color.blockSeparator)
}
