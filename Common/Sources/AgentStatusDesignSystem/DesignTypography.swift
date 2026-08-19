import Foundation

/// SF Pro weights the design system allows. Only three: 510 / 590 / 700.
public enum DesignFontWeight: Hashable, Sendable {
    /// 510 — body, captions, sidebar labels.
    case medium
    /// 590 — list titles, pills, counts.
    case semibold
    /// 700 — titles, section headers, tag text.
    case bold
}

public enum DesignFontFamily: Hashable, Sendable {
    /// SF Pro (`-apple-system`).
    case sans
    /// SF Mono — numbers, IDs, paths, timestamps; tabular numerals.
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
}

public extension DesignSystem {
    /// L1 基础规范 · 排版. Five sizes, three weights; mono for numbers.
    enum Typography {
        // MARK: Light surfaces (macOS window, iOS)

        /// 22 / 700 / -.01em / 26 — detail page title.
        public static let detailTitle = DesignTextStyle(size: 22, weight: .bold, lineHeight: 26, trackingEm: -0.01)
        /// 15 / 700 / 18 — section title ("Activity"), Notch detail title.
        public static let sectionTitle = DesignTextStyle(size: 15, weight: .bold, lineHeight: 18)
        /// 13 / 700 / 16 — sidebar section header, inspector group.
        public static let groupHeader = DesignTextStyle(size: 13, weight: .bold, lineHeight: 16)
        /// 13 / 590 / 16 — list title, emphasis, Notch session title.
        public static let listTitle = DesignTextStyle(size: 13, weight: .semibold, lineHeight: 16)
        /// 13 / 510 / 16 — body, sidebar label, Activity content.
        public static let body = DesignTextStyle(size: 13, weight: .medium, lineHeight: 16)
        /// 11 / 590 / 14 — status pill, counts.
        public static let pill = DesignTextStyle(size: 11, weight: .semibold, lineHeight: 14)
        /// 11 / 510 / 14 — subtitle, caption, field value.
        public static let caption = DesignTextStyle(size: 11, weight: .medium, lineHeight: 14)
        /// 10 / 590 / .04em / 13 — metric label, lane name.
        public static let metricLabel = DesignTextStyle(size: 10, weight: .semibold, lineHeight: 13, trackingEm: 0.04)
        /// SF Mono 10 — timestamps.
        public static let monoTimestamp = DesignTextStyle(size: 10, weight: .medium, lineHeight: 13, family: .mono)
        /// SF Mono 11 — IDs, paths, numbers.
        public static let monoValue = DesignTextStyle(size: 11, weight: .medium, lineHeight: 14, family: .mono)
        /// 9 / 700 / .04em — category tag text (82pt chip).
        public static let tag = DesignTextStyle(size: 9, weight: .bold, lineHeight: 11, trackingEm: 0.04)
        /// 10 / 590 — collapsed-children count badge.
        public static let countBadge = DesignTextStyle(size: 10, weight: .semibold, lineHeight: 14)

        // MARK: Notch (dark glass)

        /// 11 / 510 / 16 — echoed user input, turn summary.
        public static let notchBody = DesignTextStyle(size: 11, weight: .medium, lineHeight: 16)
        /// 11 / 510 / 14 — activity row content, `agent · model · cwd`.
        public static let notchCaption = DesignTextStyle(size: 11, weight: .medium, lineHeight: 14)
        /// 11 / 590 — collapsed session count, metric chip value (tabular).
        public static let notchCount = DesignTextStyle(size: 11, weight: .semibold, lineHeight: 14)
        /// 10 / 590 / 14 — agent chip, `Turn started`, running pill, footer.
        public static let notchChip = DesignTextStyle(size: 10, weight: .semibold, lineHeight: 14)
        /// 10 / 510 — metric chip unit label.
        public static let notchChipLabel = DesignTextStyle(size: 10, weight: .medium, lineHeight: 14)
        /// 10 / 700 / .05em — `RECENT ACTIVITY` section label.
        public static let notchSectionLabel = DesignTextStyle(size: 10, weight: .bold, lineHeight: 13, trackingEm: 0.05)
        /// 9 / 700 / .06em — `USER` label on the echoed-input card.
        public static let notchCardLabel = DesignTextStyle(size: 9, weight: .bold, lineHeight: 11, trackingEm: 0.06)
        /// 9 / 590 / .04em uppercase — metric card label.
        public static let notchMetricLabel = DesignTextStyle(size: 9, weight: .semibold, lineHeight: 11, trackingEm: 0.04)
        /// 9 / 700 / .03em — 60pt activity tag.
        public static let notchTag = DesignTextStyle(size: 9, weight: .bold, lineHeight: 11, trackingEm: 0.03)
        /// 13 / 590 — primary action button label; 12 / 590 secondary.
        public static let notchButton = DesignTextStyle(size: 13, weight: .semibold, lineHeight: 16)
        public static let notchSecondaryButton = DesignTextStyle(size: 12, weight: .semibold, lineHeight: 15)
    }
}
