import DaemonRuntime
import IPCClient
import Foundation
import Testing

private func makeSupportRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lumi-migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func configuration(supportRoot: URL) -> DaemonConfiguration {
    DaemonConfiguration.default(environment: ["LUMI_SUPPORT_DIRECTORY": supportRoot.path])
}

@Test func defaultConfigurationDerivesLayoutFromApplicationSupportBase() {
    let base = URL(fileURLWithPath: "/tmp/base", isDirectory: true)
    let config = DaemonConfiguration.default(
        environment: [:],
        homeDirectory: URL(fileURLWithPath: "/Users/me", isDirectory: true),
        applicationSupportDirectory: base
    )
    #expect(config.supportDirectory.path == "/tmp/base/Lumi")
    #expect(config.daemonDirectory.path == "/tmp/base/Lumi/Lumen")
    #expect(config.databasePath == "/tmp/base/Lumi/Lumen/sessions.sqlite3")
    #expect(config.relayStatePath == "/tmp/base/Lumi/Lumen/relay-host-state.json")
    #expect(config.socketPath == "/tmp/base/Lumi/daemon.sock")
}

@Test func socketPathFollowsSupportDirectoryOverrideAndSocketOverrideWins() {
    let base = URL(fileURLWithPath: "/tmp/base", isDirectory: true)
    let fromSupport = DaemonEndpoint.defaultSocketPath(
        environment: ["LUMI_SUPPORT_DIRECTORY": "/tmp/isolated"],
        applicationSupportDirectory: base
    )
    #expect(fromSupport == "/tmp/isolated/daemon.sock")
    let fromSocket = DaemonEndpoint.defaultSocketPath(
        environment: ["LUMI_SUPPORT_DIRECTORY": "/tmp/isolated", "LUMI_SOCKET": "/tmp/pin.sock"],
        applicationSupportDirectory: base
    )
    #expect(fromSocket == "/tmp/pin.sock")
}

@Test func migrationMovesLegacyStateIntoDaemonDirectory() throws {
    let root = try makeSupportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = configuration(supportRoot: root)
    try config.prepareFileSystem()
    for name in ["sessions.sqlite3", "sessions.sqlite3-wal", "sessions.sqlite3-shm", "relay-host-state.json"] {
        try Data(name.utf8).write(to: root.appendingPathComponent(name))
    }

    DaemonStorageMigration.run(configuration: config, environment: [:])

    let manager = FileManager.default
    #expect(manager.fileExists(atPath: config.databasePath))
    #expect(manager.fileExists(atPath: config.databasePath + "-wal"))
    #expect(manager.fileExists(atPath: config.databasePath + "-shm"))
    #expect(manager.fileExists(atPath: config.relayStatePath))
    for name in ["sessions.sqlite3", "sessions.sqlite3-wal", "sessions.sqlite3-shm", "relay-host-state.json"] {
        #expect(!manager.fileExists(atPath: root.appendingPathComponent(name).path))
    }

    // Second run is a no-op and must not disturb the migrated files.
    DaemonStorageMigration.run(configuration: config, environment: [:])
    #expect(try Data(contentsOf: URL(fileURLWithPath: config.databasePath)) == Data("sessions.sqlite3".utf8))
}

@Test func migrationResumesAfterPartialSidecarMove() throws {
    let root = try makeSupportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = configuration(supportRoot: root)
    try config.prepareFileSystem()
    // Crash simulation: the wal already moved, main + shm still at legacy.
    try Data("wal".utf8).write(to: URL(fileURLWithPath: config.databasePath + "-wal"))
    try Data("main".utf8).write(to: root.appendingPathComponent("sessions.sqlite3"))
    try Data("shm".utf8).write(to: root.appendingPathComponent("sessions.sqlite3-shm"))

    DaemonStorageMigration.run(configuration: config, environment: [:])

    let manager = FileManager.default
    #expect(manager.fileExists(atPath: config.databasePath))
    #expect(manager.fileExists(atPath: config.databasePath + "-wal"))
    #expect(manager.fileExists(atPath: config.databasePath + "-shm"))
    #expect(!manager.fileExists(atPath: root.appendingPathComponent("sessions.sqlite3").path))
}

@Test func migrationNeverOverwritesAnExistingNewDatabase() throws {
    let root = try makeSupportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = configuration(supportRoot: root)
    try config.prepareFileSystem()
    try Data("legacy".utf8).write(to: root.appendingPathComponent("sessions.sqlite3"))
    try Data("new".utf8).write(to: URL(fileURLWithPath: config.databasePath))

    DaemonStorageMigration.run(configuration: config, environment: [:])

    #expect(try Data(contentsOf: URL(fileURLWithPath: config.databasePath)) == Data("new".utf8))
    #expect(try Data(contentsOf: root.appendingPathComponent("sessions.sqlite3")) == Data("legacy".utf8))
}

@Test func migrationDeletesStaleLegacyRelayStateOnCollision() throws {
    let root = try makeSupportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = configuration(supportRoot: root)
    try config.prepareFileSystem()
    try Data("legacy".utf8).write(to: root.appendingPathComponent("relay-host-state.json"))
    try Data("new".utf8).write(to: URL(fileURLWithPath: config.relayStatePath))

    DaemonStorageMigration.run(configuration: config, environment: [:])

    #expect(try Data(contentsOf: URL(fileURLWithPath: config.relayStatePath)) == Data("new".utf8))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("relay-host-state.json").path))
}

@Test func migrationSkipsItemsWithExplicitOverrides() throws {
    let root = try makeSupportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = configuration(supportRoot: root)
    try config.prepareFileSystem()
    try Data("db".utf8).write(to: root.appendingPathComponent("sessions.sqlite3"))
    try Data("relay".utf8).write(to: root.appendingPathComponent("relay-host-state.json"))

    DaemonStorageMigration.run(configuration: config, environment: [
        "LUMI_DATABASE": "/tmp/elsewhere.sqlite3",
        "LUMI_RELAY_STATE": "/tmp/elsewhere.json",
    ])

    let manager = FileManager.default
    #expect(manager.fileExists(atPath: root.appendingPathComponent("sessions.sqlite3").path))
    #expect(manager.fileExists(atPath: root.appendingPathComponent("relay-host-state.json").path))
    #expect(!manager.fileExists(atPath: config.databasePath))
    #expect(!manager.fileExists(atPath: config.relayStatePath))
}
