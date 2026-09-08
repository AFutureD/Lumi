import Core
import Transport
import Foundation

/// The iPhone's own derivations over the Macs' usage reports — pure, so
/// they are tested without a view.
///
/// `All Macs` merges every Mac's report by key: totals and comparison
/// totals are summed; `byAgent` by agent, `byModel` by (agent, model),
/// `byProject` by workspace, the time tables and `trend` by their period
/// (each Mac's own local day — the handoff's "各自本地日对齐"). Sessions,
/// turns and calls are distinct per Mac, so they add. A comparison is only
/// kept when every Mac carried one; otherwise the delta has nothing honest
/// to compare against and is left out.
enum UsageAggregate {
    /// The report the History segment reads for a scope: that Mac's, or
    /// the merge of every Mac's for `All Macs`. `nil` when no Mac has one.
    static func report(for scope: HostID?, in reports: [HostID: UsageReport]) -> UsageReport? {
        if let scope { return reports[scope] }
        return merge(reports)
    }

    static func merge(_ reports: [HostID: UsageReport]) -> UsageReport? {
        // Sorted by host id so the merged row order is stable across reloads.
        let ordered = reports.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { reports[$0] }
        guard let first = ordered.first else { return nil }
        if ordered.count == 1 { return first }

        var merged = first
        merged.since = ordered.map(\.since).min() ?? first.since
        merged.until = ordered.map(\.until).max() ?? first.until
        merged.generatedAt = ordered.map(\.generatedAt).max() ?? first.generatedAt
        merged.totals = ordered.dropFirst().reduce(first.totals) { sum($0, $1.totals) }
        merged.byAgent = mergeRows(ordered.flatMap(\.byAgent), key: { AgentKey($0) }, order: costDescending)
        merged.byModel = mergeRows(ordered.flatMap(\.byModel), key: { ModelKey($0) }, order: modelOrder)
        merged.byProject = mergeRows(ordered.flatMap(\.byProject), key: { $0.workspace ?? "" }, order: costDescending)
        merged.byDay = mergeRows(ordered.flatMap(\.byDay), key: { $0.period }, order: periodAscending)
        merged.byWeek = mergeRows(ordered.flatMap(\.byWeek), key: { $0.period }, order: periodAscending)
        merged.byMonth = mergeRows(ordered.flatMap(\.byMonth), key: { $0.period }, order: periodAscending)
        merged.trend = mergeRows(ordered.flatMap(\.trend), key: { TrendKey($0) }, order: periodAscending)
        merged.comparison = mergeComparisons(ordered.map(\.comparison))
        return merged
    }

    /// One row per key, every duplicate summed into the first; then ordered.
    private static func mergeRows<Key: Hashable>(
        _ rows: [UsageSlice],
        key: (UsageSlice) -> Key,
        order: (UsageSlice, UsageSlice) -> Bool
    ) -> [UsageSlice] {
        var index: [Key: Int] = [:]
        var result: [UsageSlice] = []
        for row in rows {
            let k = key(row)
            if let position = index[k] {
                result[position] = sum(result[position], row)
            } else {
                index[k] = result.count
                result.append(row)
            }
        }
        return result.sorted(by: order)
    }

    private static func mergeComparisons(_ comparisons: [UsageComparison?]) -> UsageComparison? {
        let present = comparisons.compactMap { $0 }
        guard present.count == comparisons.count, let first = present.first else { return nil }
        return UsageComparison(
            since: present.map(\.since).min() ?? first.since,
            until: present.map(\.until).max() ?? first.until,
            totals: present.dropFirst().reduce(first.totals) { sum($0, $1.totals) },
            byAgent: mergeRows(present.flatMap(\.byAgent), key: { AgentKey($0) }, order: costDescending)
        )
    }

    /// `a + b`, keeping `a`'s grouping keys. Cost is `nil` only when both
    /// sides are unpriced (a missing price, not a zero).
    static func sum(_ a: UsageSlice, _ b: UsageSlice) -> UsageSlice {
        var result = a
        result.tokens.add(b.tokens)
        result.costUSD = (a.costUSD == nil && b.costUSD == nil) ? nil : (a.costUSD ?? 0) + (b.costUSD ?? 0)
        result.unpricedTokens = a.unpricedTokens + b.unpricedTokens
        result.calls = a.calls + b.calls
        result.sessions = a.sessions + b.sessions
        result.turns = a.turns + b.turns
        result.lastDay = [a.lastDay, b.lastDay].compactMap { $0 }.max()
        if result.provider == nil { result.provider = b.provider }
        return result
    }

    // MARK: Keys and orders

    private struct AgentKey: Hashable {
        let agent: AgentProvider?
        init(_ slice: UsageSlice) { agent = slice.agent }
    }

    private struct ModelKey: Hashable {
        let agent: AgentProvider?
        let model: String?
        init(_ slice: UsageSlice) { agent = slice.agent; model = slice.model }
    }

    private struct TrendKey: Hashable {
        let period: UsagePeriod?
        let agent: AgentProvider?
        let model: String?
        init(_ slice: UsageSlice) { period = slice.period; agent = slice.agent; model = slice.model }
    }

    private static func costDescending(_ a: UsageSlice, _ b: UsageSlice) -> Bool {
        (a.costUSD ?? -1) > (b.costUSD ?? -1)
    }

    /// Cost descending, unpriced rows last (the daemon's own `byModel` order).
    private static func modelOrder(_ a: UsageSlice, _ b: UsageSlice) -> Bool {
        switch (a.costUSD, b.costUSD) {
        case let (x?, y?): x > y
        case (nil, nil): a.tokens.total > b.tokens.total
        case (nil, _): false
        case (_, nil): true
        }
    }

    private static func periodAscending(_ a: UsageSlice, _ b: UsageSlice) -> Bool {
        switch (a.period, b.period) {
        case let (x?, y?): x < y
        case (nil, nil): false
        case (nil, _): true
        case (_, nil): false
        }
    }

    // MARK: Chart series

    /// The series id of the merged `Other N models` segment.
    static let otherSeriesID = "model:other"
    /// Ramp step of the `Other` segment — the lightest blue, `#DBECFD`.
    static let otherColorIndex = 3

    /// A by-model trend fit for a 152pt chart: unpriced models produce no
    /// cost and are left out; more than `maximumSeries` priced models
    /// become the top three by cost plus one `Other N models` segment (any
    /// thinner slice is 1–2px and unreadable). Series are re-indexed deep →
    /// light by share, bottom → top. A by-agent trend is returned as is.
    static func reducingModels(_ trend: UsageTrend, maximumSeries: Int = 4) -> UsageTrend {
        let isByModel = trend.series.contains { $0.id.hasPrefix("model:") }
        guard isByModel else { return trend }
        let priced = trend.series.filter { $0.colorIndex != nil }
        let cost: (UsageTrendSeries) -> Double = { series in
            trend.bars.reduce(0) { $0 + $1.value(.cost, series: series.id) }
        }
        let ranked = priced.sorted { cost($0) > cost($1) }
        if ranked.count <= maximumSeries {
            let series = ranked.enumerated().map { offset, item in
                UsageTrendSeries(id: item.id, name: item.name, colorIndex: offset)
            }
            return UsageTrend(unit: trend.unit, bars: bars(trend.bars, keeping: Set(series.map(\.id))), series: series)
        }
        let kept = Array(ranked.prefix(maximumSeries - 1))
        let folded = Array(ranked.dropFirst(maximumSeries - 1))
        let foldedIDs = Set(folded.map(\.id))
        var series = kept.enumerated().map { offset, item in
            UsageTrendSeries(id: item.id, name: item.name, colorIndex: offset)
        }
        series.append(UsageTrendSeries(id: otherSeriesID, name: "Other \(folded.count) models", colorIndex: otherColorIndex))
        let bars = trend.bars.map { bar in
            var values: [String: UsageTrendValue] = [:]
            var other = UsageTrendValue()
            for (id, value) in bar.values {
                if foldedIDs.contains(id) {
                    other.cost += value.cost
                    other.tokens += value.tokens
                } else if kept.contains(where: { $0.id == id }) {
                    values[id] = value
                }
            }
            if other.cost > 0 || other.tokens > 0 { values[otherSeriesID] = other }
            return UsageTrendBar(id: bar.id, period: bar.period, axisLabel: bar.axisLabel, title: bar.title, values: values)
        }
        return UsageTrend(unit: trend.unit, bars: bars, series: series)
    }

    private static func bars(_ bars: [UsageTrendBar], keeping ids: Set<String>) -> [UsageTrendBar] {
        bars.map { bar in
            UsageTrendBar(
                id: bar.id, period: bar.period, axisLabel: bar.axisLabel, title: bar.title,
                values: bar.values.filter { ids.contains($0.key) }
            )
        }
    }

    // MARK: Selected bucket

    /// The slice a selected bar stands for: every agent's part of the bucket,
    /// or one agent's when the chart is filtered. Cost and tokens are the
    /// real per-bucket sums from the daemon's `trend` rows, not a share of
    /// the range. Sessions / turns / calls are not bucketed on the wire and
    /// stay at zero.
    static func bucketSlice(bar: UsageTrendBar, agent: UsageSummaryAgent) -> UsageSlice {
        var cost = 0.0
        var tokens = 0.0
        if let provider = agent.provider {
            let value = bar.values[provider.rawValue] ?? UsageTrendValue()
            cost = value.cost
            tokens = value.tokens
        } else {
            cost = bar.total(.cost)
            tokens = bar.total(.tokens)
        }
        return UsageSlice(
            agent: agent.provider,
            period: bar.period,
            tokens: UsageTokens(input: Int64(tokens.rounded())),
            costUSD: cost
        )
    }
}
