import Core
import DesignSystem
import AppKit
import SwiftUI

/// Session status colours (design system §4.1) on the light macOS window —
/// the five tiers of `SessionStatusTone`: Running blue, Waiting (input /
/// approval) orange, Completed · unreviewed green, Completed gray, Failed /
/// Aborted red.
extension SessionStatusTone {
    /// Dot and status-text colour.
    var appKitColor: NSColor { NSColor(lightStyle.color) }

    var swiftUIColor: Color { Color(lightStyle.color) }

    var pillFill: NSColor { NSColor(lightStyle.pill.fill) }

    var pillStroke: NSColor { NSColor(lightStyle.pill.ring) }

    var pillText: NSColor { NSColor(lightStyle.pill.text) }

    /// Halo around the dot while the tier is in progress (Running / Waiting);
    /// it breathes. Ended tiers have none.
    var dotHalo: NSColor? { lightStyle.halo.map(NSColor.init) }
}
