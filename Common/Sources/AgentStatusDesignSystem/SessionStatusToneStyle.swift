import AgentStatusCore
import Foundation

/// Session lifecycle colours (L4 · 生命周期三档 + 失败态), light and dark.
public struct SessionStatusToneStyle: Hashable, Sendable {
    /// Dot and status-text colour.
    public var color: DesignColor
    /// Halo around the dot. Light surfaces: every tier. Dark: Completed has none.
    public var halo: DesignColor?
    /// Pill fill (already composited where the handoff stacks a white veil).
    public var pillFill: DesignColor
    public var pillRing: DesignColor
    public var pillText: DesignColor

    public init(color: DesignColor, halo: DesignColor?, pillFill: DesignColor, pillRing: DesignColor, pillText: DesignColor) {
        self.color = color
        self.halo = halo
        self.pillFill = pillFill
        self.pillRing = pillRing
        self.pillText = pillText
    }
}

public extension SessionStatusTone {
    func style(_ appearance: DesignAppearance) -> SessionStatusToneStyle {
        appearance == .dark ? darkStyle : lightStyle
    }

    /// Light: `sessionStates` in the design system.
    var lightStyle: SessionStatusToneStyle {
        let veil = DesignColor(white: 1, alpha: 0.35)
        switch self {
        case .blue:
            let hue = DesignSystem.Semantic.agentBlue.light
            return SessionStatusToneStyle(
                color: hue,
                halo: hue.opacity(0.18),
                pillFill: veil.composited(over: hue.opacity(0.16)),
                pillRing: hue.opacity(0.28),
                pillText: DesignSystem.Semantic.agentBlueText.light
            )
        case .green:
            let hue = DesignSystem.Semantic.userGreen.light
            return SessionStatusToneStyle(
                color: hue,
                halo: hue.opacity(0.18),
                pillFill: veil.composited(over: hue.opacity(0.16)),
                pillRing: hue.opacity(0.28),
                pillText: DesignSystem.Semantic.userGreenText.light
            )
        case .gray:
            return SessionStatusToneStyle(
                color: DesignSystem.Semantic.completed.light,
                halo: DesignSystem.Semantic.completed.light.opacity(0.16),
                pillFill: DesignSystem.Ink.chipFill,
                pillRing: DesignSystem.Ink.chipStroke,
                pillText: DesignSystem.Ink.secondary
            )
        case .red:
            let hue = DesignSystem.Semantic.errorRed.light
            return SessionStatusToneStyle(
                color: hue,
                halo: hue.opacity(0.16),
                pillFill: veil.composited(over: hue.opacity(0.14)),
                pillRing: hue.opacity(0.26),
                pillText: DesignSystem.Semantic.errorRedText.light
            )
        }
    }

    /// Dark (Notch): `sessionStatesDark` in the design system. Pills are the
    /// tone at `.18` with a `.32` ring (Completed `.12` / `.16`).
    var darkStyle: SessionStatusToneStyle {
        switch self {
        case .blue:
            let hue = DesignSystem.Semantic.agentBlue.dark
            return SessionStatusToneStyle(
                color: hue, halo: hue.opacity(0.22),
                pillFill: hue.opacity(0.18), pillRing: hue.opacity(0.32),
                pillText: DesignSystem.Semantic.agentBlueText.dark
            )
        case .green:
            let hue = DesignSystem.Semantic.userGreen.dark
            return SessionStatusToneStyle(
                color: hue, halo: hue.opacity(0.24),
                pillFill: hue.opacity(0.18), pillRing: hue.opacity(0.32),
                pillText: DesignSystem.Semantic.userGreenText.dark
            )
        case .gray:
            let hue = DesignSystem.Semantic.completed.dark
            return SessionStatusToneStyle(
                color: hue, halo: nil,
                pillFill: DesignColor(white: 1, alpha: 0.12), pillRing: DesignColor(white: 1, alpha: 0.16),
                pillText: DesignSystem.InkDark.chipTextStrong
            )
        case .red:
            let hue = DesignSystem.Semantic.errorRed.dark
            return SessionStatusToneStyle(
                color: hue, halo: hue.opacity(0.24),
                pillFill: hue.opacity(0.18), pillRing: hue.opacity(0.32),
                pillText: DesignSystem.Semantic.errorRedText.dark
            )
        }
    }
}
