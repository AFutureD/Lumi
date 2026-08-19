import Foundation

public extension DesignSystem {
    /// L1 基础规范 · 间距 (4pt base — not 8pt).
    enum Spacing {
        /// Control inner gap, glass stroke offset.
        public static let hairline: Double = 2
        /// Lane-cell gap, sidebar icon↔text, selection outset.
        public static let xs: Double = 4
        /// Tag padding, dot↔text.
        public static let s: Double = 6
        /// Control↔label, in-card gaps.
        public static let m: Double = 8
        /// Pill padding, in-card group gap.
        public static let mPlus: Double = 10
        /// Activity column gap, card grid gap.
        public static let l: Double = 12
        /// Sidebar side padding, card padding.
        public static let lPlus: Double = 14
        /// Table row padding, in-section gap.
        public static let xl: Double = 16
        /// Large card padding.
        public static let xlPlus: Double = 18
        /// Detail area padding, Activity row side padding.
        public static let xxl: Double = 24
        /// Detail right padding.
        public static let xxxl: Double = 28
        /// Page section gap.
        public static let section: Double = 48
    }

    /// Corner radii.
    enum Radius {
        /// Controls, segments, pills — fully round.
        public static let capsule: Double = 1000
        public static let window: Double = 16
        public static let card: Double = 14
        public static let popover: Double = 12
        public static let selection: Double = 8
        public static let tag: Double = 5
        public static let checkbox: Double = 4
        public static let laneCell: Double = 3
        /// Notch cards (echoed input, metric cards).
        public static let notchCard: Double = 10
        /// Notch action buttons.
        public static let notchButton: Double = 9
        /// Notch metric chips.
        public static let notchMetricChip: Double = 8
        /// Notch agent chip, archive button.
        public static let notchChip: Double = 6
    }

    /// Key metrics of the macOS window (L1 → L3 sizes).
    enum Metrics {
        public static let toolbarHeight: Double = 52
        public static let sidebarWidth: Double = 224
        public static let sidebarRowHeight: Double = 32
        public static let sidebarFirstGroupHeight: Double = 34
        public static let sidebarGroupHeight: Double = 43
        public static let sidebarGroupBottomInset: Double = 9
        public static let sessionListWidth: Double = 324
        public static let inspectorWidth: Double = 288
        public static let settingsListWidth: Double = 260
        public static let settingsRowHeight: Double = 44
        /// Settings card rows: `52` min-height, padding `12 16`.
        public static let settingsRowMinimumHeight: Double = 52
        /// Inspector / Settings fact rows (label + value).
        public static let factRowHeight: Double = 38
        public static let listRowHeight: Double = 52
        public static let activityRowHeight: Double = 40
        public static let activityHeaderRowHeight: Double = 36
        public static let activityMarkerRowHeight: Double = 32
        public static let activityTimestampWidth: Double = 56
        public static let activityTagWidth: Double = 82
        public static let activityStatusDotColumn: Double = 10
        public static let laneCellSize: Double = 13
        public static let laneNameWidth: Double = 44
        public static let buttonHeight: Double = 28
        public static let switchTrackWidth: Double = 38
        public static let switchTrackHeight: Double = 22
        public static let switchKnob: Double = 18
        public static let sliderTrack: Double = 4
        public static let sliderKnob: Double = 20
        public static let checkboxSize: Double = 14
        public static let pillHeight: Double = 22
        /// Activity count pill next to the section title: `padding 1 7`, capsule.
        public static let countPillVerticalPadding: Double = 1
        public static let countPillHorizontalPadding: Double = 7
        public static let statusDot: Double = 7
        /// 82pt tag: `padding 3px 0`.
        public static let tagVerticalPadding: Double = 3
        public static let rowChevronWidth: Double = 7
        public static let rowChevronHeight: Double = 11
    }

    /// Icons: SF Symbols, line style only.
    enum Icon {
        /// Sidebar, accent-tinted.
        public static let sidebar: Double = 16
        /// Toolbar, primary-tinted.
        public static let toolbar: Double = 14
        /// Icon slot is 24pt, centred.
        public static let slot: Double = 24
        /// Agent glyph in list rows.
        public static let agentGlyph: Double = 16
        /// Agent glyph in Settings · Agents rows.
        public static let agentGlyphLarge: Double = 20
    }

    /// Notch panel metrics (`Agent Status Notch - 完整设计`).
    enum Notch {
        public static let compactWidth: Double = 64
        public static let expandedWidth: Double = 520
        public static let topBandHeight: Double = 32
        /// Collapsed status dot and its halo width.
        public static let compactDot: Double = 8
        public static let compactDotHalo: Double = 3
        public static let compactSlot: Double = 28

        // List rows: grid `8px | 1fr | auto`, column gap 10, padding `10 16 11`.
        public static let rowDot: Double = 8
        public static let rowDotHalo: Double = 3
        public static let rowGap: Double = 10
        public static let rowTop: Double = 10
        public static let rowBottom: Double = 11
        /// Bottom padding when subagent rows follow.
        public static let rowBottomWithChildren: Double = 4
        public static let sideInset: Double = 16
        public static let chipHeight: Double = 20
        public static let chipHorizontalPadding: Double = 7
        /// Trailing cell holding the relative time / archive button.
        public static let trailingCell: Double = 20
        /// The design draws a 13px line glyph; `archivebox` at 11pt matches it optically.
        public static let archiveSymbolSize: Double = 11
        // Subagent child rows: indent 34, 6px dot, padding `3 16 3 34`, 9 below the last.
        public static let childIndent: Double = 34
        public static let childDot: Double = 6
        public static let childRowVertical: Double = 3
        public static let childRowLastBottom: Double = 9
        public static let childTimeWidth: Double = 34
        /// Elbow: vertical at x = sideInset + rowDot / 2, radius 5.
        public static let elbowX: Double = 20
        public static let elbowRadius: Double = 5
        public static let listTopInset: Double = 4
        public static let listMaxHeight: Double = 320
        // Footer `9 16 12`.
        public static let footerTop: Double = 9
        public static let footerBottom: Double = 12
        public static let footerGap: Double = 4

        // Cards (turn started / ended / detail).
        public static let cardTop: Double = 14
        public static let detailTop: Double = 13
        public static let cardBottom: Double = 12
        public static let turnStartBottom: Double = 15
        public static let detailBottom: Double = 14
        public static let cardGap: Double = 11
        public static let headerTitleGap: Double = 10
        public static let headerTrailingGap: Double = 7
        public static let headerSubtitleGap: Double = 3
        public static let headerBlockGap: Double = 6
        public static let userCardPaddingVertical: Double = 9
        public static let userCardPaddingHorizontal: Double = 11
        public static let userCardGap: Double = 4
        public static let bodyLineLimit: Int = 6
        public static let metricChipGap: Double = 6
        public static let metricChipPaddingVertical: Double = 4
        public static let metricChipPaddingHorizontal: Double = 9
        public static let metricChipInnerGap: Double = 5
        public static let metricCardPaddingVertical: Double = 7
        public static let metricCardPaddingHorizontal: Double = 9
        public static let metricCardGap: Double = 2
        public static let buttonHeight: Double = 30
        public static let buttonGap: Double = 8
        public static let actionRowTop: Double = 2
        public static let backButtonWidth: Double = 22
        public static let backButtonHeight: Double = 20
        public static let backChevron: Double = 11
        public static let pillHeight: Double = 20
        public static let pillHorizontalPadding: Double = 8
        public static let pillDot: Double = 6
        public static let pillDotGap: Double = 6
        public static let pillRowGap: Double = 7
        // RECENT ACTIVITY: rows 22 tall, gap 12, 60pt tag, `padding 2 0`.
        public static let activityRowHeight: Double = 22
        public static let activityRowGap: Double = 12
        public static let activityListGap: Double = 3
        public static let activityHeaderGap: Double = 8
        public static let activityHeaderBottom: Double = 2
        public static let activityTagWidth: Double = 60
        public static let activityTagVerticalPadding: Double = 2
        public static let emptyStateVertical: Double = 26
        public static let emptyStateGap: Double = 8
        public static let emptyStateGlyph: Double = 24
        public static let settingsGlyph: Double = 12
        public static let settingsButton: Double = 24
    }

    /// Interaction-state opacities.
    enum Opacity {
        /// Accent wash behind a row the lane strip just jumped to.
        public static let jumpHighlight: Double = 0.12
        /// Category wash behind a hovered TOOL / RESULT pair.
        public static let pairHighlight: Double = 0.08
        /// Low point of the Running halo's breathing cycle.
        public static let breathingHalo: Double = 0.35
        /// Reset button while the slider already sits at its default.
        public static let disabledReset: Double = 0.3
    }

    /// Hairline / ring widths.
    enum Stroke {
        public static let hairline: Double = 0.5
        public static let separator: Double = 1
        public static let elbow: Double = 1
        /// `started` item dot ring.
        public static let startedRing: Double = 1.5
        /// `running` item dot halo.
        public static let runningHalo: Double = 2.5
    }
}
