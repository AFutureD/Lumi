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
        static let connected = NSColor(red: 0x1D / 255, green: 0xA8 / 255, blue: 0x4C / 255, alpha: 1)

        enum UI {
            static let chipFill = SwiftUI.Color(nsColor: Color.chipFill)
            static let chipStroke = SwiftUI.Color(nsColor: Color.chipStroke)
            static let cardFill = SwiftUI.Color(nsColor: Color.cardFill)
            static let cardStroke = SwiftUI.Color(nsColor: Color.cardStroke)
            static let hairline = SwiftUI.Color(nsColor: Color.hairline)
            static let zebra = SwiftUI.Color(nsColor: Color.zebra)
            static let destructiveText = SwiftUI.Color(nsColor: Color.destructiveText)
        }
    }
}

extension SessionActivityCategory {
    /// Colours from the handoff category table (Light mode).
    var labelBackground: Color {
        switch self {
        case .system: Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255, opacity: 0.16)
        case .context: Color(hex: 0x0078F0)
        case .user: Color(hex: 0x1DA84C)
        case .assistantReasoning: Color(hex: 0xE7DAFB)
        case .assistant: Color(hex: 0x8E3FE8)
        case .tool: Color(hex: 0xF0B400)
        case .subagent: Color(hex: 0xED6A0C)
        case .other: Color(hex: 0xE5352F)
        }
    }

    var labelForeground: Color {
        switch self {
        case .system: Color(hex: 0x4B4E55)
        case .assistantReasoning: Color(hex: 0x6A2FD1)
        case .tool: Color(hex: 0x3A2A00)
        case .context, .user, .assistant, .subagent, .other: .white
        }
    }

    var laneCellColor: Color {
        switch self {
        case .system: Color(hex: 0xB4B7BE)
        case .context: Color(hex: 0x0078F0)
        case .user: Color(hex: 0x1DA84C)
        case .assistantReasoning: Color(hex: 0xC9AEFB)
        case .assistant: Color(hex: 0x8E3FE8)
        case .tool: Color(hex: 0xF0B400)
        case .subagent: Color(hex: 0xED6A0C)
        case .other: Color(hex: 0xE5352F)
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
    /// OpenAI mark (bundled `openai.svg`), used for Codex.
    static let openAI: NSImage? = {
        guard let url = Bundle.module.url(forResource: "openai", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = false
        return image
    }()

    /// Codex: the OpenAI mark on a rounded-rectangle tile (white mark on black),
    /// so it reads as an app-style icon next to titles.
    static func image(for agent: AgentKind, pointSize: CGFloat) -> NSImage? {
        switch agent {
        case .codex, .codexSubagent:
            guard let mark = openAI else { return placeholder(pointSize: pointSize) }
            let size = NSSize(width: pointSize, height: pointSize)
            let tile = NSImage(size: size, flipped: false) { rect in
                let radius = pointSize * 0.28
                let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                NSColor.black.setFill()
                path.fill()
                path.addClip()
                let inset = pointSize * 0.2
                let markRect = rect.insetBy(dx: inset, dy: inset)
                // Tint the mark white by using it as a mask.
                if let cg = mark.cgImage(forProposedRect: nil, context: nil, hints: nil),
                   let context = NSGraphicsContext.current?.cgContext {
                    context.saveGState()
                    context.clip(to: markRect, mask: cg)
                    context.setFillColor(NSColor.white.cgColor)
                    context.fill(markRect)
                    context.restoreGState()
                } else {
                    mark.draw(in: markRect)
                }
                return true
            }
            return tile
        case .unknown:
            return placeholder(pointSize: pointSize)
        }
    }

    private static func placeholder(pointSize: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Agent")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize - 2, weight: .medium))
    }
}
