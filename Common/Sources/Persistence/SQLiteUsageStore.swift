import Core
import Transport
import Foundation
import GRDB

/// GRDB implementation of `UsageStore` over the daemon's session database
/// (`makeUsageStore()` on `SQLiteSessionRepository`). Every write is one
/// transaction: seen-key inserts, bucket upserts, cursor save.
public actor SQLiteUsageStore: UsageStore {
    private let database: DatabaseQueue
    private let calendar: Calendar
    private let encoder = TransportCoding.makeEncoder()
    private let decoder = TransportCoding.makeDecoder()

    public init(database: DatabaseQueue, calendar: Calendar = .current) {
        self.database = database
        self.calendar = calendar
    }

    @discardableResult
    public func apply(records: [UsageRecord], cursor: UsageCursor) async throws -> Int {
        let calendar = calendar
        let state = try encoder.encode(cursor.state)
        return try await database.write { db in
            var applied = 0
            // Prepared once per batch: a first scan applies tens of thousands of records.
            let markSeen = try db.cachedStatement(sql: "INSERT OR IGNORE INTO usage_seen(key) VALUES(?)")
            let upsert = try db.cachedStatement(sql: """
                        INSERT INTO usage_buckets(
                            agent, session_id, turn_id, model, day, hour, tier, workspace,
                            first_at, last_at,
                            input_tokens, cache_read_tokens, cache_write_5m_tokens, cache_write_1h_tokens,
                            output_tokens, reasoning_tokens, calls, reported_cost_usd, reported_calls
                        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(agent, session_id, turn_id, model, day, hour, tier) DO UPDATE SET
                            first_at = MIN(first_at, excluded.first_at),
                            last_at = MAX(last_at, excluded.last_at),
                            input_tokens = input_tokens + excluded.input_tokens,
                            cache_read_tokens = cache_read_tokens + excluded.cache_read_tokens,
                            cache_write_5m_tokens = cache_write_5m_tokens + excluded.cache_write_5m_tokens,
                            cache_write_1h_tokens = cache_write_1h_tokens + excluded.cache_write_1h_tokens,
                            output_tokens = output_tokens + excluded.output_tokens,
                            reasoning_tokens = reasoning_tokens + excluded.reasoning_tokens,
                            calls = calls + excluded.calls,
                            reported_cost_usd = CASE
                                WHEN excluded.reported_cost_usd IS NULL THEN reported_cost_usd
                                ELSE COALESCE(reported_cost_usd, 0) + excluded.reported_cost_usd END,
                            reported_calls = reported_calls + excluded.reported_calls
                        """)
            for record in records {
                try markSeen.execute(arguments: [record.dedupeKey])
                guard db.changesCount == 1 else { continue }
                applied += 1
                let day = UsageDay(record.occurredAt, calendar: calendar)
                let hour = calendar.component(.hour, from: record.occurredAt)
                let at = record.occurredAt.timeIntervalSince1970
                try upsert.execute(arguments: [
                    record.agent.rawValue, record.sessionID, record.turnID, record.model, day.rawValue, hour, record.tier, record.workspace,
                    at, at,
                    record.tokens.input, record.tokens.cacheRead, record.tokens.cacheWrite5m, record.tokens.cacheWrite1h,
                    record.tokens.output, record.tokens.reasoning,
                    record.isCall ? 1 : 0, record.reportedCostUSD, record.reportedCostUSD == nil ? 0 : 1,
                ])
            }
            try db.execute(
                sql: """
                    INSERT INTO usage_cursors(identity, path, source, byte_offset, file_size, modified_at, prefix_length, prefix_hash, state)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(identity) DO UPDATE SET
                        path = excluded.path,
                        source = excluded.source,
                        byte_offset = excluded.byte_offset,
                        file_size = excluded.file_size,
                        modified_at = excluded.modified_at,
                        prefix_length = excluded.prefix_length,
                        prefix_hash = excluded.prefix_hash,
                        state = excluded.state
                    """,
                arguments: [
                    cursor.identity, cursor.path, cursor.source.rawValue, Int64(cursor.byteOffset), Int64(cursor.fileSize),
                    cursor.modifiedAt.timeIntervalSince1970, cursor.prefixLength, cursor.prefixHash, state,
                ]
            )
            return applied
        }
    }

    public func cursor(identity: String) async throws -> UsageCursor? {
        let decoder = decoder
        return try await database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM usage_cursors WHERE identity = ?", arguments: [identity])
                .map { try Self.cursor(from: $0, decoder: decoder) }
        }
    }

    public func cursors() async throws -> [UsageCursor] {
        let decoder = decoder
        return try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM usage_cursors ORDER BY path").map {
                try Self.cursor(from: $0, decoder: decoder)
            }
        }
    }

    public func buckets(since: UsageDay, until: UsageDay) async throws -> [UsageBucket] {
        try await database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM usage_buckets WHERE day >= ? AND day <= ?",
                arguments: [since.rawValue, until.rawValue]
            ).map { row in
                let rawAgent: String = row["agent"]
                let rawDay: String = row["day"]
                guard let agent = AgentKind(rawValue: rawAgent), let day = UsageDay(rawValue: rawDay) else {
                    throw DatabaseError(message: "usage bucket row is unreadable: agent=\(rawAgent) day=\(rawDay)")
                }
                let firstAt: Double = row["first_at"]
                let lastAt: Double = row["last_at"]
                return UsageBucket(
                    agent: agent,
                    sessionID: row["session_id"],
                    turnID: row["turn_id"],
                    model: row["model"],
                    day: day,
                    hour: row["hour"],
                    tier: row["tier"],
                    workspace: row["workspace"],
                    firstAt: Date(timeIntervalSince1970: firstAt),
                    lastAt: Date(timeIntervalSince1970: lastAt),
                    tokens: UsageTokens(
                        input: row["input_tokens"],
                        cacheRead: row["cache_read_tokens"],
                        cacheWrite5m: row["cache_write_5m_tokens"],
                        cacheWrite1h: row["cache_write_1h_tokens"],
                        output: row["output_tokens"],
                        reasoning: row["reasoning_tokens"]
                    ),
                    calls: row["calls"],
                    reportedCostUSD: row["reported_cost_usd"],
                    reportedCalls: row["reported_calls"]
                )
            }
        }
    }

    private static func cursor(from row: Row, decoder: JSONDecoder) throws -> UsageCursor {
        let rawSource: String = row["source"]
        guard let source = AgentProvider(rawValue: rawSource) else {
            throw DatabaseError(message: "usage cursor row has an unknown source: \(rawSource)")
        }
        let byteOffset: Int64 = row["byte_offset"]
        let fileSize: Int64 = row["file_size"]
        let modifiedAt: Double = row["modified_at"]
        let state: Data = row["state"]
        return UsageCursor(
            identity: row["identity"],
            path: row["path"],
            source: source,
            byteOffset: UInt64(byteOffset),
            fileSize: UInt64(fileSize),
            modifiedAt: Date(timeIntervalSince1970: modifiedAt),
            prefixLength: row["prefix_length"],
            prefixHash: row["prefix_hash"],
            state: try decoder.decode(UsageScanState.self, from: state)
        )
    }
}
