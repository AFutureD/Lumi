import Core
import Persistence
import Transport
import Foundation
import Testing

private func stores() throws -> [(name: String, store: any SettingsStore)] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString)")
    let repository = try SQLiteSessionRepository(path: directory.appendingPathComponent("sessions.sqlite3").path)
    return [("memory", InMemorySettingsStore()), ("sqlite", repository.makeSettingsStore())]
}

@Test func settingsReadAsDefaultsUntilWritten() async throws {
    for (name, store) in try stores() {
        #expect(try await store.settings() == .defaults, "\(name)")
        let wanted = DaemonSettings(planUsage: PlanUsageSettings(enabledAccounts: [.codex], percentStyle: .remaining))
        try await store.replace(wanted)
        #expect(try await store.settings() == wanted, "\(name)")
        // Switching an account off keeps a row (`false`), so a later import never revives it.
        try await store.replace(.defaults)
        #expect(try await store.settings() == .defaults, "\(name)")
    }
}

@Test func settingsPersistAcrossRepositoryInstancesAndSurviveClearHistory() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("settings-persist-\(UUID().uuidString)")
    let path = directory.appendingPathComponent("sessions.sqlite3").path
    let wanted = DaemonSettings(planUsage: PlanUsageSettings(enabledAccounts: [.claude, .codex], percentStyle: .remaining))
    let first = try SQLiteSessionRepository(path: path)
    try await first.makeSettingsStore().replace(wanted)
    _ = try await first.deleteAllSessions()
    let second = try SQLiteSessionRepository(path: path)
    #expect(try await second.makeSettingsStore().settings() == wanted)
}

@Test func rowsUseDottedKeysAndIgnoreStrangers() throws {
    let rows = try SettingsKeys.rows(DaemonSettings(planUsage: PlanUsageSettings(enabledAccounts: [.claude], percentStyle: .used)))
    #expect(rows.map(\.key) == ["plan_usage.percent_style", "plan_usage.enabled.claude", "plan_usage.enabled.codex"])
    #expect(String(decoding: rows[0].value, as: UTF8.self) == "\"used\"")
    #expect(String(decoding: rows[1].value, as: UTF8.self) == "true")
    var extended = rows
    extended.append((key: "future.thing", value: Data("1".utf8)))
    #expect(try SettingsKeys.settings(rows: extended).planUsage == PlanUsageSettings(enabledAccounts: [.claude], percentStyle: .used))
    #expect(throws: DecodingError.self) {
        try SettingsKeys.settings(rows: [(key: "plan_usage.percent_style", value: Data("\"half\"".utf8))])
    }
}
