import Core
import Diagnostics
import Logging
import Transport
import Foundation

private let log = Logger(label: "db")

/// Before `lumi-v12-settings` the plan-usage switches lived in
/// `Lumen/plan-usage-settings.json` (`{"enabled":{"claude":true}}`). On the
/// first start with the table, the file's switches become
/// `plan_usage.enabled.*` rows and the file goes away — unless the table
/// already has switches, in which case the file is stale and just removed.
public enum LegacyPlanUsageSettingsImport {
    struct File: Decodable {
        var enabled: [String: Bool] = [:]
    }

    public static func run(path: String, into store: any SettingsStore, now: Date = Date()) async throws {
        guard let data = FileManager.default.contents(atPath: path) else { return }
        defer { try? FileManager.default.removeItem(atPath: path) }
        let current = try await store.settings()
        guard current.planUsage.enabledAccounts.isEmpty else {
            log.info("settings_import_skipped", metadata: .fields(["path": path, "reason": "table already has switches"]))
            return
        }
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            log.error("settings_import_unreadable", metadata: .fields(["path": path, "error": error]))
            return
        }
        var settings = current
        settings.planUsage.enabledAccounts = file.enabled
            .filter(\.value)
            .map { PlanUsageAccountID(rawValue: $0.key) }
            .sorted { $0.rawValue < $1.rawValue }
        try await store.replace(settings)
        log.info("settings_imported", metadata: .fields([
            "path": path,
            "enabled": settings.planUsage.enabledAccounts.map(\.rawValue).joined(separator: ","),
        ]))
    }
}
