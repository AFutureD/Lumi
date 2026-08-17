import AgentStatusCore
import UIKit

extension SessionStatusTone {
    var uiKitColor: UIColor {
        switch self {
        case .blue: .systemBlue
        case .green: .systemGreen
        case .orange: .systemOrange
        case .gray: .secondaryLabel
        }
    }
}
