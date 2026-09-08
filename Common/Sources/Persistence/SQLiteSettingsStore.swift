import Core
import Transport
import Foundation
import GRDB

/// GRDB implementation of `SettingsStore` over the daemon's session database
/// (`makeSettingsStore()` on `SQLiteSessionRepository`): the `settings`
/// table, one dotted key per leaf, created by `lumi-v12-settings`.
public actor SQLiteSettingsStore: SettingsStore {
    private let database: DatabaseQueue

    public init(database: DatabaseQueue) {
        self.database = database
    }

    public func settings() async throws -> DaemonSettings {
        let rows = try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT key, value FROM settings ORDER BY key")
                .map { (key: $0["key"] as String, value: $0["value"] as Data) }
        }
        return try SettingsKeys.settings(rows: rows)
    }

    public func replace(_ settings: DaemonSettings) async throws {
        let rows = try SettingsKeys.rows(settings)
        try await database.write { db in
            let now = Date().timeIntervalSince1970
            for row in rows {
                let current = try Data.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [row.key])
                guard current != row.value else { continue }
                try db.execute(
                    sql: """
                        INSERT INTO settings(key, value, updated_at) VALUES(?, ?, ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                        """,
                    arguments: [row.key, row.value, now]
                )
            }
        }
    }
}
