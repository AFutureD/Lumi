import Transport
import Foundation
import Testing
@testable import Core

private let prices = ModelPriceTable(providers: [
    "anthropic": ["claude-fable-5": ModelPrice(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5)],
    "openai": ["gpt-5.5": ModelPrice(input: 2, output: 8, cacheRead: 0.2, tiers: [
        ModelPriceTier(size: 272_000, rates: ModelRates(input: 4, output: 16, cacheRead: 0.4)),
    ])],
])

private func bucket(
    agent: AgentKind = .claude, session: String = "s1", turn: String = "t1", model: String = "claude-fable-5",
    day: UsageDay = UsageDay(year: 2026, month: 9, day: 5), workspace: String = "/w",
    tokens: UsageTokens = UsageTokens(input: 1_000_000, output: 1_000_000), calls: Int = 1,
    reportedCostUSD: Double? = nil, reportedCalls: Int = 0, tier: Int = 0
) -> UsageBucket {
    UsageBucket(
        agent: agent, sessionID: session, turnID: turn, model: model, day: day, tier: tier, workspace: workspace,
        firstAt: Date(timeIntervalSince1970: 0), lastAt: Date(timeIntervalSince1970: 0), tokens: tokens, calls: calls,
        reportedCostUSD: reportedCostUSD, reportedCalls: reportedCalls
    )
}

private let status = UsagePricingStatus(source: .builtin, modelCount: 2)
private let scan = UsageScanStatus(scannedFiles: 3, pendingFiles: 0, isScanning: false)

@Test func reportFoldsBucketsIntoEveryGrouping() {
    let report = UsageReportBuilder.build(
        buckets: [
            bucket(),                                                                       // $60
            bucket(turn: "t2", day: UsageDay(year: 2026, month: 9, day: 6), calls: 3),       // $60, same session
            bucket(agent: .claudeSubagent, turn: "t1", workspace: "/w"),                     // $60, parent session id
            bucket(agent: .codex, session: "c1", turn: "u1", model: "gpt-5.5", workspace: "/c",
                   tokens: UsageTokens(input: 1_000_000, cacheRead: 1_000_000, output: 0)),  // $2.2
            bucket(agent: .codex, session: "c2", turn: "", model: "codex-auto-review", workspace: "/c",
                   tokens: UsageTokens(input: 500, output: 500)),                            // unpriced
        ],
        prices: prices,
        since: UsageDay(year: 2026, month: 9, day: 1),
        until: UsageDay(year: 2026, month: 9, day: 7),
        generatedAt: Date(timeIntervalSince1970: 1),
        pricing: status,
        scan: scan
    )
    #expect(report.since == UsageDay(year: 2026, month: 9, day: 1))
    #expect(report.pricing == status)
    #expect(report.scan == scan)

    let totals = report.totals
    #expect(totals.costUSD == 182.2)
    #expect(totals.unpricedTokens == 1_000)
    #expect(totals.tokens.total == 3 * 2_000_000 + 2_000_000 + 1_000)
    #expect(totals.calls == 7)
    #expect(totals.sessions == 3)          // s1 (incl. its subagent), c1, c2
    #expect(totals.turns == 3)             // s1/t1, s1/t2, c1/u1 — the empty turn is not one
    #expect(totals.lastDay == UsageDay(year: 2026, month: 9, day: 6))

    #expect(report.byAgent.map(\.agent) == [.claude, .codex])
    #expect(report.byAgent[0].costUSD == 180)
    #expect(report.byAgent[1].costUSD == 2.2)
    #expect(report.byAgent[1].unpricedTokens == 1_000)
    #expect(report.byAgent[1].sessions == 2)

    #expect(report.byProject.map(\.workspace) == ["/w", "/c"])
    #expect(report.byProject[1].costUSD == 2.2)
    #expect(report.byProject[1].sessions == 2)
    #expect(report.byProject[1].turns == 1)

    #expect(report.byModel.map(\.model) == ["claude-fable-5", "gpt-5.5", "codex-auto-review"])
    #expect(report.byModel[2].costUSD == nil)
    #expect(report.byModel[2].unpricedTokens == 1_000)
    #expect(report.byModel[2].agent == .codex)
    #expect(report.byModel[0].calls == 5)
}

@Test func reportOrdersByCostThenTokensThenNameWithUnpricedLast() {
    let sorted = UsageReportBuilder.sorted([
        UsageSlice(model: "b", tokens: UsageTokens(output: 10), costUSD: nil, unpricedTokens: 10),
        UsageSlice(model: "a", tokens: UsageTokens(output: 5), costUSD: 1),
        UsageSlice(model: "c", tokens: UsageTokens(output: 9), costUSD: 1),
        UsageSlice(model: "d", tokens: UsageTokens(output: 1), costUSD: 3),
        UsageSlice(model: "e", tokens: UsageTokens(output: 99), costUSD: nil, unpricedTokens: 99),
    ])
    #expect(sorted.map(\.model) == ["d", "c", "a", "e", "b"])
}

@Test func emptyRangeProducesAnEmptyReport() {
    let report = UsageReportBuilder.build(
        buckets: [], prices: prices,
        since: UsageDay(year: 2026, month: 9, day: 5), until: UsageDay(year: 2026, month: 9, day: 5),
        generatedAt: Date(timeIntervalSince1970: 1), pricing: status, scan: scan
    )
    #expect(report.totals == UsageSlice(costUSD: 0))
    #expect(report.byAgent.isEmpty && report.byProject.isEmpty && report.byModel.isEmpty)
}

@Test func reportedCostWinsOnlyWhenEveryCallInTheBucketReportedOne() {
    let report = UsageReportBuilder.build(
        buckets: [
            // Unpriceable model, but the source billed it: the reported figure stands.
            bucket(turn: "t1", model: "<synthetic>", tokens: UsageTokens(output: 10), calls: 1, reportedCostUSD: 1.5, reportedCalls: 1),
            // Priced model with a reported cost: reported wins over the estimate ($60).
            bucket(turn: "t2", calls: 2, reportedCostUSD: 2.25, reportedCalls: 2),
            // Mixed bucket: one of two calls reported — estimated whole.
            bucket(turn: "t3", calls: 2, reportedCostUSD: 0.5, reportedCalls: 1),
        ],
        prices: prices,
        since: UsageDay(year: 2026, month: 9, day: 5), until: UsageDay(year: 2026, month: 9, day: 5),
        generatedAt: Date(timeIntervalSince1970: 1), pricing: status, scan: scan
    )
    #expect(report.totals.costUSD == 1.5 + 2.25 + 60)
    #expect(report.totals.unpricedTokens == 0)
    #expect(report.byModel.first { $0.model == "<synthetic>" }?.costUSD == 1.5)
}

@Test func bucketsInALongContextBandArePricedAtTheBandRates() {
    let report = UsageReportBuilder.build(
        buckets: [
            bucket(agent: .codex, session: "c1", turn: "u1", model: "gpt-5.5", workspace: "/c",
                   tokens: UsageTokens(input: 1_000_000, cacheRead: 1_000_000, output: 0)),                 // $2.2
            bucket(agent: .codex, session: "c1", turn: "u1", model: "gpt-5.5", workspace: "/c",
                   tokens: UsageTokens(input: 1_000_000, cacheRead: 1_000_000, output: 0), tier: 1),        // $4.4
        ],
        prices: prices,
        since: UsageDay(year: 2026, month: 9, day: 5), until: UsageDay(year: 2026, month: 9, day: 5),
        generatedAt: Date(timeIntervalSince1970: 1), pricing: status, scan: scan
    )
    #expect(abs((report.totals.costUSD ?? 0) - 6.6) < 1e-9)
    // The two bands fold into one model row and one turn.
    #expect(report.byModel.count == 1)
    #expect(report.byModel[0].turns == 1)
    #expect(report.byModel[0].calls == 2)
}
