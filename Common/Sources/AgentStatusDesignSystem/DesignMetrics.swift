import AgentStatusTransport
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
        public static let checkbox: Double = 4
        /// macOS FilterDropdown trigger (3.4).
        public static let filterTrigger: Double = 6
        /// macOS FilterDropdown panel (3.4); the iOS panel is 14.
        public static let filterPanel: Double = 10
        /// Notch cards (echoed input, metric cards).
        public static let notchCard: Double = 10
        /// Notch action buttons.
        public static let notchButton: Double = 9
        /// Notch metric chips.
        public static let notchMetricChip: Double = 8
        /// Notch subagent pill, archive button.
        public static let notchChip: Double = 6
        /// Notch list agent tag.
        public static let notchAgentTag: Double = 4
        /// Notch list activity-line category tag.
        public static let notchActivityTag: Double = 3
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
        public static let buttonHeight: Double = 28
        public static let switchTrackWidth: Double = 38
        public static let switchTrackHeight: Double = 22
        public static let switchKnob: Double = 18
        public static let sliderTrack: Double = 4
        public static let sliderKnob: Double = 20
        public static let checkboxSize: Double = 14
        /// Activity count pill next to the section title: `padding 1 7`, capsule.
        public static let countPillVerticalPadding: Double = 1
        public static let countPillHorizontalPadding: Double = 7
        public static let rowChevronWidth: Double = 7
        public static let rowChevronHeight: Double = 11
    }

    /// 2.6 标签 Tag — a 5pt-radius rectangle (not a capsule), height 17,
    /// `padding 0 6`, 9 / Medium / .04em, centred in a fixed 82pt column.
    /// Every tier carries a `.5px` inset ring.
    enum Tag {
        public static let height: Double = 17
        public static let horizontalPadding: Double = 6
        /// Activity column width; the Notch's compact variant is 60.
        public static let width: Double = 82
        public static let compactWidth: Double = 60
        public static let radius: Double = 5
        public static let ring: Double = 0.5
    }

    /// 2.7 状态点 ItemStatus — 7px dot in a 10px slot after the tag. Hollow =
    /// 1.5px ring, solid = fill, breathing = fill + 2.5px halo. Without a
    /// status the whole slot stays empty.
    enum StatusDot {
        public static let size: Double = 7
        public static let slot: Double = 10
        public static let hollowRing: Double = 1.5
        public static let halo: Double = 2.5
        /// Notch list rows: 8px dot with a 3px halo; subagent children 6px.
        public static let notchSize: Double = 8
        public static let notchHalo: Double = 3
        /// Status dot inside a subagent pill.
        public static let notchPillDot: Double = 5
    }

    /// 3.1 状态药丸 StatusPill — solid dot + label; height 22, capsule,
    /// `padding 0 10`, 6px slot after the dot, 11 / Semibold.
    enum StatusPill {
        public static let height: Double = 22
        public static let horizontalPadding: Double = 10
        public static let dot: Double = 7
        public static let dotGap: Double = 6
        public static let ring: Double = 0.5
        /// Notch detail header: height 20, `padding 0 8`, 6px dot.
        public static let notchHeight: Double = 20
        public static let notchHorizontalPadding: Double = 8
        public static let notchDot: Double = 6
    }

    /// 3.3 泳道 — three lanes of 13×13 cells, radius 3, gap 4; empty cells
    /// stay blank. Cross-lane events do not occupy a lane: each lane draws a
    /// 13×4 bar, radius 2, and the column narrows to 4.
    enum Lane {
        public static let cell: Double = 13
        public static let radius: Double = 3
        public static let gap: Double = 4
        public static let markerWidth: Double = 4
        public static let markerRadius: Double = 2
        public static let nameWidth: Double = 44
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

    /// Notch panel metrics (the Notch design canvas).
    enum Notch {
        public static let compactWidth: Double = 64
        public static let expandedWidth: Double = 520
        // Top band: height 32, padding `0 14`; left cluster gap 10 (15px brand
        // glyph + 11 / Regular title), right cluster gap 15 (15px line icons).
        public static let topBandHeight: Double = 32
        public static let topBarSideInset: Double = 14
        public static let topBarLeadingGap: Double = 10
        public static let topBarTrailingGap: Double = 15
        /// Design draws 15px 1.25–1.3 stroke line glyphs; SF Symbols at this
        /// point size match them optically, laid out in a 15px box.
        public static let topBarGlyph: Double = 12
        public static let topBarIconBox: Double = 15
        public static let compactSlot: Double = 28

        // List rows: grid `8px | 1fr | auto`, column gap 9, row gap 2,
        // padding `3 14 4` → a single-line row is ~28pt.
        public static let rowColumnGap: Double = 9
        public static let rowLineGap: Double = 2
        public static let rowTop: Double = 3
        public static let rowBottom: Double = 4
        /// List rows and separators sit at 14; cards and the detail keep 16.
        public static let listSideInset: Double = 14
        public static let sideInset: Double = 16
        public static let listTopPadding: Double = 2
        // Agent tag: 15 tall, padding `0 5`, r4, opaque fill.
        public static let agentTagHeight: Double = 15
        public static let agentTagHorizontalPadding: Double = 5
        // Right cluster: tag + a 26pt time cell (22 tall), gap 5, 8 before.
        public static let trailingClusterGap: Double = 5
        public static let trailingClusterLeadingPad: Double = 8
        public static let timeCellWidth: Double = 26
        public static let timeCellHeight: Double = 22
        /// Archive button replacing the time in place on hover.
        public static let archiveButton: Double = 22
        /// The design draws a 15px line glyph; `archivebox` at 12.5pt matches it optically.
        public static let archiveSymbolSize: Double = 12.5
        // Activity line (running rows): 14pt tag, padding `0 4`, gap 6.
        public static let activityTagHeight: Double = 14
        public static let activityTagHorizontalPadding: Double = 4
        public static let activityLineGap: Double = 6
        // Rows with a subagent group (Screen 2 / 2b): padding `4 14 5`, the
        // title grid, the count strip and the pill group stacked at 5pt gaps.
        public static let subagentRowTop: Double = 4
        public static let subagentRowBottom: Double = 5
        public static let subagentRowGap: Double = 5
        /// Strip and pills start under the title text: dot 8 + column gap 9.
        public static let subagentIndent: Double = 17
        // Count strip: 22 tall, inner gap 8; one 9px dot per subagent with a
        // 1.5px panel-colour ring, overlapping by 3 from the second on; 10 × 6
        // chevron that turns 180° over .18s when the group is open.
        public static let subagentStripHeight: Double = 22
        public static let subagentStripGap: Double = 8
        public static let subagentStripDot: Double = 9
        public static let subagentStripDotRing: Double = 1.5
        public static let subagentStripDotOverlap: Double = 3
        public static let subagentChevronWidth: Double = 10
        public static let subagentChevronHeight: Double = 6
        /// `chevron.down` at this point size draws a 10 × 6 glyph.
        public static let subagentChevronSymbolSize: Double = 8
        public static let subagentChevronAnimation: Double = 0.18
        // Hovered subagent row: the `.07` r10 card, inset `2 6 3` from the
        // row's outer box — painted behind the flat geometry so nothing moves.
        public static let cardMarginTop: Double = 2
        public static let cardMarginHorizontal: Double = 6
        public static let cardMarginBottom: Double = 3
        // Subagent pills: 20 tall, padding `0 7`, r6, wrap at 5pt gaps.
        public static let pillHeight: Double = 20
        public static let pillHorizontalPadding: Double = 7
        public static let pillInnerGap: Double = 6
        public static let pillFlowGap: Double = 5
        /// The viewport shows this many sessions; the list scrolls beyond.
        /// The height comes from the rendered rows (rows with an activity
        /// line or a subagent group are taller than flat rows), measured in
        /// the view.
        public static let listMaxVisibleRows: Int = 6
        /// Footer: fixed height, top separator, text centred both axes.
        public static let footerHeight: Double = 26

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
        public static let pillRowGap: Double = 7
        // RECENT ACTIVITY: rows 22 tall, gap 12, 60pt tag.
        public static let activityRowHeight: Double = 22
        public static let activityRowGap: Double = 12
        public static let activityListGap: Double = 3
        public static let activityHeaderGap: Double = 8
        public static let activityHeaderBottom: Double = 2
        public static let emptyStateVertical: Double = 26
        public static let emptyStateGap: Double = 8
        public static let emptyStateGlyph: Double = 24
        /// Hit target of the top-bar icon buttons.
        public static let settingsButton: Double = 24
    }

    /// 3.4 Dropdown 多选过滤 FilterDropdown — macOS tier. One trigger per
    /// filter dimension; the panel lists the dimension's options, optionally
    /// cut into sub-groups whose header carries a tri-state checkbox. Every
    /// value is the handoff's macOS column (the iOS tier is `IOS.FilterTrigger`
    /// / `IOS.FilterPanel`).
    enum FilterDropdown {
        /// Trigger: 22 tall, radius 6, `padding 0 8`, inner gap 5; 11 / Regular
        /// title; a 14pt count badge while filtered; 8 × 5 chevron that turns
        /// 180° over `.18s ease` while the panel is open.
        public enum Trigger {
            public static let height: Double = 22
            public static let horizontalPadding: Double = 8
            public static let gap: Double = 5
            public static let badgeHeight: Double = 14
            public static let badgeMinimumWidth: Double = 14
            public static let badgeHorizontalPadding: Double = 4
            public static let chevronWidth: Double = 8
            public static let chevronHeight: Double = 5
            public static let ring: Double = 0.5
            public static let animationDuration: Double = 0.18
        }

        /// Panel: 232 wide, radius 10, dropped 8 under the trigger and
        /// right-aligned to it, at most 420 tall (scrolls beyond). Group title
        /// 24; sub-group header 26; option rows 28 (`padding 0 10`, gap 8), or
        /// 34 when the row carries a description line. 14pt checkbox (radius
        /// 4, 9 × 7 check, 8 × 2 dash, 1.2 off-ring); 72pt tag pill; 26pt
        /// level chip. Shadow `0 0 0 .5px rgba(0,0,0,.07), 0 12px 30px
        /// rgba(0,0,0,.18)`.
        public enum Panel {
            public static let width: Double = 232
            public static let offset: Double = 8
            public static let maximumHeight: Double = 420
            public static let headerHeight: Double = 24
            public static let subgroupHeight: Double = 26
            public static let rowHeight: Double = 28
            public static let describedRowHeight: Double = 34
            public static let horizontalPadding: Double = 10
            public static let gap: Double = 8
            public static let checkbox: Double = 14
            public static let checkboxRing: Double = 1.2
            public static let checkWidth: Double = 9
            public static let checkHeight: Double = 7
            /// The mock strokes 3 in a 16-unit box scaled to 9pt.
            public static let checkStroke: Double = 1.7
            public static let dashWidth: Double = 8
            public static let dashHeight: Double = 2
            public static let tagWidth: Double = 72
            public static let tagVerticalPadding: Double = 2
            public static let tagRadius: Double = 4
            public static let levelChipWidth: Double = 26
            public static let outline: Double = 0.5
            public static let shadowOffsetY: Double = 12
            /// CSS blur radius; SwiftUI's `shadow(radius:)` takes half of it.
            public static let shadowBlur: Double = 30
        }

        /// Empty state of a list whose filter intersection is empty: 320 tall,
        /// 13pt copy over a 22pt capsule Reset button (`padding 0 10`).
        public enum EmptyState {
            public static let height: Double = 320
            public static let gap: Double = 10
            public static let resetHeight: Double = 22
            public static let resetHorizontalPadding: Double = 10
        }

        // MARK: Colours (light window)

        /// Trigger at rest (all selected = unfiltered): `rgba(118,118,128,.12)` + black title.
        public static let triggerFill = DesignColor(rgb: 118, 118, 128, alpha: 0.12)
        public static let triggerText = Palette.black
        /// Filtered trigger: the blue status-pill tint (fill `.14`, ring `.24`, text Blue 700).
        public static let filteredTrigger = DesignHue.blue.pillStyle(.light)
        public static let badgeFill = Ink.accent.opacity(0.9)
        public static let badgeText = Palette.white

        public static let panelFill = DesignColor(rgb: 252, 252, 252, alpha: 0.94)
        public static let panelOutline = DesignColor(white: 0, alpha: 0.07)
        public static let panelShadow = DesignColor(white: 0, alpha: 0.18)
        /// Group title (uppercase) and the `.5px` lines between rows.
        public static let headerText = DesignColor(rgb: 60, 60, 67, alpha: 0.45)
        public static let separator = DesignColor(rgb: 60, 60, 67, alpha: 0.1)
        public static let subgroupFill = DesignColor(rgb: 118, 118, 128, alpha: 0.06)
        /// Counts on both levels; an option that counts 0 stays, in this colour.
        public static let countText = DesignColor(rgb: 60, 60, 67, alpha: 0.4)
        public static let checkboxOn = Ink.accent
        public static let checkboxRing = DesignColor(rgb: 60, 60, 67, alpha: 0.24)
        public static let checkMark = Palette.white
        public static let rowHover = DesignColor(rgb: 120, 120, 128, alpha: 0.08)
        public static let optionName = Ink.primary
        public static let optionDescription = headerText

        public static let emptyText = Ink.quaternary
        public static let resetFill = Surface.chipFill
        public static let resetText = Palette.neutral.s600

        /// Importance-level chip (`L3` / `L2` / `L1`) in the Importance panel:
        /// the three tiers in neutral — solid grey, grey tint, ring only.
        public static func levelChipStyle(_ level: TimelineAttentionLevel) -> DesignTagStyle {
            switch level {
            case .l3:
                DesignTagStyle(fill: Palette.neutralDot, text: .white, ring: .clear)
            case .l2:
                DesignTagStyle(fill: Surface.secondaryButton, text: Ink.countBadge, ring: .clear)
            case .l1:
                DesignTagStyle(fill: .clear, text: Ink.quaternary, ring: DesignColor(white: 0, alpha: 0.16))
            }
        }
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
    }
}
