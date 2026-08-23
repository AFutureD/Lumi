import Foundation

// iPhone screen file (the iPhone design canvas, 393 × 852) — the values
// the iOS client cannot take from UIKit itself. System controls (navigation
// bar, search bar, segmented control, tab bar, inset-grouped lists, sheets)
// keep their system metrics and system colours; only the product's own
// rows, chips, tags, lanes and the scanner are specified here.

public extension DesignSystem {
    enum IOS {
        // MARK: - Page

        public enum Layout {
            /// Full-width rows (Sessions list, Activity list) side padding.
            public static let sideInset: Double = 20
            /// Large title, search bar and chip row side padding.
            public static let titleInset: Double = 20
            /// Inset-grouped group title left padding.
            public static let groupHeaderInset: Double = 32
            /// Inset-grouped group footer side padding.
            public static let groupFooterInset: Double = 36
            /// Inset-grouped card side margin.
            public static let cardMargin: Double = 20
            public static let cardRadius: Double = 10
            /// Gap between inset-grouped groups.
            public static let groupGap: Double = 20
            /// Info tab: first group title sits 18 under the header.
            public static let infoListTop: Double = 18
            /// Group title → card gap.
            public static let groupHeaderGap: Double = 7
            /// Field row: `min-height 44`, `padding 8 16`.
            public static let fieldRowMinimumHeight: Double = 44
            public static let fieldRowVerticalPadding: Double = 8
            public static let fieldRowHorizontalPadding: Double = 16
            public static let fieldRowGap: Double = 14
            /// Row-end chevron `7 × 11`.
            public static let chevronWidth: Double = 7
            public static let chevronHeight: Double = 11
            /// Round 32pt navigation-bar action button.
            public static let navigationButton: Double = 32
        }

        // MARK: - Sessions list

        /// Session row: `padding 12 16`, grid `1fr auto`, column gap 10, row gap 2.
        public enum SessionRow {
            public static let top: Double = 8
            public static let bottom: Double = 8
            public static let columnGap: Double = 10
            public static let lineGap: Double = 2
            /// Status pill on the first line (right of the device name): 20
            /// tall, `padding 0 8`, 6px dot, 5pt gap, 11 / Semibold lifecycle.
            public static let statusPillHeight: Double = 20
            public static let statusPillHorizontalPadding: Double = 8
            public static let statusPillDot: Double = 6
            public static let statusPillDotGap: Double = 5
            /// Subagent chip block: flush with the row's left edge — the same
            /// x as the device name, the status dot and the latest-activity
            /// tag (the handoff's 16pt indent was dropped on 2026-08-21).
            public static let chipIndent: Double = 0
            /// Time ↔ chevron gap.
            public static let trailingGap: Double = 8
            public static let titleLineLimit: Int = 2
            /// Latest-activity line: tag `padding 1 5`, radius 4, 5pt gap to the text.
            public static let latestTagVerticalPadding: Double = 1
            public static let latestTagHorizontalPadding: Double = 5
            public static let latestTagRadius: Double = 4
            public static let latestGap: Double = 5
            /// Gap between the grid and the subagent group.
            public static let chipBlockGap: Double = 4
        }

        /// L4 §4.4 subagent group: a collapsed summary bar (26 tall, stacked
        /// 11px dots with a 1.8px white ring overlapping by 4, 13 / 18 text,
        /// 12 × 8 chevron) that expands into the chip lines below it.
        public enum SubagentGroup {
            public static let barHeight: Double = 26
            public static let barTop: Double = 2
            public static let dot: Double = 11
            public static let dotRing: Double = 1.8
            public static let dotOverlap: Double = 4
            public static let gap: Double = 9
            public static let chevronWidth: Double = 12
            public static let chevronHeight: Double = 8
            public static let lineGap: Double = 6
        }

        /// Sessions header under the navigation bar: the filter row sits 8
        /// below the bar (whose Large Title and search field are the system's)
        /// and 4 above the list's top hairline.
        public enum SessionsHeader {
            public static let gap: Double = 4
            public static let bottom: Double = 4
        }

        /// L3 §3.4 Dropdown filter trigger: 30 tall, radius 9, `padding 0 10`,
        /// inner gap 6, 8 apart; 16pt count badge when filtered; 10 × 6 chevron.
        /// The header stack (title / search / triggers) spaces 8, bottom 4.
        public enum FilterTrigger {
            public static let height: Double = 30
            public static let radius: Double = 9
            public static let horizontalPadding: Double = 10
            public static let innerGap: Double = 6
            public static let gap: Double = 8
            public static let badgeHeight: Double = 16
            public static let badgeHorizontalPadding: Double = 4
            public static let chevronWidth: Double = 10
            public static let chevronHeight: Double = 6
            public static let ring: Double = 0.5
            /// Chevron flip / panel fade: `transition .18s ease`.
            public static let animationDuration: Double = 0.18
        }

        /// L3 §3.4 Dropdown panel: 268 wide, radius 14, dropped 8 under its
        /// trigger, left-aligned to the trigger but never past the 20pt right
        /// margin. Group header 30; rows 48 (`padding 0 14`, gap 11) with a
        /// 22pt checkbox (radius 6, 13 × 10 check at stroke 2.6, off ring 1.5)
        /// and a 30pt icon tile (radius 8) holding a 9pt status dot or the
        /// laptop glyph. Shadow `0 0 0 .5px rgba(0,0,0,.07), 0 14px 36px
        /// rgba(0,0,0,.18)`.
        public enum FilterPanel {
            public static let width: Double = 268
            public static let radius: Double = 14
            public static let offset: Double = 8
            public static let edgeInset: Double = 20
            public static let headerHeight: Double = 30
            public static let rowHeight: Double = 48
            public static let horizontalPadding: Double = 14
            public static let gap: Double = 11
            public static let checkbox: Double = 22
            public static let checkboxRadius: Double = 6
            public static let checkboxRing: Double = 1.5
            public static let checkWidth: Double = 13
            public static let checkHeight: Double = 10
            public static let checkStroke: Double = 2.6
            public static let tile: Double = 30
            public static let tileRadius: Double = 8
            public static let tileDot: Double = 9
            public static let outline: Double = 0.5
            public static let shadowOffsetY: Double = 14
            /// CSS blur radius; Core Animation's `shadowRadius` is half of it.
            public static let shadowBlur: Double = 36
        }

        /// L4 §4.4 subagent chip: 26 tall, radius 8, `padding 0 9`, 6px dot.
        public enum SubagentChip {
            public static let height: Double = 26
            public static let radius: Double = 8
            public static let horizontalPadding: Double = 9
            public static let dot: Double = 6
            public static let innerGap: Double = 6
            /// Gap between two chips on one line and between lines.
            public static let gap: Double = 6
            /// Pair rule: the narrower chip must be under this fraction of the
            /// available width to share a line …
            public static let pairThreshold: Double = 0.5
            /// … and the wider one is capped at this fraction.
            public static let widerCap: Double = 2.0 / 3.0
        }

        // MARK: - Session detail

        /// Header: `padding 8 16 12`, pills → path gap 7, blocks 12 apart.
        public enum Header {
            public static let top: Double = 8
            public static let bottom: Double = 12
            public static let pillRowGap: Double = 7
            public static let blockGap: Double = 12
            /// Status pill 26 tall, `padding 0 11`, 7px dot, 6pt gap; agent pill `padding 0 10`.
            public static let pillHeight: Double = 26
            public static let pillHorizontalPadding: Double = 11
            public static let pillDot: Double = 7
            public static let pillDotGap: Double = 6
            public static let pillGap: Double = 8
            public static let agentPillHorizontalPadding: Double = 10
            public static let pathIcon: Double = 14
            public static let pathGap: Double = 6
            public static let segmentHeight: Double = 32
            /// Activity and Info both fill this slot below the segments so
            /// switching tabs never moves the list.
            public static let slotHeight: Double = 44
        }

        /// Three-lane strip: 38pt lane names, 12px cells, radius 3, gap 4.
        public enum Lane {
            public static let nameWidth: Double = 38
            public static let nameGap: Double = 10
            public static let cell: Double = 12
            public static let radius: Double = 3
            public static let gap: Double = 4
            /// Cross-lane markers (session boundaries) draw a narrow bar.
            public static let markerWidth: Double = 4
        }

        /// Metric card: 1/3 width, 44 tall, radius 10, `padding 5 10`.
        public enum MetricCard {
            public static let height: Double = 44
            public static let radius: Double = 10
            public static let verticalPadding: Double = 5
            public static let horizontalPadding: Double = 10
            public static let gap: Double = 8
            public static let innerGap: Double = 1
        }

        /// Activity row: `padding 10 16 11`, head gap 8, line gap 3; tag `padding 2 7`, radius 5.
        public enum ActivityRow {
            public static let top: Double = 10
            public static let bottom: Double = 11
            public static let headGap: Double = 8
            public static let lineGap: Double = 3
            public static let tagVerticalPadding: Double = 2
            public static let tagHorizontalPadding: Double = 7
            public static let tagRadius: Double = 5
            public static let contentLineLimit: Int = 2
        }

        /// Activity detail sheet: grabber 36 × 5, top radius 12, code block radius 10.
        public enum Sheet {
            public static let topRadius: Double = 12
            public static let titleTop: Double = 2
            public static let titleBottom: Double = 12
            public static let titleGap: Double = 10
            public static let tagVerticalPadding: Double = 3
            public static let tagHorizontalPadding: Double = 8
            public static let tagRadius: Double = 5
            public static let bodyTop: Double = 14
            public static let sectionGap: Double = 16
            public static let sectionTitleGap: Double = 6
            public static let codeRadius: Double = 10
            public static let codeVerticalPadding: Double = 10
            public static let codeHorizontalPadding: Double = 12
        }

        // MARK: - Macs / Settings / Scanner

        public enum MacRow {
            public static let minimumHeight: Double = 60
            public static let verticalPadding: Double = 10
            public static let gap: Double = 12
            public static let iconWidth: Double = 26
            public static let iconHeight: Double = 20
            public static let lineGap: Double = 2
            public static let dot: Double = 8
        }

        public enum Scanner {
            public static let viewfinder: Double = 252
            public static let radius: Double = 22
            public static let corner: Double = 44
            public static let stroke: Double = 3
            public static let captionGap: Double = 28
            public static let captionInset: Double = 44
            public static let captionLineGap: Double = 6
            public static let torchHeight: Double = 44
            public static let torchHorizontalPadding: Double = 18
            public static let torchGap: Double = 8
            public static let torchBottom: Double = 24
        }

        // MARK: - Type

        /// SF Pro sizes of the screen file that are not system text styles.
        /// Large title / navigation title / tab bar use the system styles.
        public enum Typography {
            /// List title, field label, menu item — 17 / Regular / 22 / −.01em.
            public static let listTitle = DesignTextStyle(size: 17, weight: .regular, lineHeight: 22, trackingEm: -0.01)
            /// Sheet title — 17 / Semibold / 22 / −.01em.
            public static let sheetTitle = DesignTextStyle(size: 17, weight: .semibold, lineHeight: 22, trackingEm: -0.01)
            /// Activity content, field value — 15 / Regular / 20 / −.01em.
            public static let body = DesignTextStyle(size: 15, weight: .regular, lineHeight: 20, trackingEm: -0.01)
            /// `Done`, torch label — 15 / Regular (Medium for torch) / 20.
            public static let action = DesignTextStyle(size: 15, weight: .regular, lineHeight: 20)
            public static let actionEmphasized = DesignTextStyle(size: 15, weight: .medium, lineHeight: 20)
            /// Device name, latest text, footers, path, subtitles — 13 / Regular / 18.
            public static let caption = DesignTextStyle(size: 13, weight: .regular, lineHeight: 18)
            /// Group title, status pill text, segment — 13 / Semibold / 18.
            public static let captionEmphasized = DesignTextStyle(size: 13, weight: .semibold, lineHeight: 18)
            /// Unselected segment — 13 / Medium / 18.
            public static let captionMedium = DesignTextStyle(size: 13, weight: .medium, lineHeight: 18)
            /// Path, Session ID value, code block — 13 / Mono / 18–19.
            public static let captionMono = DesignTextStyle(size: 13, weight: .regular, lineHeight: 18, family: .mono)
            public static let code = DesignTextStyle(size: 13, weight: .regular, lineHeight: 19, family: .mono)
            /// Sheet output — 12 / Mono / 18.
            public static let output = DesignTextStyle(size: 12, weight: .regular, lineHeight: 18, family: .mono)
            /// Mono field values (numbers, dates) — 15 / Mono / 22.
            public static let bodyMono = DesignTextStyle(size: 15, weight: .regular, lineHeight: 22, family: .mono)
            /// Version — 17 / Mono / 22.
            public static let listTitleMono = DesignTextStyle(size: 17, weight: .regular, lineHeight: 22, family: .mono)
            /// Filter trigger — 14 / Regular / 18 / −.01em; badge 10 / Semibold / 13.
            public static let filterTrigger = DesignTextStyle(size: 14, weight: .regular, lineHeight: 18, trackingEm: -0.01)
            public static let filterBadge = DesignTextStyle(size: 10, weight: .semibold, lineHeight: 13)
            /// Filter panel group header — 11 / Semibold / 14 / .06em, uppercase;
            /// option name is `listTitle`, count 15 / Regular / 20 tabular.
            public static let filterPanelHeader = DesignTextStyle(size: 11, weight: .semibold, lineHeight: 14, trackingEm: 0.06)
            public static let filterOptionCount = DesignTextStyle(size: 15, weight: .regular, lineHeight: 20)
            /// Subagent chip name 13 / 18, duration mono 12.
            public static let subagentName = DesignTextStyle(size: 13, weight: .regular, lineHeight: 18)
            public static let subagentTime = DesignTextStyle(size: 12, weight: .regular, lineHeight: 16, family: .mono)
            /// Category tag — 10 / Semibold / .04em.
            public static let tag = DesignTextStyle(size: 10, weight: .semibold, lineHeight: 12, trackingEm: 0.04)
            /// Activity row time — mono 11, tabular.
            public static let activityTime = DesignTextStyle(size: 11, weight: .regular, lineHeight: 14, family: .mono)
            /// Metric card value 16 / Semibold / 20 / −.01em; label 10 / Medium / 13 / .03em uppercase.
            public static let metricValue = DesignTextStyle(size: 16, weight: .semibold, lineHeight: 20, trackingEm: -0.01)
            public static let metricLabel = DesignTextStyle(size: 10, weight: .medium, lineHeight: 13, trackingEm: 0.03)
            /// Lane name — 10 / Medium / 12.
            public static let laneName = DesignTextStyle(size: 10, weight: .medium, lineHeight: 12)
            /// Status label (pill in a row) — 11 / Semibold / 14.
            public static let statusLabel = DesignTextStyle(size: 11, weight: .semibold, lineHeight: 14)
            /// Scanner caption 17 / Semibold / 22.
            public static let scannerTitle = DesignTextStyle(size: 17, weight: .semibold, lineHeight: 22)
        }

        // MARK: - Colour

        /// Colours of the screen file that are not system colours. Everything
        /// that *is* a system colour (`secondaryLabel`, `tertiarySystemFill`,
        /// `systemGroupedBackground`, `systemBlue`) is taken from UIKit.
        public enum Color {
            /// Row separator `rgba(60,60,67,.22)` — one step under the block edge.
            public static let rowSeparator = DesignColor(rgb: 60, 60, 67, alpha: 0.22)
            /// Block edge / list top line / structure connector `rgba(60,60,67,.24)`.
            public static let blockSeparator = DesignColor(rgb: 60, 60, 67, alpha: 0.24)
            /// Neutral agent pill text `rgba(60,60,67,.7)`.
            public static let agentPillText = DesignColor(rgb: 60, 60, 67, alpha: 0.7)
            /// Activity row time `rgba(60,60,67,.45)`; path folder glyph.
            public static let activityTime = DesignColor(rgb: 60, 60, 67, alpha: 0.45)
            /// Sheet output text `rgba(60,60,67,.85)`.
            public static let output = DesignColor(rgb: 60, 60, 67, alpha: 0.85)
            /// Filter badge fill `rgba(0,120,240,.9)`.
            public static let filterBadge = DesignColor(rgb: 0, 120, 240, alpha: 0.9)
            /// Filter panel (L3 §3.4): the screen file gives the light values;
            /// dark takes the matching `SurfaceDark` / `InkDark` steps.
            /// Panel `rgba(252,252,252,.9)` over a thick material.
            public static let filterPanelFill = AdaptiveDesignColor(light: DesignColor(rgb: 252, 252, 252, alpha: 0.9), dark: DesignColor(rgb: 28, 28, 30, alpha: 0.9))
            /// Panel outline `rgba(0,0,0,.07)` and drop shadow `rgba(0,0,0,.18)`.
            public static let filterPanelOutline = AdaptiveDesignColor(light: DesignColor(white: 0, alpha: 0.07), dark: SurfaceDark.separator)
            public static let filterPanelShadow = DesignColor(white: 0, alpha: 0.18)
            /// Group header text `rgba(60,60,67,.45)`.
            public static let filterPanelHeader = AdaptiveDesignColor(light: DesignColor(rgb: 60, 60, 67, alpha: 0.45), dark: InkDark.quaternary)
            /// Row separator `rgba(60,60,67,.1)`.
            public static let filterPanelSeparator = AdaptiveDesignColor(light: DesignColor(rgb: 60, 60, 67, alpha: 0.1), dark: SurfaceDark.separator)
            /// Option count `rgba(60,60,67,.4)`.
            public static let filterOptionCount = AdaptiveDesignColor(light: DesignColor(rgb: 60, 60, 67, alpha: 0.4), dark: InkDark.quaternary)
            /// Unchecked box: fill `rgba(255,255,255,.9)`, ring `rgba(60,60,67,.22)`; checked box is `Semantic.accent`.
            public static let filterCheckboxOff = AdaptiveDesignColor(light: DesignColor(white: 1, alpha: 0.9), dark: DesignColor(white: 1, alpha: 0.06))
            public static let filterCheckboxRing = AdaptiveDesignColor(light: DesignColor(rgb: 60, 60, 67, alpha: 0.22), dark: DesignColor(white: 1, alpha: 0.26))
            /// Icon tile with no semantic hue (a Mac) `rgba(118,118,128,.14)`; its laptop glyph `rgba(60,60,67,.7)`.
            public static let filterTileNeutral = AdaptiveDesignColor(light: DesignColor(rgb: 118, 118, 128, alpha: 0.14), dark: SurfaceDark.control)
            public static let filterTileGlyph = AdaptiveDesignColor(light: DesignColor(rgb: 60, 60, 67, alpha: 0.7), dark: InkDark.brandIcon)
            /// Icon tile of an option with a semantic hue (a status): the hue at
            /// 14 % (dark: D500 at 18 %, like the pill); its dot is the hue's base.
            public static func filterTileFill(_ hue: DesignHue) -> AdaptiveDesignColor {
                AdaptiveDesignColor(light: hue.base.opacity(0.14), dark: hue.darkBase.opacity(0.18))
            }
            /// Subagent summary chevron `rgba(60,60,67,.4)`.
            public static let subagentChevron = DesignColor(rgb: 60, 60, 67, alpha: 0.4)
            /// Not-allowed notification dot / offline Mac dot `rgba(60,60,67,.3)`.
            public static let inactiveDot = DesignColor(rgb: 60, 60, 67, alpha: 0.3)
            /// Laptop glyph in the Macs list: online `.75`, unavailable `.4`.
            public static let macIconOnline = DesignColor(rgb: 60, 60, 67, alpha: 0.75)
            public static let macIconOffline = DesignColor(rgb: 60, 60, 67, alpha: 0.4)
            /// Scanner: page `#101012`, gradient `#26262A → #131316` at 160°, veil white 4 %.
            public static let scannerBackground = DesignColor(hex: 0x101012)
            public static let scannerGradientStart = DesignColor(hex: 0x26262A)
            public static let scannerGradientEnd = DesignColor(hex: 0x131316)
            public static let scannerViewfinderFill = DesignColor(white: 1, alpha: 0.04)
            public static let scannerCaption = DesignColor(white: 1, alpha: 0.62)
            public static let torchFill = DesignColor(white: 1, alpha: 0.16)
            /// Dim outside the viewfinder over the live camera.
            public static let scannerDim = DesignColor(white: 0, alpha: 0.45)
            /// System green used by the notification-allowed dot and the online Mac dot.
            public static let systemGreen = DesignColor(hex: 0x34C759)
        }

        /// Breathing: dot `2.4s ease-in-out infinite` (opacity 1 → .45, scale
        /// 1 → .82); running halo `2.4s ease-out infinite` (opacity .38 → 0,
        /// scale 1 → 2.6). Ended tiers stay still.
        public enum Motion {
            public static let period: Double = 2.4
            public static let breatheOpacity: Double = 0.45
            public static let breatheScale: Double = 0.82
            public static let haloOpacity: Double = 0.38
            public static let haloScale: Double = 2.6
        }
    }
}
