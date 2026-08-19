import AgentStatusTransport
import AppKit
import SwiftUI

/// Design tokens from the Liquid Glass handoff. Semantic system colors are
/// preferred wherever they exist; literal values only cover roles the system
/// has no equivalent for (status pills, activity categories, selection tint).
enum AgentStatusDesign {
    enum Layout {
        static let sidebarWidth: CGFloat = 224
        static let sessionListWidth: CGFloat = 324
        static let settingsListWidth: CGFloat = 260
        static let inspectorWidth: CGFloat = 288
        static let toolbarHeight: CGFloat = 52
        static let contentListMinimumWidth: CGFloat = 240
        static let contentListMaximumWidth: CGFloat = 480
        static let detailMinimumWidth: CGFloat = 400

        static let sidebarRowHeight: CGFloat = 32
        static let sidebarFirstGroupHeight: CGFloat = 34
        static let sidebarGroupHeight: CGFloat = 43
        static let sidebarGroupBottomInset: CGFloat = 9

        static let listRowHeight: CGFloat = 52
        static let listHorizontalInset: CGFloat = 14
        static let listRowInset: CGFloat = 10
        static let listChildIndent: CGFloat = 22
        static let selectionCornerRadius: CGFloat = 8

        static let subheaderTopInset: CGFloat = 9
        static let subheaderBottomInset: CGFloat = 14
        static let pillHeight: CGFloat = 22

        static let activityRowHeight: CGFloat = 40
        /// SESSION / COMPACT / CONTEXT ×N rows that span all lanes.
        static let activityMarkerRowHeight: CGFloat = 32
        static let activityHorizontalInset: CGFloat = 24
        static let activityTimestampWidth: CGFloat = 56
        static let activityTagWidth: CGFloat = 82
        static let activityTagCornerRadius: CGFloat = 5
        static let laneCellSize: CGFloat = 13
        static let laneCellSpacing: CGFloat = 4
        static let laneNameWidth: CGFloat = 44

        static let inspectorInsets = NSEdgeInsets(top: 16, left: 16, bottom: 20, right: 16)
        static let inspectorSectionSpacing: CGFloat = 20

        static let cardCornerRadius: CGFloat = 14
        static let cardMaximumWidth: CGFloat = 640
        static let factRowHeight: CGFloat = 38
        static let controlRowMinimumHeight: CGFloat = 48
        static let settingsNavigationRowHeight: CGFloat = 44
    }

    @MainActor
    enum Font {
        static let title = NSFont.systemFont(ofSize: 22, weight: .bold)
        static let section = NSFont.systemFont(ofSize: 15, weight: .bold)
        static let group = NSFont.systemFont(ofSize: 13, weight: .bold)
        static let rowTitle = NSFont.systemFont(ofSize: 13, weight: .semibold)
        static let childRowTitle = NSFont.systemFont(ofSize: 12, weight: .semibold)
        static let body = NSFont.systemFont(ofSize: 13, weight: .medium)
        static let pill = NSFont.systemFont(ofSize: 11, weight: .semibold)
        static let caption = NSFont.systemFont(ofSize: 11, weight: .medium)
        static let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        static let monoSmall = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        static let titleKerning: CGFloat = -0.22

        enum UI {
            static let section = SwiftUI.Font.system(size: 15, weight: .bold)
            static let group = SwiftUI.Font.system(size: 13, weight: .bold)
            static let rowTitle = SwiftUI.Font.system(size: 13, weight: .semibold)
            static let body = SwiftUI.Font.system(size: 13, weight: .medium)
            static let pill = SwiftUI.Font.system(size: 11, weight: .semibold)
            static let caption = SwiftUI.Font.system(size: 11, weight: .medium)
            static let metricValue = SwiftUI.Font.system(size: 15, weight: .bold).monospacedDigit()
            static let metricLabel = SwiftUI.Font.system(size: 10, weight: .semibold)
            static let laneName = SwiftUI.Font.system(size: 10, weight: .semibold)
            static let tag = SwiftUI.Font.system(size: 9, weight: .bold)
            static let mono = SwiftUI.Font.system(size: 11, design: .monospaced)
            static let monoSmall = SwiftUI.Font.system(size: 10, design: .monospaced).monospacedDigit()
        }
    }

    enum Color {
        /// Selected row tint for the Sessions list and Settings categories.
        static let selection = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.09)
                : NSColor(red: 242 / 255, green: 242 / 255, blue: 242 / 255, alpha: 1)
        }
        static let hairline = NSColor.separatorColor
        static let chipFill = NSColor(red: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.12)
        static let chipStroke = NSColor(white: 0, alpha: 0.06)
        static let cardFill = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.05)
                : NSColor(white: 1, alpha: 0.7)
        }
        static let cardStroke = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.12)
                : NSColor(red: 226 / 255, green: 226 / 255, blue: 226 / 255, alpha: 1)
        }
        static let elbow = NSColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.24)
        static let destructiveText = NSColor(red: 0xB3 / 255, green: 0x26 / 255, blue: 0x1E / 255, alpha: 1)
        static let zebra = NSColor(red: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.045)
        static let inkPrimary = NSColor(red: 26 / 255, green: 26 / 255, blue: 26 / 255, alpha: 1)
        static let inkTertiary = NSColor(red: 114 / 255, green: 114 / 255, blue: 114 / 255, alpha: 1)
        static let inkQuaternary = NSColor(red: 138 / 255, green: 138 / 255, blue: 138 / 255, alpha: 1)
        static let activityHairline = NSColor(white: 0, alpha: 0.05)
        static let chevron = NSColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.3)
        static let connected = NSColor(red: 0x1D / 255, green: 0xA8 / 255, blue: 0x4C / 255, alpha: 1)

        enum UI {
            static let chipFill = SwiftUI.Color(nsColor: Color.chipFill)
            static let chipStroke = SwiftUI.Color(nsColor: Color.chipStroke)
            static let cardFill = SwiftUI.Color(nsColor: Color.cardFill)
            static let cardStroke = SwiftUI.Color(nsColor: Color.cardStroke)
            static let hairline = SwiftUI.Color(nsColor: Color.hairline)
            static let zebra = SwiftUI.Color(nsColor: Color.zebra)
            static let inkPrimary = SwiftUI.Color(nsColor: Color.inkPrimary)
            static let inkTertiary = SwiftUI.Color(nsColor: Color.inkTertiary)
            static let inkQuaternary = SwiftUI.Color(nsColor: Color.inkQuaternary)
            static let activityHairline = SwiftUI.Color(nsColor: Color.activityHairline)
            static let chevron = SwiftUI.Color(nsColor: Color.chevron)
            static let destructiveText = SwiftUI.Color(nsColor: Color.destructiveText)
        }
    }
}

/// Tag chip + lane-cell colours from the design system (L1 基础规范 → L4 类别总表).
/// L1: no fill, gray text. L2: category at 14–16% + deep text + .5px ring at
/// 24–32%. L3: solid category colour + white text, no ring (+6% lightness dark).
/// Hues: Agent blue (ASSISTANT L2 / TURN END L3), User green, PLAN purple,
/// SUBAGENT orange, TOOL·RESULT yellow, failure red.
struct TimelineTagStyle: Equatable {
    let fill: Color
    let text: Color
    let ring: Color?

    static func style(for tag: TimelineTag, dark: Bool = false) -> TimelineTagStyle {
        let l1Text = dark ? Color.white.opacity(0.38) : Color(hex: 0x8A8A8A)
        switch tag {
        case .session, .compact, .contextGroup, .context, .reasoning:
            return TimelineTagStyle(fill: .clear, text: l1Text, ring: nil)
        case .user:
            return TimelineTagStyle(fill: Color(hex: dark ? 0x22B856 : 0x1DA84C), text: .white, ring: nil)
        case .turnEnd:
            return TimelineTagStyle(fill: Color(hex: dark ? 0x2A8CFF : 0x0078F0), text: .white, ring: nil)
        case .failed, .aborted:
            return TimelineTagStyle(fill: Color(hex: dark ? 0xEE4038 : 0xE5352F), text: .white, ring: nil)
        case .assistant:
            return dark
                ? TimelineTagStyle(fill: Color(hex: 0x0078F0, opacity: 0.26), text: Color(hex: 0x9DC7FF), ring: Color(hex: 0x0078F0, opacity: 0.34))
                : TimelineTagStyle(fill: Color(hex: 0x0078F0, opacity: 0.14), text: Color(hex: 0x0A5FBF), ring: Color(hex: 0x0078F0, opacity: 0.26))
        case .plan:
            return dark
                ? TimelineTagStyle(fill: Color(hex: 0x8E3FE8, opacity: 0.26), text: Color(hex: 0xC9AEFB), ring: Color(hex: 0x8E3FE8, opacity: 0.34))
                : TimelineTagStyle(fill: Color(hex: 0x8E3FE8, opacity: 0.14), text: Color(hex: 0x6A2FD1), ring: Color(hex: 0x8E3FE8, opacity: 0.24))
        case .subagent:
            return dark
                ? TimelineTagStyle(fill: Color(hex: 0xF5760F, opacity: 0.24), text: Color(hex: 0xFFB27A), ring: Color(hex: 0xF5760F, opacity: 0.34))
                : TimelineTagStyle(fill: Color(hex: 0xED6A0C, opacity: 0.16), text: Color(hex: 0x8A3E05), ring: Color(hex: 0xED6A0C, opacity: 0.32))
        case .tool, .result:
            return dark
                ? TimelineTagStyle(fill: Color(hex: 0xF0B400, opacity: 0.22), text: Color(hex: 0xF5C862), ring: Color(hex: 0xF0B400, opacity: 0.30))
                : TimelineTagStyle(fill: Color(hex: 0xF0B400, opacity: 0.16), text: Color(hex: 0x6E5417), ring: Color(hex: 0xF0B400, opacity: 0.32))
        }
    }
}

extension TimelineTag {
    /// Lane-strip cell colour: the three-tier ramp of the tag's hue.
    /// L1 = neutral `#E7E8EC`, L2 = the pale tint, L3 = the solid category colour.
    var laneCellColor: Color {
        switch self {
        case .session, .compact, .contextGroup, .context, .reasoning: Color(hex: 0xE7E8EC)
        case .assistant: Color(hex: 0xDBECFD)
        case .plan: Color(hex: 0xEFE4FC)
        case .subagent: Color(hex: 0xFCE7D8)
        case .tool, .result: Color(hex: 0xFDF3D6)
        case .user: Color(hex: 0x1DA84C)
        case .turnEnd: Color(hex: 0x0078F0)
        case .failed, .aborted: Color(hex: 0xE5352F)
        }
    }

    /// Full-saturation category colour (L3 base) for notch toasts and pair highlights.
    var accentColor: Color {
        switch self {
        case .user: Color(hex: 0x1DA84C)
        case .assistant, .turnEnd: Color(hex: 0x0078F0)
        case .plan: Color(hex: 0x8E3FE8)
        case .failed, .aborted: Color(hex: 0xE5352F)
        case .subagent: Color(hex: 0xED6A0C)
        case .tool, .result: Color(hex: 0xF0B400)
        case .session, .compact, .contextGroup, .context, .reasoning: Color(hex: 0xE7E8EC)
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

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

@MainActor
enum AgentIcons {
    /// Codex tile (bundled `codex.svg`, already drawn as a rounded icon).
    static let codex: NSImage? = {
        guard let url = Bundle.module.url(forResource: "codex", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = false
        return image
    }()

    /// Claude glyph (bundled `claude.svg`, the orange mark) drawn on a white
    /// rounded tile with a hairline stroke, matching the Codex tile.
    static let claude: NSImage? = {
        guard let url = Bundle.module.url(forResource: "claude", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = false
        return image
    }()

    static func image(for agent: AgentKind, pointSize: CGFloat) -> NSImage? {
        switch agent {
        case .codex, .codexSubagent:
            guard let codex else { return placeholder(pointSize: pointSize) }
            let size = NSSize(width: pointSize, height: pointSize)
            return NSImage(size: size, flipped: false) { rect in
                codex.draw(in: rect)
                return true
            }
        case .claude, .claudeSubagent:
            guard let claude else { return placeholder(pointSize: pointSize) }
            let size = NSSize(width: pointSize, height: pointSize)
            return NSImage(size: size, flipped: false) { rect in
                let radius = pointSize * 0.28
                let tile = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                NSColor.white.setFill()
                tile.fill()
                let inset = pointSize * 0.18
                claude.draw(in: rect.insetBy(dx: inset, dy: inset))
                let stroke = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
                stroke.lineWidth = 1
                AgentStatusDesign.Color.cardStroke.setStroke()
                stroke.stroke()
                return true
            }
        case .unknown:
            return placeholder(pointSize: pointSize)
        }
    }

    private static func placeholder(pointSize: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Agent")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize - 2, weight: .medium))
    }
}
