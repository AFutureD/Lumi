import Core
import Transport
import Foundation
import GRDB

public actor SQLiteSessionRepository: SessionRepository {
    private let database: DatabaseQueue
    private let encoder = TransportCoding.makeEncoder()
    private let decoder = TransportCoding.makeDecoder()
    /// Only the daemon installs one; the Mac and iPhone mirrors open their
    /// databases without it and keep the streamed verdict.
    private let sessionFilter: (any SessionFilterEvaluating)?
    /// Memoized `TurnProjection` results, dropped whenever a session's
    /// timeline rows change (summary-only writes leave it alone). The actor
    /// serializes access; an entry is a few KB per session.
    private var turnsCache: [SessionID: [TurnSummary]] = [:]

    public init(path: String, sessionFilter: (any SessionFilterEvaluating)? = nil) throws {
        self.sessionFilter = sessionFilter
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
        migrator.registerMigration("lumi-v1") { db in
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
        migrator.registerMigration("lumi-v2-turns") { db in
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
        migrator.registerMigration("lumi-v3-sweep-empty-claude-sessions") { db in
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
        migrator.registerMigration("lumi-v4-needs-review") { db in
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
        migrator.registerMigration("lumi-v5-hidden-in-notch") { db in
            try db.execute(sql: """
                UPDATE sessions SET summary =
                    CAST(json_set(
                        CAST(summary AS TEXT),
                        '$.hiddenInNotch', json('false')
                    ) AS BLOB)
                WHERE json_extract(CAST(summary AS TEXT), '$.hiddenInNotch') IS NULL;
                """)
        }
        // The `subagent_running` turn phase was retired in favour of
        // `executing`; rewrite stored summaries so strict decoding keeps
        // working. Turn rows carry the phase too.
        migrator.registerMigration("lumi-v6-retire-subagent-running") { db in
            try db.execute(sql: """
                UPDATE sessions SET summary =
                    CAST(json_set(
                        CAST(summary AS TEXT),
                        '$.phase', 'executing'
                    ) AS BLOB)
                WHERE json_extract(CAST(summary AS TEXT), '$.phase') = 'subagent_running';
                UPDATE turns SET summary =
                    CAST(json_set(
                        CAST(summary AS TEXT),
                        '$.phase', 'executing'
                    ) AS BLOB)
                WHERE json_extract(CAST(summary AS TEXT), '$.phase') = 'subagent_running';
                """)
        }
        // Backfill `hiddenByFilter` into summaries written before the flag
        // existed so strict decoding keeps working (no rules existed, so
        // every old session is visible), and create the rule storage. The
        // rules are settings, not session history: `deleteAllSessions`
        // (clear history) and per-session deletes must never touch them.
        //
        // The orphan sweep must come first: GRDB ends every migration with a
        // full-database foreign-key check, so child rows whose session is
        // already gone — however they got stranded — fail THIS migration on
        // a database the previous versions ran happily, and the daemon
        // crash-loops before it can serve.
        migrator.registerMigration("lumi-v7-session-filters") { db in
            try db.execute(sql: """
                DELETE FROM turns WHERE session_id NOT IN (SELECT id FROM sessions);
                DELETE FROM timeline WHERE session_id NOT IN (SELECT id FROM sessions);
                UPDATE sessions SET summary =
                    CAST(json_set(
                        CAST(summary AS TEXT),
                        '$.hiddenByFilter', json('false')
                    ) AS BLOB)
                WHERE json_extract(CAST(summary AS TEXT), '$.hiddenByFilter') IS NULL;
                CREATE TABLE IF NOT EXISTS session_filters (
                    id TEXT PRIMARY KEY NOT NULL,
                    position INTEGER NOT NULL,
                    rule BLOB NOT NULL
                );
                """)
        }
        // Two changes shipped together. The `turns` table was a second copy
        // of what the timeline already records — `TurnProjection` now derives
        // turn aggregates on read, so the table goes (v2 still creates it on
        // fresh databases; v3/v7 still reference it and run first, in order).
        // `filterEvaluated` backfills to true: every pre-existing session is
        // frozen as already judged — moving the filter trigger to "first user
        // message" must not retroactively evaluate old sessions.
        migrator.registerMigration("lumi-v8-drop-turns-filter-latch") { db in
            try db.execute(sql: """
                DROP TABLE IF EXISTS turns;
                UPDATE sessions SET summary =
                    CAST(json_set(
                        CAST(summary AS TEXT),
                        '$.filterEvaluated', json('true')
                    ) AS BLOB)
                WHERE json_extract(CAST(summary AS TEXT), '$.filterEvaluated') IS NULL;
                """)
        }
        // Usage: token buckets scanned from the agents' own transcripts, with
        // the dedupe keys and per-file cursors that feed them. No foreign key
        // to `sessions` by design — usage is not Session history: deleting a
        // Session or clearing history leaves these tables alone, and a
        // bucket may name a session Lumi never ingested (filtered, pre-install).
        // Cursors are keyed by file identity (device + inode), not path: a
        // rollout Codex archives keeps its cursor.
        migrator.registerMigration("lumi-v9-usage") { db in
            try db.execute(sql: Self.usageSchema)
        }
        // The parsing rules changed after v9 first ran (Claude's larger later
        // copies top the output up; Codex fork replays are skipped): buckets
        // counted under the old rules are wrong and the dedupe keys would
        // keep a rescan from correcting them. Start the usage tables over;
        // the scanner rebuilds them from the transcripts on the next launch.
        migrator.registerMigration("lumi-v10-usage-rules") { db in
            try db.execute(sql: """
                DROP TABLE IF EXISTS usage_buckets;
                DROP TABLE IF EXISTS usage_seen;
                DROP TABLE IF EXISTS usage_cursors;
                """)
            try db.execute(sql: Self.usageSchema)
        }
        try migrator.migrate(database)
    }

    /// The usage store over this repository's database. Usage shares the
    /// file (one migrator, one write queue) but nothing else: it has its own
    /// tables, its own contract, and no dependency on Session rows.
    public nonisolated func makeUsageStore(calendar: Calendar = .current) -> SQLiteUsageStore {
        SQLiteUsageStore(database: database, calendar: calendar)
    }

    /// The usage tables (see `docs/design/usage.md`). One definition,
    /// created by v9 and re-created by v10.
    static let usageSchema = """
        CREATE TABLE IF NOT EXISTS usage_buckets (
            agent TEXT NOT NULL,
            session_id TEXT NOT NULL,
            turn_id TEXT NOT NULL,
            model TEXT NOT NULL,
            day TEXT NOT NULL,
            tier INTEGER NOT NULL,
            workspace TEXT NOT NULL,
            first_at REAL NOT NULL,
            last_at REAL NOT NULL,
            input_tokens INTEGER NOT NULL,
            cache_read_tokens INTEGER NOT NULL,
            cache_write_5m_tokens INTEGER NOT NULL,
            cache_write_1h_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            reasoning_tokens INTEGER NOT NULL,
            calls INTEGER NOT NULL,
            reported_cost_usd REAL,
            reported_calls INTEGER NOT NULL,
            PRIMARY KEY(agent, session_id, turn_id, model, day, tier)
        );
        CREATE INDEX IF NOT EXISTS usage_buckets_day
            ON usage_buckets(day, agent, model);
        CREATE INDEX IF NOT EXISTS usage_buckets_workspace
            ON usage_buckets(workspace);
        CREATE TABLE IF NOT EXISTS usage_seen (
            key TEXT PRIMARY KEY NOT NULL
        );
        CREATE TABLE IF NOT EXISTS usage_cursors (
            identity TEXT PRIMARY KEY NOT NULL,
            path TEXT NOT NULL,
            source TEXT NOT NULL,
            byte_offset INTEGER NOT NULL,
            file_size INTEGER NOT NULL,
            modified_at REAL NOT NULL,
            prefix_length INTEGER NOT NULL,
            prefix_hash TEXT NOT NULL,
            state BLOB NOT NULL
        );
        """

    /// Turn aggregates derived on read (the `turns` table is gone): decode
    /// only the turn-relevant rows — SQL filters out the reasoning/context
    /// bulk — and fold them with `TurnProjection`.
    private static func projectedTurns(_ db: Database, sessionID: SessionID, decoder: JSONDecoder) throws -> [TurnSummary] {
        let data = try Data.fetchAll(
            db,
            sql: """
                SELECT item FROM timeline
                WHERE session_id = ?
                  AND json_extract(CAST(item AS TEXT), '$.turnID') IS NOT NULL
                  AND json_extract(CAST(item AS TEXT), '$.payload.type')
                      IN ('message', 'tool', 'subagent', 'turn_end', 'error')
                ORDER BY occurred_at ASC, id ASC
                """,
            arguments: [sessionID.rawValue]
        )
        let items = try data.map { try decoder.decode(TimelineItem.self, from: $0) }
        return TurnProjection.turns(from: items, sessionID: sessionID)
    }

    @discardableResult
    public func apply(_ event: AgentIngressEvent) async throws -> Bool {
        let encoder = encoder
        let decoder = decoder
        let sessionFilter = sessionFilter
        let applied = try await database.write { db in
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
            var summary = SessionReduction.summary(applying: event, to: current)
            // The one-shot filter verdict, committed atomically with the
            // event carrying the session's first user message. Latch first —
            // the parked verdict frame must carry it so mirrors converge.
            if SessionReduction.startsFilterEvaluation(summary, from: current, event: event) {
                summary = summary.withFilterEvaluated(true)
                if let sessionFilter, sessionFilter.shouldHide(summary: summary, event: event) {
                    summary = summary.withHiddenByFilter(true)
                }
            }
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
        if applied, event.timelineItem != nil || event.disposition == .discard {
            turnsCache.removeValue(forKey: event.sessionID)
        }
        return applied
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
        let cachedTurns = turnsCache[id]
        let detail = try await database.read { db -> SessionDetail? in
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
                turns: try cachedTurns ?? Self.projectedTurns(db, sessionID: id, decoder: decoder),
                timeline: Array(items.prefix(pageSize)),
                nextCursor: items.count > pageSize
                    ? PaginationCursor(value: String(offset + pageSize))
                    : nil
            )
        }
        if cachedTurns == nil, let detail { turnsCache[id] = detail.turns }
        return detail
    }

    /// The summary alone — for callers that broadcast or inspect summary-only
    /// state. Deliberately skips the timeline and the turn projection.
    public func sessionSummary(id: SessionID) async throws -> SessionSummary? {
        let decoder = decoder
        return try await database.read { db in
            guard let data = try Data.fetchOne(
                db,
                sql: "SELECT summary FROM sessions WHERE id = ?",
                arguments: [id.rawValue]
            ) else { return nil }
            return try decoder.decode(SessionSummary.self, from: data)
        }
    }

    public func currentTurnID(sessionID: SessionID) async throws -> TurnID? {
        let decoder = decoder
        return try await database.read { db in
            guard let data = try Data.fetchOne(
                db,
                sql: """
                    SELECT item FROM timeline
                    WHERE session_id = ?
                      AND json_extract(CAST(item AS TEXT), '$.turnID') IS NOT NULL
                    ORDER BY occurred_at DESC, id DESC
                    LIMIT 1
                    """,
                arguments: [sessionID.rawValue]
            ) else { return nil }
            return try decoder.decode(TimelineItem.self, from: data).turnID
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

    /// Reads only the model-configuration items to resolve each Session's
    /// latest CLI-reported model and reasoning effort (the macOS Sessions
    /// list subtitle), without decoding entire timelines. Every requested id
    /// gets a stamp — an empty one when the session reported nothing — so
    /// callers can cache "known absent".
    public func latestModelStamps(
        sessionIDs: [SessionID]
    ) async throws -> [SessionID: SessionModelStamp] {
        let decoder = decoder
        return try await database.read { db in
            var stamps: [SessionID: SessionModelStamp] = [:]
            for sessionID in sessionIDs where stamps[sessionID] == nil {
                let cursor = try Data.fetchCursor(
                    db,
                    sql: """
                        SELECT item FROM timeline
                        WHERE session_id = ?
                          AND json_extract(CAST(item AS TEXT), '$.payload.type') = 'model_configuration'
                        ORDER BY occurred_at DESC, id DESC
                        """,
                    arguments: [sessionID.rawValue]
                )
                var model: String?
                var effort: String?
                while model == nil || effort == nil, let data = try cursor.next() {
                    let item = try decoder.decode(TimelineItem.self, from: data)
                    guard case let .modelConfiguration(payload) = item.payload else { continue }
                    if model == nil { model = payload.model }
                    if effort == nil { effort = payload.reasoningEffort }
                }
                stamps[sessionID] = SessionModelStamp(model: model, reasoningEffort: effort)
            }
            return stamps
        }
    }

    /// Atomically installs one authoritative session: clears its tombstone,
    /// then replaces summary, turns and timeline wholesale. `processed_events`
    /// is untouched so client-side event dedupe survives the replace.
    public func replaceSession(_ detail: SessionDetail) async throws {
        let encoder = encoder
        turnsCache.removeValue(forKey: detail.summary.id)
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
        turnsCache = turnsCache.filter { ids.contains($0.key) }
        return try await database.write { db in
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
        turnsCache.removeAll()
        return try await database.write { db in
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
        let removed = try await database.write { db in
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
        for id in removed { turnsCache.removeValue(forKey: id) }
        return removed
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
        turnsCache.removeValue(forKey: detail.summary.id)
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
        let cachedTurns = turnsCache[id]
        let detail = try await database.read { db -> SessionDetail? in
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
                turns: try cachedTurns ?? Self.projectedTurns(db, sessionID: id, decoder: decoder),
                timeline: Array(items.prefix(pageSize)),
                nextCursor: items.count > pageSize
                    ? PaginationCursor(value: String(offset + pageSize))
                    : nil
            )
        }
        if cachedTurns == nil, let detail { turnsCache[id] = detail.turns }
        return detail
    }

    /// Hides a session for good: tombstone the id and drop the row (the
    /// timeline cascades). Shared by manual deletion and helper discards.
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
        turnsCache.removeValue(forKey: id)
        return try await database.write { db in
            let existed = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ?)",
                arguments: [id.rawValue]
            ) ?? false
            // The timeline cascades from the session row.
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

    public func setSessionFilterVerdict(_ sessionID: SessionID, hiddenByFilter: Bool, filterEvaluated: Bool) async throws {
        let encoder = encoder
        let decoder = decoder
        try await database.write { db in
            guard let data = try Data.fetchOne(
                db,
                sql: "SELECT summary FROM sessions WHERE id = ?",
                arguments: [sessionID.rawValue]
            ) else { return }
            let summary = try decoder.decode(SessionSummary.self, from: data)
                .withHiddenByFilter(hiddenByFilter)
                .withFilterEvaluated(filterEvaluated)
            try db.execute(
                sql: "UPDATE sessions SET summary = ? WHERE id = ?",
                arguments: [try encoder.encode(summary), sessionID.rawValue]
            )
        }
    }

    public func sessionFilterRules() async throws -> [SessionFilterRule] {
        let decoder = decoder
        return try await database.read { db in
            let rows = try Data.fetchAll(
                db,
                sql: "SELECT rule FROM session_filters ORDER BY position ASC"
            )
            return try rows.map { try decoder.decode(SessionFilterRule.self, from: $0) }
        }
    }

    public func setSessionFilterRules(_ rules: [SessionFilterRule]) async throws {
        let encoder = encoder
        try await database.write { db in
            try db.execute(sql: "DELETE FROM session_filters")
            for (position, rule) in rules.enumerated() {
                try db.execute(
                    sql: "INSERT INTO session_filters(id, position, rule) VALUES(?, ?, ?)",
                    arguments: [rule.id.rawValue, position, try encoder.encode(rule)]
                )
            }
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
