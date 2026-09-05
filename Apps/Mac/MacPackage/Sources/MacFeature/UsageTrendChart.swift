import Charts
import Core
import DesignSystem
import Transport
import SwiftUI

/// The Summary card's trend: stacked bars per period (Swift Charts), four
/// dashed grid lines over a solid zero axis, a legend, and a hover
/// annotation that follows the pointer. Bars share the plot width evenly
/// (3pt apart, at most 36 wide); every bar but the hovered one dims.
struct UsageTrendChart: View {
    typealias Chart = DesignSystem.Chart
    typealias Plot = Charts.Chart

    let trend: UsageTrend
    let metric: UsageTrendMetric

    @State private var selected: String?
    @State private var plotWidth: CGFloat = 0
    @State private var cardSize: CGSize = .zero

    private var top: Double { UsageTrend.niceMaximum(trend.maximum(metric)) }
    private var grid: [Double] { trend.gridValues(metric) }

    /// The hovered bar, if it has anything to show; an empty slot neither
    /// dims the others nor gets a card.
    private var hoveredBar: UsageTrendBar? {
        guard let bar = trend.bars.first(where: { $0.id == selected }), bar.total(metric) > 0 else { return nil }
        return bar
    }

    private var barWidth: CGFloat {
        guard plotWidth > 0, !trend.bars.isEmpty else { return Chart.barMaximumWidth }
        let slot = plotWidth / CGFloat(trend.bars.count)
        return max(1, min(Chart.barMaximumWidth, slot - Chart.barGap))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Chart.blockGap) {
            chart
                .frame(height: Chart.plotHeight + Chart.axisLabelRow)
            if trend.hasData {
                legend
            }
        }
        .onChange(of: trend.bars.map(\.id)) { _, _ in selected = nil }
    }

    private var chart: some View {
        let seriesIDs = trend.series.map(\.id)
        let seriesColors = trend.series.map { Color($0.color) }
        let barIDs = trend.bars.map(\.id)
        return Plot {
            ForEach(trend.bars) { bar in
                ForEach(trend.series) { series in
                    segment(bar: bar, series: series)
                }
            }
        }
        .chartForegroundStyleScale(domain: seriesIDs, range: seriesColors)
        .chartXScale(domain: barIDs)
        // Headroom above the top grid line for its label (labels sit above their line).
        .chartYScale(domain: 0...(top * (1 + Chart.topLabelRoom / Chart.plotHeight)))
        .chartXSelection(value: $selected)
        .chartLegend(.hidden)
        .chartXAxis { xAxis(barIDs) }
        .chartYAxis { yAxis }
        .chartPlotStyle { plot in
            plot.frame(height: Chart.plotHeight)
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                // The hover card is a plain overlay above the whole chart —
                // a chart annotation sits in the marks' own layer, where the
                // bars drawn after it paint over it.
                let plotFrame = proxy.plotFrame.map { geometry[$0] } ?? CGRect(origin: .zero, size: proxy.plotSize)
                Color.clear
                    .onAppear { plotWidth = plotFrame.width }
                    .onChange(of: plotFrame.width) { _, width in plotWidth = width }
                if let placement = hoverCard(in: plotFrame, proxy: proxy) {
                    UsageTrendAnnotation(bar: placement.bar, series: trend.series, metric: metric)
                        .onGeometryChange(for: CGSize.self, of: \.size) { cardSize = $0 }
                        .position(placement.center)
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityLabel(trend.title(metric))
    }

    /// Where the hover card goes: centred over the hovered bar, its bottom
    /// 8pt above the bar's top; slid sideways to stay inside the plot, and
    /// pushed down when it would leave the plot at the top.
    private func hoverCard(in plotFrame: CGRect, proxy: ChartProxy) -> (bar: UsageTrendBar, center: CGPoint)? {
        guard let bar = hoveredBar, let index = trend.bars.firstIndex(where: { $0.id == bar.id }),
              let barTop = proxy.position(forY: bar.total(metric)) else { return nil }
        let slot = plotFrame.width / CGFloat(max(trend.bars.count, 1))
        let anchorX = plotFrame.minX + slot * (CGFloat(index) + 0.5)
        let anchorY = plotFrame.minY + barTop
        let halfWidth = max(cardSize.width, Chart.Annotation.minimumWidth) / 2
        let x = min(max(anchorX, plotFrame.minX + halfWidth), plotFrame.maxX - halfWidth)
        let top = max(anchorY - Chart.Annotation.offset - cardSize.height, plotFrame.minY)
        return (bar, CGPoint(x: x, y: top + cardSize.height / 2))
    }

    private func segment(bar: UsageTrendBar, series: UsageTrendSeries) -> some ChartContent {
        let isTop = topSeries(of: bar) == series.id
        let value = bar.value(metric, series: series.id)
        return BarMark(
            x: .value("Period", bar.id),
            y: .value(metric.title, value),
            width: .fixed(barWidth)
        )
        .foregroundStyle(by: .value("Series", series.id))
        .opacity(hoveredBar == nil || hoveredBar?.id == bar.id ? 1 : Chart.dimmedBar)
        .cornerRadius(isTop ? Chart.barRadius : 0)
    }

    private func xAxis(_ barIDs: [String]) -> some AxisContent {
        AxisMarks(values: barIDs) { value in
            AxisValueLabel(centered: true) {
                if let id = value.as(String.self) {
                    Text(axisLabel(for: id))
                        .font(Font(DesignSystem.Typography.usageAxisLabel))
                        .foregroundStyle(Color(Chart.axisLabel))
                }
            }
        }
    }

    @AxisContentBuilder
    private var yAxis: some AxisContent {
        AxisMarks(position: .leading, values: [0.0]) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: DesignSystem.Stroke.separator))
                .foregroundStyle(Color(Chart.baseline))
        }
        AxisMarks(position: .leading, values: grid) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: DesignSystem.Stroke.separator, dash: Chart.gridDash.map { CGFloat($0) }))
                .foregroundStyle(Color(Chart.gridLine))
            AxisValueLabel(anchor: .bottomTrailing) {
                if trend.hasData, let number = value.as(Double.self) {
                    Text(UsageTrend.axisLabel(number, metric: metric, top: top))
                        .font(Font(DesignSystem.Typography.usageAxisLabel))
                        .foregroundStyle(Color(Chart.axisLabel))
                }
            }
        }
    }

    private func axisLabel(for barID: String) -> String {
        trend.bars.first { $0.id == barID }?.axisLabel ?? ""
    }

    private var legend: some View {
        HStack(spacing: Chart.legendGap) {
            ForEach(trend.series) { series in
                HStack(spacing: Chart.legendItemGap) {
                    RoundedRectangle(cornerRadius: Chart.legendSwatchRadius, style: .continuous)
                        .fill(Color(series.color))
                        .frame(width: Chart.legendSwatch, height: Chart.legendSwatch)
                    Text(series.legend)
                        .font(Font(DesignSystem.Typography.subheadline))
                        .foregroundStyle(Color(DesignSystem.Usage.secondaryText))
                        .lineLimit(1)
                }
            }
        }
    }

    /// The uppermost segment with a value — the one that gets the rounded top.
    private func topSeries(of bar: UsageTrendBar) -> String? {
        trend.series.last { bar.value(metric, series: $0.id) > 0 }?.id
    }
}

/// The hover card: date + total, then one line per series that has a value.
private struct UsageTrendAnnotation: View {
    typealias A = DesignSystem.Chart.Annotation

    let bar: UsageTrendBar
    let series: [UsageTrendSeries]
    let metric: UsageTrendMetric

    var body: some View {
        VStack(alignment: .leading, spacing: A.rowGap) {
            HStack(spacing: DesignSystem.Spacing.l) {
                Text(bar.title)
                    .font(Font(DesignSystem.Typography.usageAnnotationDate))
                    .foregroundStyle(Color(DesignSystem.Usage.secondaryText))
                Spacer(minLength: 0)
                Text(UsageTrend.valueLabel(bar.total(metric), metric: metric))
                    .font(Font(DesignSystem.Typography.usageAnnotationTotal))
                    .foregroundStyle(Color(DesignSystem.Usage.primaryText))
            }
            ForEach(series.filter { bar.value(metric, series: $0.id) > 0 }) { item in
                let value = bar.value(metric, series: item.id)
                HStack(spacing: DesignSystem.Spacing.s) {
                    RoundedRectangle(cornerRadius: DesignSystem.Chart.legendSwatchRadius, style: .continuous)
                        .fill(Color(item.color))
                        .frame(width: A.swatch, height: A.swatch)
                    Text(item.name)
                        .font(Font(DesignSystem.Typography.footnote))
                        .foregroundStyle(Color(A.name))
                        .lineLimit(1)
                    Spacer(minLength: DesignSystem.Spacing.l)
                    Text(UsageTrend.valueLabel(value, metric: metric))
                        .font(Font(DesignSystem.Typography.usageAxisLabel))
                        .foregroundStyle(Color(DesignSystem.Usage.primaryText))
                }
            }
        }
        .padding(.top, A.paddingTop)
        .padding(.horizontal, A.paddingHorizontal)
        .padding(.bottom, A.paddingBottom)
        .frame(minWidth: A.minimumWidth, alignment: .leading)
        .background(Color(A.fill), in: RoundedRectangle(cornerRadius: A.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: A.radius, style: .continuous)
                .strokeBorder(Color(A.ring), lineWidth: DesignSystem.Stroke.hairline)
        }
        .shadow(color: Color(A.shadow), radius: A.shadowBlur / 2, y: A.shadowOffsetY)
        .fixedSize()
    }
}
