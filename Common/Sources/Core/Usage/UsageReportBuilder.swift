import Transport
import Foundation

/// Folds the daemon's usage buckets for one day range into the report the
/// Mac shows: totals, per agent, per project (working directory), per
/// (agent, model), per day / week / month, the trend rows, and the
/// comparison period's totals. Pure; prices are applied here, at query
/// time, so a price refresh reaches history without rewriting a bucket.
public enum UsageReportBuilder {
    /// Ranges longer than this draw the trend by week instead of by day.
    public static let maximumDailyTrendDays = 90

    public static func build(
        buckets: [UsageBucket],
        prices: ModelPriceTable,
        since: UsageDay,
        until: UsageDay,
        comparison: (since: UsageDay, until: UsageDay, buckets: [UsageBucket])? = nil,
        generatedAt: Date,
        pricing: UsagePricingStatus,
        scan: UsageScanStatus,
        calendar: Calendar = .current
    ) -> UsageReport {
        let trendUnit = Self.trendUnit(since: since, until: until, calendar: calendar)
        var costs = Costing(prices: prices, calendar: calendar)
        var totals = Accumulator()
        var byAgent: [AgentProvider: Accumulator] = [:]
        var byProject: [String: Accumulator] = [:]
        var byModel: [ModelKey: Accumulator] = [:]
        var byPeriod: [UsagePeriodUnit: [UsagePeriod: Accumulator]] = [:]
        var trend: [TrendKey: Accumulator] = [:]

        for bucket in buckets where !bucket.isEmpty {
            let priced = costs.price(bucket)
            let modelKey = ModelKey(agent: bucket.agent.provider, model: bucket.model)
            totals.add(bucket, cost: priced.cost)
            byAgent[modelKey.agent, default: Accumulator()].add(bucket, cost: priced.cost)
            byProject[bucket.workspace, default: Accumulator()].add(bucket, cost: priced.cost)
            byModel[modelKey, default: Accumulator()].add(bucket, cost: priced.cost)
            for unit in [UsagePeriodUnit.day, .week, .month] {
                byPeriod[unit, default: [:]][costs.period(unit, of: bucket), default: Accumulator()].add(bucket, cost: priced.cost)
            }
            trend[TrendKey(period: costs.period(trendUnit, of: bucket), model: modelKey), default: Accumulator()].add(bucket, cost: priced.cost)
        }

        return UsageReport(
            since: since,
            until: until,
            generatedAt: generatedAt,
            totals: totals.slice(),
            byAgent: Self.sorted(byAgent.map { $0.value.slice(agent: $0.key) }),
            byProject: Self.sorted(byProject.map { $0.value.slice(workspace: $0.key) }),
            byModel: Self.sorted(byModel.map {
                $0.value.slice(agent: $0.key.agent, model: $0.key.model, provider: costs.provider(of: $0.key))
            }),
            byDay: Self.chronological(byPeriod[.day] ?? [:]),
            byWeek: Self.chronological(byPeriod[.week] ?? [:]),
            byMonth: Self.chronological(byPeriod[.month] ?? [:]),
            trendUnit: trendUnit,
            trend: trend
                .map { $0.value.slice(agent: $0.key.model.agent, model: $0.key.model.model, provider: costs.provider(of: $0.key.model), period: $0.key.period) }
                .sorted { lhs, rhs in
                    guard let l = lhs.period, let r = rhs.period, l != r else { return Self.precedes(lhs, rhs) }
                    return l < r
                },
            comparison: comparison.map { Self.comparison(buckets: $0.buckets, since: $0.since, until: $0.until, costs: &costs) },
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

    private static func comparison(buckets: [UsageBucket], since: UsageDay, until: UsageDay, costs: inout Costing) -> UsageComparison {
        var totals = Accumulator()
        var byAgent: [AgentProvider: Accumulator] = [:]
        for bucket in buckets where !bucket.isEmpty {
            let cost = costs.price(bucket).cost
            totals.add(bucket, cost: cost)
            byAgent[bucket.agent.provider, default: Accumulator()].add(bucket, cost: cost)
        }
        return UsageComparison(
            since: since,
            until: until,
            totals: totals.slice(),
            byAgent: Self.sorted(byAgent.map { $0.value.slice(agent: $0.key) })
        )
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

    /// Per-report memo of the price lookups and calendar arithmetic that
    /// repeat for every bucket: a report has a handful of distinct models
    /// and at most a year of distinct days.
    private struct Costing {
        let prices: ModelPriceTable
        let calendar: Calendar
        private var listings: [ModelKey: (provider: String, price: ModelPrice)?] = [:]
        private var periods: [PeriodKey: UsagePeriod] = [:]

        private struct PeriodKey: Hashable {
            let unit: UsagePeriodUnit
            let day: UsageDay
            let hour: Int
        }

        init(prices: ModelPriceTable, calendar: Calendar) {
            self.prices = prices
            self.calendar = calendar
        }

        mutating func listing(_ key: ModelKey) -> (provider: String, price: ModelPrice)? {
            if let cached = listings[key] { return cached }
            let found = prices.listing(for: key.model, agent: key.agent)
            listings[key] = .some(found)
            return found
        }

        mutating func provider(of key: ModelKey) -> String? {
            listing(key)?.provider
        }

        /// What the source itself billed wins over an estimate — but only
        /// when every call in the bucket reported one; a mixed bucket cannot
        /// split its tokens, so it is estimated whole. `nil` = unpriced.
        mutating func price(_ bucket: UsageBucket) -> (cost: Double?, provider: String?) {
            let listing = listing(ModelKey(agent: bucket.agent.provider, model: bucket.model))
            if bucket.reportedCalls > 0, bucket.reportedCalls == bucket.calls, let reported = bucket.reportedCostUSD {
                return (reported, listing?.provider)
            }
            return (listing.map { UsageCost.usd(tokens: bucket.tokens, price: $0.price, tier: bucket.tier) }, listing?.provider)
        }

        mutating func period(_ unit: UsagePeriodUnit, of bucket: UsageBucket) -> UsagePeriod {
            let key = PeriodKey(unit: unit, day: bucket.day, hour: unit == .hour ? bucket.hour : 0)
            if let cached = periods[key] { return cached }
            let period = UsagePeriod(unit: unit, containing: bucket.day, hour: bucket.hour, calendar: calendar)
            periods[key] = period
            return period
        }
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

extension UsageBucket {
    /// Buckets written before the parser dropped empty calls (Claude's
    /// `<synthetic>` placeholders): nothing to show, so nothing to count.
    var isEmpty: Bool { tokens.total == 0 && (reportedCostUSD ?? 0) == 0 }
}
