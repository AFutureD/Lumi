import AgentStatusTransport
import Foundation

/// Credentials and cursor for one paired Mac-to-iOS channel.
public struct RelayDeviceCredentials: Codable, Hashable, Sendable {
    public let relayURL: URL
    public let hostID: HostID
    public let hostName: String?
    public let deviceID: DeviceID
    public let deviceToken: String
    public let keyPair: RelayKeyPair
    public let hostPublicKey: Data
    /// When this iPhone paired with the Mac (`RelayPairingResult.pairedAt`).
    public let pairedAt: Date
    public var lastAcknowledgedSequence: UInt64

    public init(
        relayURL: URL,
        hostID: HostID,
        hostName: String? = nil,
        deviceID: DeviceID,
        deviceToken: String,
        keyPair: RelayKeyPair,
        hostPublicKey: Data,
        pairedAt: Date = Date(),
        lastAcknowledgedSequence: UInt64 = 0
    ) {
        self.relayURL = relayURL
        self.hostID = hostID
        self.hostName = hostName
        self.deviceID = deviceID
        self.deviceToken = deviceToken
        self.keyPair = keyPair
        self.hostPublicKey = hostPublicKey
        self.pairedAt = pairedAt
        self.lastAcknowledgedSequence = lastAcknowledgedSequence
    }

    public var displayName: String {
        if let hostName, !hostName.isEmpty { return hostName }
        return "Mac \(hostID.rawValue.suffix(6))"
    }
}

/// Persistent index of channels. Session payloads are intentionally absent.
public struct RelayDeviceCredentialCollection: Codable, Hashable, Sendable {
    public private(set) var channels: [RelayDeviceCredentials]

    public init(channels: [RelayDeviceCredentials] = []) {
        self.channels = channels
    }

    public mutating func upsert(_ credentials: RelayDeviceCredentials) {
        channels.removeAll { $0.hostID == credentials.hostID }
        channels.append(credentials)
    }

    public mutating func remove(hostID: HostID) {
        channels.removeAll { $0.hostID == hostID }
    }
}
