import Core
import Transport
import Foundation

/// `-LumiPreviewData` for the Usage tab: a week of cost / tokens per Mac
/// (the design's `$20.06 · 41.3M · 34 / 512 / 1,208` once both Macs are
/// merged) and the Plan card states of handoff page 8b. Only `This week`
/// is carried — the preview never asks a Mac, so the other ranges show the
/// loading row.
extension PreviewFixture {
    static func usageSnapshot(for hostID: HostID, now: Date) -> UsageSnapshot {
        let share = hostID == HostID("preview-macbook-pro") ? 0.7 : 0.3
        return UsageSnapshot(
            report: usageReport(share: share, now: now),
            preset: .thisWeek,
            fetchedAt: now.addingTimeInterval(-120),
            isLoading: false,
            error: nil
        )
    }

    static func planUsageSnapshot(for hostID: HostID, now: Date) -> PlanUsageSnapshot {
        let fetchedAt = now.addingTimeInterval(-2 * 60)
        if hostID == HostID("preview-macbook-pro") {
            let state = PlanUsageState(
                accounts: [
                    PlanUsageAccount(
                        id: .claude, provider: .claude, email: "huanan@example.com", plan: "Max 20x", enabled: true, status: .ok,
                        limits: [
                            PlanUsageLimit(window: .session, usedPercent: 42, resetsAt: now.addingTimeInterval(2 * 3_600 + 10 * 60)),
                            PlanUsageLimit(window: .weekly, usedPercent: 18, resetsAt: now.addingTimeInterval(4 * 86_400 + 6 * 3_600)),
                            PlanUsageLimit(window: .weekly, model: "Fable", usedPercent: 7, resetsAt: now.addingTimeInterval(4 * 86_400 + 6 * 3_600)),
                        ],
                        fetchedAt: fetchedAt
                    ),
                    PlanUsageAccount(
                        id: .codex, provider: .codex, plan: "Pro", enabled: true, status: .ok,
                        limits: [PlanUsageLimit(window: .weekly, usedPercent: 12, resetsAt: now.addingTimeInterval(5 * 86_400 + 3 * 3_600))],
                        fetchedAt: fetchedAt
                    ),
                ],
                generatedAt: fetchedAt
            )
            return PlanUsageSnapshot(
                state: state,
                settings: DaemonSettings(planUsage: PlanUsageSettings(enabledAccounts: [.claude, .codex], percentStyle: .used)),
                fetchedAt: fetchedAt, isLoading: false, error: nil
            )
        }
        let rateLimitedAt = now.addingTimeInterval(-6 * 60)
        let state = PlanUsageState(
            accounts: [
                PlanUsageAccount(
                    id: .claude, provider: .claude, plan: "Pro", enabled: true, status: .rateLimited,
                    statusDetail: "429 from the usage endpoint", retryAt: now.addingTimeInterval(4 * 60),
                    limits: [
                        PlanUsageLimit(window: .session, usedPercent: 91, resetsAt: now.addingTimeInterval(38 * 60)),
                        PlanUsageLimit(window: .weekly, usedPercent: 63, resetsAt: now.addingTimeInterval(3 * 86_400 + 2 * 3_600)),
                    ],
                    fetchedAt: rateLimitedAt
                ),
                PlanUsageAccount(id: .codex, provider: .codex, enabled: true, status: .credentialsMissing, statusDetail: "no ~/.codex/auth.json"),
            ],
            generatedAt: rateLimitedAt
        )
        return PlanUsageSnapshot(
            state: state,
            settings: DaemonSettings(planUsage: PlanUsageSettings(enabledAccounts: [.claude, .codex], percentStyle: .remaining)),
            fetchedAt: rateLimitedAt, isLoading: false, error: nil
        )
    }

    // MARK: - Week report

    private struct Model {
        let agent: AgentProvider
        let name: String
        let cost: Double?
        let tokens: Int64
        let sessions: Int
        let turns: Int
        let calls: Int
    }

    /// The whole week across both Macs; each Mac carries `share` of it.
    private static let models: [Model] = [
        Model(agent: .claude, name: "claude-sonnet-4-6", cost: 9.20, tokens: 21_000_000, sessions: 12, turns: 190, calls: 460),
        Model(agent: .claude, name: "claude-opus-4-2", cost: 4.90, tokens: 7_400_000, sessions: 6, turns: 90, calls: 210),
        Model(agent: .claude, name: "claude-haiku-4-5", cost: 1.50, tokens: 5_600_000, sessions: 4, turns: 60, calls: 140),
        Model(agent: .codex, name: "gpt-5.6", cost: 4.46, tokens: 6_100_000, sessions: 9, turns: 132, calls: 318),
        Model(agent: .codex, name: "codex-spark", cost: nil, tokens: 1_200_000, sessions: 3, turns: 40, calls: 80),
    ]

    /// Monday → Sunday spend shape (the design's bars); renormalised over the days the week has had.
    private static let dayWeights: [Double] = [0.14, 0.20, 0.08, 0.26, 0.17, 0.04, 0.11]

    private static func tokens(_ total: Int64) -> UsageTokens {
        UsageTokens(
            input: Int64(Double(total) * 0.097),
            cacheRead: Int64(Double(total) * 0.78),
            cacheWrite5m: Int64(Double(total) * 0.053),
            output: Int64(Double(total) * 0.07),
            reasoning: Int64(Double(total) * 0.02)
        )
    }

    private static func scaled(_ value: Int64, _ factor: Double) -> Int64 { Int64((Double(value) * factor).rounded()) }
    private static func scaled(_ value: Int, _ factor: Double) -> Int { Int((Double(value) * factor).rounded()) }

    private static func slice(_ model: Model, factor: Double, period: UsagePeriod? = nil, lastDay: UsageDay?) -> UsageSlice {
        let total = scaled(model.tokens, factor)
        return UsageSlice(
            agent: model.agent,
            model: model.name,
            provider: model.cost == nil ? nil : (model.agent == .claude ? "anthropic" : "openai"),
            period: period,
            tokens: tokens(total),
            costUSD: model.cost.map { $0 * factor },
            unpricedTokens: model.cost == nil ? total : 0,
            calls: scaled(model.calls, factor),
            sessions: scaled(model.sessions, factor),
            turns: scaled(model.turns, factor),
            lastDay: lastDay
        )
    }

    private static func usageReport(share: Double, now: Date) -> UsageReport {
        let calendar = Calendar.current
        let today = UsageDay(now, calendar: calendar)
        let since = today.startOfWeek(in: calendar)
        var days: [UsageDay] = []
        var cursor = since
        while cursor <= today, days.count < 7 {
            days.append(cursor)
            guard let next = cursor.adding(days: 1, calendar: calendar) else { break }
            cursor = next
        }
        let weights = Array(dayWeights.prefix(days.count))
        let weightSum = weights.reduce(0, +)

        let byModel = models.map { slice($0, factor: share, lastDay: today) }
        let byAgent = [AgentProvider.claude, .codex].map { agent in
            let rows = byModel.filter { $0.agent == agent }
            var sum = UsageSlice(agent: agent, costUSD: 0)
            for row in rows { sum = UsageAggregate.sum(sum, row) }
            sum.model = nil
            sum.provider = nil
            return sum
        }
        var totals = UsageSlice(costUSD: 0)
        for row in byModel { totals = UsageAggregate.sum(totals, row) }
        totals.model = nil
        totals.provider = nil
        totals.agent = nil

        var trend: [UsageSlice] = []
        var byDay: [UsageSlice] = []
        for (offset, day) in days.enumerated() {
            let factor = share * weights[offset] / weightSum
            let period = UsagePeriod(unit: .day, start: day)
            var dayTotal = UsageSlice(period: period, costUSD: 0)
            for model in models {
                let row = slice(model, factor: factor, period: period, lastDay: day)
                trend.append(row)
                dayTotal = UsageAggregate.sum(dayTotal, row)
            }
            dayTotal.agent = nil
            dayTotal.model = nil
            dayTotal.provider = nil
            byDay.append(dayTotal)
        }

        let previousSince = since.adding(days: -7, calendar: calendar) ?? since
        let previousUntil = today.adding(days: -7, calendar: calendar) ?? today
        let previousFactor = share * (17.0 / 20.06)
        var previousTotals = UsageSlice(costUSD: 0)
        var previousByAgent: [UsageSlice] = []
        for agent in [AgentProvider.claude, .codex] {
            var sum = UsageSlice(agent: agent, costUSD: 0)
            for model in models where model.agent == agent {
                sum = UsageAggregate.sum(sum, slice(model, factor: previousFactor, lastDay: previousUntil))
            }
            sum.model = nil
            sum.provider = nil
            previousByAgent.append(sum)
            previousTotals = UsageAggregate.sum(previousTotals, sum)
        }
        previousTotals.agent = nil

        return UsageReport(
            since: since,
            until: today,
            generatedAt: now.addingTimeInterval(-120),
            totals: totals,
            byAgent: byAgent,
            byProject: [
                UsageSlice(workspace: "/Users/huanan/dev/lumi", tokens: tokens(scaled(30_000_000, share)), costUSD: 14.2 * share, calls: scaled(900, share), sessions: scaled(24, share), turns: scaled(380, share), lastDay: today),
                UsageSlice(workspace: "/Users/huanan/dev/lumi/Relay", tokens: tokens(scaled(11_300_000, share)), costUSD: 5.86 * share, unpricedTokens: scaled(1_200_000, share), calls: scaled(308, share), sessions: scaled(10, share), turns: scaled(132, share), lastDay: today),
            ],
            byModel: byModel,
            byDay: byDay,
            byWeek: [UsageSlice(period: UsagePeriod(unit: .week, start: since), tokens: totals.tokens, costUSD: totals.costUSD, unpricedTokens: totals.unpricedTokens, calls: totals.calls, sessions: totals.sessions, turns: totals.turns, lastDay: today)],
            byMonth: [UsageSlice(period: UsagePeriod(unit: .month, start: since.startOfMonth), tokens: totals.tokens, costUSD: totals.costUSD, unpricedTokens: totals.unpricedTokens, calls: totals.calls, sessions: totals.sessions, turns: totals.turns, lastDay: today)],
            trendUnit: .day,
            trend: trend,
            comparison: UsageComparison(since: previousSince, until: previousUntil, totals: previousTotals, byAgent: previousByAgent),
            pricing: UsagePricingStatus(source: .fresh, fetchedAt: now.addingTimeInterval(-3_600), modelCount: 412),
            scan: UsageScanStatus(scannedFiles: 1_240, pendingFiles: 0, lastScanAt: now.addingTimeInterval(-120), isScanning: false)
        )
    }
}
