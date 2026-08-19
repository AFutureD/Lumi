import AgentStatusTransport
import Foundation

/// Tag chip colours from the design system (L1 基础规范 → L4 类别总表).
///
/// - L1 一般消息: no fill, gray text, `.5px` neutral ring.
/// - L2 消息过程: category at 14–16% + deep text + `.5px` ring at 24–32%.
/// - L3 阶段消息: solid category colour + white text + `.5px` same-hue dark
///   ring at 38% (+6% lightness in dark).
///
/// **Every tag carries a `.5px` inset ring in all three tiers.**
public struct TimelineTagStyle: Hashable, Sendable {
    public var fill: DesignColor
    public var text: DesignColor
    public var ring: DesignColor

    public init(fill: DesignColor, text: DesignColor, ring: DesignColor) {
        self.fill = fill
        self.text = text
        self.ring = ring
    }

    public static func style(for tag: TimelineTag, appearance: DesignAppearance = .light) -> TimelineTagStyle {
        let dark = appearance == .dark
        switch tag {
        case .session, .compact, .contextGroup, .context, .reasoning:
            return TimelineTagStyle(
                fill: .clear,
                text: dark ? DesignSystem.InkDark.quaternary : DesignSystem.Ink.quaternary,
                ring: dark ? DesignSystem.InkDark.tagRing : DesignColor(white: 0, alpha: 0.16)
            )
        case .user:
            return TimelineTagStyle(
                fill: DesignColor(hex: dark ? 0x22B856 : 0x1DA84C),
                text: .white,
                ring: DesignColor(rgb: 0, 78, 32, alpha: 0.38)
            )
        case .turnEnd:
            return TimelineTagStyle(
                fill: DesignColor(hex: dark ? 0x2A8CFF : 0x0078F0),
                text: .white,
                ring: DesignColor(rgb: 0, 72, 160, alpha: 0.38)
            )
        case .failed, .aborted:
            return TimelineTagStyle(
                fill: DesignSystem.Semantic.errorRed.resolve(appearance),
                text: .white,
                ring: DesignColor(rgb: 140, 18, 14, alpha: 0.38)
            )
        case .assistant:
            let hue = DesignSystem.Semantic.agentBlue.light
            return TimelineTagStyle(
                fill: hue.opacity(dark ? 0.26 : 0.14),
                text: dark ? DesignColor(hex: 0x9DC7FF) : DesignSystem.Semantic.agentBlueDeep,
                ring: hue.opacity(dark ? 0.34 : 0.26)
            )
        case .plan:
            let hue = DesignSystem.Semantic.plan
            return TimelineTagStyle(
                fill: hue.opacity(dark ? 0.26 : 0.14),
                text: DesignSystem.Semantic.planText.resolve(appearance),
                ring: hue.opacity(dark ? 0.34 : 0.24)
            )
        case .subagent:
            let hue = DesignSystem.Semantic.subagent.resolve(appearance)
            return TimelineTagStyle(
                fill: hue.opacity(dark ? 0.24 : 0.16),
                text: DesignSystem.Semantic.subagentText.resolve(appearance),
                ring: hue.opacity(dark ? 0.34 : 0.32)
            )
        case .tool, .result:
            let hue = DesignSystem.Semantic.tool
            return TimelineTagStyle(
                fill: hue.opacity(dark ? 0.22 : 0.16),
                text: DesignSystem.Semantic.toolText.resolve(appearance),
                ring: hue.opacity(dark ? 0.30 : 0.32)
            )
        }
    }
}

public extension TimelineTag {
    /// Lane-strip cell colour: the three-tier ramp of the tag's hue.
    /// L1 = neutral `#E7E8EC`, L2 = the pale tint, L3 = the solid category colour.
    var laneCellColor: DesignColor {
        switch self {
        case .session, .compact, .contextGroup, .context, .reasoning: DesignSystem.Ramp.neutral
        case .assistant: DesignSystem.Ramp.blue
        case .plan: DesignSystem.Ramp.purple
        case .subagent: DesignSystem.Ramp.orange
        case .tool, .result: DesignSystem.Ramp.yellow
        case .user: DesignSystem.Semantic.userGreen.light
        case .turnEnd: DesignSystem.Semantic.agentBlue.light
        case .failed, .aborted: DesignSystem.Semantic.errorRed.light
        }
    }

    /// Full-saturation category colour (L3 base) for toasts and pair highlights.
    var categoryColor: DesignColor {
        switch self {
        case .user: DesignSystem.Semantic.userGreen.light
        case .assistant, .turnEnd: DesignSystem.Semantic.agentBlue.light
        case .plan: DesignSystem.Semantic.plan
        case .failed, .aborted: DesignSystem.Semantic.errorRed.light
        case .subagent: DesignSystem.Semantic.subagent.light
        case .tool, .result: DesignSystem.Semantic.tool
        case .session, .compact, .contextGroup, .context, .reasoning: DesignSystem.Ramp.neutral
        }
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

/// Item status dot (L2 状态点): `info` blank · `started` hollow 1.5px blue
/// ring · `running` solid blue + 2.5px breathing halo · `succeeded` deep
/// blue · `failed` red · `cancelled` gray 138.
public struct TimelineStatusDotStyle: Hashable, Sendable {
    public var fill: DesignColor
    public var ring: DesignColor?
    public var halo: DesignColor?
    public var breathes: Bool

    public init(fill: DesignColor, ring: DesignColor? = nil, halo: DesignColor? = nil, breathes: Bool = false) {
        self.fill = fill
        self.ring = ring
        self.halo = halo
        self.breathes = breathes
    }
}

public extension TimelineRowStatus {
    var dotStyle: TimelineStatusDotStyle {
        let blue = DesignSystem.Semantic.agentBlue.light
        switch self {
        case .info: return TimelineStatusDotStyle(fill: .clear)
        case .started: return TimelineStatusDotStyle(fill: .clear, ring: blue)
        case .running: return TimelineStatusDotStyle(fill: blue, halo: blue.opacity(0.18), breathes: true)
        case .succeeded: return TimelineStatusDotStyle(fill: DesignSystem.Semantic.agentBlueDeep)
        case .failed: return TimelineStatusDotStyle(fill: DesignSystem.Semantic.errorRed.light)
        case .cancelled: return TimelineStatusDotStyle(fill: DesignSystem.Ink.quaternary)
        }
    }
}

/// Turn phase only changes the status dot and the header subtitle — never the
/// lifecycle tier colour.
public extension TurnPhase {
    var dotColor: DesignColor {
        switch self {
        case .thinking, .responding, .executing: DesignSystem.Semantic.agentBlue.light
        case .waitingForApproval: DesignSystem.Semantic.userGreen.light
        case .subagentRunning: DesignSystem.Semantic.subagent.light
        case .compacting, .idle: DesignSystem.Semantic.completed.light
        case .unknown: DesignSystem.Ink.quaternary
        }
    }
}
