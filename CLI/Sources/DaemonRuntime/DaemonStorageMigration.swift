import Diagnostics
import Logging
import Foundation

private let log = Logger(label: "db")

/// One-time move of the daemon's state from the support root into
/// `Lumi/Lumen/` (2026-08-31 layout change). Runs on every start and no-ops
/// once the legacy files are gone; never throws — a failed move is logged and
/// the daemon starts against whatever the resolved paths hold.
public enum DaemonStorageMigration {
    public static func run(
        configuration: DaemonConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        let legacyRoot = configuration.supportDirectory

        // Database, gated on its own override: with `LUMI_DATABASE` the
        // resolved path is unrelated to the layout and the legacy file is
        // someone else's concern.
        if environment["LUMI_DATABASE"] == nil {
            migrateDatabase(
                from: legacyRoot.appendingPathComponent("sessions.sqlite3").path,
                to: configuration.databasePath,
                fileManager: fileManager
            )
        }

        if environment["LUMI_RELAY_STATE"] == nil {
            migrateRelayState(
                from: legacyRoot.appendingPathComponent("relay-host-state.json").path,
                to: configuration.relayStatePath,
                fileManager: fileManager
            )
        }
    }

    /// Sidecars first, main file last: a crash mid-move leaves the legacy
    /// main in place and the new main absent, so the next start re-runs and
    /// converges (already-moved sidecars are simply gone from the legacy
    /// side). If a database already exists at the new path, nothing is
    /// touched — the new file wins, the legacy one stays for inspection.
    private static func migrateDatabase(from legacyPath: String, to newPath: String, fileManager: FileManager) {
        guard legacyPath != newPath, fileManager.fileExists(atPath: legacyPath) else { return }
        guard !fileManager.fileExists(atPath: newPath) else {
            log.warning("storage_migration_collision", metadata: .fields([
                "legacy": legacyPath,
                "new": newPath,
            ]))
            return
        }
        do {
            for suffix in ["-wal", "-shm", ""] {
                let source = legacyPath + suffix
                guard fileManager.fileExists(atPath: source) else { continue }
                try fileManager.moveItem(atPath: source, toPath: newPath + suffix)
            }
            log.info("storage_migrated_database", metadata: .fields(["from": legacyPath, "to": newPath]))
        } catch {
            log.error("storage_migration_failed", metadata: .fields([
                "from": legacyPath,
                "to": newPath,
                "error": error,
            ]))
        }
    }

    /// The relay state is small and strictly newer at the new path once one
    /// exists there; a leftover legacy copy is stale (sequence gaps are legal
    /// by design), so it is deleted rather than kept.
    private static func migrateRelayState(from legacyPath: String, to newPath: String, fileManager: FileManager) {
        guard legacyPath != newPath, fileManager.fileExists(atPath: legacyPath) else { return }
        do {
            if fileManager.fileExists(atPath: newPath) {
                try fileManager.removeItem(atPath: legacyPath)
                log.info("storage_removed_stale_relay_state", metadata: .fields(["path": legacyPath]))
            } else {
                try fileManager.moveItem(atPath: legacyPath, toPath: newPath)
                log.info("storage_migrated_relay_state", metadata: .fields(["from": legacyPath, "to": newPath]))
            }
        } catch {
            log.error("storage_migration_failed", metadata: .fields([
                "from": legacyPath,
                "to": newPath,
                "error": error,
            ]))
        }
    }
}
