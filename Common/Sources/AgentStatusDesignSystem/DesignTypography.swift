import Foundation

/// SF Pro weights the design system allows — three, on SF's variable scale:
/// Regular 400 / Medium 510 / Semibold 590. **No Bold**: macOS keeps Bold for
/// Headline and Title 1 Emphasized, neither of which this UI uses; hierarchy
/// comes from size, colour and position.
public enum DesignFontWeight: Hashable, Sendable {
    /// 400 — the default. Body, captions, timestamps, IDs, paths.
    case regular
    /// 510 — only the Caption 2 10pt uppercase label (and the 9pt tag).
    case medium
    /// 590 — Emphasized. List titles, section titles, status pills.
    case semibold
}

public enum DesignFontFamily: Hashable, Sendable {
    /// SF Pro (`-apple-system`) — all interface text.
    case sans
    /// SF Mono (`ui-monospace`) — numbers, time, paths, IDs; tabular numerals.
    case mono
}

/// One row of the type scale: size / weight / line height / tracking.
public struct DesignTextStyle: Hashable, Sendable {
    public var size: Double
    public var weight: DesignFontWeight
    public var lineHeight: Double
    /// Letter spacing in em (`.04em` ⇢ 0.04). Platforms convert to points.
    public var trackingEm: Double
    public var family: DesignFontFamily

    public init(
        size: Double,
        weight: DesignFontWeight,
        lineHeight: Double,
        trackingEm: Double = 0,
        family: DesignFontFamily = .sans
    ) {
        self.size = size
        self.weight = weight
        self.lineHeight = lineHeight
        self.trackingEm = trackingEm
        self.family = family
    }

    /// Tracking in points for this size.
    public var tracking: Double { size * trackingEm }
    /// Extra leading above the font's natural line height (platforms that
    /// express line spacing as an increment use this).
    public var lineSpacing: Double { max(0, lineHeight - size * 1.2) }

    /// Same style in SF Mono.
    public var mono: DesignTextStyle {
        var copy = self
        copy.family = .mono
        return copy
    }
}

public extension DesignSystem {
    /// 1.2 排版. Five sizes mapped straight onto macOS system text styles, line
    /// height following the style: 22 Title 1 / 26 · 15 Title 3 / 20 ·
    /// 13 Body / 16 · 11 Subheadline / 14 · 10 Footnote & Caption 2 / 13.
    /// Default Regular; to emphasise take only the style's own Emphasized
    /// weight — 13 / 11 / 15 are Semibold, 10 takes Caption 2's Medium.
    enum Typography {
        // MARK: System text styles

        /// Title 1 — 22 / Regular / 26. Detail page title.
        public static let title1 = DesignTextStyle(size: 22, weight: .regular, lineHeight: 26)
        /// Title 3 Emphasized — 15 / Semibold / 20. Section titles, Notch detail title.
        public static let title3Emphasized = DesignTextStyle(size: 15, weight: .semibold, lineHeight: 20)
        /// Body Emphasized — 13 / Semibold / 16. Sidebar group headers, list titles, Inspector groups.
        public static let bodyEmphasized = DesignTextStyle(size: 13, weight: .semibold, lineHeight: 16)
        /// Body — 13 / Regular / 16. Body, sidebar labels, Activity content.
        public static let body = DesignTextStyle(size: 13, weight: .regular, lineHeight: 16)
        /// Subheadline Emphasized — 11 / Semibold / 14. Status pills, counts.
        public static let subheadlineEmphasized = DesignTextStyle(size: 11, weight: .semibold, lineHeight: 14)
        /// Subheadline — 11 / Regular / 14. Subtitles, captions, field values.
        public static let subheadline = DesignTextStyle(size: 11, weight: .regular, lineHeight: 14)
        /// Caption 2 — 10 / Medium / 13 / .04em. Metric labels, lane names (uppercase).
        public static let caption2 = DesignTextStyle(size: 10, weight: .medium, lineHeight: 13, trackingEm: 0.04)
        /// Footnote — 10 / Regular / 13. Notch chip labels, footer counts.
        public static let footnote = DesignTextStyle(size: 10, weight: .regular, lineHeight: 13)
        /// Footnote · SF Mono — 10 / Regular / 13. Timestamps, relative time.
        public static let footnoteMono = footnote.mono
        /// Subheadline · SF Mono — 11 / Regular / 14. IDs, paths, numbers.
        public static let subheadlineMono = subheadline.mono

        // MARK: Role aliases (what the surfaces call them)

        /// Detail page title.
        public static let detailTitle = title1
        /// Section title (`Activity`), Notch detail title.
        public static let sectionTitle = title3Emphasized
        /// Sidebar section header, Inspector group.
        public static let groupHeader = bodyEmphasized
        /// List title, emphasis, Notch session title.
        public static let listTitle = bodyEmphasized
        /// Status pill, counts, metric chip value.
        public static let pill = subheadlineEmphasized
        /// Subtitle, caption, field value, Notch body copy.
        public static let caption = subheadline
        /// Metric-card label, lane name.
        public static let metricLabel = caption2
        /// Timestamps.
        public static let monoTimestamp = footnoteMono
        /// IDs, paths, numbers.
        public static let monoValue = subheadlineMono
        /// Collapsed-children count badge (10 / Semibold, tabular).
        public static let countBadge = DesignTextStyle(size: 10, weight: .semibold, lineHeight: 14)

        // MARK: Components

        /// Tag (2.6) — 9 / Medium / .04em in a 17pt chip.
        public static let tag = DesignTextStyle(size: 9, weight: .medium, lineHeight: 11, trackingEm: 0.04)
        /// Notch 60pt tag — 9 / Medium / .03em.
        public static let tagCompact = DesignTextStyle(size: 9, weight: .medium, lineHeight: 11, trackingEm: 0.03)

        // MARK: Notch (dark panel)

        /// Agent label, `Turn started`, footer count, `N items` — 10 / Medium / 14.
        public static let notchLabel = DesignTextStyle(size: 10, weight: .medium, lineHeight: 14)
        /// `RECENT ACTIVITY` — 10 / Medium / .05em.
        public static let notchSectionLabel = DesignTextStyle(size: 10, weight: .medium, lineHeight: 13, trackingEm: 0.05)
        /// Metric-card label — 9 / Semibold / .04em uppercase.
        public static let notchMetricLabel = DesignTextStyle(size: 9, weight: .semibold, lineHeight: 11, trackingEm: 0.04)
        /// Echoed user input, turn summary — 11 / Regular / 16.
        public static let notchBody = DesignTextStyle(size: 11, weight: .regular, lineHeight: 16)
        /// Primary action button — 13 / Semibold; secondary 12 / Semibold.
        public static let notchButton = DesignTextStyle(size: 13, weight: .semibold, lineHeight: 16)
        public static let notchSecondaryButton = DesignTextStyle(size: 12, weight: .semibold, lineHeight: 15)
        /// List agent tag (`Codex` / `Claude`) — 9 / Medium / 12 / .01em.
        public static let notchAgentTag = DesignTextStyle(size: 9, weight: .medium, lineHeight: 12, trackingEm: 0.01)
        /// List activity-line category tag — 9 / Semibold / .03em.
        public static let notchActivityTag = DesignTextStyle(size: 9, weight: .semibold, lineHeight: 11, trackingEm: 0.03)
    }
}
