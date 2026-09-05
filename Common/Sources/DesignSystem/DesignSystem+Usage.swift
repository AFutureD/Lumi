import Foundation

public extension DesignSystem {
    /// 1.1 图表序列 — the Usage trend chart and the token composition bar
    /// draw only the blue ramp plus one grey for unpriced tokens; nothing is
    /// invented outside the palette. Series keep their order (segment 1 is
    /// always the bottom of the stack); they are never sorted by size.
    enum Chart {
        /// Series 1–4: Blue 600 / 500 / 400 / 200 in light, D600 / D500 /
        /// D400 / D300 in dark. Stacked by agent, series 1 is Claude Code and
        /// series 3 is Codex; stacked by model, models take 1, 2, 3, 4 in
        /// cost order.
        public static let series: [AdaptiveDesignColor] = [
            AdaptiveDesignColor(light: Palette.blue.s600, dark: Palette.blueDark.d600),
            AdaptiveDesignColor(light: Palette.blue.s500, dark: Palette.blueDark.d500),
            AdaptiveDesignColor(light: Palette.blue.s400, dark: Palette.blueDark.d400),
            AdaptiveDesignColor(light: Palette.blue.s200, dark: Palette.blueDark.d300),
        ]
        /// Models without a published price: Neutral 300 / 中性灰 Dark.
        public static let unpriced = AdaptiveDesignColor(light: Palette.neutral.s300, dark: DesignColor(white: 1, alpha: 0.38))
        /// Which series stacks in the `All agents` chart for each agent.
        public static let claudeSeries = 0
        public static let codexSeries = 2

        // Token composition bar: Input → Cache read → Cache write → Output.
        public static var compositionInput: AdaptiveDesignColor { series[0] }
        public static var compositionCacheRead: AdaptiveDesignColor { series[2] }
        public static var compositionCacheWrite: AdaptiveDesignColor { series[3] }
        public static var compositionOutput: AdaptiveDesignColor { series[1] }

        /// Four dashed grid lines above a solid zero axis; labels 10pt SF
        /// Mono to the left of the plot (Swift Charts sizes that gutter).
        public static let gridLine = AdaptiveDesignColor(light: DesignColor(white: 0, alpha: 0.08), dark: DesignColor(white: 1, alpha: 0.10))
        public static let baseline = AdaptiveDesignColor(light: DesignColor(white: 0, alpha: 0.16), dark: DesignColor(white: 1, alpha: 0.24))
        public static let axisLabel = AdaptiveDesignColor(light: DesignColor(rgb: 150, 150, 150), dark: InkDark.tertiary)
        public static let gridLines = 4
        public static let gridDash: [Double] = [3, 3]
        public static let plotHeight: Double = 148
        /// The x-axis label row under the plot and the space the top grid
        /// label needs above it (labels sit 7px above their line).
        public static let axisLabelRow: Double = 24
        public static let topLabelRoom: Double = 12
        public static let barGap: Double = 3
        public static let barMaximumWidth: Double = 36
        public static let barRadius: Double = 2
        /// Every bar but the hovered one drops to this opacity.
        public static let dimmedBar: Double = 0.38
        public static let titleHeight: Double = 22
        public static let blockGap: Double = 12
        public static let legendSwatch: Double = 8
        public static let legendSwatchRadius: Double = 2
        public static let legendGap: Double = 16
        public static let legendItemGap: Double = 6

        /// Hover annotation: an opaque white card 8px above the bar, first
        /// row date + total, then one row per series.
        public enum Annotation {
            public static let fill = AdaptiveDesignColor(light: Palette.white, dark: DesignColor(rgb: 40, 40, 40))
            public static let ring = AdaptiveDesignColor(light: DesignColor(white: 0, alpha: 0.10), dark: DesignColor(white: 1, alpha: 0.14))
            public static let shadow = DesignColor(white: 0, alpha: 0.16)
            public static let shadowOffsetY: Double = 6
            /// CSS blur radius; SwiftUI's `shadow(radius:)` takes half of it.
            public static let shadowBlur: Double = 18
            public static let radius: Double = 8
            public static let minimumWidth: Double = 132
            public static let paddingTop: Double = 7
            public static let paddingHorizontal: Double = 9
            public static let paddingBottom: Double = 8
            public static let rowGap: Double = 4
            public static let swatch: Double = 7
            public static let offset: Double = 8
            public static let name = AdaptiveDesignColor(light: DesignColor(rgb: 80, 80, 80), dark: InkDark.body)
        }
    }

    /// Usage page (macOS handoff page 8): a Summary card (metrics, token
    /// composition bar, trend chart) over a Detail card (one table, four
    /// groupings). Every value here is the handoff's; the dark column is the
    /// design system's Dark role for the same surface.
    enum Usage {
        // MARK: Layout

        /// The content column hugs a 1440 window's content area.
        public static let contentMaximumWidth: Double = 1160
        public static let cardGap: Double = 20
        public static let cardHeaderHeight: Double = 36
        public static let cardInset: Double = 16
        public static let bodyTop: Double = 16
        public static let bodyBottom: Double = 20
        /// Summary: metrics column | trend chart.
        public static let columnGap: Double = 24
        public static let metricsColumnWidth: Double = 208
        public static let metricsBlockGap: Double = 16
        public static let compositionBarHeight: Double = 6
        public static let compositionBarRadius: Double = 3
        public static let compositionBarTopGap: Double = 3
        public static let figureGap: Double = 24
        public static let labelGap: Double = 4
        /// Detail table.
        public static let tableHeaderHeight: Double = 30
        public static let rowMinimumHeight: Double = 44
        public static let rowInset: Double = 16
        public static let columnSpacing: Double = 12
        public static let childIndent: Double = 20
        public static let groupControlGap: Double = 16
        public static let groupLabelGap: Double = 6
        public static let chevronWidth: Double = 7
        public static let chevronHeight: Double = 11
        /// Notice / error bars above the cards.
        public static let noticeRadius: Double = 9
        public static let noticeVerticalPadding: Double = 9
        public static let noticeHorizontalPadding: Double = 12
        public static let noticeIcon: Double = 14
        public static let noticeGap: Double = 8
        public static let footnoteVerticalPadding: Double = 9

        // MARK: Colours

        public static let cardFill = AdaptiveDesignColor(light: Palette.white, dark: SurfaceDark.card)
        public static let cardRing = AdaptiveDesignColor(light: Surface.hairline, dark: SurfaceDark.hairline)
        public static let cardShadow = DesignColor(white: 0, alpha: 0.03)
        public static let cardShadowOffsetY: Double = 1
        public static let cardShadowBlur: Double = 2
        /// Card header bottom edge and data-row separators.
        public static let rowSeparator = AdaptiveDesignColor(light: Surface.separator, dark: SurfaceDark.separator)
        public static let tableHeaderSeparator = AdaptiveDesignColor(light: DesignColor(white: 0, alpha: 0.06), dark: SurfaceDark.separator)
        public static let tableHeaderFill = AdaptiveDesignColor(light: Palette.neutral.s50, dark: DesignColor(white: 1, alpha: 0.04))
        public static let compositionTrack = AdaptiveDesignColor(light: Surface.chipFill, dark: SurfaceDark.control)
        public static let noticeFill = AdaptiveDesignColor(light: DesignColor(rgb: 120, 120, 128, alpha: 0.10), dark: DesignColor(white: 1, alpha: 0.10))
        public static let noticeRing = AdaptiveDesignColor(light: DesignColor(white: 0, alpha: 0.07), dark: DesignColor(white: 1, alpha: 0.08))
        public static let noticeText = AdaptiveDesignColor(light: DesignColor(rgb: 80, 80, 80), dark: InkDark.body)
        public static let errorFill = AdaptiveDesignColor(light: Palette.red.s600.opacity(0.10), dark: Palette.redDark.d500.opacity(0.14))
        public static let errorRing = AdaptiveDesignColor(light: Palette.red.s600.opacity(0.24), dark: Palette.redDark.d500.opacity(0.32))
        public static let errorText = AdaptiveDesignColor(light: Ink.destructive, dark: InkDark.destructive)
        public static let primaryText = AdaptiveDesignColor(light: Ink.primary, dark: InkDark.primary)
        /// `rgb(114,114,114)` — delta lines, composition caption, chart title, legend.
        public static let secondaryText = AdaptiveDesignColor(light: Ink.tertiary, dark: InkDark.secondary)
        /// `rgb(138,138,138)` — small labels, table headers, paths, dashes.
        public static let tertiaryText = AdaptiveDesignColor(light: Ink.quaternary, dark: InkDark.tertiary)
        public static let childText = AdaptiveDesignColor(light: Ink.primary.opacity(0.86), dark: InkDark.body)
        public static let chevron = AdaptiveDesignColor(light: DesignColor(rgb: 60, 60, 67, alpha: 0.5), dark: InkDark.subagentChevron)
    }
}

public extension DesignSystem.Typography {
    /// Usage metric value — 30 / Regular / 34 / −.022em, tabular numerals, SF Pro.
    static let usageMetricValue = DesignTextStyle(size: 30, weight: .regular, lineHeight: 34, trackingEm: -0.022)
    /// Usage small figures (Sessions / Turns / Calls) — 15 / Regular / 20.
    static let usageFigure = DesignTextStyle(size: 15, weight: .regular, lineHeight: 20)
    /// Usage small labels (COST / TOKENS …) and the chart title — 11 / Semibold / 14 / .04em uppercase.
    static let usageLabel = DesignTextStyle(size: 11, weight: .semibold, lineHeight: 14, trackingEm: 0.04)
    /// Usage table header — 11 / Medium / 14 / .02em.
    static let usageTableHeader = DesignTextStyle(size: 11, weight: .medium, lineHeight: 14, trackingEm: 0.02)
    /// Trend axis labels and annotation rows — 10 / Regular SF Mono.
    static let usageAxisLabel = footnoteMono
    /// Annotation total — 12 / Semibold SF Mono.
    static let usageAnnotationTotal = DesignTextStyle(size: 12, weight: .semibold, lineHeight: 15, family: .mono)
    /// Annotation date — 10 / Regular.
    static let usageAnnotationDate = footnote
}
