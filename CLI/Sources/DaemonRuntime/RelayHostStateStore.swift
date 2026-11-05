import Remote
import Transport
import Foundation

/// The daemon's Relay host state that is not a credential but must survive a
/// restart — `relay-host-state.json` (0600) next to the daemon's database, a
/// hot path the Keychain is not meant for:
/// - per-device host → device send sequences, persisted before anything hits
///   the wire: a crash mid-publish leaves a legal gap, never a fatal reuse;
/// - which iPhones this Mac trusts. A device is trusted exactly while its
///   public key is pinned here: Match pins the key the Numeric Comparison
///   covered, Revoke drops it. This is the only place trust is read from —
///   nothing the Relay lists or answers can make a device trusted (again);
/// - when this Mac revoked a device. The mark keeps the row "Revoked" and
///   keeps the daemon re-sending the revocation until the Relay applies it.
///
/// Every change is written before it takes effect: a write that fails
/// throws and leaves both the file and this value as they were, so what the
/// daemon acts on is always what a restart would read back.
public struct RelayHostStateStore: Sendable {
    /// The highest sequence a channel may reach: the largest integer the
    /// Relay itself can count exactly. Nothing — a cursor the Relay reports
    /// least of all — moves a channel past it.
    public static let highestSequence: UInt64 = 1 << 53

    private struct State: Codable, Equatable {
        var channelSequences: [String: UInt64] = [:]
        var verifiedDeviceKeys: [String: Data] = [:]
        var revokedDevices: [String: Date] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            channelSequences = try container.decode([String: UInt64].self, forKey: .channelSequences)
            verifiedDeviceKeys = try container.decode([String: Data].self, forKey: .verifiedDeviceKeys)
            // A file written before revocations were recorded here has none.
            revokedDevices = try container.decodeIfPresent([String: Date].self, forKey: .revokedDevices) ?? [:]
        }
    }

    public let path: String
    private var state: State

    public init(path: String) {
        self.path = path
        if let data = FileManager.default.contents(atPath: path),
           let state = try? JSONDecoder().decode(State.self, from: data) {
            self.state = state
        } else {
            state = State()
        }
    }

    // MARK: - Sequences

    public func current(for device: DeviceID) -> UInt64 {
        state.channelSequences[device.rawValue] ?? 0
    }

    /// Reserves `count` sequences for the device and persists the new high
    /// water mark; returns the first reserved value.
    public mutating func reserve(for device: DeviceID, count: Int) throws -> UInt64 {
        precondition(count > 0)
        let previous = current(for: device)
        guard previous <= Self.highestSequence, UInt64(count) <= Self.highestSequence - previous else {
            throw RelayHostStateError.sequenceOutOfRange
        }
        try commit { $0.channelSequences[device.rawValue] = previous + UInt64(count) }
        return previous + 1
    }

    /// The relay reported the channel is already past `sequence` (state file
    /// lost, or another daemon instance published): jump ahead of it. A
    /// cursor beyond `highestSequence` is not one the Relay could hold, so
    /// it is refused rather than left to exhaust the channel.
    public mutating func advance(_ device: DeviceID, past sequence: UInt64) throws {
        guard sequence >= current(for: device) else { return }
        guard sequence < Self.highestSequence else { throw RelayHostStateError.sequenceOutOfRange }
        try commit { $0.channelSequences[device.rawValue] = sequence }
    }

    // MARK: - Device trust

    /// The public key this daemon pinned for the device; `nil` for a device
    /// this Mac never approved or has revoked. A pinned key is what makes a
    /// device trusted, and the only key the daemon derives channel keys from.
    public func verifiedKey(for device: DeviceID) -> Data? {
        state.verifiedDeviceKeys[device.rawValue]
    }

    /// Every device this Mac trusts right now.
    public var verifiedDeviceIDs: [DeviceID] {
        state.verifiedDeviceKeys.keys.sorted().map { DeviceID($0) }
    }

    /// When this Mac revoked the device, if it did and has not paired it again since.
    public func revokedAt(for device: DeviceID) -> Date? {
        state.revokedDevices[device.rawValue]
    }

    /// Pins the device's public key (the Mac approved it after comparing the
    /// SAS) and lifts an earlier revocation: a Match is the only thing that
    /// trusts a device again.
    public mutating func setVerifiedKey(_ key: Data, for device: DeviceID) throws {
        try commit {
            $0.verifiedDeviceKeys[device.rawValue] = key
            $0.revokedDevices[device.rawValue] = nil
        }
    }

    /// Revokes the device on this Mac: its pinned key is dropped and the
    /// revocation is kept until the device is paired again or removed.
    /// Repeating it keeps the first date.
    public mutating func revoke(_ device: DeviceID, at date: Date) throws {
        try commit {
            $0.verifiedDeviceKeys[device.rawValue] = nil
            $0.revokedDevices[device.rawValue] = $0.revokedDevices[device.rawValue] ?? date
        }
    }

    /// Forgets a removed device: its pin and its revocation mark.
    public mutating func forget(_ device: DeviceID) throws {
        try commit {
            $0.verifiedDeviceKeys[device.rawValue] = nil
            $0.revokedDevices[device.rawValue] = nil
        }
    }

    /// Puts the device's pin and revocation mark back to what `earlier` held
    /// (a Match the Relay then refused).
    public mutating func restoreTrust(of device: DeviceID, from earlier: RelayHostStateStore) throws {
        try commit {
            $0.verifiedDeviceKeys[device.rawValue] = earlier.state.verifiedDeviceKeys[device.rawValue]
            $0.revokedDevices[device.rawValue] = earlier.state.revokedDevices[device.rawValue]
        }
    }

    /// Applies `change` to a copy, writes it, and only then adopts it.
    private mutating func commit(_ change: (inout State) -> Void) throws {
        var next = state
        change(&next)
        guard next != state else { return }
        try persist(next)
        state = next
    }

    private func persist(_ state: State) throws {
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

public enum RelayHostStateError: Error, Sendable {
    /// A channel's sequence would leave the range the Relay can count.
    case sequenceOutOfRange
}
