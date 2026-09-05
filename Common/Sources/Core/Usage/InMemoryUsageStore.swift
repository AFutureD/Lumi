import Transport
import Foundation

/// `UsageStore` in memory, for tests and for hosts without a database.
/// Same rules as the SQLite store: a dedupe key counts once, buckets sum
/// by `(agent, session, turn, model, day)`, the cursor saves with the batch.
public actor InMemoryUsageStore: UsageStore {
    private struct Key: Hashable {
        let agent: AgentKind
        let session: String
        let turn: String
        let model: String
        let day: UsageDay
        let tier: Int
    }

    private let calendar: Calendar
    private var seen = Set<String>()
    private var buckets: [Key: UsageBucket] = [:]
    private var cursorsByIdentity: [String: UsageCursor] = [:]

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    @discardableResult
    public func apply(records: [UsageRecord], cursor: UsageCursor) async throws -> Int {
        var applied = 0
        for record in records where seen.insert(record.dedupeKey).inserted {
            applied += 1
            let day = UsageDay(record.occurredAt, calendar: calendar)
            let key = Key(agent: record.agent, session: record.sessionID, turn: record.turnID, model: record.model, day: day, tier: record.tier)
            if var bucket = buckets[key] {
                bucket.firstAt = min(bucket.firstAt, record.occurredAt)
                bucket.lastAt = max(bucket.lastAt, record.occurredAt)
                bucket.tokens.add(record.tokens)
                if record.isCall { bucket.calls += 1 }
                if let cost = record.reportedCostUSD {
                    bucket.reportedCostUSD = (bucket.reportedCostUSD ?? 0) + cost
                    bucket.reportedCalls += 1
                }
                buckets[key] = bucket
            } else {
                buckets[key] = UsageBucket(
                    agent: record.agent, sessionID: record.sessionID, turnID: record.turnID, model: record.model,
                    day: day, tier: record.tier, workspace: record.workspace, firstAt: record.occurredAt, lastAt: record.occurredAt,
                    tokens: record.tokens, calls: record.isCall ? 1 : 0,
                    reportedCostUSD: record.reportedCostUSD, reportedCalls: record.reportedCostUSD == nil ? 0 : 1
                )
            }
        }
        cursorsByIdentity[cursor.identity] = cursor
        return applied
    }

    public func cursor(identity: String) async throws -> UsageCursor? {
        cursorsByIdentity[identity]
    }

    public func cursors() async throws -> [UsageCursor] {
        cursorsByIdentity.values.sorted { $0.path < $1.path }
    }

    public func buckets(since: UsageDay, until: UsageDay) async throws -> [UsageBucket] {
        buckets.values
            .filter { $0.day >= since && $0.day <= until }
            .sorted { ($0.day, $0.agent.rawValue, $0.sessionID, $0.turnID, $0.model, $0.tier) < ($1.day, $1.agent.rawValue, $1.sessionID, $1.turnID, $1.model, $1.tier) }
    }
}
