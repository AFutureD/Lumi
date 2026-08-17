import AgentStatusCore
import AppKit
import SwiftUI

extension SessionStatusTone {
    var appKitColor: NSColor {
        switch self {
        case .blue: .systemBlue
        case .green: .systemGreen
        case .orange: .systemOrange
        case .gray: .secondaryLabelColor
        }
    }

    var swiftUIColor: Color {
        Color(nsColor: appKitColor)
    }
}
