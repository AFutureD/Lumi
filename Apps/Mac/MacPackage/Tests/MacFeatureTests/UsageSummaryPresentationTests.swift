import Core
import DesignSystem
import Transport
import Foundation
import Testing
@testable import MacFeature

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private let saturday = UsageDay(year: 2026, month: 9, day: 5)
private let status = UsagePricingStatus(source: .builtin, modelCount: 1)
private let scan = UsageScanStatus(scannedFiles: 1, pendingFiles: 0, isScanning: false)

private func slice(
    agent: AgentProvider? = nil, model: String? = nil, period: UsagePeriod? = nil,
    tokens: UsageTokens, cost: Double?, calls: Int = 1, sessions: Int = 1, turns: Int = 1
) -> UsageSlice {
    UsageSlice(agent: agent, model: model, period: period, tokens: tokens, costUSD: cost, unpricedTokens: cost == nil ? tokens.total : 0, calls: calls, sessions: sessions, turns: turns)
}

private func report(since: UsageDay, until: UsageDay, trendUnit: UsagePeriodUnit, trend: [UsageSlice], totals: UsageSlice, byAgent: [UsageSlice], byModel: [UsageSlice]) -> UsageReport {
    UsageReport(
        since: since, until: until, generatedAt: Date(timeIntervalSince1970: 0),
        totals: totals, byAgent: byAgent, byProject: [], byModel: byModel,
        trendUnit: trendUnit, trend: trend, pricing: status, scan: scan
    )
}

@Test func summaryFiguresFollowTheAgentAndCompareWithThePreviousPeriod() {
    let claude = slice(agent: .claude, tokens: UsageTokens(input: 100, cacheRead: 800, cacheWrite5m: 50, output: 50), cost: 12, calls: 4, sessions: 2, turns: 3)
    let codex = slice(agent: .codex, tokens: UsageTokens(input: 500, output: 500), cost: nil, calls: 2, sessions: 1, turns: 1)
    let totals = slice(tokens: UsageTokens(input: 600, cacheRead: 800, cacheWrite5m: 50, output: 550), cost: 12, calls: 6, sessions: 3, turns: 4)
    let current = report(since: saturday, until: saturday, trendUnit: .hour, trend: [], totals: totals, byAgent: [claude, codex], byModel: [])
    let previousTotals = slice(tokens: UsageTokens(input: 10), cost: 10, calls: 1)
    let previous = report(since: saturday, until: saturday, trendUnit: .hour, trend: [], totals: previousTotals, byAgent: [slice(agent: .claude, tokens: UsageTokens(input: 10), cost: 10)], byModel: [])

    let all = UsageSummaryFigures.build(report: current, previous: previous, agent: .all, comparisonLabel: "yesterday")
    #expect(all.cost == "$12.00")
    #expect(all.costDelta == "↑ 20% vs yesterday")
    #expect(all.tokens == "2.0K")
    #expect(all.tokensExact == "2,000")
    #expect(all.composition == "Cache read 40.0% · output 27.5%")
    #expect(all.segments.map(\.id) == ["input", "cacheRead", "cacheWrite", "output"])
    #expect(abs(all.segments.reduce(0) { $0 + $1.fraction } - 1) < 1e-9)
    #expect(all.sessions == "3" && all.turns == "4" && all.calls == "6")
    #expect(!all.allUnpriced && all.hasUsage)

    let codexOnly = UsageSummaryFigures.build(report: current, previous: previous, agent: .codex, comparisonLabel: "yesterday")
    #expect(codexOnly.cost == "—")
    #expect(codexOnly.allUnpriced)
    #expect(codexOnly.costDelta == "no comparable previous period")
    #expect(codexOnly.segments.map(\.id) == ["input", "output"])
    #expect(codexOnly.calls == "2")

    // An agent absent from the range is a real zero, not unpriced.
    let none = report(since: saturday, until: saturday, trendUnit: .hour, trend: [], totals: claude, byAgent: [claude], byModel: [])
    let codexAbsent = UsageSummaryFigures.build(report: none, previous: nil, agent: .codex, comparisonLabel: "yesterday")
    #expect(codexAbsent.cost == "$0.00")
    #expect(codexAbsent.composition == "no tokens in this range")
    #expect(codexAbsent.segments.isEmpty)
    #expect(!codexAbsent.hasUsage && !codexAbsent.allUnpriced)
}

@Test func trendAxisCoversTheWholePresetAndLabelsByCount() {
    // Today: 24 hour bars, a label every three hours.
    let today = UsageRange(kind: .today, since: saturday, until: saturday)
    let hours = UsageTrend.axis(unit: .hour, range: today, calendar: utc)
    #expect(hours.count == 24)
    #expect(hours.map(\.axisLabel).filter { !$0.isEmpty } == ["00", "03", "06", "09", "12", "15", "18", "21"])
    #expect(hours[9].title == "9/5 09:00")

    // This week: Monday to Sunday, weekday labels, future days present but empty.
    let week = UsageRange(kind: .thisWeek, since: UsageDay(year: 2026, month: 8, day: 31), until: saturday)
    let days = UsageTrend.axis(unit: .day, range: week, calendar: utc)
    #expect(days.map(\.axisLabel) == ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
    #expect(days.last?.period.start == UsageDay(year: 2026, month: 9, day: 6))
    #expect(days[5].title == "Sat 9/5")

    // This month: the 1st to the 30th, month/day labels every fifth bar and on the last.
    let month = UsageRange(kind: .thisMonth, since: UsageDay(year: 2026, month: 9, day: 1), until: saturday)
    let monthDays = UsageTrend.axis(unit: .day, range: month, calendar: utc)
    #expect(monthDays.count == 30)
    #expect(monthDays.map(\.axisLabel).filter { !$0.isEmpty } == ["9/1", "9/6", "9/11", "9/16", "9/21", "9/26", "9/30"])

    // Beyond 90 days: Monday-start weeks, every other one labelled.
    let long = UsageRange(kind: .custom, since: UsageDay(year: 2026, month: 6, day: 3), until: saturday)
    let weeks = UsageTrend.axis(unit: .week, range: long, calendar: utc)
    #expect(weeks.first?.period.start == UsageDay(year: 2026, month: 6, day: 1))
    #expect(weeks.last?.period.start == UsageDay(year: 2026, month: 8, day: 31))
    #expect(weeks.count == 14)
    #expect(weeks[0].axisLabel == "6/1" && weeks[1].axisLabel.isEmpty && weeks[2].axisLabel == "6/15")
    #expect(weeks[0].title == "Week of 6/1")
}

@Test func trendStacksByAgentOrByModelAndKeepsUnpricedGrey() {
    let monday = UsageDay(year: 2026, month: 8, day: 31)
    let range = UsageRange(kind: .thisWeek, since: monday, until: saturday)
    let fable = slice(agent: .claude, model: "claude-fable-5", tokens: UsageTokens(input: 1_000), cost: 10)
    let opus = slice(agent: .claude, model: "claude-opus-5", tokens: UsageTokens(input: 500), cost: 4)
    let review = slice(agent: .codex, model: "codex-auto-review", tokens: UsageTokens(input: 300), cost: nil)
    let gpt = slice(agent: .codex, model: "gpt-5.5", tokens: UsageTokens(input: 200), cost: 1)
    let trendRows = [
        slice(agent: .claude, model: "claude-fable-5", period: UsagePeriod(unit: .day, start: monday), tokens: UsageTokens(input: 600), cost: 6),
        slice(agent: .claude, model: "claude-opus-5", period: UsagePeriod(unit: .day, start: monday), tokens: UsageTokens(input: 500), cost: 4),
        slice(agent: .codex, model: "codex-auto-review", period: UsagePeriod(unit: .day, start: monday), tokens: UsageTokens(input: 300), cost: nil),
        slice(agent: .claude, model: "claude-fable-5", period: UsagePeriod(unit: .day, start: saturday), tokens: UsageTokens(input: 400), cost: 4),
        slice(agent: .codex, model: "gpt-5.5", period: UsagePeriod(unit: .day, start: saturday), tokens: UsageTokens(input: 200), cost: 1),
    ]
    let full = report(
        since: monday, until: saturday, trendUnit: .day, trend: trendRows,
        totals: slice(tokens: UsageTokens(input: 2_000), cost: 15),
        byAgent: [slice(agent: .claude, tokens: UsageTokens(input: 1_500), cost: 14), slice(agent: .codex, tokens: UsageTokens(input: 500), cost: 1)],
        byModel: [fable, opus, gpt, review]
    )

    let all = UsageTrend.build(report: full, range: range, agent: .all, calendar: utc)
    #expect(all.unit == .day)
    #expect(all.title(.cost) == "COST PER DAY")
    #expect(all.series.map(\.id) == ["claude", "codex"])
    #expect(all.series.map(\.colorIndex) == [DesignSystem.Chart.claudeSeries, DesignSystem.Chart.codexSeries])
    #expect(all.series.map(\.legend) == ["Claude Code", "Codex"])
    #expect(all.bars[0].value(.cost, series: "claude") == 10)
    #expect(all.bars[0].value(.cost, series: "codex") == 0)     // unpriced adds no cost…
    #expect(all.bars[0].value(.tokens, series: "codex") == 300) // …but all of its tokens
    #expect(all.bars[5].total(.cost) == 5)
    #expect(all.bars[6].total(.tokens) == 0)                    // Sunday is in the future
    #expect(all.maximum(.cost) == 10 && all.hasData)

    let codex = UsageTrend.build(report: full, range: range, agent: .codex, calendar: utc)
    #expect(codex.series.map(\.name) == ["gpt-5.5", "codex-auto-review"])
    #expect(codex.series.map(\.colorIndex) == [0, nil])
    #expect(codex.series[1].legend == "codex-auto-review · no price")
    #expect(codex.bars[0].total(.cost) == 0 && codex.bars[0].total(.tokens) == 300)
    #expect(codex.title(.tokens) == "TOKENS PER DAY")

    let claude = UsageTrend.build(report: full, range: range, agent: .claude, calendar: utc)
    #expect(claude.series.map(\.colorIndex) == [0, 1])
    #expect(claude.bars[0].value(.cost, series: UsageTrend.modelSeriesID("claude-opus-5")) == 4)
}

@Test func trendAxisScaleIsNiceAndLabelsFollowTheMetric() {
    #expect(UsageTrend.niceMaximum(0) == 1)
    #expect(UsageTrend.niceMaximum(31.2) == 40)
    #expect(UsageTrend.niceMaximum(100) == 100)
    #expect(UsageTrend.niceMaximum(0.42) == 0.5)
    #expect(UsageTrend.niceMaximum(7_300_000) == 8_000_000)
    #expect(UsageTrend.axisLabel(30, metric: .cost, top: 40) == "$30")
    #expect(UsageTrend.axisLabel(0.25, metric: .cost, top: 0.5) == "$0.25")
    #expect(UsageTrend.axisLabel(0.5, metric: .cost, top: 1) == "$0.5")
    #expect(UsageTrend.axisLabel(2_000_000, metric: .tokens, top: 8_000_000) == "2.0M")
    #expect(UsageTrend.valueLabel(31.2, metric: .cost) == "$31.20")
    #expect(UsageTrend.valueLabel(12_400, metric: .tokens) == "12.4K")
    let empty = UsageTrend(unit: .day, bars: [], series: [])
    #expect(empty.gridValues(.cost) == [0.25, 0.5, 0.75, 1])
}
