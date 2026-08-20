import Foundation

public enum RelayFrameKind: Hashable, Sendable {
    case hello
    case data
    case acknowledgement
    case attention
    case error
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .hello: "hello"
        case .data: "data"
        case .acknowledgement: "ack"
        case .attention: "attention"
        case .error: "error"
        case let .unknown(value): value
        }
    }
}

extension RelayFrameKind: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = switch value {
        case "hello": .hello
        case "data": .data
        case "ack": .acknowledgement
        case "attention": .attention
        case "error": .error
        default: .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RelayRoutingFrame: Codable, Hashable, Sendable {
    public let version: ProtocolVersion
    public let hostID: HostID
    public let deviceID: DeviceID?
    public let sequence: UInt64
    public let kind: RelayFrameKind
    public let nonce: Data?
    public let ciphertext: Data?
    public let acknowledgedSequence: UInt64?

    public init(
        version: ProtocolVersion = .current,
        hostID: HostID,
        deviceID: DeviceID? = nil,
        sequence: UInt64,
        kind: RelayFrameKind,
        nonce: Data? = nil,
        ciphertext: Data? = nil,
        acknowledgedSequence: UInt64? = nil
    ) {
        self.version = version
        self.hostID = hostID
        self.deviceID = deviceID
        self.sequence = sequence
        self.kind = kind
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.acknowledgedSequence = acknowledgedSequence
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case hostID
        case deviceID
        case sequence
        case kind
        case nonce
        case ciphertext
        case acknowledgedSequence
    }
}

public struct PairingOffer: Codable, Hashable, Sendable {
    public let version: ProtocolVersion
    public let relayURL: URL
    public let hostID: HostID
    public let hostName: String?
    public let challenge: String
    public let hostPublicKey: Data
    public let expiresAt: Date

    public init(
        version: ProtocolVersion = .current,
        relayURL: URL,
        hostID: HostID,
        hostName: String? = nil,
        challenge: String,
        hostPublicKey: Data,
        expiresAt: Date
    ) {
        self.version = version
        self.relayURL = relayURL
        self.hostID = hostID
        self.hostName = hostName
        self.challenge = challenge
        self.hostPublicKey = hostPublicKey
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case relayURL
        case hostID
        case hostName
        case challenge
        case hostPublicKey
        case expiresAt
    }
}

public struct PairingRequest: Codable, Hashable, Sendable {
    public let hostID: HostID
    public let deviceID: DeviceID
    public let challenge: String
    public let deviceName: String
    public let devicePublicKey: Data

    public init(
        hostID: HostID,
        deviceID: DeviceID,
        challenge: String,
        deviceName: String,
        devicePublicKey: Data
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.challenge = challenge
        self.deviceName = deviceName
        self.devicePublicKey = devicePublicKey
    }

    private enum CodingKeys: String, CodingKey {
        case hostID
        case deviceID
        case challenge
        case deviceName
        case devicePublicKey
    }
}

public struct PairedDevice: Codable, Hashable, Sendable {
    public let id: DeviceID
    public let name: String
    public let publicKey: Data
    public let pairedAt: Date
    public let revokedAt: Date?

    public init(
        id: DeviceID,
        name: String,
        publicKey: Data,
        pairedAt: Date,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.pairedAt = pairedAt
        self.revokedAt = revokedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case publicKey
        case pairedAt
        case revokedAt
    }
}

public struct DeviceRevocation: Codable, Hashable, Sendable {
    public let hostID: HostID
    public let deviceID: DeviceID
    public let revokedAt: Date

    public init(hostID: HostID, deviceID: DeviceID, revokedAt: Date = Date()) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.revokedAt = revokedAt
    }

    private enum CodingKeys: String, CodingKey {
        case hostID
        case deviceID
        case revokedAt
    }
}

public struct SyncCursor: Codable, Hashable, Sendable {
    public let lastAcknowledgedSequence: UInt64

    public init(lastAcknowledgedSequence: UInt64) {
        self.lastAcknowledgedSequence = lastAcknowledgedSequence
    }

    private enum CodingKeys: String, CodingKey {
        case lastAcknowledgedSequence
    }
}

public enum RemotePayloadKind: Hashable, Sendable {
    case index
    case session
    case unavailable
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .index: "index"
        case .session: "session"
        case .unavailable: "unavailable"
        case let .unknown(value): value
        }
    }
}

extension RemotePayloadKind: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = switch value {
        case "index": .index
        case "session": .session
        case "unavailable": .unavailable
        default: .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The encrypted application payload sent through Relay. Relay only sees the
/// routing frame. Full state travels one session at a time:
/// - `.session` carries one part of one session; `session.nextCursor != nil`
///   means more parts follow, `part` counts from 0 and part 0 restarts a
///   transfer (later parts carry empty `turns`).
/// - `.index` closes a publish batch: the authoritative visible id set the
///   device prunes its cache to.
/// - `.unavailable` reports the Mac daemon being down.
public struct RemoteSessionPayload: Codable, Hashable, Sendable {
    public let kind: RemotePayloadKind
    public let generatedAt: Date
    public let sessionIDs: [SessionID]?
    public let session: SessionDetail?
    public let part: Int?
    public let message: String?

    public init(
        kind: RemotePayloadKind,
        generatedAt: Date = Date(),
        sessionIDs: [SessionID]? = nil,
        session: SessionDetail? = nil,
        part: Int? = nil,
        message: String? = nil
    ) {
        self.kind = kind
        self.generatedAt = generatedAt
        self.sessionIDs = sessionIDs
        self.session = session
        self.part = part
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case generatedAt
        case sessionIDs
        case session
        case part
        case message
    }
}

public enum TransportGoldenFixtures {
    public static func relayRoutingV1() throws -> Data {
        guard let url = Bundle.module.url(forResource: "transport-v1", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
}
