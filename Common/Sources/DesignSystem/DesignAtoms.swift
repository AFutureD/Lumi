import Transport
import Foundation

// L2 原子组件 — the two custom atoms (Tag, ItemStatus dot) as pure styles,
// one table per hue × appearance. System controls (buttons, fields, switches,
// segments, sliders) are AppKit / SwiftUI natives and have no style here.

// MARK: - 2.6 Tag · 注意力三档

/// Tag colours: fill / text / `.5px` inset ring. The tier is decided by
/// whether a human must act, never by the category:
/// - **L1 无饱和底** — no fill, neutral ring; text still carries the hue
///   (same value as the L2 tint text) — neutral tags stay grey.
/// - **L2 淡纯色** — hue 600 at 14–26 %, hue 700 text (light) or D400 / D500 (dark), same-hue ring.
/// - **L3 满饱和实色** — solid hue, white text, deep same-hue ring at 38 %.
public struct DesignTagStyle: Hashable, Sendable {
    public var fill: DesignColor
    public var text: DesignColor
    public var ring: DesignColor

    public init(fill: DesignColor, text: DesignColor, ring: DesignColor) {
        self.fill = fill
        self.text = text
        self.ring = ring
    }
}

public extension DesignHue {
    /// `1.1 注意力三档` — light and dark tables, read as written.
    func tagStyle(_ tier: TimelineAttentionLevel, appearance: DesignAppearance) -> DesignTagStyle {
        switch (tier, appearance) {
        case (.l1, .light):
            return DesignTagStyle(fill: .clear, text: l1TextLight, ring: DesignColor(white: 0, alpha: 0.16))
        case (.l1, .dark):
            return DesignTagStyle(fill: .clear, text: l1TextDark, ring: DesignColor(white: 1, alpha: 0.20))
        case (.l2, .light):
            return lightTint
        case (.l2, .dark):
            return darkTint
        case (.l3, .light):
            return DesignTagStyle(fill: base, text: .white, ring: deepRing)
        case (.l3, .dark):
            return DesignTagStyle(fill: darkSolid, text: .white, ring: deepRing)
        }
    }

    /// L1 text: no fill, but the text still carries the hue — same value as
    /// the L2 tint text. Neutral keeps the dedicated grey.
    var l1TextLight: DesignColor {
        self == .neutral ? DesignSystem.Ink.quaternary : lightTint.text
    }

    /// L1 dark text (White 38 %). Neutral is a dedicated value, distinct
    /// from `InkDark.quaternary` (White 46 %, used for timestamps).
    var l1TextDark: DesignColor {
        self == .neutral ? DesignColor(white: 1, alpha: 0.38) : darkTint.text
    }

    /// L2 on light: hue 600 at 14 % (blue, red, purple) / 16 % (green, yellow,
    /// orange); text hue 700 (yellow takes a darker `#8A6A00` for contrast —
    /// pure yellow, not a red-tinted brown); ring hue 600 at 24–32 %.
    /// Neutral: `rgba(120,120,128,.12)` + Neutral 500.
    var lightTint: DesignTagStyle {
        switch self {
        case .neutral:
            return DesignTagStyle(fill: DesignSystem.Surface.chipFill, text: DesignSystem.Ink.tertiary, ring: DesignSystem.Surface.chipRing)
        case .blue:
            return DesignTagStyle(fill: base.opacity(0.14), text: ramp.s700, ring: base.opacity(0.26))
        case .green:
            return DesignTagStyle(fill: base.opacity(0.16), text: ramp.s700, ring: base.opacity(0.24))
        case .red:
            return DesignTagStyle(fill: base.opacity(0.14), text: ramp.s700, ring: base.opacity(0.24))
        case .yellow:
            return DesignTagStyle(fill: base.opacity(0.16), text: DesignColor(hex: 0x8A6A00), ring: base.opacity(0.32))
        case .purple:
            return DesignTagStyle(fill: base.opacity(0.14), text: ramp.s700, ring: base.opacity(0.24))
        case .orange:
            return DesignTagStyle(fill: base.opacity(0.16), text: ramp.s700, ring: base.opacity(0.32))
        }
    }

    /// L2 on dark: hue 600 at 22–26 %; text D400 (blue, green, red) or D500
    /// (yellow, purple, orange); ring hue 600 at 30–34 %. Neutral: white 14 % + 78 %.
    var darkTint: DesignTagStyle {
        let light600 = ramp.s600
        switch self {
        case .neutral:
            return DesignTagStyle(fill: DesignSystem.SurfaceDark.control, text: DesignSystem.InkDark.body, ring: DesignSystem.SurfaceDark.hairline)
        case .blue:
            return DesignTagStyle(fill: light600.opacity(0.26), text: DesignSystem.Palette.blueDark.d400, ring: light600.opacity(0.34))
        case .green:
            return DesignTagStyle(fill: light600.opacity(0.26), text: DesignSystem.Palette.greenDark.d400, ring: light600.opacity(0.32))
        case .red:
            return DesignTagStyle(fill: light600.opacity(0.24), text: DesignSystem.Palette.redDark.d400, ring: light600.opacity(0.32))
        case .yellow:
            return DesignTagStyle(fill: light600.opacity(0.22), text: DesignSystem.Palette.yellowDark.d500, ring: light600.opacity(0.30))
        case .purple:
            return DesignTagStyle(fill: light600.opacity(0.26), text: DesignSystem.Palette.purpleDark.d500, ring: light600.opacity(0.34))
        case .orange:
            return DesignTagStyle(fill: light600.opacity(0.24), text: DesignSystem.Palette.orangeDark.d500, ring: light600.opacity(0.34))
        }
    }

    /// L3 solid on dark: lifted one step where the D500 would read dull
    /// (blue / green / yellow D600), D500 for red, D700 for purple / orange;
    /// neutral is white 42 %.
    var darkSolid: DesignColor {
        switch self {
        case .neutral: DesignSystem.Semantic.completed.dark
        case .blue: DesignSystem.Palette.blueDark.d600
        case .green: DesignSystem.Palette.greenDark.d600
        case .red: DesignSystem.Palette.redDark.d500
        case .yellow: DesignSystem.Palette.yellowDark.d600
        case .purple: DesignSystem.Palette.purpleDark.d700
        case .orange: DesignSystem.Palette.orangeDark.d700
        }
    }

    /// L3 `.5px` ring: a deep tone of the hue at 38 %, the same in both appearances.
    var deepRing: DesignColor {
        switch self {
        case .neutral: ramp.s700.opacity(0.38)
        case .blue: DesignColor(rgb: 0, 72, 160, alpha: 0.38)
        case .green: DesignColor(rgb: 0, 78, 32, alpha: 0.38)
        case .red: DesignColor(rgb: 140, 18, 14, alpha: 0.38)
        case .yellow, .purple, .orange: ramp.s700.opacity(0.38)
        }
    }
}

// MARK: - 2.7 Status dot · ItemStatus

/// The three forms of the 7px dot.
public enum DesignStatusDotForm: Hashable, Sendable {
    /// 1.5px ring, no fill.
    case hollow
    /// Solid fill.
    case solid
    /// Solid fill + 2.5px halo that breathes.
    case breathing
}

/// Dot colours: the hue's base, and its halo — **light `.20`, dark `.32`**
/// (a `.20` halo is invisible on pure black; neutral dark is `.14`).
public struct DesignStatusDotStyle: Hashable, Sendable {
    public var form: DesignStatusDotForm
    public var color: DesignColor
    public var halo: DesignColor

    public init(form: DesignStatusDotForm, color: DesignColor, halo: DesignColor) {
        self.form = form
        self.color = color
        self.halo = halo
    }

    public var breathes: Bool { form == .breathing }
    public var isHollow: Bool { form == .hollow }
}

public extension DesignHue {
    func statusDot(_ form: DesignStatusDotForm, appearance: DesignAppearance) -> DesignStatusDotStyle {
        let color = base(appearance)
        let haloAlpha: Double = switch (self, appearance) {
        case (.neutral, .dark): 0.14
        case (_, .dark): 0.32
        case (_, .light): 0.20
        }
        return DesignStatusDotStyle(form: form, color: color, halo: color.opacity(haloAlpha))
    }
}

// MARK: - Timeline tags → hue + tier

public extension TimelineTag {
    /// Hue of the tag (`4.3 消息类别`): Neutral SESSION · COMPACT · CONFIG ·
    /// CONTEXT (L1); Blue REASONING (L1) · ASSISTANT (L2) · TURN END (L3);
    /// Yellow TOOL (L1) · RESULT (L2); Purple PLAN (L2); Orange SUBAGENT (L2);
    /// Green USER (L3); Red FAILED (tool · turn) · ABORTED (L3).
    var hue: DesignHue {
        switch self {
        case .session, .compact, .config, .context: .neutral
        case .reasoning: .blue
        case .tool, .result: .yellow
        case .plan: .purple
        case .subagent: .orange
        case .assistant, .turnEnd: .blue
        case .user: .green
        case .failed, .turnFailed, .aborted: .red
        }
    }

    /// Tag chip colours for the tag's own tier.
    func tagStyle(_ appearance: DesignAppearance = .light) -> DesignTagStyle {
        hue.tagStyle(level, appearance: appearance)
    }

    /// Lane-strip cell colour: L1 = neutral `#E7E8EC`, L2 = the hue's 200 step
    /// (the pale tint), L3 = the solid hue.
    var laneCellColor: DesignColor {
        switch level {
        case .l1: DesignSystem.Palette.neutralMarker
        case .l2: hue.ramp.s200
        case .l3: hue.base
        }
    }

    /// Full-saturation category colour (hue base) for toasts and pair
    /// highlights. Always the hue's own colour, not gated by tier — TOOL (L1)
    /// and RESULT (L2) share a hue and must still highlight in the same
    /// colour when their `toolUseID` pairs them.
    var categoryColor: DesignColor {
        hue.base
    }

    /// Narrow-chip label for the Notch's 60pt tags (`ASSIST`, `SUBAG`, `REASON`).
    var shortLabel: String {
        switch self {
        case .assistant: "ASSIST"
        case .subagent: "SUBAG"
        case .reasoning: "REASON"
        default: label
        }
    }
}

/// Item status dot (2.7) in the Activity list: `info` blank · `started`
/// hollow blue · `running` blue + breathing halo · `succeeded` solid green ·
/// `failed` solid red · `cancelled` solid grey.
public extension TimelineRowStatus {
    func dotStyle(_ appearance: DesignAppearance = .light) -> DesignStatusDotStyle? {
        switch self {
        case .info: nil
        case .started: DesignHue.blue.statusDot(.hollow, appearance: appearance)
        case .running: DesignHue.blue.statusDot(.breathing, appearance: appearance)
        case .succeeded: DesignHue.green.statusDot(.solid, appearance: appearance)
        case .failed: DesignHue.red.statusDot(.solid, appearance: appearance)
        case .cancelled: DesignHue.neutral.statusDot(.solid, appearance: appearance)
        }
    }
}

/// Turn phase (`4.2`) only changes the status dot and the header subtitle —
/// never the lifecycle tier colour. `submitted` is the only hollow phase.
public extension TurnPhase {
    var dotHue: DesignHue {
        switch self {
        case .thinking, .responding, .executing: .blue
        case .waitingForApproval: .green
        case .compacting, .idle: .neutral
        }
    }

    var dotForm: DesignStatusDotForm {
        switch self {
        case .thinking, .responding, .executing, .waitingForApproval, .compacting: .breathing
        case .idle: .solid
        }
    }

    func dotStyle(_ appearance: DesignAppearance = .light) -> DesignStatusDotStyle {
        dotHue.statusDot(dotForm, appearance: appearance)
    }

    /// Dot colour on the light window.
    var dotColor: DesignColor { dotHue.base }
}
