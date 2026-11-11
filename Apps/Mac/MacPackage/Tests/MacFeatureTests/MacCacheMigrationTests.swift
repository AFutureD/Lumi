import Foundation
import Testing
@testable import MacFeature

private func makeRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lumi-cache-retire-\(UUID().uuidString)", isDirectory: true)
    for directory in ["Mac", "Storage"] {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(directory, isDirectory: true),
            withIntermediateDirectories: true
        )
    }
    return root
}

@Test func retiredCachesAreDeletedWithSidecarsAndEmptyDirectories() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = root.appendingPathComponent("Storage/cache.sqlite").path
    let legacy = root.appendingPathComponent("Mac/sessions.sqlite3").path
    for path in [storage, legacy] {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try Data(("db" + suffix).utf8).write(to: URL(fileURLWithPath: path + suffix))
        }
    }
    // The current cache shares `Storage/` with the retired one.
    let current = root.appendingPathComponent("Storage/session-cache.sqlite").path
    try Data("current".utf8).write(to: URL(fileURLWithPath: current))

    MacSessionStore.discardRetiredCaches([storage, legacy])

    let manager = FileManager.default
    for path in [storage, legacy] {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            #expect(!manager.fileExists(atPath: path + suffix))
        }
    }
    #expect(!manager.fileExists(atPath: root.appendingPathComponent("Mac").path))
    #expect(try Data(contentsOf: URL(fileURLWithPath: current)) == Data("current".utf8))

    // Idempotent once the files are gone.
    MacSessionStore.discardRetiredCaches([storage, legacy])
    #expect(manager.fileExists(atPath: current))
}

@Test func retiringKeepsDirectoryWithForeignContent() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("Mac/sessions.sqlite3").path
    try Data("db".utf8).write(to: URL(fileURLWithPath: legacy))
    let foreign = root.appendingPathComponent("Mac/notes.txt")
    try Data("keep".utf8).write(to: foreign)

    MacSessionStore.discardRetiredCaches([legacy])

    #expect(!FileManager.default.fileExists(atPath: legacy))
    #expect(FileManager.default.fileExists(atPath: foreign.path))
}
