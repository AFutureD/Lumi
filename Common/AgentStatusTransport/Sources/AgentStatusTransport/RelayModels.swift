import Foundation

/// What a routing frame carries. The Relay reads only this and the routing
/// header; the body is sealed per Mac ↔ iPhone channel.
/// - `data`: host → device, a sealed `RemoteSessionPayload`.
/// - `request`: device → host, a sealed `RemoteSessionPayload` asking for
///   something (`syncIndex`, `fetchSession`, …) or reporting `sessionReviewed`.
/// - `error`: reserved.
public enum RelayFrameKind: Hashable, Sendable {
    case data
    case request
    case error

    public var rawValue: String {
        switch self {
        case .data: "data"
        case .request: "request"
        case .error: "error"
        }
    }
}

extension RelayFrameKind: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = switch value {
        case "data": .data
        case "request": .request
        case "error": .error
        default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown relay frame kind: \(value)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The routing envelope the Relay understands. Host → device sequences are
/// strictly increasing per device channel (the Relay drops reuse); device →
/// host sequences are connection-local and only diagnostic.
public struct RelayRoutingFrame: Codable, Hashable, Sendable {
    public let version: ProtocolVersion
    public let hostID: HostID
    public let deviceID: DeviceID?
    public let sequence: UInt64
    public let kind: RelayFrameKind
    public let nonce: Data?
    public let ciphertext: Data?

    public init(
        version: ProtocolVersion = .current,
        hostID: HostID,
        deviceID: DeviceID? = nil,
        sequence: UInt64,
        kind: RelayFrameKind,
        nonce: Data? = nil,
        ciphertext: Data? = nil
    ) {
        self.version = version
        self.hostID = hostID
        self.deviceID = deviceID
        self.sequence = sequence
        self.kind = kind
        self.nonce = nonce
        self.ciphertext = ciphertext
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case hostID
        case deviceID
        case sequence
        case kind
        case nonce
        case ciphertext
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

/// The daemon's view of its Relay host connection, served to the Mac app over
/// IPC (`relay_status`). Data only — the app renders it.
public struct RelayHostStatus: Codable, Hashable, Sendable {
    public let connected: Bool
    public let hostID: HostID?
    public let relayURL: URL?
    public let lastError: String?
    public let devices: [PairedDevice]
    public let updatedAt: Date

    public init(
        connected: Bool,
        hostID: HostID? = nil,
        relayURL: URL? = nil,
        lastError: String? = nil,
        devices: [PairedDevice] = [],
        updatedAt: Date = Date()
    ) {
        self.connected = connected
        self.hostID = hostID
        self.relayURL = relayURL
        self.lastError = lastError
        self.devices = devices
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case connected
        case hostID
        case relayURL
        case lastError
        case devices
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connected = try c.decode(Bool.self, forKey: .connected)
        hostID = try c.decodeIfPresent(HostID.self, forKey: .hostID)
        relayURL = try c.decodeIfPresent(URL.self, forKey: .relayURL)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        devices = try c.decodeIfPresent([PairedDevice].self, forKey: .devices) ?? []
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

/// What a sealed payload is. Requests travel device → host in `request`
/// frames; everything else travels host → device in `data` frames.
public enum RemotePayloadKind: Hashable, Sendable {
    // MARK: device → host
    /// Send me the session index.
    case syncIndex
    /// Send me these sessions in full (`sessionIDs`).
    case fetchSession
    /// Send me this session's timeline from `since` on (`sessionIDs[0]`, `since`).
    case fetchTimelineSince
    /// The human looked at the sessions in `sessionIDs` on the iPhone.
    case sessionReviewed

    // MARK: host → device
    /// One part of the index (`index`, `part`, `partCount`, `requestID`).
    case sessionIndex
    /// Summaries that changed without a timeline event (`summaries`).
    case sessionInfo
    /// One part of one whole session (`session`, `part`, `requestID`).
    case sessionFull
    /// One part of a session's timeline tail (`session`, `part`, `requestID`).
    case sessionTimeline
    /// Live events as the daemon applied them (`events`).
    case sessionMessage
    /// Sessions the daemon no longer retains (`sessionIDs`, `requestID?`).
    case sessionRemoved
    /// The daemon's health (`health`).
    case health

    public var rawValue: String {
        switch self {
        case .syncIndex: "sync_index"
        case .fetchSession: "fetch_session"
        case .fetchTimelineSince: "fetch_timeline_since"
        case .sessionReviewed: "session_reviewed"
        case .sessionIndex: "session_index"
        case .sessionInfo: "session_info"
        case .sessionFull: "session_full"
        case .sessionTimeline: "session_timeline"
        case .sessionMessage: "session_message"
        case .sessionRemoved: "session_removed"
        case .health: "health"
        }
    }
}

extension RemotePayloadKind: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = switch value {
        case "sync_index": .syncIndex
        case "fetch_session": .fetchSession
        case "fetch_timeline_since": .fetchTimelineSince
        case "session_reviewed": .sessionReviewed
        case "session_index": .sessionIndex
        case "session_info": .sessionInfo
        case "session_full": .sessionFull
        case "session_timeline": .sessionTimeline
        case "session_message": .sessionMessage
        case "session_removed": .sessionRemoved
        case "health": .health
        default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown remote payload kind: \(value)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One row of the session index: the data-layer summary plus the two raw
/// timeline facts a mirror needs to decide whether its copy is current.
public struct SessionIndexEntry: Codable, Hashable, Sendable {
    public let summary: SessionSummary
    /// `COUNT(*)` of the session's timeline rows.
    public let timelineItemCount: Int
    /// `MAX(occurred_at)` of the session's timeline rows; `nil` when empty.
    public let lastItemAt: Date?

    public init(summary: SessionSummary, timelineItemCount: Int, lastItemAt: Date?) {
        self.summary = summary
        self.timelineItemCount = timelineItemCount
        self.lastItemAt = lastItemAt
    }

    private enum CodingKeys: String, CodingKey {
        case summary
        case timelineItemCount
        case lastItemAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(SessionSummary.self, forKey: .summary)
        timelineItemCount = try c.decode(Int.self, forKey: .timelineItemCount)
        lastItemAt = try c.decodeIfPresent(Date.self, forKey: .lastItemAt)
    }
}

/// The sealed application payload. Only `kind` and `generatedAt` are always
/// present; the rest is per kind (see `RemotePayloadKind`). Multi-part
/// payloads (`sessionIndex`, `sessionFull`, `sessionTimeline`) count `part`
/// from 0; the index says `partCount`, sessions say `session.nextCursor`
/// (`nil` on the last part). Responses echo the request's `requestID`.
public struct RemoteSessionPayload: Codable, Hashable, Sendable {
    public let kind: RemotePayloadKind
    public let generatedAt: Date
    public let requestID: RequestID?
    public let sessionIDs: [SessionID]?
    public let since: Date?
    public let index: [SessionIndexEntry]?
    public let part: Int?
    public let partCount: Int?
    public let summaries: [SessionSummary]?
    public let session: SessionDetail?
    public let events: [AgentIngressEvent]?
    public let health: DaemonHealth?

    public init(
        kind: RemotePayloadKind,
        generatedAt: Date = Date(),
        requestID: RequestID? = nil,
        sessionIDs: [SessionID]? = nil,
        since: Date? = nil,
        index: [SessionIndexEntry]? = nil,
        part: Int? = nil,
        partCount: Int? = nil,
        summaries: [SessionSummary]? = nil,
        session: SessionDetail? = nil,
        events: [AgentIngressEvent]? = nil,
        health: DaemonHealth? = nil
    ) {
        self.kind = kind
        self.generatedAt = generatedAt
        self.requestID = requestID
        self.sessionIDs = sessionIDs
        self.since = since
        self.index = index
        self.part = part
        self.partCount = partCount
        self.summaries = summaries
        self.session = session
        self.events = events
        self.health = health
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case generatedAt
        case requestID
        case sessionIDs
        case since
        case index
        case part
        case partCount
        case summaries
        case session
        case events
        case health
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(RemotePayloadKind.self, forKey: .kind)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        requestID = try c.decodeIfPresent(RequestID.self, forKey: .requestID)
        sessionIDs = try c.decodeIfPresent([SessionID].self, forKey: .sessionIDs)
        since = try c.decodeIfPresent(Date.self, forKey: .since)
        index = try c.decodeIfPresent([SessionIndexEntry].self, forKey: .index)
        part = try c.decodeIfPresent(Int.self, forKey: .part)
        partCount = try c.decodeIfPresent(Int.self, forKey: .partCount)
        summaries = try c.decodeIfPresent([SessionSummary].self, forKey: .summaries)
        session = try c.decodeIfPresent(SessionDetail.self, forKey: .session)
        events = try c.decodeIfPresent([AgentIngressEvent].self, forKey: .events)
        health = try c.decodeIfPresent(DaemonHealth.self, forKey: .health)
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
