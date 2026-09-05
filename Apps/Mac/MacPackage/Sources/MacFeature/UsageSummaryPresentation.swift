import Core
import DesignSystem
import Transport
import Foundation

/// What the Summary card shows for one agent choice: the two big numbers
/// with their captions, the composition bar's segments and the three small
/// figures. Pure — derived from the report (and the comparison period the
/// daemon folded into it) so the view holds no arithmetic.
struct UsageSummaryFigures: Equatable {
    struct Segment: Equatable, Identifiable {
        let id: String
        let color: AdaptiveDesignColor
        let fraction: Double
    }

    let cost: String
    let costDelta: String
    let tokens: String
    let tokensExact: String
    let composition: String
    let segments: [Segment]
    let sessions: String
    let turns: String
    let calls: String
    /// Every model in the slice is unpriced: Cost reads `—`, the trend falls back to Tokens.
    let allUnpriced: Bool

    static func build(report: UsageReport, agent: UsageSummaryAgent, comparisonLabel: String) -> UsageSummaryFigures {
        let slice = Self.slice(totals: report.totals, byAgent: report.byAgent, for: agent)
        let previousSlice = report.comparison.map { Self.slice(totals: $0.totals, byAgent: $0.byAgent, for: agent) }
        let total = slice.tokens.total
        let composition = total > 0
            ? "Cache read \(UsageFormatting.percent(slice.tokens.cacheRead, of: total)) · output \(UsageFormatting.percent(slice.tokens.output, of: total))"
            : "no tokens in this range"
        let segments: [Segment] = total > 0 ? [
            Segment(id: "input", color: DesignSystem.Chart.compositionInput, fraction: Double(slice.tokens.input) / Double(total)),
            Segment(id: "cacheRead", color: DesignSystem.Chart.compositionCacheRead, fraction: Double(slice.tokens.cacheRead) / Double(total)),
            Segment(id: "cacheWrite", color: DesignSystem.Chart.compositionCacheWrite, fraction: Double(slice.tokens.cacheWrite) / Double(total)),
            Segment(id: "output", color: DesignSystem.Chart.compositionOutput, fraction: Double(slice.tokens.output) / Double(total)),
        ].filter { $0.fraction > 0 } : []
        return UsageSummaryFigures(
            cost: UsageFormatting.cost(slice.costUSD),
            costDelta: UsageFormatting.delta(current: slice.costUSD, previous: previousSlice?.costUSD, against: comparisonLabel),
            tokens: UsageFormatting.tokens(total),
            tokensExact: UsageFormatting.exactTokens(total),
            composition: composition,
            segments: segments,
            sessions: UsageFormatting.count(slice.sessions),
            turns: UsageFormatting.count(slice.turns),
            calls: UsageFormatting.count(slice.calls),
            allUnpriced: slice.costUSD == nil
        )
    }

    /// The totals row, or the agent's row (a zero row when the agent has no
    /// usage in the range — its cost is a real $0, not unpriced).
    static func slice(totals: UsageSlice, byAgent: [UsageSlice], for agent: UsageSummaryAgent) -> UsageSlice {
        guard let provider = agent.provider else { return totals }
        return byAgent.first { $0.agent == provider } ?? UsageSlice(agent: provider, costUSD: 0)
    }
}

/// One stacked series of the trend chart.
struct UsageTrendSeries: Identifiable, Equatable {
    let id: String
    let name: String
    /// Index into `DesignSystem.Chart.series`; `nil` draws the unpriced grey.
    let colorIndex: Int?

    var legend: String { colorIndex == nil ? "\(name) · no price" : name }
    var color: AdaptiveDesignColor {
        colorIndex.map { DesignSystem.Chart.series[$0 % DesignSystem.Chart.series.count] } ?? DesignSystem.Chart.unpriced
    }
}

struct UsageTrendValue: Equatable {
    var cost = 0.0
    var tokens = 0.0
}

/// One bar of the trend chart: a period on the axis, with a value per series.
struct UsageTrendBar: Identifiable, Equatable {
    let id: String
    let period: UsagePeriod
    /// Text under the bar; empty for the bars the axis skips.
    let axisLabel: String
    /// The annotation's first line: `Sat 9/5`, `9/5 09:00`, `Week of 8/31`.
    let title: String
    var values: [String: UsageTrendValue] = [:]

    func value(_ metric: UsageTrendMetric, series: String) -> Double {
        let value = values[series] ?? UsageTrendValue()
        return metric == .cost ? value.cost : value.tokens
    }

    func total(_ metric: UsageTrendMetric) -> Double {
        values.values.reduce(0) { $0 + (metric == .cost ? $1.cost : $1.tokens) }
    }
}

/// The trend chart's data for one agent choice: bars on a fixed axis (the
/// whole month, the whole week, 24 hours — future slots stay empty) and the
/// series they stack. Built from `UsageReport.trend`, whose granularity the
/// daemon chose from the range.
struct UsageTrend: Equatable {
    let unit: UsagePeriodUnit
    let bars: [UsageTrendBar]
    let series: [UsageTrendSeries]

    var hasData: Bool { bars.contains { $0.total(.tokens) > 0 } }

    /// `COST PER DAY`, `TOKENS PER HOUR`, …
    func title(_ metric: UsageTrendMetric) -> String {
        "\(metric.title) per \(unit.rawValue)".uppercased()
    }

    func maximum(_ metric: UsageTrendMetric) -> Double {
        bars.map { $0.total(metric) }.max() ?? 0
    }

    /// The y axis top: the smallest of 1 / 1.5 / 2 / 2.5 / 3 / 4 / 5 / 6 /
    /// 8 / 10 × 10ⁿ at or above the tallest bar.
    static func niceMaximum(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let power = pow(10, floor(log10(value)))
        let normalized = value / power
        let steps: [Double] = [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]
        let step = steps.first { $0 >= normalized - 1e-9 } ?? 10
        return step * power
    }

    /// Grid line values, evenly spaced up to the nice maximum.
    func gridValues(_ metric: UsageTrendMetric) -> [Double] {
        let top = Self.niceMaximum(maximum(metric))
        let count = DesignSystem.Chart.gridLines
        return (1...count).map { top / Double(count) * Double($0) }
    }

    /// `$20`, `$0.25`, `12.4K` — an axis label.
    static func axisLabel(_ value: Double, metric: UsageTrendMetric, top: Double) -> String {
        switch metric {
        case .cost:
            if top >= 10 { return "$" + String(format: "%.0f", value) }
            var text = String(format: "%.2f", value)
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            return "$" + text
        case .tokens:
            return UsageFormatting.tokens(Int64(value.rounded()))
        }
    }

    /// `$31.20` / `12.4K` — an annotation value.
    static func valueLabel(_ value: Double, metric: UsageTrendMetric) -> String {
        switch metric {
        case .cost: UsageFormatting.cost(value)
        case .tokens: UsageFormatting.tokens(Int64(value.rounded()))
        }
    }

    static func build(
        report: UsageReport,
        range: UsageRange,
        agent: UsageSummaryAgent,
        calendar: Calendar
    ) -> UsageTrend {
        let unit = report.trendUnit
        var bars = Self.axis(unit: unit, range: range, calendar: calendar)
        let series = Self.series(of: report, for: agent)
        var index: [String: Int] = [:]
        for (offset, bar) in bars.enumerated() { index[bar.id] = offset }
        for slice in report.trend {
            guard let period = slice.period, let provider = slice.agent else { continue }
            if let wanted = agent.provider, wanted != provider { continue }
            guard let position = index[Self.barID(period)] else { continue }
            let seriesID = agent == .all ? provider.rawValue : Self.modelSeriesID(slice.model ?? "")
            var value = bars[position].values[seriesID] ?? UsageTrendValue()
            value.cost += slice.costUSD ?? 0
            value.tokens += Double(slice.tokens.total)
            bars[position].values[seriesID] = value
        }
        return UsageTrend(unit: unit, bars: bars, series: series)
    }

    /// `All agents` stacks Claude Code (series 1) under Codex (series 3);
    /// one agent stacks its models in cost order on series 1–4, unpriced
    /// models in grey.
    static func series(of report: UsageReport, for agent: UsageSummaryAgent) -> [UsageTrendSeries] {
        guard let provider = agent.provider else {
            return [AgentProvider.claude, .codex]
                .filter { candidate in report.byAgent.contains { $0.agent == candidate } }
                .map { candidate in
                    UsageTrendSeries(
                        id: candidate.rawValue,
                        name: UsageSummaryAgent(candidate).title,
                        colorIndex: candidate == .claude ? DesignSystem.Chart.claudeSeries : DesignSystem.Chart.codexSeries
                    )
                }
        }
        var priced = 0
        return report.byModel.filter { $0.agent == provider }.map { slice in
            let model = slice.model ?? ""
            let colorIndex: Int?
            if slice.costUSD == nil {
                colorIndex = nil
            } else {
                colorIndex = priced
                priced += 1
            }
            return UsageTrendSeries(id: modelSeriesID(model), name: model.isEmpty ? "Unknown model" : model, colorIndex: colorIndex)
        }
    }

    /// The bars the range spans, before any data: 24 hours for a day; the
    /// whole week or month for those presets (future days empty); every day
    /// of a custom range; Monday-start weeks beyond 90 days.
    static func axis(unit: UsagePeriodUnit, range: UsageRange, calendar: Calendar) -> [UsageTrendBar] {
        switch unit {
        case .hour:
            return (0..<24).map { hour in
                let period = UsagePeriod(unit: .hour, start: range.since, hour: hour)
                return UsageTrendBar(
                    id: barID(period),
                    period: period,
                    axisLabel: hour % 3 == 0 ? String(format: "%02d", hour) : "",
                    title: "\(UsageFormatting.monthDay(range.since)) \(UsageFormatting.hourLabel(hour))"
                )
            }
        case .day:
            let (first, last): (UsageDay, UsageDay) = switch range.kind {
            case .thisMonth: (range.since.startOfMonth, range.since.endOfMonth(in: calendar))
            case .thisWeek: (range.since.startOfWeek(in: calendar), range.since.endOfWeek(in: calendar))
            case .today, .custom: (range.since, range.until)
            }
            var days: [UsageDay] = []
            var cursor = first
            while cursor <= last, days.count < 400 {
                days.append(cursor)
                guard let next = cursor.adding(days: 1, calendar: calendar) else { break }
                cursor = next
            }
            return days.enumerated().map { offset, day in
                let period = UsagePeriod(unit: .day, start: day)
                let label = days.count <= 7
                    ? UsageFormatting.weekday(day, calendar: calendar)
                    : (offset % 5 == 0 || offset == days.count - 1 ? UsageFormatting.monthDay(day) : "")
                return UsageTrendBar(
                    id: barID(period),
                    period: period,
                    axisLabel: label,
                    title: "\(UsageFormatting.weekday(day, calendar: calendar)) \(UsageFormatting.monthDay(day))"
                )
            }
        case .week, .month:
            var starts: [UsageDay] = []
            var cursor = range.since.startOfWeek(in: calendar)
            while cursor <= range.until, starts.count < 100 {
                starts.append(cursor)
                guard let next = cursor.adding(days: 7, calendar: calendar) else { break }
                cursor = next
            }
            return starts.enumerated().map { offset, start in
                let period = UsagePeriod(unit: .week, start: start)
                return UsageTrendBar(
                    id: barID(period),
                    period: period,
                    axisLabel: offset % 2 == 0 ? UsageFormatting.monthDay(start) : "",
                    title: "Week of \(UsageFormatting.monthDay(start))"
                )
            }
        }
    }

    static func barID(_ period: UsagePeriod) -> String {
        period.hour.map { "\(period.start.rawValue)@\($0)" } ?? period.start.rawValue
    }

    static func modelSeriesID(_ model: String) -> String { "model:\(model)" }
}
