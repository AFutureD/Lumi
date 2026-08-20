import AgentStatusCore
import Foundation

// L3 分子组件 — atoms composed into units: the status pill, and the session
// lifecycle ladder that rows, pills and the Notch all read through
// `SessionStatusTone`. Sidebar / Session rows and the lane strip are layout
// (`DesignSystem.Metrics`, `.Lane`) and live in the surfaces.

// MARK: - 3.1 StatusPill

/// Solid dot + label in a capsule. Four values: fill / ring / dot / text.
public struct DesignStatusPillStyle: Hashable, Sendable {
    public var fill: DesignColor
    public var ring: DesignColor
    public var dot: DesignColor
    public var text: DesignColor

    public init(fill: DesignColor, ring: DesignColor, dot: DesignColor, text: DesignColor) {
        self.fill = fill
        self.ring = ring
        self.dot = dot
        self.text = text
    }
}

public extension DesignHue {
    /// `3.1 状态药丸` light / dark tables.
    /// Light: the hue's L2 tint (hue 200 / hue 600 at 14–16 %), ring hue 600 at
    /// 24–32 %, dot hue 600, text hue 700 (yellow `#6E5417`). Dark: D500 at
    /// `.18`, ring D500 at `.32`, dot D500, text D400 (yellow / purple / orange
    /// one step lighter than their tint text). Neutral: chip fill + Neutral 500
    /// / white `.12` + `.78`.
    func pillStyle(_ appearance: DesignAppearance) -> DesignStatusPillStyle {
        switch appearance {
        case .light:
            let tint = lightTint
            let ring: DesignColor = switch self {
            case .neutral: DesignSystem.Surface.chipRing
            case .yellow, .orange: base.opacity(0.32)
            case .blue, .green, .red, .purple: base.opacity(0.24)
            }
            return DesignStatusPillStyle(fill: tint.fill, ring: ring, dot: base, text: tint.text)
        case .dark:
            guard let dark = darkRamp else {
                return DesignStatusPillStyle(
                    fill: DesignSystem.SurfaceDark.selection,
                    ring: DesignSystem.SurfaceDark.hairline,
                    dot: darkBase,
                    text: DesignSystem.InkDark.body
                )
            }
            return DesignStatusPillStyle(
                fill: dark.d500.opacity(0.18),
                ring: dark.d500.opacity(0.32),
                dot: dark.d500,
                text: dark.d400
            )
        }
    }
}

// MARK: - 4.1 Session lifecycle → hue + dot form

/// Colours of one lifecycle tier on one appearance: the dot (with its form)
/// and the pill. Everything a row, a pill or the Notch needs for a session.
public struct SessionStatusToneStyle: Hashable, Sendable {
    public var hue: DesignHue
    public var dot: DesignStatusDotStyle
    public var pill: DesignStatusPillStyle

    public init(hue: DesignHue, dot: DesignStatusDotStyle, pill: DesignStatusPillStyle) {
        self.hue = hue
        self.dot = dot
        self.pill = pill
    }

    /// Dot and status-text colour.
    public var color: DesignColor { dot.color }
    /// Halo only while the tier breathes (Running / Waiting); nil once ended.
    public var halo: DesignColor? { dot.breathes ? dot.halo : nil }
}

public extension SessionStatusTone {
    /// Running → Blue breathing · Waiting for approval → Orange breathing ·
    /// Turn finished, unreviewed → Green breathing · Completed / Idle →
    /// Neutral solid · Failed / Aborted → Red solid.
    /// **Only tiers that want the human breathe**; ended tiers are solid, no halo.
    var hue: DesignHue {
        switch self {
        case .blue: .blue
        case .orange: .orange
        case .green: .green
        case .gray: .neutral
        case .red: .red
        }
    }

    var dotForm: DesignStatusDotForm {
        switch self {
        case .blue, .orange, .green: .breathing
        case .gray, .red: .solid
        }
    }

    func style(_ appearance: DesignAppearance) -> SessionStatusToneStyle {
        SessionStatusToneStyle(
            hue: hue,
            dot: hue.statusDot(dotForm, appearance: appearance),
            pill: hue.pillStyle(appearance)
        )
    }

    /// The light window.
    var lightStyle: SessionStatusToneStyle { style(.light) }
    /// The Notch panel.
    var darkStyle: SessionStatusToneStyle { style(.dark) }
}
