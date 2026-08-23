import Core
import Foundation
import Testing

@Test func sha256HexMatchesKnownDigest() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fingerprint-\(UUID().uuidString)")
    try Data("abc".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let hash = try ExecutableFingerprint.sha256Hex(fileAt: url)
    // SHA-256("abc"), the FIPS 180 reference vector.
    #expect(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func sha256HexThrowsForMissingFile() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fingerprint-missing-\(UUID().uuidString)")
    #expect(throws: (any Error).self) {
        try ExecutableFingerprint.sha256Hex(fileAt: url)
    }
}
