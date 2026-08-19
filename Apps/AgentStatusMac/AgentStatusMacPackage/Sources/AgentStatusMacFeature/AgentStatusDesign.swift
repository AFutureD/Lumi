import AgentStatusDesignSystem
import AgentStatusTransport
import AppKit
import SwiftUI

// MARK: - Platform adapters

extension NSColor {
    convenience init(_ design: DesignColor) {
        self.init(srgbRed: design.red, green: design.green, blue: design.blue, alpha: design.alpha)
    }

    /// Appearance-aware colour: `light` under Aqua, `dark` under Dark Aqua.
    convenience init(_ design: AdaptiveDesignColor) {
        self.init(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? design.dark : design.light)
        }
    }
}

extension NSFont {
    static func design(_ style: DesignTextStyle) -> NSFont {
        let weight: NSFont.Weight = switch style.weight {
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
        switch style.family {
        case .sans:
            return NSFont.systemFont(ofSize: style.size, weight: weight)
        case .mono:
            return NSFont.monospacedSystemFont(ofSize: style.size, weight: weight)
        }
    }
}

extension NSEdgeInsets {
    init(top: Double, leading: Double, bottom: Double, trailing: Double) {
        self.init(top: top, left: leading, bottom: bottom, right: trailing)
    }
}

/// AppKit / SwiftUI-typed view of the shared design system for the macOS
/// window. Semantic system colours are preferred wherever they exist; every
/// other value is read from `DesignSystem` — no literals live here.
enum AgentStatusDesign {
    typealias DS = DesignSystem

    enum Layout {
        static let sidebarWidth: CGFloat = DS.Metrics.sidebarWidth
        static let sessionListWidth: CGFloat = DS.Metrics.sessionListWidth
        static let settingsListWidth: CGFloat = DS.Metrics.settingsListWidth
        static let inspectorWidth: CGFloat = DS.Metrics.inspectorWidth
        static let toolbarHeight: CGFloat = DS.Metrics.toolbarHeight
        // Split-view resize limits: engineering constraints around the design
        // widths, not design-system values.
        static let contentListMinimumWidth: CGFloat = 240
        static let contentListMaximumWidth: CGFloat = 480
        static let detailMinimumWidth: CGFloat = 400

        static let sidebarRowHeight: CGFloat = DS.Metrics.sidebarRowHeight
        static let sidebarFirstGroupHeight: CGFloat = DS.Metrics.sidebarFirstGroupHeight
        static let sidebarGroupHeight: CGFloat = DS.Metrics.sidebarGroupHeight
        static let sidebarGroupBottomInset: CGFloat = DS.Metrics.sidebarGroupBottomInset

        static let listRowHeight: CGFloat = DS.Metrics.listRowHeight
        static let listHorizontalInset: CGFloat = DS.Spacing.lPlus
        static let listRowInset: CGFloat = DS.Spacing.mPlus
        static let selectionCornerRadius: CGFloat = DS.Radius.selection

        static let subheaderTopInset: CGFloat = DS.Metrics.sidebarGroupBottomInset
        static let subheaderBottomInset: CGFloat = DS.Spacing.lPlus
        static let pillHeight: CGFloat = DS.Metrics.pillHeight

        static let activityRowHeight: CGFloat = DS.Metrics.activityRowHeight
        /// SESSION / COMPACT / CONTEXT ×N rows that span all lanes.
        static let activityMarkerRowHeight: CGFloat = DS.Metrics.activityMarkerRowHeight
        static let activityHorizontalInset: CGFloat = DS.Spacing.xxl
        static let activityColumnGap: CGFloat = DS.Spacing.l
        static let activityTimestampWidth: CGFloat = DS.Metrics.activityTimestampWidth
        static let activityTagWidth: CGFloat = DS.Metrics.activityTagWidth
        static let activityTagCornerRadius: CGFloat = DS.Radius.tag
        static let activityTagVerticalPadding: CGFloat = DS.Metrics.tagVerticalPadding
        static let laneCellSize: CGFloat = DS.Metrics.laneCellSize
        static let laneCellSpacing: CGFloat = DS.Spacing.xs
        static let laneCellCornerRadius: CGFloat = DS.Radius.laneCell
        static let laneNameWidth: CGFloat = DS.Metrics.laneNameWidth
        static let rowChevronSize = CGSize(width: DS.Metrics.rowChevronWidth, height: DS.Metrics.rowChevronHeight)

        static let inspectorInsets = NSEdgeInsets(top: DS.Spacing.xl, leading: DS.Spacing.xl, bottom: DS.Spacing.xl + DS.Spacing.xs, trailing: DS.Spacing.xl)
        static let inspectorSectionSpacing: CGFloat = DS.Spacing.xl + DS.Spacing.xs

        static let cardCornerRadius: CGFloat = DS.Radius.card
        /// Settings cards stop growing past this; a readability limit, not a design value.
        static let cardMaximumWidth: CGFloat = 640
        static let settingsRowMinimumHeight: CGFloat = DS.Metrics.settingsRowMinimumHeight
        static let settingsRowInsets = NSEdgeInsets(top: DS.Spacing.l, leading: DS.Spacing.xl, bottom: DS.Spacing.l, trailing: DS.Spacing.xl)
        static let factRowHeight: CGFloat = DS.Metrics.factRowHeight
        static let settingsNavigationRowHeight: CGFloat = DS.Metrics.settingsRowHeight
    }

    @MainActor
    enum Font {
        static let title = NSFont.design(DS.Typography.detailTitle)
        static let section = NSFont.design(DS.Typography.sectionTitle)
        static let group = NSFont.design(DS.Typography.groupHeader)
        static let rowTitle = NSFont.design(DS.Typography.listTitle)
        static let body = NSFont.design(DS.Typography.body)
        static let pill = NSFont.design(DS.Typography.pill)
        static let caption = NSFont.design(DS.Typography.caption)
        static let countBadge = NSFont.design(DS.Typography.countBadge)
        static let mono = NSFont.design(DS.Typography.monoValue)
        static let monoSmall = NSFont.design(DS.Typography.monoTimestamp)

        static let titleKerning: CGFloat = DS.Typography.detailTitle.tracking

        enum UI {
            static let section = SwiftUI.Font(DS.Typography.sectionTitle)
            static let group = SwiftUI.Font(DS.Typography.groupHeader)
            static let rowTitle = SwiftUI.Font(DS.Typography.listTitle)
            static let body = SwiftUI.Font(DS.Typography.body)
            static let pill = SwiftUI.Font(DS.Typography.pill)
            static let caption = SwiftUI.Font(DS.Typography.caption)
            static let metricValue = SwiftUI.Font(DS.Typography.sectionTitle).monospacedDigit()
            static let metricLabel = SwiftUI.Font(DS.Typography.metricLabel)
            static let laneName = SwiftUI.Font(DS.Typography.metricLabel)
            static let tag = SwiftUI.Font(DS.Typography.tag)
            static let mono = SwiftUI.Font(DS.Typography.monoValue)
            static let monoSmall = SwiftUI.Font(DS.Typography.monoTimestamp)
        }
    }

    enum Color {
        /// Selected row tint for the Sessions list and Settings categories.
        static let selection = NSColor(AdaptiveDesignColor(light: DS.Ink.selection, dark: DS.InkDark.chipFill))
        static let hairline = NSColor.separatorColor
        static let chipFill = NSColor(DS.Ink.chipFill)
        static let chipStroke = NSColor(DS.Ink.chipStroke)
        static let cardFill = NSColor(AdaptiveDesignColor(light: DS.Ink.cardFill, dark: DS.InkDark.cardFill))
        static let cardStroke = NSColor(AdaptiveDesignColor(light: DS.Ink.hairline, dark: DS.InkDark.archiveFill))
        static let elbow = NSColor(DS.Ink.elbow)
        static let destructiveText = NSColor(DS.Ink.destructiveText)
        static let zebra = NSColor(DS.Ink.zebra)
        static let inkPrimary = NSColor(DS.Ink.primary)
        static let inkSecondary = NSColor(DS.Ink.secondary)
        static let inkTertiary = NSColor(DS.Ink.tertiary)
        static let inkQuaternary = NSColor(DS.Ink.quaternary)
        static let childTitle = NSColor(DS.Ink.childTitle)
        static let countBadge = NSColor(DS.Ink.countBadge)
        static let activityHairline = NSColor(DS.Ink.separator)
        static let chevron = NSColor(DS.Ink.chevron)
        static let connected = NSColor(DS.Semantic.connected)

        enum UI {
            static let chipFill = SwiftUI.Color(nsColor: Color.chipFill)
            static let chipStroke = SwiftUI.Color(nsColor: Color.chipStroke)
            static let cardFill = SwiftUI.Color(nsColor: Color.cardFill)
            static let cardStroke = SwiftUI.Color(nsColor: Color.cardStroke)
            static let hairline = SwiftUI.Color(nsColor: Color.hairline)
            static let zebra = SwiftUI.Color(nsColor: Color.zebra)
            static let inkPrimary = SwiftUI.Color(DS.Ink.primary)
            static let inkTertiary = SwiftUI.Color(DS.Ink.tertiary)
            static let inkQuaternary = SwiftUI.Color(DS.Ink.quaternary)
            static let activityHairline = SwiftUI.Color(DS.Ink.separator)
            static let chevron = SwiftUI.Color(DS.Ink.chevron)
            static let destructiveText = SwiftUI.Color(DS.Ink.destructiveText)
            static let accent = SwiftUI.Color(DS.Ink.accent)
        }
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
