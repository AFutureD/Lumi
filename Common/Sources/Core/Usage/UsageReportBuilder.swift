import Transport
import Foundation

/// Folds the daemon's usage buckets for one day range into the report the
/// Mac shows: totals, per agent, per project (working directory), per
/// (agent, model), per day / week / month, and the trend rows. Pure; prices
/// are applied here, at query time, so a price refresh reaches history
/// without rewriting a bucket.
public enum UsageReportBuilder {
    /// Ranges longer than this draw the trend by week instead of by day.
    public static let maximumDailyTrendDays = 90

    public static func build(
        buckets: [UsageBucket],
        prices: ModelPriceTable,
        since: UsageDay,
        until: UsageDay,
        generatedAt: Date,
        pricing: UsagePricingStatus,
        scan: UsageScanStatus,
        calendar: Calendar = .current
    ) -> UsageReport {
        let trendUnit = Self.trendUnit(since: since, until: until, calendar: calendar)
        var totals = Accumulator()
        var byAgent: [AgentProvider: Accumulator] = [:]
        var byProject: [String: Accumulator] = [:]
        var byModel: [ModelKey: Accumulator] = [:]
        var providers: [ModelKey: String] = [:]
        var byDay: [UsagePeriod: Accumulator] = [:]
        var byWeek: [UsagePeriod: Accumulator] = [:]
        var byMonth: [UsagePeriod: Accumulator] = [:]
        var trend: [TrendKey: Accumulator] = [:]

        for bucket in buckets {
            // Buckets scanned before the parser dropped empty calls (Claude's
            // `<synthetic>` placeholders): nothing to show, so nothing to count.
            guard bucket.tokens.total > 0 || (bucket.reportedCostUSD ?? 0) > 0 else { continue }
            let provider = bucket.agent.provider
            let listing = prices.listing(for: bucket.model, agent: provider)
            // What the source itself billed wins over an estimate — but only
            // when every call in the bucket reported one; a mixed bucket
            // cannot split its tokens, so it is estimated whole.
            let cost: Double? = if bucket.reportedCalls > 0, bucket.reportedCalls == bucket.calls, let reported = bucket.reportedCostUSD {
                reported
            } else {
                listing.map { UsageCost.usd(tokens: bucket.tokens, price: $0.price, tier: bucket.tier) }
            }
            let modelKey = ModelKey(agent: provider, model: bucket.model)
            totals.add(bucket, cost: cost)
            byAgent[provider, default: Accumulator()].add(bucket, cost: cost)
            byProject[bucket.workspace, default: Accumulator()].add(bucket, cost: cost)
            byModel[modelKey, default: Accumulator()].add(bucket, cost: cost)
            if let listing { providers[modelKey] = listing.provider }
            byDay[UsagePeriod(unit: .day, start: bucket.day), default: Accumulator()].add(bucket, cost: cost)
            byWeek[UsagePeriod(unit: .week, containing: bucket.day, hour: bucket.hour, calendar: calendar), default: Accumulator()].add(bucket, cost: cost)
            byMonth[UsagePeriod(unit: .month, containing: bucket.day, hour: bucket.hour, calendar: calendar), default: Accumulator()].add(bucket, cost: cost)
            let period = UsagePeriod(unit: trendUnit, containing: bucket.day, hour: bucket.hour, calendar: calendar)
            trend[TrendKey(period: period, model: modelKey), default: Accumulator()].add(bucket, cost: cost)
        }

        return UsageReport(
            since: since,
            until: until,
            generatedAt: generatedAt,
            totals: totals.slice(),
            byAgent: Self.sorted(byAgent.map { $0.value.slice(agent: $0.key) }),
            byProject: Self.sorted(byProject.map { $0.value.slice(workspace: $0.key) }),
            byModel: Self.sorted(byModel.map {
                $0.value.slice(agent: $0.key.agent, model: $0.key.model, provider: providers[$0.key])
            }),
            byDay: Self.chronological(byDay),
            byWeek: Self.chronological(byWeek),
            byMonth: Self.chronological(byMonth),
            trendUnit: trendUnit,
            trend: trend
                .map { $0.value.slice(agent: $0.key.model.agent, model: $0.key.model.model, provider: providers[$0.key.model], period: $0.key.period) }
                .sorted { lhs, rhs in
                    guard let l = lhs.period, let r = rhs.period, l != r else { return Self.precedes(lhs, rhs) }
                    return l < r
                },
            pricing: pricing,
            scan: scan
        )
    }

    /// Hour bars for one day, day bars up to `maximumDailyTrendDays`, week
    /// bars beyond.
    public static func trendUnit(since: UsageDay, until: UsageDay, calendar: Calendar = .current) -> UsagePeriodUnit {
        if since == until { return .hour }
        let days = (since.days(until: until, calendar: calendar) ?? 0) + 1
        return days > maximumDailyTrendDays ? .week : .day
    }

    /// Cost descending, unpriced rows last, then tokens descending, then
    /// name — a stable order the tables can show without re-sorting.
    static func sorted(_ slices: [UsageSlice]) -> [UsageSlice] {
        slices.sorted(by: precedes)
    }

    private static func precedes(_ lhs: UsageSlice, _ rhs: UsageSlice) -> Bool {
        switch (lhs.costUSD, rhs.costUSD) {
        case let (l?, r?) where l != r: return l > r
        case (nil, .some): return false
        case (.some, nil): return true
        default: break
        }
        if lhs.tokens.total != rhs.tokens.total { return lhs.tokens.total > rhs.tokens.total }
        return name(of: lhs) < name(of: rhs)
    }

    private static func chronological(_ periods: [UsagePeriod: Accumulator]) -> [UsageSlice] {
        periods.keys.sorted().map { periods[$0]!.slice(period: $0) }
    }

    private static func name(of slice: UsageSlice) -> String {
        [slice.agent?.rawValue, slice.model, slice.workspace].compactMap { $0 }.joined(separator: " ")
    }

    private struct ModelKey: Hashable {
        let agent: AgentProvider
        let model: String
    }

    private struct TrendKey: Hashable {
        let period: UsagePeriod
        let model: ModelKey
    }

    private struct Accumulator {
        var tokens = UsageTokens.zero
        var pricedCost = 0.0
        var pricedTokens: Int64 = 0
        var unpricedTokens: Int64 = 0
        var calls = 0
        var sessions = Set<String>()
        var turns = Set<TurnKey>()
        var lastDay: UsageDay?

        struct TurnKey: Hashable {
            let session: String
            let turn: String
        }

        mutating func add(_ bucket: UsageBucket, cost: Double?) {
            tokens.add(bucket.tokens)
            if let cost {
                pricedCost += cost
                pricedTokens += bucket.tokens.total
            } else {
                unpricedTokens += bucket.tokens.total
            }
            calls += bucket.calls
            sessions.insert(bucket.sessionID)
            if !bucket.turnID.isEmpty {
                turns.insert(TurnKey(session: bucket.sessionID, turn: bucket.turnID))
            }
            lastDay = lastDay.map { max($0, bucket.day) } ?? bucket.day
        }

        func slice(
            agent: AgentProvider? = nil,
            model: String? = nil,
            provider: String? = nil,
            workspace: String? = nil,
            period: UsagePeriod? = nil
        ) -> UsageSlice {
            UsageSlice(
                agent: agent,
                model: model,
                provider: provider,
                workspace: workspace,
                period: period,
                tokens: tokens,
                costUSD: pricedTokens == 0 && unpricedTokens > 0 ? nil : pricedCost,
                unpricedTokens: unpricedTokens,
                calls: calls,
                sessions: sessions.count,
                turns: turns.count,
                lastDay: lastDay
            )
        }
    }
}
