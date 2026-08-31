import Foundation
import Testing
@testable import MacFeature

private func makeRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lumi-cache-migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Mac", isDirectory: true),
        withIntermediateDirectories: true
    )
    return root
}

@Test func cacheMigrationMovesAndRenamesTrioThenRemovesLegacyDirectory() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("Mac/sessions.sqlite3").path
    let new = root.appendingPathComponent("Storage/cache.sqlite").path
    for suffix in ["", "-wal", "-shm"] {
        try Data(("db" + suffix).utf8).write(to: URL(fileURLWithPath: legacy + suffix))
    }

    MacSessionStore.migrateLegacyCache(from: legacy, to: new)

    let manager = FileManager.default
    for suffix in ["", "-wal", "-shm"] {
        #expect(try Data(contentsOf: URL(fileURLWithPath: new + suffix)) == Data(("db" + suffix).utf8))
        #expect(!manager.fileExists(atPath: legacy + suffix))
    }
    #expect(!manager.fileExists(atPath: root.appendingPathComponent("Mac").path))

    // Idempotent once the legacy files are gone.
    MacSessionStore.migrateLegacyCache(from: legacy, to: new)
    #expect(manager.fileExists(atPath: new))
}

@Test func cacheMigrationDeletesLegacyWhenNewCacheAlreadyExists() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("Mac/sessions.sqlite3").path
    let new = root.appendingPathComponent("Storage/cache.sqlite").path
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Storage", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data("legacy".utf8).write(to: URL(fileURLWithPath: legacy))
    try Data("legacy-wal".utf8).write(to: URL(fileURLWithPath: legacy + "-wal"))
    try Data("new".utf8).write(to: URL(fileURLWithPath: new))

    MacSessionStore.migrateLegacyCache(from: legacy, to: new)

    let manager = FileManager.default
    #expect(try Data(contentsOf: URL(fileURLWithPath: new)) == Data("new".utf8))
    #expect(!manager.fileExists(atPath: legacy))
    #expect(!manager.fileExists(atPath: legacy + "-wal"))
    #expect(!manager.fileExists(atPath: root.appendingPathComponent("Mac").path))
}

@Test func cacheMigrationKeepsLegacyDirectoryWithForeignContent() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("Mac/sessions.sqlite3").path
    let new = root.appendingPathComponent("Storage/cache.sqlite").path
    try Data("db".utf8).write(to: URL(fileURLWithPath: legacy))
    let foreign = root.appendingPathComponent("Mac/notes.txt")
    try Data("keep".utf8).write(to: foreign)

    MacSessionStore.migrateLegacyCache(from: legacy, to: new)

    #expect(FileManager.default.fileExists(atPath: new))
    #expect(FileManager.default.fileExists(atPath: foreign.path))
}
