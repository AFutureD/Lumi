import AgentStatusCore
import AgentStatusDesignSystem
import UIKit

/// Session lifecycle colours (design system §4.1), following the trait
/// collection: the light ladder in light mode, the Notch's dark ladder in dark.
extension SessionStatusTone {
    var uiKitColor: UIColor {
        UIColor(AdaptiveDesignColor(light: lightStyle.color, dark: darkStyle.color))
    }
}
