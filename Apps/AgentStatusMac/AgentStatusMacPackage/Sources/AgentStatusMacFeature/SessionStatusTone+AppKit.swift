import AgentStatusCore
import AgentStatusDesignSystem
import AppKit
import SwiftUI

/// Session lifecycle colours (design system §4.1) on the light macOS window:
/// Running blue, Waiting for input green, Completed gray, Failed / Aborted red.
extension SessionStatusTone {
    /// Dot and status-text colour.
    var appKitColor: NSColor { NSColor(lightStyle.color) }

    var swiftUIColor: Color { Color(lightStyle.color) }

    /// Pill fill: tinted colour composited over a white veil.
    var pillFill: NSColor { NSColor(lightStyle.pillFill) }

    var pillStroke: NSColor { NSColor(lightStyle.pillRing) }

    var pillText: NSColor { NSColor(lightStyle.pillText) }

    /// Only the Running tone carries a halo around its dot (it "breathes").
    var dotHalo: NSColor? {
        switch self {
        case .blue: lightStyle.halo.map(NSColor.init)
        case .green, .gray, .red: nil
        }
    }
}
