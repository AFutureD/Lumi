import Transport
import Foundation

/// Folds the daemon's usage buckets for one day range into the report the
/// Mac shows: totals, per agent, per project (working directory), per
/// (agent, model). Pure; prices are applied here, at query time, so a price
/// refresh reaches history without rewriting a bucket.
public enum UsageReportBuilder {
    public static func build(
        buckets: [UsageBucket],
        prices: ModelPriceTable,
        since: UsageDay,
        until: UsageDay,
        generatedAt: Date,
        pricing: UsagePricingStatus,
        scan: UsageScanStatus
    ) -> UsageReport {
        var totals = Accumulator()
        var byAgent: [AgentProvider: Accumulator] = [:]
        var byProject: [String: Accumulator] = [:]
        var byModel: [ModelKey: Accumulator] = [:]

        for bucket in buckets {
            let provider = bucket.agent.provider
            // What the source itself billed wins over an estimate — but only
            // when every call in the bucket reported one; a mixed bucket
            // cannot split its tokens, so it is estimated whole.
            let cost: Double? = if bucket.reportedCalls > 0, bucket.reportedCalls == bucket.calls, let reported = bucket.reportedCostUSD {
                reported
            } else {
                prices.price(for: bucket.model, agent: provider).map {
                    UsageCost.usd(tokens: bucket.tokens, price: $0, tier: bucket.tier)
                }
            }
            totals.add(bucket, cost: cost)
            byAgent[provider, default: Accumulator()].add(bucket, cost: cost)
            byProject[bucket.workspace, default: Accumulator()].add(bucket, cost: cost)
            byModel[ModelKey(agent: provider, model: bucket.model), default: Accumulator()].add(bucket, cost: cost)
        }

        return UsageReport(
            since: since,
            until: until,
            generatedAt: generatedAt,
            totals: totals.slice(),
            byAgent: Self.sorted(byAgent.map { $0.value.slice(agent: $0.key) }),
            byProject: Self.sorted(byProject.map { $0.value.slice(workspace: $0.key) }),
            byModel: Self.sorted(byModel.map { $0.value.slice(agent: $0.key.agent, model: $0.key.model) }),
            pricing: pricing,
            scan: scan
        )
    }

    /// Cost descending, unpriced rows last, then tokens descending, then
    /// name — a stable order the tables can show without re-sorting.
    static func sorted(_ slices: [UsageSlice]) -> [UsageSlice] {
        slices.sorted { lhs, rhs in
            switch (lhs.costUSD, rhs.costUSD) {
            case let (l?, r?) where l != r: return l > r
            case (nil, .some): return false
            case (.some, nil): return true
            default: break
            }
            if lhs.tokens.total != rhs.tokens.total { return lhs.tokens.total > rhs.tokens.total }
            return Self.name(of: lhs) < Self.name(of: rhs)
        }
    }

    private static func name(of slice: UsageSlice) -> String {
        [slice.agent?.rawValue, slice.model, slice.workspace].compactMap { $0 }.joined(separator: " ")
    }

    private struct ModelKey: Hashable {
        let agent: AgentProvider
        let model: String
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

        func slice(agent: AgentProvider? = nil, model: String? = nil, workspace: String? = nil) -> UsageSlice {
            UsageSlice(
                agent: agent,
                model: model,
                workspace: workspace,
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
