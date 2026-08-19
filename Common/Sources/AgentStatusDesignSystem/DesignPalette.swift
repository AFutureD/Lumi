import Foundation

/// L1 基础规范 · 颜色. Every colour any Agent Status surface paints comes
/// from here; views never write a colour literal. Source of truth:
/// `design/DESIGN SYSTEM.html` (L1 colours, semantic ramps, session states).
public enum DesignSystem {}

public extension DesignSystem {
    /// Neutral ink on light surfaces (the macOS window, iOS light).
    enum Ink {
        /// Titles, body, list titles.
        public static let primary = DesignColor(rgb: 26, 26, 26)
        /// Secondary body, unselected segment.
        public static let secondary = DesignColor(rgb: 64, 64, 64)
        /// Section headers, labels, captions.
        public static let tertiary = DesignColor(rgb: 114, 114, 114)
        /// Timestamps and the weakest information.
        public static let quaternary = DesignColor(rgb: 138, 138, 138)
        /// Icons, selection, the Prominent button.
        public static let accent = DesignColor(rgb: 0, 120, 240)
        /// Row separators, header bottom edge.
        public static let separator = DesignColor(white: 0, alpha: 0.05)
        /// Card `.5px` outline.
        public static let hairline = DesignColor(rgb: 226, 226, 226)
        /// Sidebar / list / settings selected fill.
        public static let selection = DesignColor(rgb: 242, 242, 242)
        /// Subagent child-row title in the Sessions list (13 / 510).
        public static let childTitle = DesignColor(rgb: 60, 60, 67)
        /// Text of the collapsed-children count badge.
        public static let countBadge = DesignColor(rgb: 90, 90, 90)
        /// Row-end chevron `7×11`.
        public static let chevron = DesignColor(rgb: 60, 60, 67, alpha: 0.3)
        /// Tree elbow from a parent row to its subagent children.
        public static let elbow = DesignColor(rgb: 60, 60, 67, alpha: 0.24)
        /// 1px ring around a hovered lane cell.
        public static let hoverRing = DesignColor(rgb: 60, 60, 67, alpha: 0.3)
        /// Neutral chip / count-pill fill (`rgba(120,120,128,.12)`).
        public static let chipFill = DesignColor(rgb: 120, 120, 128, alpha: 0.12)
        public static let chipStroke = DesignColor(white: 0, alpha: 0.06)
        /// Alternating row wash.
        public static let zebra = DesignColor(rgb: 120, 120, 128, alpha: 0.045)
        /// Destructive button label (`#B3261E`); the button itself stays Bordered.
        public static let destructiveText = DesignColor(hex: 0xB3261E)
        /// Liquid-glass card fill above the window shell (light).
        public static let cardFill = DesignColor(white: 1, alpha: 0.7)
    }

    /// Neutral ink on the Notch's dark glass. Four tiers mirroring the light
    /// ladder plus the panel fills the Notch screens use.
    enum InkDark {
        /// Active session title, metric values, primary button fill.
        public static let primary = DesignColor.white
        /// Echoed user input on the turn-started card (`.86`).
        public static let echoBody = DesignColor(white: 1, alpha: 0.86)
        /// Body copy in activity rows (`rgba(255,255,255,.8)`).
        public static let body = DesignColor(white: 1, alpha: 0.8)
        /// Turn summary on the turn-complete card (`.78`).
        public static let summaryBody = DesignColor(white: 1, alpha: 0.78)
        /// Subagent child rows, completed sessions, archive glyph.
        public static let secondary = DesignColor(white: 1, alpha: 0.72)
        /// Agent chip text in the detail header (`.66`).
        public static let chipTextStrong = DesignColor(white: 1, alpha: 0.66)
        /// Agent chip text in list rows (`.6`).
        public static let chipText = DesignColor(white: 1, alpha: 0.6)
        /// `agent · model · cwd` subtitle (`.52`).
        public static let subtitle = DesignColor(white: 1, alpha: 0.52)
        /// Metric-chip unit label (`.45`); dimmed agent chip text.
        public static let label = DesignColor(white: 1, alpha: 0.45)
        /// Metric-card label (`.42`).
        public static let metricLabel = DesignColor(white: 1, alpha: 0.42)
        /// Group labels, section labels, `USER` label, elapsed (`.4`).
        public static let tertiary = DesignColor(white: 1, alpha: 0.4)
        /// L1 tag text (`.38`); relative time in list rows.
        public static let quaternary = DesignColor(white: 1, alpha: 0.38)
        /// Completed-tier dot (`.34`).
        public static let idle = DesignColor(white: 1, alpha: 0.34)
        /// Subagent child-row time (`.32`).
        public static let timestampDim = DesignColor(white: 1, alpha: 0.32)
        /// `N items` count next to RECENT ACTIVITY (`.3`).
        public static let count = DesignColor(white: 1, alpha: 0.3)
        /// L1 tag ring on dark (`.2`).
        public static let tagRing = DesignColor(white: 1, alpha: 0.2)
        /// Tree elbow from a parent row to its subagent children (`.16`).
        public static let elbow = DesignColor(white: 1, alpha: 0.16)
        /// Row separators, footer top edge (`.08`).
        public static let hairline = DesignColor(white: 1, alpha: 0.08)

        /// Echoed-input card and metric cards (`.06`).
        public static let cardFill = DesignColor(white: 1, alpha: 0.06)
        /// Card inset ring (`.09`).
        public static let cardRing = DesignColor(white: 1, alpha: 0.09)
        /// Turn-complete metric chips; dimmed agent chip (`.07`).
        public static let chipFillDim = DesignColor(white: 1, alpha: 0.07)
        /// Back button, agent capsule in the detail header (`.08`).
        public static let controlFill = DesignColor(white: 1, alpha: 0.08)
        /// Agent chip in list rows (`.09`).
        public static let chipFill = DesignColor(white: 1, alpha: 0.09)
        /// Secondary action button (`.1`) and its ring (`.14`).
        public static let secondaryButtonFill = DesignColor(white: 1, alpha: 0.1)
        public static let secondaryButtonRing = DesignColor(white: 1, alpha: 0.14)
        /// Hover archive button (`.12`).
        public static let archiveFill = DesignColor(white: 1, alpha: 0.12)
        /// Primary button ink on a white fill.
        public static let buttonInk = DesignColor(hex: 0x111111)
        /// Collapsed count when there is nothing to show (`.5`).
        public static let compactCountIdle = DesignColor(white: 1, alpha: 0.5)
        /// `Turn started` / `Turn complete` header label; running pill text.
        public static let turnLabel = DesignColor(hex: 0x9DC7FF)
    }

    /// Semantic hues with their light / dark values and deep text tones.
    enum Semantic {
        /// Agent blue · accent.
        public static let agentBlue = AdaptiveDesignColor(light: DesignColor(hex: 0x0078F0), dark: DesignColor(hex: 0x4C9BFF))
        /// Pill text above a blue tint (`rgb(0,105,215)` light, `#9DC7FF` dark).
        public static let agentBlueText = AdaptiveDesignColor(light: DesignColor(rgb: 0, 105, 215), dark: DesignColor(hex: 0x9DC7FF))
        /// Deep blue: ASSISTANT L2 text and the `succeeded` item dot.
        public static let agentBlueDeep = DesignColor(hex: 0x0A5FBF)

        /// User green · success.
        public static let userGreen = AdaptiveDesignColor(light: DesignColor(hex: 0x1DA84C), dark: DesignColor(hex: 0x34C759))
        public static let userGreenText = AdaptiveDesignColor(light: DesignColor(hex: 0x157A38), dark: DesignColor(hex: 0x5EE07E))

        /// Error red.
        public static let errorRed = AdaptiveDesignColor(light: DesignColor(hex: 0xE5352F), dark: DesignColor(hex: 0xEE4038))
        public static let errorRedText = AdaptiveDesignColor(light: DesignColor(hex: 0xB3261E), dark: DesignColor(hex: 0xFF8A83))

        /// PLAN purple.
        public static let plan = DesignColor(hex: 0x8E3FE8)
        public static let planText = AdaptiveDesignColor(light: DesignColor(hex: 0x6A2FD1), dark: DesignColor(hex: 0xC9AEFB))

        /// SUBAGENT orange (`#F5760F` base in dark).
        public static let subagent = AdaptiveDesignColor(light: DesignColor(hex: 0xED6A0C), dark: DesignColor(hex: 0xF5760F))
        public static let subagentText = AdaptiveDesignColor(light: DesignColor(hex: 0x8A3E05), dark: DesignColor(hex: 0xFFB27A))

        /// TOOL · RESULT yellow.
        public static let tool = DesignColor(hex: 0xF0B400)
        public static let toolText = AdaptiveDesignColor(light: DesignColor(hex: 0x6E5417), dark: DesignColor(hex: 0xF5C862))

        /// Neutral (L1): no saturation.
        public static let neutral = AdaptiveDesignColor(light: DesignColor(hex: 0xE7E8EC), dark: DesignColor(white: 1, alpha: 0.38))
        /// Completed / Idle gray.
        public static let completed = AdaptiveDesignColor(light: DesignColor(rgb: 110, 113, 120), dark: DesignColor(white: 1, alpha: 0.34))
        /// Relay / iPhone "connected" dot.
        public static let connected = DesignColor(hex: 0x1DA84C)
    }

    /// L2 pale tints of each hue (lane cells, tag fills on light).
    enum Ramp {
        public static let blue = DesignColor(hex: 0xDBECFD)
        public static let purple = DesignColor(hex: 0xEFE4FC)
        public static let orange = DesignColor(hex: 0xFCE7D8)
        public static let yellow = DesignColor(hex: 0xFDF3D6)
        public static let neutral = DesignColor(hex: 0xE7E8EC)
    }
}
