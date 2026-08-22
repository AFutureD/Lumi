import AgentStatusRemote
import AgentStatusTransport
import Foundation

/// The daemon's Relay host state that is not a credential but must survive a
/// restart — `relay-host-state.json` (0600) next to the daemon's database, a
/// hot path the Keychain is not meant for:
/// - per-device host → device send sequences, persisted before anything hits
///   the wire: a crash mid-publish leaves a legal gap, never a fatal reuse;
/// - the device public keys the daemon pinned when the Mac pressed Match (the
///   key the Numeric Comparison covered): the Relay's device list is only
///   believed where it matches one of these.
public struct RelayHostStateStore: Sendable {
    private struct State: Codable {
        var channelSequences: [String: UInt64]
        var verifiedDeviceKeys: [String: Data]
    }

    public let path: String
    private var sequences: [String: UInt64]
    private var verifiedKeys: [String: Data]

    public init(path: String) {
        self.path = path
        if let data = FileManager.default.contents(atPath: path),
           let state = try? JSONDecoder().decode(State.self, from: data) {
            sequences = state.channelSequences
            verifiedKeys = state.verifiedDeviceKeys
        } else {
            sequences = [:]
            verifiedKeys = [:]
        }
    }

    // MARK: - Sequences

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

    // MARK: - Device keys

    /// The public key this daemon pinned for the device, if any.
    public func verifiedKey(for device: DeviceID) -> Data? {
        verifiedKeys[device.rawValue]
    }

    /// Pins the device's public key (the Mac approved it after comparing the SAS).
    public mutating func setVerifiedKey(_ key: Data, for device: DeviceID) throws {
        guard verifiedKeys[device.rawValue] != key else { return }
        verifiedKeys[device.rawValue] = key
        try persist()
    }

    /// Forgets a removed device's pin (a re-pair pins a fresh key anyway).
    public mutating func clearVerifiedKey(for device: DeviceID) throws {
        guard verifiedKeys.removeValue(forKey: device.rawValue) != nil else { return }
        try persist()
    }

    private func persist() throws {
        let state = State(channelSequences: sequences, verifiedDeviceKeys: verifiedKeys)
        let data = try JSONEncoder().encode(state)
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
