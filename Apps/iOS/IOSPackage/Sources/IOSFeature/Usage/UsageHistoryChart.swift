import Charts
import Core
import DesignSystem
import Observation
import SwiftUI
import UIKit
import os

private let log = os.Logger(subsystem: "app.huanan.lumi", category: "usage.history")

/// The chart card's data, owned by UIKit and read by SwiftUI. The only
/// SwiftUI in the app: Swift Charts draws the stacked bars, everything
/// around it is UIKit (`UsageChartCardView` hosts this through a
/// `UIHostingController`).
@MainActor
@Observable
final class UsageChartModel {
    var trend: UsageTrend
    /// The y axis top — always the All-agents trend's nice maximum, so a
    /// filtered chart shrinks instead of rescaling.
    var yMaximum: Double
    /// Half the gap between bars (`8` for day bars, `2` for the 30-bar month).
    var barInset: CGFloat

    init(trend: UsageTrend, yMaximum: Double, barInset: CGFloat) {
        self.trend = trend
        self.yMaximum = yMaximum
        self.barInset = barInset
    }
}

extension UsageTrendSeries {
    /// Ramp step → the design system's blue ramp; unpriced models grey.
    var uiColor: UIColor {
        UIColor(colorIndex.map { DesignSystem.Chart.series[$0 % DesignSystem.Chart.series.count] } ?? DesignSystem.Chart.unpriced)
    }
}

/// `COST PER DAY`: stacked `BarMark`s per bucket, a 1px baseline, no y
/// axis, 11pt axis labels (the Core axis already blanks all but five of the
/// month's 30), and a wrapping legend. Height is the plot (152) + the axis
/// row + the legend.
///
/// Tapping a bar opens the bucket popup over it (the other bars dim to .3);
/// tapping the same bar, an empty one, or changing the range closes it. The
/// popup is the chart's own state — nothing above the chart follows it.
/// Every change of `shown` runs on one spring: the popup fades and scales
/// out of the bar top (and slides to the next bar), the bars dim with it.
struct UsageHistoryChart: View {
    private typealias U = DesignSystem.IOS.Usage

    let model: UsageChartModel
    /// The `chartXSelection` binding; reset after every tap so the same bar
    /// can be tapped again.
    @State private var tapped: String?
    /// `UsageTrendBar.id` of the bar whose popup is open.
    @State private var shown: String?
    @State private var popupSize: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: U.chartLegendGap) {
            chart
                .frame(height: U.chartHeight + U.chartAxisRowHeight)
            if model.trend.hasData {
                legend
            }
        }
        .onChange(of: model.trend.bars.map(\.id)) { _, _ in show(nil) }
    }

    private static let spring = Animation.spring(duration: U.popupSpringDuration)

    private func show(_ bucket: String?) {
        withAnimation(Self.spring) { shown = bucket }
    }

    /// The bar whose popup is open; a bar that lost its cost (the agent
    /// filter changed) closes it.
    private var shownBar: UsageTrendBar? {
        guard let bar = model.trend.bars.first(where: { $0.id == shown }), bar.total(.cost) > 0 else { return nil }
        return bar
    }

    private var chart: some View {
        let trend = model.trend
        let barIDs = trend.bars.map(\.id)
        let selected = shownBar?.id
        return Chart {
            ForEach(trend.bars) { bar in
                let dimmed = selected != nil && selected != bar.id
                let top = trend.series.last { bar.value(.cost, series: $0.id) > 0 }?.id
                ForEach(trend.series) { series in
                    BarMark(
                        x: .value("Period", bar.id),
                        y: .value("Cost", bar.value(.cost, series: series.id)),
                        width: .inset(model.barInset)
                    )
                    .foregroundStyle(by: .value("Series", series.id))
                    .opacity(dimmed ? U.dimmedBar : 1)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: top == series.id ? U.barRadius : 0,
                        topTrailingRadius: top == series.id ? U.barRadius : 0
                    ))
                }
            }
        }
        .chartForegroundStyleScale(domain: trend.series.map(\.id), range: trend.series.map { Color(uiColor: $0.uiColor) })
        .chartXScale(domain: barIDs)
        .chartYScale(domain: 0...max(model.yMaximum, 1e-9))
        .chartXSelection(value: $tapped)
        // The default iOS selection gesture is press-and-drag; a bar here is
        // tapped, so a plain tap drives the same binding.
        .chartGesture { proxy in
            SpatialTapGesture().onEnded { value in proxy.selectXValue(at: value.location.x) }
        }
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: barIDs) { value in
                AxisValueLabel(centered: true) {
                    if let id = value.as(String.self) {
                        let isSelected = id == selected
                        // The label switches weight, not size: kept out of
                        // the popup's spring so it never animates its width
                        // (and truncates) on the way.
                        Text(trend.bars.first { $0.id == id }?.axisLabel ?? "")
                            .font(Font(isSelected ? DesignSystem.IOS.Typography.usageAxisLabelSelected : DesignSystem.IOS.Typography.usageAxisLabel).monospacedDigit())
                            .foregroundStyle(isSelected ? Color(uiColor: UIColor(U.selectedAxisLabel)) : Color(U.tertiaryText))
                            .fixedSize()
                            .transaction { $0.animation = nil }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.0]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: DesignSystem.Stroke.separator))
                    .foregroundStyle(Color(U.chartBaseline))
            }
        }
        .chartPlotStyle { plot in
            plot.frame(height: U.chartHeight)
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                // The popup is a plain overlay above the whole chart — a
                // chart annotation sits in the marks' own layer, where the
                // bars drawn after it paint over it. It is hidden until
                // measured, so it never flashes at the bar top first.
                let plotFrame = proxy.plotFrame.map { geometry[$0] } ?? CGRect(origin: .zero, size: proxy.plotSize)
                if let placement = popup(in: plotFrame, proxy: proxy) {
                    UsageBucketPopup(bar: placement.bar, series: trend.series)
                        .onGeometryChange(for: CGSize.self, of: \.size) { popupSize = $0 }
                        .opacity(popupSize == .zero ? 0 : 1)
                        .position(placement.center)
                        .transition(.opacity.combined(with: .scale(scale: U.popupEntranceScale, anchor: .bottom)))
                }
            }
            .allowsHitTesting(false)
        }
        // A tap lands here as a new value: it opens that bar's popup, or
        // closes the popup when it is the open bar or an empty one. The
        // binding is reset so the same bar can be tapped again.
        .onChange(of: tapped) { _, new in
            guard let new else { return }
            let hasCost = trend.bars.first { $0.id == new }?.total(.cost) ?? 0 > 0
            show((shown == new || !hasCost) ? nil : new)
            log.info("history_bucket bucket=\(shown ?? "none", privacy: .public)")
            Task { @MainActor in tapped = nil }
        }
        .accessibilityLabel(trend.title(.cost))
    }

    /// Where the popup goes: centred over the open bar, its bottom 8pt
    /// above the bar's top; slid sideways to stay inside the plot, and
    /// pushed down when it would leave the plot at the top.
    private func popup(in plotFrame: CGRect, proxy: ChartProxy) -> (bar: UsageTrendBar, center: CGPoint)? {
        let bars = model.trend.bars
        guard let bar = shownBar, let index = bars.firstIndex(where: { $0.id == bar.id }),
              let barTop = proxy.position(forY: bar.total(.cost)) else { return nil }
        let slot = plotFrame.width / CGFloat(max(bars.count, 1))
        let anchorX = plotFrame.minX + slot * (CGFloat(index) + 0.5)
        let anchorY = plotFrame.minY + barTop
        // The popup is narrower than any plot (its model name is capped),
        // so clamping never inverts.
        let halfWidth = min(max(popupSize.width, DesignSystem.Chart.Annotation.minimumWidth), plotFrame.width) / 2
        let x = min(max(anchorX, plotFrame.minX + halfWidth), plotFrame.maxX - halfWidth)
        let top = max(anchorY - DesignSystem.Chart.Annotation.offset - popupSize.height, plotFrame.minY)
        return (bar, CGPoint(x: x, y: top + popupSize.height / 2))
    }

    private var legend: some View {
        FlowLayout(spacing: U.legendGap, rowSpacing: U.legendRowGap) {
            ForEach(model.trend.series) { series in
                HStack(spacing: U.legendItemGap) {
                    RoundedRectangle(cornerRadius: U.legendSwatchRadius, style: .continuous)
                        .fill(Color(uiColor: series.uiColor))
                        .frame(width: U.legendSwatch, height: U.legendSwatch)
                    Text(series.legend)
                        .font(Font(DesignSystem.IOS.Typography.usageLegend))
                        .foregroundStyle(Color(U.secondaryText))
                        .lineLimit(1)
                }
            }
        }
    }
}

/// The bucket popup: date + total cost, one row per series that has a
/// value, then the bucket's tokens. Same card as the Mac hover annotation,
/// with a capped model name so it always fits the phone's plot. Its fill
/// is adaptive, so every colour on it is too.
private struct UsageBucketPopup: View {
    private typealias A = DesignSystem.Chart.Annotation

    let bar: UsageTrendBar
    let series: [UsageTrendSeries]

    var body: some View {
        VStack(alignment: .leading, spacing: A.rowGap) {
            HStack(spacing: DesignSystem.Spacing.l) {
                Text(bar.title)
                    .font(Font(DesignSystem.Typography.usageAnnotationDate))
                    .foregroundStyle(Color(uiColor: .inkSecondary))
                Spacer(minLength: 0)
                Text(UsageFormatting.cost(bar.total(.cost)))
                    .font(Font(DesignSystem.Typography.usageAnnotationTotal))
                    .foregroundStyle(Color(uiColor: .inkPrimary))
            }
            ForEach(series.filter { bar.value(.cost, series: $0.id) > 0 }) { item in
                HStack(spacing: DesignSystem.Spacing.s) {
                    RoundedRectangle(cornerRadius: DesignSystem.Chart.legendSwatchRadius, style: .continuous)
                        .fill(Color(uiColor: item.uiColor))
                        .frame(width: A.swatch, height: A.swatch)
                    Text(item.name)
                        .font(Font(DesignSystem.Typography.footnote))
                        .foregroundStyle(Color(uiColor: UIColor(A.name)))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: DesignSystem.IOS.Usage.popupNameMaximumWidth, alignment: .leading)
                    Spacer(minLength: DesignSystem.Spacing.l)
                    Text(UsageFormatting.cost(bar.value(.cost, series: item.id)))
                        .font(Font(DesignSystem.IOS.Typography.usageAxisLabel).monospacedDigit())
                        .foregroundStyle(Color(uiColor: .inkPrimary))
                }
            }
            HStack(spacing: DesignSystem.Spacing.l) {
                Text("Tokens")
                    .font(Font(DesignSystem.Typography.footnote))
                    .foregroundStyle(Color(uiColor: .inkSecondary))
                Spacer(minLength: 0)
                Text(UsageFormatting.tokens(Int64(bar.total(.tokens).rounded())))
                    .font(Font(DesignSystem.IOS.Typography.usageAxisLabel).monospacedDigit())
                    .foregroundStyle(Color(uiColor: .inkPrimary))
            }
        }
        .padding(.top, A.paddingTop)
        .padding(.horizontal, A.paddingHorizontal)
        .padding(.bottom, A.paddingBottom)
        .frame(minWidth: A.minimumWidth, alignment: .leading)
        .background(Color(uiColor: UIColor(A.fill)), in: RoundedRectangle(cornerRadius: A.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: A.radius, style: .continuous)
                .strokeBorder(Color(uiColor: UIColor(A.ring)), lineWidth: DesignSystem.Stroke.hairline)
        }
        .shadow(color: Color(A.shadow), radius: A.shadowBlur / 2, y: A.shadowOffsetY)
        .fixedSize()
    }
}

/// Left-to-right, wrapping to the next row when the width runs out.
private struct FlowLayout: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: width.isFinite ? width : widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
