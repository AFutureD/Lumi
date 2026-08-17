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
        try migrator.migrate(database)
    }

    @discardableResult
    public func apply(_ event: AgentIngressEvent) async throws -> Bool {
        let encoder = encoder
        let decoder = decoder
        return try await database.write { db in
            let ignored = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM ignored_sessions WHERE id = ?)",
                arguments: [event.sessionID.rawValue]
            ) ?? false
            guard !ignored else { return false }

            let duplicate = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM processed_events WHERE id = ?)",
                arguments: [event.eventID.rawValue]
            ) ?? false
            guard !duplicate else { return false }

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

            if let item = event.timelineItem {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO timeline(id, session_id, occurred_at, item)
                        VALUES(?, ?, ?, ?)
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
                timeline: Array(items.prefix(pageSize)),
                nextCursor: items.count > pageSize
                    ? PaginationCursor(value: String(offset + pageSize))
                    : nil
            )
        }
    }

    /// Atomically makes a client cache match the daemon's authoritative snapshot.
    public func replaceSnapshot(_ details: [SessionDetail]) async throws {
        let encoder = encoder
        try await database.write { db in
            try db.execute(sql: "DELETE FROM sessions")
            for detail in details {
                let summary = detail.summary
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

    public func deleteSession(id: SessionID) async throws -> Bool {
        try await database.write { db in
            let existed = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ?)",
                arguments: [id.rawValue]
            ) ?? false
            try db.execute(
                sql: "INSERT OR IGNORE INTO ignored_sessions(id) VALUES(?)",
                arguments: [id.rawValue]
            )
            try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [id.rawValue])
            return existed
        }
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
