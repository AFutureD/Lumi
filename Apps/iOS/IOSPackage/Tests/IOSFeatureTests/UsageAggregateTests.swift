import Core
import Transport
import Foundation
import Testing
@testable import IOSFeature

private let pricing = UsagePricingStatus(source: .builtin, modelCount: 3)
private let scan = UsageScanStatus(scannedFiles: 1, pendingFiles: 0, isScanning: false)
private let monday = UsageDay(year: 2026, month: 9, day: 7)
private let tuesday = UsageDay(year: 2026, month: 9, day: 8)
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func day(_ day: UsageDay) -> UsagePeriod { UsagePeriod(unit: .day, start: day) }

private func row(
    agent: AgentProvider? = nil, model: String? = nil, period: UsagePeriod? = nil,
    cost: Double?, tokens: Int64, sessions: Int = 1, turns: Int = 2, calls: Int = 3
) -> UsageSlice {
    UsageSlice(
        agent: agent, model: model, period: period,
        tokens: UsageTokens(input: tokens), costUSD: cost,
        unpricedTokens: cost == nil ? tokens : 0, calls: calls, sessions: sessions, turns: turns
    )
}

private func report(
    since: UsageDay = monday, until: UsageDay = tuesday,
    totals: UsageSlice, byAgent: [UsageSlice], byModel: [UsageSlice], trend: [UsageSlice],
    comparison: UsageComparison? = nil
) -> UsageReport {
    UsageReport(
        since: since, until: until, generatedAt: Date(timeIntervalSince1970: 1_000),
        totals: totals, byAgent: byAgent, byProject: [], byModel: byModel,
        trendUnit: .day, trend: trend, comparison: comparison, pricing: pricing, scan: scan
    )
}

private let pro = HostID("pro")
private let mini = HostID("mini")

private func proReport(comparison: UsageComparison? = UsageComparison(since: monday, until: monday, totals: row(cost: 5, tokens: 500), byAgent: [row(agent: .claude, cost: 5, tokens: 500)])) -> UsageReport {
    report(
        totals: row(cost: 10, tokens: 1_000, sessions: 3, turns: 30, calls: 300),
        byAgent: [row(agent: .claude, cost: 8, tokens: 800), row(agent: .codex, cost: 2, tokens: 200)],
        byModel: [row(agent: .claude, model: "sonnet", cost: 8, tokens: 800), row(agent: .codex, model: "gpt", cost: 2, tokens: 200)],
        trend: [
            row(agent: .claude, model: "sonnet", period: day(monday), cost: 6, tokens: 600),
            row(agent: .claude, model: "sonnet", period: day(tuesday), cost: 2, tokens: 200),
            row(agent: .codex, model: "gpt", period: day(tuesday), cost: 2, tokens: 200),
        ],
        comparison: comparison
    )
}

private func miniReport(comparison: UsageComparison? = UsageComparison(since: monday, until: monday, totals: row(cost: 1, tokens: 100), byAgent: [row(agent: .codex, cost: 1, tokens: 100)])) -> UsageReport {
    report(
        since: tuesday, until: tuesday,
        totals: row(cost: 4, tokens: 400, sessions: 2, turns: 20, calls: 200),
        byAgent: [row(agent: .codex, cost: 3, tokens: 300), row(agent: .claude, cost: 1, tokens: 100)],
        byModel: [row(agent: .codex, model: "gpt", cost: 3, tokens: 300), row(agent: .claude, model: "haiku", cost: 1, tokens: 100)],
        trend: [
            row(agent: .codex, model: "gpt", period: day(tuesday), cost: 3, tokens: 300),
            row(agent: .claude, model: "haiku", period: day(tuesday), cost: 1, tokens: 100),
        ],
        comparison: comparison
    )
}

@Suite("UsageAggregate.merge")
struct UsageAggregateMergeTests {
    @Test func mergesTwoMacsByKey() throws {
        let merged = try #require(UsageAggregate.merge([pro: proReport(), mini: miniReport()]))

        #expect(merged.since == monday)
        #expect(merged.until == tuesday)
        #expect(merged.totals.costUSD == 14)
        #expect(merged.totals.tokens.total == 1_400)
        #expect(merged.totals.sessions == 5)
        #expect(merged.totals.turns == 50)
        #expect(merged.totals.calls == 500)

        // by agent: summed per provider, cost descending
        #expect(merged.byAgent.map(\.agent) == [.claude, .codex])
        #expect(merged.byAgent.map(\.costUSD) == [9, 5])

        // by model: (agent, model) keyed; the shared `gpt` row is one row
        #expect(merged.byModel.count == 3)
        #expect(merged.byModel.first { $0.model == "gpt" }?.costUSD == 5)
        #expect(merged.byModel.map(\.model) == ["sonnet", "gpt", "haiku"])

        // trend: (period, agent, model) keyed, period ascending
        #expect(merged.trend.count == 4)
        let tuesdayGPT = merged.trend.first { $0.period == day(tuesday) && $0.model == "gpt" }
        #expect(tuesdayGPT?.costUSD == 5)
        #expect(merged.trend.first?.period == day(monday))

        // comparison: both carried one → summed
        let comparison = try #require(merged.comparison)
        #expect(comparison.totals.costUSD == 6)
        #expect(comparison.byAgent.count == 2)
    }

    @Test func comparisonDroppedWhenAnyMacLacksOne() throws {
        let merged = try #require(UsageAggregate.merge([pro: proReport(), mini: miniReport(comparison: nil)]))
        #expect(merged.comparison == nil)
    }

    @Test func singleMacPassesThroughAndEmptyIsNil() {
        #expect(UsageAggregate.merge([pro: proReport()]) == proReport())
        #expect(UsageAggregate.merge([:]) == nil)
        #expect(UsageAggregate.report(for: mini, in: [pro: proReport(), mini: miniReport()]) == miniReport())
    }

    @Test func unpricedCostStaysNilOnlyWhenBothSidesAreUnpriced() {
        let unpriced = row(agent: .codex, model: "spark", cost: nil, tokens: 50)
        let priced = row(agent: .codex, model: "spark", cost: 2, tokens: 50)
        #expect(UsageAggregate.sum(unpriced, unpriced).costUSD == nil)
        #expect(UsageAggregate.sum(unpriced, priced).costUSD == 2)
        #expect(UsageAggregate.sum(unpriced, unpriced).unpricedTokens == 100)
    }
}

@Suite("UsageAggregate.reducingModels")
struct UsageAggregateModelReductionTests {
    private func trend(models: [(String, Double)], unpriced: [String] = []) -> UsageTrend {
        let byModel = models.map { row(agent: .claude, model: $0.0, cost: $0.1, tokens: Int64($0.1 * 100)) }
            + unpriced.map { row(agent: .claude, model: $0, cost: nil, tokens: 10) }
        let trendRows = byModel.map { slice in
            var copy = slice
            copy.period = day(monday)
            return copy
        }
        let report = report(
            since: monday, until: monday,
            totals: row(cost: models.map(\.1).reduce(0, +), tokens: 0),
            byAgent: [row(agent: .claude, cost: models.map(\.1).reduce(0, +), tokens: 0)],
            byModel: byModel, trend: trendRows
        )
        let range = UsageRange(kind: .thisWeek, since: monday, until: monday)
        return UsageTrend.build(report: report, range: range, agent: .claude, calendar: calendar)
    }

    @Test func fourOrFewerModelsKeepTheirOwnSeriesReindexedByCost() {
        let reduced = UsageAggregate.reducingModels(trend(models: [("a", 5), ("b", 3), ("c", 1)], unpriced: ["u"]))
        #expect(reduced.series.map(\.name) == ["a", "b", "c"])
        #expect(reduced.series.map(\.colorIndex) == [0, 1, 2])
        // The unpriced model produces no cost and leaves the chart.
        #expect(!reduced.series.contains { $0.name == "u" })
        #expect(reduced.bars.first?.values.keys.contains(UsageTrend.modelSeriesID("u")) == false)
    }

    @Test func moreThanFourModelsFoldIntoTopThreePlusOther() throws {
        let reduced = UsageAggregate.reducingModels(trend(models: [("a", 5), ("b", 4), ("c", 3), ("d", 2), ("e", 1), ("f", 0.5)]))
        #expect(reduced.series.map(\.name) == ["a", "b", "c", "Other 3 models"])
        #expect(reduced.series.map(\.colorIndex) == [0, 1, 2, UsageAggregate.otherColorIndex])
        let bar = try #require(reduced.bars.first { $0.id == UsageTrend.barID(day(monday)) })
        #expect(bar.value(.cost, series: UsageAggregate.otherSeriesID) == 3.5)
        #expect(bar.value(.cost, series: UsageTrend.modelSeriesID("a")) == 5)
        #expect(bar.total(.cost) == 15.5)
    }

    @Test func byAgentTrendIsUntouched() {
        let range = UsageRange(kind: .thisWeek, since: monday, until: tuesday)
        let all = UsageTrend.build(report: proReport(), range: range, agent: .all, calendar: calendar)
        #expect(UsageAggregate.reducingModels(all) == all)
    }
}

@Suite("UsageHistoryState")
struct UsageHistoryStateTests {
    @Test func defaultsFollowTheHandoff() {
        let state = UsageHistoryState()
        #expect(state.range == .thisWeek)
        #expect(state.scope == nil)
        #expect(state.chartAgent == .all)
        #expect(state.selectedBucket == nil)
        #expect(state.preset == .thisWeek)
    }

    @Test func rangeAndAgentClearSelectionScopeKeepsIt() {
        var state = UsageHistoryState()
        state.toggle(bucket: "2026-09-07")
        #expect(state.selectedBucket == "2026-09-07")

        state.select(scope: pro)
        #expect(state.selectedBucket == "2026-09-07")

        state.select(range: .thisWeek) // unchanged range keeps it
        #expect(state.selectedBucket == "2026-09-07")
        state.select(range: .today)
        #expect(state.selectedBucket == nil)

        state.toggle(bucket: "x")
        state.select(agent: .claude)
        #expect(state.selectedBucket == nil)
        #expect(state.chartAgent == .claude)
    }

    @Test func tappingTheSelectedBucketAgainClearsIt() {
        var state = UsageHistoryState()
        state.toggle(bucket: "a")
        state.toggle(bucket: "b")
        #expect(state.selectedBucket == "b")
        state.toggle(bucket: "b")
        #expect(state.selectedBucket == nil)
    }

    @Test func unpairedScopeFallsBackToAllMacs() {
        var state = UsageHistoryState()
        state.select(scope: mini)
        state.reconcile(pairedHosts: [pro])
        #expect(state.scope == nil)
    }
}

@Suite("UsageHistoryText")
struct UsageHistoryTextTests {
    @Test func rangeCaptions() {
        #expect(UsageHistoryText.rangeCaption(since: UsageDay(year: 2026, month: 9, day: 1), until: UsageDay(year: 2026, month: 9, day: 7)) == "Sep 1 – 7, 2026")
        #expect(UsageHistoryText.rangeCaption(since: UsageDay(year: 2026, month: 8, day: 31), until: UsageDay(year: 2026, month: 9, day: 6)) == "Aug 31 – Sep 6, 2026")
        #expect(UsageHistoryText.rangeCaption(since: UsageDay(year: 2026, month: 9, day: 7), until: UsageDay(year: 2026, month: 9, day: 7)) == "Sep 7")
    }

    @Test func unpricedNotice() {
        #expect(UsageHistoryText.unpricedNotice(modelCount: 0) == nil)
        #expect(UsageHistoryText.unpricedNotice(modelCount: 1) == "1 model has no price · counted in tokens, not in cost")
        #expect(UsageHistoryText.unpricedNotice(modelCount: 2) == "2 models have no price · counted in tokens, not in cost")
    }

    @Test func bucketCostSplitAndSlice() {
        let bar = UsageTrendBar(
            id: "b", period: day(monday), axisLabel: "M", title: "Mon 9/7",
            values: ["claude": UsageTrendValue(cost: 4.05, tokens: 1_000), "codex": UsageTrendValue(cost: 1.12, tokens: 500)]
        )
        #expect(UsageHistoryText.bucketCostSplit(bar: bar, agent: .all) == "Claude Code $4.05 · Codex $1.12")
        #expect(UsageHistoryText.bucketCostSplit(bar: bar, agent: .claude) == "Claude Code only")

        let whole = UsageAggregate.bucketSlice(bar: bar, agent: .all)
        #expect(whole.costUSD == 5.17)
        #expect(whole.tokens.total == 1_500)
        let claude = UsageAggregate.bucketSlice(bar: bar, agent: .claude)
        #expect(claude.costUSD == 4.05)
        #expect(claude.tokens.total == 1_000)
    }
}

@Suite("PlanAccountModel")
struct PlanAccountModelTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func account(status: PlanUsageAccountStatus = .ok, enabled: Bool = true, limits: [PlanUsageLimit]? = nil) -> PlanUsageAccount {
        PlanUsageAccount(
            id: .claude, provider: .claude, enabled: enabled, status: status,
            statusDetail: status == .credentialsMissing ? "no ~/.claude/.credentials.json" : nil,
            retryAt: status == .rateLimited ? now.addingTimeInterval(240) : nil,
            limits: limits ?? [
                PlanUsageLimit(window: .weekly, usedPercent: 18, resetsAt: now.addingTimeInterval(4 * 86_400 + 6 * 3_600)),
                PlanUsageLimit(window: .weekly, model: "Fable", usedPercent: 7),
                PlanUsageLimit(window: .session, usedPercent: 91, resetsAt: now.addingTimeInterval(38 * 60)),
            ],
            fetchedAt: now.addingTimeInterval(-120)
        )
    }

    @Test func windowsAreOrderedAndWarnOnlyTheNumber() {
        let model = PlanAccountModel.build(account: account(), percentStyle: .used, macName: "MacBook Pro", macOnline: true, snapshotAt: now, now: now)
        #expect(model.stamp == "updated 2m ago")
        #expect(model.windows.map(\.title) == ["SESSION · 5 HOURS", "WEEKLY · 7 DAYS", "FABLE · 7 DAYS"])
        #expect(model.windows.map(\.percent) == ["91%", "18%", "7%"])
        #expect(model.windows.map(\.warning) == [true, false, false])
        #expect(model.windows[0].resets == "resets in 38m 0s")
        #expect(model.windows[2].resets == nil)
        #expect(model.windows.allSatisfy { $0.usedNote == nil })
        #expect(model.note == nil)
        #expect(!model.dimmed)
    }

    @Test func remainingStyleChangesTheNumberNotTheBar() {
        let model = PlanAccountModel.build(account: account(), percentStyle: .remaining, macName: "Mac mini", macOnline: true, snapshotAt: now, now: now)
        #expect(model.windows[0].percent == "9%")
        #expect(model.windows[0].usedFraction == 0.91)
        #expect(model.windows[0].usedNote == "91% used")
        #expect(model.windows[0].warning)
    }

    @Test func switchedOffAndSignInStates() {
        let off = PlanAccountModel.build(account: account(enabled: false), percentStyle: .used, macName: "M", macOnline: true, snapshotAt: now, now: now)
        #expect(off.stamp == "off")
        #expect(off.windows.isEmpty)
        #expect(off.note == PlanAccountModel.Note(text: "Switched off on this Mac", warning: false))

        let missing = PlanAccountModel.build(account: account(status: .credentialsMissing), percentStyle: .used, macName: "M", macOnline: true, snapshotAt: now, now: now)
        #expect(missing.dimmed)
        #expect(missing.windows.isEmpty)
        #expect(missing.stamp == nil)
        #expect(missing.note == PlanAccountModel.Note(text: "Not signed in · no ~/.claude/.credentials.json", warning: true))

        let expired = PlanAccountModel.build(account: account(status: .signInExpired), percentStyle: .used, macName: "M", macOnline: true, snapshotAt: now, now: now)
        #expect(expired.note?.text == "Saved sign-in expired · sign in again with Claude Code")
    }

    @Test func rateLimitedKeepsNumbersAndOfflineExplainsTheAge() {
        let limited = PlanAccountModel.build(account: account(status: .rateLimited), percentStyle: .used, macName: "M", macOnline: true, snapshotAt: now, now: now)
        #expect(limited.windows.count == 3)
        #expect(limited.note == PlanAccountModel.Note(text: "Rate limited · retry in 4m 0s", warning: true))

        let offline = PlanAccountModel.build(account: account(), percentStyle: .used, macName: "MacBook Pro", macOnline: false, snapshotAt: now.addingTimeInterval(-7_200), now: now)
        #expect(offline.windows.count == 3)
        #expect(offline.note == PlanAccountModel.Note(text: "MacBook Pro offline · numbers from 2h ago", warning: true))
    }
}
