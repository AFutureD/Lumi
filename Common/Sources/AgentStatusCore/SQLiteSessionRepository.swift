import AgentStatusTransport
import Foundation
import GRDB

public actor SQLiteSessionRepository: SessionRepository {
    private let database: DatabaseQueue
    private let encoder = TransportCoding.makeEncoder()
    private let decoder = TransportCoding.makeDecoder()

    public init(path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var configuration = Configuration()
        configuration.busyMode = .timeout(3)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        database = try DatabaseQueue(path: path, configuration: configuration)

        var migrator = DatabaseMigrator()
        migrator.registerMigration("agent-status-v1") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sessions (
                    id TEXT PRIMARY KEY NOT NULL,
                    summary BLOB NOT NULL,
                    updated_at REAL NOT NULL,
                    last_activity_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS timeline (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    occurred_at REAL NOT NULL,
                    item BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS timeline_session_time
                    ON timeline(session_id, occurred_at, id);
                CREATE TABLE IF NOT EXISTS processed_events (
                    id TEXT PRIMARY KEY NOT NULL,
                    occurred_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS rollout_cursors (
                    path TEXT PRIMARY KEY NOT NULL,
                    byte_offset INTEGER NOT NULL,
                    file_size INTEGER NOT NULL,
                    session_id TEXT,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS ignored_sessions (
                    id TEXT PRIMARY KEY NOT NULL
                );
                CREATE TABLE IF NOT EXISTS metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                """)
        }
        migrator.registerMigration("agent-status-v2-turns") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS turns (
                    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    turn_id TEXT NOT NULL,
                    started_at REAL NOT NULL,
                    summary BLOB NOT NULL,
                    PRIMARY KEY(session_id, turn_id)
                );
                CREATE INDEX IF NOT EXISTS turns_session_time
                    ON turns(session_id, started_at, turn_id);
                """)
        }
        // One-off sweep of Claude sessions recorded before the helper learned
        // to discard sessions that end before their first Turn (desktop
        // config-loading probes): completed, no turns, nothing but the two
        // session markers. `summary` is JSON text stored as a BLOB, hence CAST.
        // Foreign keys are off inside migrations, so children go explicitly.
        migrator.registerMigration("agent-status-v3-sweep-empty-claude-sessions") { db in
            try db.execute(sql: """
                CREATE TEMP TABLE sweep AS
                    SELECT id FROM sessions
                    WHERE json_extract(CAST(summary AS TEXT), '$.agent') = 'claude'
                      AND json_extract(CAST(summary AS TEXT), '$.lifecycle') = 'completed'
                      AND NOT EXISTS (SELECT 1 FROM turns t WHERE t.session_id = sessions.id)
                      AND NOT EXISTS (
                          SELECT 1 FROM timeline tl
                          WHERE tl.session_id = sessions.id AND tl.id NOT LIKE 'marker:%'
                      );
                INSERT OR IGNORE INTO ignored_sessions(id) SELECT id FROM sweep;
                DELETE FROM timeline WHERE session_id IN (SELECT id FROM sweep);
                DELETE FROM turns WHERE session_id IN (SELECT id FROM sweep);
                DELETE FROM sessions WHERE id IN (SELECT id FROM sweep);
                DROP TABLE sweep;
                """)
        }
        // Backfill `needsReview` into summaries written before the flag
        // existed so strict decoding keeps working; old sessions were
        // presumably seen, so they start reviewed, and `needsAttention` is
        // re-derived under the same rule (approval / failure only).
        migrator.registerMigration("agent-status-v4-needs-review") { db in
            try db.execute(sql: """
                UPDATE sessions SET summary =
                    CAST(json_set(
                        CAST(summary AS TEXT),
                        '$.needsReview', json('false'),
                        '$.needsAttention',
                        CASE WHEN json_extract(CAST(summary AS TEXT), '$.phase') = 'waiting_for_approval'
                               OR json_extract(CAST(summary AS TEXT), '$.lifecycle') IN ('failed', 'interrupted')
                             THEN json('true') ELSE json('false') END
                    ) AS BLOB)
                WHERE json_extract(CAST(summary AS TEXT), '$.needsReview') IS NULL;
                """)
        }
        // Backfill `hiddenInNotch` into summaries written before the flag
        // existed so strict decoding keeps working; nothing was archived from
        // the Notch yet, so every session starts visible there.
        migrator.registerMigration("agent-status-v5-hidden-in-notch") { db in
            try db.execute(sql: """
                UPDATE sessions SET summary =
                    CAST(json_set(
                        CAST(summary AS TEXT),
                        '$.hiddenInNotch', json('false')
                    ) AS BLOB)
                WHERE json_extract(CAST(summary AS TEXT), '$.hiddenInNotch') IS NULL;
                """)
        }
        try migrator.migrate(database)
    }

    private static func fetchTurns(_ db: Database, sessionID: SessionID, decoder: JSONDecoder) throws -> [TurnSummary] {
        let data = try Data.fetchAll(
            db,
            sql: "SELECT summary FROM turns WHERE session_id = ? ORDER BY started_at ASC, turn_id ASC",
            arguments: [sessionID.rawValue]
        )
        return try data.map { try decoder.decode(TurnSummary.self, from: $0) }
    }

    private static func upsertTurn(_ db: Database, _ turn: TurnSummary, encoder: JSONEncoder) throws {
        try db.execute(
            sql: """
                INSERT INTO turns(session_id, turn_id, started_at, summary)
                VALUES(?, ?, ?, ?)
                ON CONFLICT(session_id, turn_id) DO UPDATE SET
                    started_at = excluded.started_at,
                    summary = excluded.summary
                """,
            arguments: [
                turn.sessionID.rawValue,
                turn.id.rawValue,
                turn.startedAt.timeIntervalSince1970,
                try encoder.encode(turn),
            ]
        )
    }

    @discardableResult
    public func apply(_ event: AgentIngressEvent) async throws -> Bool {
        let encoder = encoder
        let decoder = decoder
        return try await database.write { db in
            // Dedupe first: a replayed event must never un-ignore a session.
            let duplicate = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM processed_events WHERE id = ?)",
                arguments: [event.eventID.rawValue]
            ) ?? false
            guard !duplicate else { return false }

            if event.disposition == .discard {
                // Delete + tombstone (timeline / turns cascade), then report
                // success so the event is published and every mirror runs the
                // same deletion. Nothing below may run: the row is gone.
                try Self.tombstone(db, event.sessionID)
                try db.execute(
                    sql: "INSERT INTO processed_events(id, occurred_at) VALUES(?, ?)",
                    arguments: [event.eventID.rawValue, event.occurredAt.timeIntervalSince1970]
                )
                return true
            }

            let ignored = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM ignored_sessions WHERE id = ?)",
                arguments: [event.sessionID.rawValue]
            ) ?? false
            if ignored {
                // A hidden session comes back only on live activity (a
                // lifecycle-bearing event), never on passive backfill.
                guard event.resurrectsHiddenSession else { return false }
                try db.execute(sql: "DELETE FROM ignored_sessions WHERE id = ?", arguments: [event.sessionID.rawValue])
            }

            let currentData = try Data.fetchOne(
                db,
                sql: "SELECT summary FROM sessions WHERE id = ?",
                arguments: [event.sessionID.rawValue]
            )
            let current = try currentData.map { try decoder.decode(SessionSummary.self, from: $0) }
            let summary = SessionReduction.summary(applying: event, to: current)
            try db.execute(
                sql: """
                    INSERT INTO sessions(id, summary, updated_at, last_activity_at)
                    VALUES(?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        summary = excluded.summary,
                        updated_at = excluded.updated_at,
                        last_activity_at = excluded.last_activity_at
                    """,
                arguments: [
                    event.sessionID.rawValue,
                    try encoder.encode(summary),
                    summary.updatedAt.timeIntervalSince1970,
                    summary.lastActivityAt.timeIntervalSince1970,
                ]
            )

            if let turnID = event.turnID ?? event.turn?.id {
                let currentTurnData = try Data.fetchOne(
                    db,
                    sql: "SELECT summary FROM turns WHERE session_id = ? AND turn_id = ?",
                    arguments: [event.sessionID.rawValue, turnID.rawValue]
                )
                let currentTurn = try currentTurnData.map { try decoder.decode(TurnSummary.self, from: $0) }
                if let turn = TurnReduction.summary(applying: event, to: currentTurn) {
                    try Self.upsertTurn(db, turn, encoder: encoder)
                }
            }

            if let item = event.timelineItem {
                try db.execute(
                    sql: """
                        INSERT INTO timeline(id, session_id, occurred_at, item)
                        VALUES(?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            session_id = excluded.session_id,
                            occurred_at = excluded.occurred_at,
                            item = excluded.item
                        WHERE excluded.occurred_at >= timeline.occurred_at
                        """,
                    arguments: [
                        item.id.rawValue,
                        event.sessionID.rawValue,
                        item.occurredAt.timeIntervalSince1970,
                        try encoder.encode(item),
                    ]
                )
            }
            try db.execute(
                sql: "INSERT INTO processed_events(id, occurred_at) VALUES(?, ?)",
                arguments: [event.eventID.rawValue, event.occurredAt.timeIntervalSince1970]
            )
            return true
        }
    }

    public func listSessions(limit: Int) async throws -> [SessionSummary] {
        let decoder = decoder
        return try await database.read { db in
            let data = try Data.fetchAll(
                db,
                sql: "SELECT summary FROM sessions ORDER BY last_activity_at DESC LIMIT ?",
                arguments: [max(0, min(limit, 10_000))]
            )
            return try data.map { try decoder.decode(SessionSummary.self, from: $0) }
        }
    }

    public func sessionDetail(
        id: SessionID,
        cursor: PaginationCursor?,
        limit: Int
    ) async throws -> SessionDetail? {
        let decoder = decoder
        return try await database.read { db in
            guard let summaryData = try Data.fetchOne(
                db,
                sql: "SELECT summary FROM sessions WHERE id = ?",
                arguments: [id.rawValue]
            ) else { return nil }
            let summary = try decoder.decode(SessionSummary.self, from: summaryData)
            let offset = max(0, Int(cursor?.value ?? "0") ?? 0)
            let pageSize = max(1, min(limit, 500))
            let data = try Data.fetchAll(
                db,
                sql: """
                    SELECT item FROM timeline
                    WHERE session_id = ?
                    ORDER BY occurred_at ASC, id ASC
                    LIMIT ? OFFSET ?
                    """,
                arguments: [id.rawValue, pageSize + 1, offset]
            )
            let items = try data.map { try decoder.decode(TimelineItem.self, from: $0) }
            return SessionDetail(
                summary: summary,
                turns: try Self.fetchTurns(db, sessionID: id, decoder: decoder),
                timeline: Array(items.prefix(pageSize)),
                nextCursor: items.count > pageSize
                    ? PaginationCursor(value: String(offset + pageSize))
                    : nil
            )
        }
    }

    /// Reads only as far back as needed to resolve each Session's current-turn
    /// user message. This avoids decoding entire retained timelines for compact
    /// surfaces such as the macOS Notch.
    public func currentTurnUserMessages(
        sessionIDs: [SessionID]
    ) async throws -> [SessionID: String] {
        let decoder = decoder
        return try await database.read { db in
            var messages: [SessionID: String] = [:]
            var visited: Set<SessionID> = []
            for sessionID in sessionIDs where visited.insert(sessionID).inserted {
                let cursor = try Data.fetchCursor(
                    db,
                    sql: """
                        SELECT item FROM timeline
                        WHERE session_id = ?
                        ORDER BY occurred_at DESC, id DESC
                        """,
                    arguments: [sessionID.rawValue]
                )
                var currentTurnID: TurnID?
                var newestUserMessage: String?

                while let data = try cursor.next() {
                    let item = try decoder.decode(TimelineItem.self, from: data)
                    if currentTurnID == nil, let turnID = item.turnID {
                        currentTurnID = turnID
                    }
                    guard case let .message(message) = item.payload,
                          message.role == .user else { continue }
                    if newestUserMessage == nil { newestUserMessage = message.text }
                    if let currentTurnID, item.turnID == currentTurnID {
                        messages[sessionID] = message.text
                        break
                    }
                }

                if messages[sessionID] == nil, let newestUserMessage {
                    messages[sessionID] = newestUserMessage
                }
            }
            return messages
        }
    }

    /// Atomically installs one authoritative session: clears its tombstone,
    /// then replaces summary, turns and timeline wholesale. `processed_events`
    /// is untouched so client-side event dedupe survives the replace.
    public func replaceSession(_ detail: SessionDetail) async throws {
        let encoder = encoder
        try await database.write { db in
            let summary = detail.summary
            // The authoritative source brought the session back; a local
            // tombstone must not swallow its future events.
            try db.execute(
                sql: "DELETE FROM ignored_sessions WHERE id = ?",
                arguments: [summary.id.rawValue]
            )
            try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [summary.id.rawValue])
            try db.execute(
                sql: """
                    INSERT INTO sessions(id, summary, updated_at, last_activity_at)
                    VALUES(?, ?, ?, ?)
                    """,
                arguments: [
                    summary.id.rawValue,
                    try encoder.encode(summary),
                    summary.updatedAt.timeIntervalSince1970,
                    summary.lastActivityAt.timeIntervalSince1970,
                ]
            )
            for turn in detail.turns {
                try Self.upsertTurn(db, turn, encoder: encoder)
            }
            for item in detail.timeline {
                try db.execute(
                    sql: """
                        INSERT INTO timeline(id, session_id, occurred_at, item)
                        VALUES(?, ?, ?, ?)
                        """,
                    arguments: [
                        item.id.rawValue,
                        summary.id.rawValue,
                        item.occurredAt.timeIntervalSince1970,
                        try encoder.encode(item),
                    ]
                )
            }
        }
    }

    @discardableResult
    public func pruneSessions(keeping ids: Set<SessionID>) async throws -> Int {
        try await database.write { db in
            try db.execute(sql: "CREATE TEMP TABLE IF NOT EXISTS keep(id TEXT PRIMARY KEY)")
            try db.execute(sql: "DELETE FROM keep")
            for id in ids {
                try db.execute(sql: "INSERT OR IGNORE INTO keep(id) VALUES(?)", arguments: [id.rawValue])
            }
            // No tombstones: the authoritative side may resurrect any of these.
            try db.execute(sql: "DELETE FROM sessions WHERE id NOT IN (SELECT id FROM keep)")
            let pruned = db.changesCount
            try db.execute(sql: "DELETE FROM keep")
            return pruned
        }
    }

    public func deleteAllSessions() async throws -> Int {
        try await database.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions") ?? 0
            try db.execute(sql: """
                INSERT OR IGNORE INTO ignored_sessions(id) SELECT id FROM sessions;
                DELETE FROM sessions;
                DELETE FROM processed_events;
                """)
            return count
        }
    }

    @discardableResult
    public func deleteSession(id: SessionID) async throws -> [SessionID] {
        try await database.write { db in
            // The lineage subtree goes with the root: subagents can spawn
            // subagents, so walk `$.lineage.parentSessionID` transitively.
            let doomed = try String.fetchAll(
                db,
                sql: """
                    WITH RECURSIVE doomed(id) AS (
                        VALUES(?)
                        UNION
                        SELECT s.id FROM sessions s
                        JOIN doomed
                          ON json_extract(CAST(s.summary AS TEXT), '$.lineage.parentSessionID') = doomed.id
                    )
                    SELECT id FROM doomed
                    """,
                arguments: [id.rawValue]
            )
            var existed: [SessionID] = []
            for member in doomed {
                let present = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ?)",
                    arguments: [member]
                ) ?? false
                if present { existed.append(SessionID(member)) }
                try Self.tombstone(db, SessionID(member))
            }
            return existed
        }
    }

    public func sessionIndex(limit: Int) async throws -> [SessionIndexEntry] {
        let decoder = decoder
        return try await database.read { db in
            // Both subqueries are answered from `timeline_session_time`
            // (session_id, occurred_at, id): MAX is one index seek, COUNT an
            // index-only range scan — no item BLOB is decoded.
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.summary AS summary,
                           (SELECT COUNT(*) FROM timeline t WHERE t.session_id = s.id) AS item_count,
                           (SELECT MAX(occurred_at) FROM timeline t WHERE t.session_id = s.id) AS last_item_at
                    FROM sessions s
                    ORDER BY s.last_activity_at DESC
                    LIMIT ?
                    """,
                arguments: [max(0, min(limit, 10_000))]
            )
            return try rows.map { row in
                let data: Data = row["summary"]
                let count: Int = row["item_count"]
                let lastItemAt: Double? = row["last_item_at"]
                return SessionIndexEntry(
                    summary: try decoder.decode(SessionSummary.self, from: data),
                    timelineItemCount: count,
                    lastItemAt: lastItemAt.map { Date(timeIntervalSince1970: $0) }
                )
            }
        }
    }

    public func updateSummary(_ summary: SessionSummary) async throws {
        let encoder = encoder
        try await database.write { db in
            try db.execute(
                sql: "UPDATE sessions SET summary = ?, updated_at = ?, last_activity_at = ? WHERE id = ?",
                arguments: [
                    try encoder.encode(summary),
                    summary.updatedAt.timeIntervalSince1970,
                    summary.lastActivityAt.timeIntervalSince1970,
                    summary.id.rawValue,
                ]
            )
        }
    }

    public func mergeSession(_ detail: SessionDetail) async throws {
        let encoder = encoder
        try await database.write { db in
            let summary = detail.summary
            try db.execute(
                sql: "DELETE FROM ignored_sessions WHERE id = ?",
                arguments: [summary.id.rawValue]
            )
            try db.execute(
                sql: """
                    INSERT INTO sessions(id, summary, updated_at, last_activity_at)
                    VALUES(?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        summary = excluded.summary,
                        updated_at = excluded.updated_at,
                        last_activity_at = excluded.last_activity_at
                    """,
                arguments: [
                    summary.id.rawValue,
                    try encoder.encode(summary),
                    summary.updatedAt.timeIntervalSince1970,
                    summary.lastActivityAt.timeIntervalSince1970,
                ]
            )
            for turn in detail.turns {
                try Self.upsertTurn(db, turn, encoder: encoder)
            }
            for item in detail.timeline {
                try db.execute(
                    sql: """
                        INSERT INTO timeline(id, session_id, occurred_at, item)
                        VALUES(?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            session_id = excluded.session_id,
                            occurred_at = excluded.occurred_at,
                            item = excluded.item
                        WHERE excluded.occurred_at >= timeline.occurred_at
                        """,
                    arguments: [
                        item.id.rawValue,
                        summary.id.rawValue,
                        item.occurredAt.timeIntervalSince1970,
                        try encoder.encode(item),
                    ]
                )
            }
        }
    }

    public func timelineSince(
        id: SessionID,
        since: Date,
        cursor: PaginationCursor?,
        limit: Int
    ) async throws -> SessionDetail? {
        let decoder = decoder
        return try await database.read { db in
            guard let summaryData = try Data.fetchOne(
                db,
                sql: "SELECT summary FROM sessions WHERE id = ?",
                arguments: [id.rawValue]
            ) else { return nil }
            let summary = try decoder.decode(SessionSummary.self, from: summaryData)
            let offset = max(0, Int(cursor?.value ?? "0") ?? 0)
            let pageSize = max(1, min(limit, 500))
            let data = try Data.fetchAll(
                db,
                sql: """
                    SELECT item FROM timeline
                    WHERE session_id = ? AND occurred_at >= ?
                    ORDER BY occurred_at ASC, id ASC
                    LIMIT ? OFFSET ?
                    """,
                arguments: [id.rawValue, since.timeIntervalSince1970, pageSize + 1, offset]
            )
            let items = try data.map { try decoder.decode(TimelineItem.self, from: $0) }
            return SessionDetail(
                summary: summary,
                turns: try Self.fetchTurns(db, sessionID: id, decoder: decoder),
                timeline: Array(items.prefix(pageSize)),
                nextCursor: items.count > pageSize
                    ? PaginationCursor(value: String(offset + pageSize))
                    : nil
            )
        }
    }

    /// Hides a session for good: tombstone the id and drop the row (timeline
    /// and turns cascade). Shared by manual deletion and helper discards.
    private static func tombstone(_ db: Database, _ id: SessionID) throws {
        try db.execute(
            sql: "INSERT OR IGNORE INTO ignored_sessions(id) VALUES(?)",
            arguments: [id.rawValue]
        )
        try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [id.rawValue])
    }

    public func rolloutCursor(path: String) async throws -> RolloutCursor? {
        try await database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT byte_offset, file_size, session_id, updated_at
                    FROM rollout_cursors WHERE path = ?
                    """,
                arguments: [path]
            ) else { return nil }
            let byteOffset: Int64 = row["byte_offset"]
            let fileSize: Int64 = row["file_size"]
            let rawSessionID: String? = row["session_id"]
            let updatedAt: Double = row["updated_at"]
            return RolloutCursor(
                path: path,
                byteOffset: UInt64(max(0, byteOffset)),
                fileSize: UInt64(max(0, fileSize)),
                sessionID: rawSessionID.map(SessionID.init),
                updatedAt: Date(timeIntervalSince1970: updatedAt)
            )
        }
    }

    public func rolloutCursor(sessionID: SessionID) async throws -> RolloutCursor? {
        try await database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT path, byte_offset, file_size, updated_at
                    FROM rollout_cursors WHERE session_id = ?
                    ORDER BY updated_at DESC LIMIT 1
                    """,
                arguments: [sessionID.rawValue]
            ) else { return nil }
            let byteOffset: Int64 = row["byte_offset"]
            let fileSize: Int64 = row["file_size"]
            let updatedAt: Double = row["updated_at"]
            return RolloutCursor(
                path: row["path"],
                byteOffset: UInt64(max(0, byteOffset)),
                fileSize: UInt64(max(0, fileSize)),
                sessionID: sessionID,
                updatedAt: Date(timeIntervalSince1970: updatedAt)
            )
        }
    }

    public func resetSession(id: SessionID) async throws -> Bool {
        try await database.write { db in
            let existed = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ?)",
                arguments: [id.rawValue]
            ) ?? false
            // turns / timeline cascade from the session row.
            try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [id.rawValue])
            try db.execute(sql: "DELETE FROM rollout_cursors WHERE session_id = ?", arguments: [id.rawValue])
            return existed
        }
    }

    public func saveRolloutCursor(_ cursor: RolloutCursor) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO rollout_cursors(path, byte_offset, file_size, session_id, updated_at)
                    VALUES(?, ?, ?, ?, ?)
                    ON CONFLICT(path) DO UPDATE SET
                        byte_offset = excluded.byte_offset,
                        file_size = excluded.file_size,
                        session_id = excluded.session_id,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    cursor.path,
                    Int64(cursor.byteOffset),
                    Int64(cursor.fileSize),
                    cursor.sessionID?.rawValue,
                    cursor.updatedAt.timeIntervalSince1970,
                ]
            )
        }
    }

    public func markSessionIgnored(_ sessionID: SessionID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO ignored_sessions(id) VALUES(?)",
                arguments: [sessionID.rawValue]
            )
        }
    }

    public func isSessionIgnored(_ sessionID: SessionID) async throws -> Bool {
        try await database.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM ignored_sessions WHERE id = ?)",
                arguments: [sessionID.rawValue]
            ) ?? false
        }
    }

    public func markSessionReviewed(_ sessionID: SessionID) async throws {
        let encoder = encoder
        let decoder = decoder
        try await database.write { db in
            guard let data = try Data.fetchOne(
                db,
                sql: "SELECT summary FROM sessions WHERE id = ?",
                arguments: [sessionID.rawValue]
            ) else { return }
            let summary = try decoder.decode(SessionSummary.self, from: data).reviewed
            try db.execute(
                sql: "UPDATE sessions SET summary = ? WHERE id = ?",
                arguments: [try encoder.encode(summary), sessionID.rawValue]
            )
        }
    }

    public func markSessionHiddenInNotch(_ sessionID: SessionID) async throws {
        let encoder = encoder
        let decoder = decoder
        try await database.write { db in
            guard let data = try Data.fetchOne(
                db,
                sql: "SELECT summary FROM sessions WHERE id = ?",
                arguments: [sessionID.rawValue]
            ) else { return }
            let summary = try decoder.decode(SessionSummary.self, from: data).withHiddenInNotch(true)
            try db.execute(
                sql: "UPDATE sessions SET summary = ? WHERE id = ?",
                arguments: [try encoder.encode(summary), sessionID.rawValue]
            )
        }
    }

    public func isRolloutBaselineInitialized() async throws -> Bool {
        try await database.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM metadata WHERE key = 'rollout_baseline_initialized'"
            ) == "1"
        }
    }

    public func markRolloutBaselineInitialized() async throws {
        try await database.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO metadata(key, value) VALUES('rollout_baseline_initialized', '1')"
            )
        }
    }
}
