import Charts
import Core
import DesignSystem
import Observation
import SwiftUI
import UIKit

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
    var selected: String?
    var onTap: (String) -> Void

    init(trend: UsageTrend, yMaximum: Double, barInset: CGFloat, selected: String? = nil, onTap: @escaping (String) -> Void) {
        self.trend = trend
        self.yMaximum = yMaximum
        self.barInset = barInset
        self.selected = selected
        self.onTap = onTap
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
/// month's 30), tap a bar to select it (the others dim to .3), and a
/// wrapping legend. Height is the plot (152) + the axis row + the legend.
struct UsageHistoryChart: View {
    private typealias U = DesignSystem.IOS.Usage

    let model: UsageChartModel
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: U.chartLegendGap) {
            chart
                .frame(height: U.chartHeight + U.chartAxisRowHeight)
            if model.trend.hasData {
                legend
            }
        }
    }

    private var chart: some View {
        let trend = model.trend
        let barIDs = trend.bars.map(\.id)
        let selected = model.selected
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
        .chartXSelection(value: $selection)
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
                        Text(trend.bars.first { $0.id == id }?.axisLabel ?? "")
                            .font(Font(isSelected ? DesignSystem.IOS.Typography.usageAxisLabelSelected : DesignSystem.IOS.Typography.usageAxisLabel).monospacedDigit())
                            .foregroundStyle(Color(isSelected ? U.selectedAxisLabel : U.tertiaryText))
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
        // A tap lands here as a new value; UIKit decides what it means
        // (select, or clear when it is the selected bar) and the binding is
        // reset so the same bar can be tapped again.
        .onChange(of: selection) { _, new in
            guard let new else { return }
            model.onTap(new)
            Task { @MainActor in selection = nil }
        }
        .accessibilityLabel(trend.title(.cost))
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
