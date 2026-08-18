import AgentStatusCore
import AppKit
import SwiftUI

/// Status colours from the handoff (Running / Waiting / Completed / Connected).
extension SessionStatusTone {
    /// Dot and status-text colour.
    var appKitColor: NSColor {
        switch self {
        case .blue: NSColor(hex: 0x0078F0)
        case .orange: NSColor(hex: 0xB4741F)
        case .gray: NSColor(hex: 0x6E7178)
        case .green: NSColor(hex: 0x1DA84C)
        }
    }

    var swiftUIColor: Color {
        Color(nsColor: appKitColor)
    }

    /// Pill fill: tinted colour composited over a white veil.
    var pillFill: NSColor {
        switch self {
        case .blue: NSColor(hex: 0x0078F0, alpha: 0.16).blendedOverWhiteVeil()
        case .orange: NSColor(hex: 0xB4741F, alpha: 0.16).blendedOverWhiteVeil()
        case .gray: NSColor(red: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.12)
        case .green: NSColor(hex: 0x1DA84C, alpha: 0.16).blendedOverWhiteVeil()
        }
    }

    var pillStroke: NSColor {
        switch self {
        case .blue: NSColor(hex: 0x0078F0, alpha: 0.28)
        case .orange: NSColor(hex: 0xB4741F, alpha: 0.28)
        case .gray: NSColor(white: 0, alpha: 0.06)
        case .green: NSColor(hex: 0x1DA84C, alpha: 0.28)
        }
    }

    var pillText: NSColor {
        switch self {
        case .blue: NSColor(hex: 0x0069D7)
        case .orange: NSColor(hex: 0x8C5813)
        case .gray: NSColor(hex: 0x404040)
        case .green: NSColor(hex: 0x157A38)
        }
    }

    /// Only the Running tone carries a halo around its dot.
    var dotHalo: NSColor? {
        switch self {
        case .blue: NSColor(hex: 0x0078F0, alpha: 0.18)
        case .orange, .gray, .green: nil
        }
    }
}

private extension NSColor {
    /// The handoff layers `rgba(255,255,255,.35)` above the tint; fold it into one colour.
    func blendedOverWhiteVeil() -> NSColor {
        let veil = NSColor(white: 1, alpha: 0.35)
        guard let tint = usingColorSpace(.sRGB) else { return self }
        // Composite veil over tint (both premultiplied over an implicit white surface).
        let alpha = veil.alphaComponent + tint.alphaComponent * (1 - veil.alphaComponent)
        func channel(_ t: CGFloat) -> CGFloat {
            (1 * veil.alphaComponent + t * tint.alphaComponent * (1 - veil.alphaComponent)) / alpha
        }
        return NSColor(
            red: channel(tint.redComponent),
            green: channel(tint.greenComponent),
            blue: channel(tint.blueComponent),
            alpha: alpha
        )
    }
}
