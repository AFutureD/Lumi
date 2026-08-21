import AgentStatusTransport
import Foundation

/// Per-device host → device send sequences, persisted before anything hits
/// the wire: a crash mid-publish leaves a legal gap, never a fatal reuse.
/// Lives in `relay-host-state.json` (0600) next to the daemon's database —
/// a hot path the Keychain is not meant for.
public struct RelayHostSequenceStore: Sendable {
    private struct State: Codable {
        var channelSequences: [String: UInt64]
    }

    public let path: String
    private var sequences: [String: UInt64]

    public init(path: String) {
        self.path = path
        if let data = FileManager.default.contents(atPath: path),
           let state = try? JSONDecoder().decode(State.self, from: data) {
            sequences = state.channelSequences
        } else {
            sequences = [:]
        }
    }

    public func current(for device: DeviceID) -> UInt64 {
        sequences[device.rawValue] ?? 0
    }

    /// Reserves `count` sequences for the device and persists the new high
    /// water mark; returns the first reserved value.
    public mutating func reserve(for device: DeviceID, count: Int) throws -> UInt64 {
        precondition(count > 0)
        let previous = current(for: device)
        sequences[device.rawValue] = previous + UInt64(count)
        try persist()
        return previous + 1
    }

    /// The relay reported the channel is already past `sequence` (state file
    /// lost, or another daemon instance published): jump ahead of it.
    public mutating func advance(_ device: DeviceID, past sequence: UInt64) throws {
        guard sequence >= current(for: device) else { return }
        sequences[device.rawValue] = sequence
        try persist()
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(State(channelSequences: sequences))
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
