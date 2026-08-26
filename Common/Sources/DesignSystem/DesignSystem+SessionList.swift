import Foundation

// L4 §4.4b macOS Session 行（两行式 · 子代理一行一个）— the macOS Sessions
// list row. Two lines per session (status dot + title + relative time over
// agent icon + model · effort + stacked subagent dots + chevron); expanded
// subagents one per line inside the same block. Values are the handoff's
// macOS column; the iOS / Notch chip pairing (§4.4) does not use these.

public extension DesignSystem {
    enum SessionList {
        // MARK: Row block

        /// Row inner padding `7px 10px`.
        public static let rowVerticalPadding: Double = 7
        public static let rowHorizontalPadding: Double = 10
        /// Title line height 18, subtitle line height 16, 2 between them.
        public static let titleLineHeight: Double = 18
        public static let subtitleLineHeight: Double = 16
        public static let lineGap: Double = 2
        /// `[16 dot column] 8 [content] 8 [time]`.
        public static let dotColumnWidth: Double = 16
        public static let columnGap: Double = 8
        /// Subtitle left inset — aligns with the title text (16 + 8).
        public static let subtitleIndent: Double = 24
        /// Subtitle inner gap (icon ↔ model ↔ effort).
        public static let subtitleGap: Double = 6
        /// Scroll body bottom padding (`padding: 0 0 12px`).
        public static let listBottomPadding: Double = 12

        // MARK: Status dots

        /// Session dot 7px with a 2.5px halo (`DesignSystem.StatusDot`);
        /// subagent line dot 6px, no halo.
        public static let subagentDot: Double = 6

        /// Agent icon in the subtitle, original colours.
        public static let agentIcon: Double = 13

        // MARK: Stacked subagent dots + chevron

        /// 9px dots, ringed 1.5px in near-white, overlapping 3 from the
        /// second on; at most 5 are drawn — the rest only count in the tooltip.
        public static let stackedDot: Double = 9
        public static let stackedDotRing: Double = 1.5
        public static let stackedDotOverlap: Double = 3
        public static let stackedDotMaximum: Int = 5
        public static let stackedDotRingColor = DesignColor(white: 1, alpha: 0.95)
        /// `chevron.down` in a 12pt slot; rotates 180° over 0.2s when the
        /// group opens. Bold at 8pt draws the §4.4b nominal 10×6 glyph —
        /// the same rendering the Notch's count strip uses.
        public static let chevronSymbolSize: Double = 8
        public static let chevronSlot: Double = 12
        public static let chevronStroke = DesignColor(rgb: 60, 60, 67, alpha: 0.42)
        public static let chevronAnimation: Double = 0.2
        /// Cluster gap (dots ↔ chevron).
        public static let clusterGap: Double = 6

        // MARK: Subagent line group

        /// Group container: `margin-left 24 · margin-top 4 · padding-top 5`,
        /// 1px top border.
        public static let subagentGroupIndent: Double = 24
        public static let subagentGroupTopMargin: Double = 4
        public static let subagentGroupTopPadding: Double = 5
        public static let subagentGroupSeparator = DesignColor(white: 0, alpha: 0.08)
        /// Line height 20, `gap 8`, selection outsets 4 each side.
        public static let subagentLineHeight: Double = 20
        public static let subagentLineGap: Double = 8

        // MARK: Selection & hover

        /// Session block selection is full-width, square (`Surface.selection`);
        /// a selected subagent line is a radius-6 rounded rect grown 4 to
        /// each side. The two are mutually exclusive.
        public static let subagentSelectionRadius: Double = 6
        public static let subagentSelectionOutset: Double = 4
        /// Hover wash, same shape as the selection it previews.
        public static let hover = DesignColor(white: 0, alpha: 0.04)
        public static let hoverDark = DesignColor(white: 1, alpha: 0.06)

        // MARK: Text colours

        /// Completed rows drop the title to this; every other tier keeps
        /// `Ink.primary`.
        public static let completedTitle = DesignColor(rgb: 90, 90, 90)
        /// Subtitle (`model · effort`) and relative times (Neutral 400).
        public static let subtitleText = DesignSystem.Ink.quaternary

        // MARK: Search header

        /// Header 52 high, `padding 0 14`, 1px bottom separator; the search
        /// field inside is the system one (28 high, capsule).
        public static let headerHeight: Double = 52
        public static let headerHorizontalPadding: Double = 14
    }
}
