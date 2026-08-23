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

/// A paired iPhone as the Relay lists it, plus the daemon's verdict on its
/// key. `keyVerified` is set by the daemon once the key the Relay reports is
/// the one the daemon pinned when the Mac approved the pairing (the key the
/// Numeric Comparison covered). Unverified devices get no frames; the Mac
/// shows them as such.
public struct PairedDevice: Codable, Hashable, Sendable {
    public let id: DeviceID
    public let name: String
    public let publicKey: Data
    public let keyVerified: Bool
    public let pairedAt: Date
    public let revokedAt: Date?

    public init(
        id: DeviceID,
        name: String,
        publicKey: Data,
        keyVerified: Bool = false,
        pairedAt: Date,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.keyVerified = keyVerified
        self.pairedAt = pairedAt
        self.revokedAt = revokedAt
    }

    public func withKeyVerified(_ verified: Bool) -> PairedDevice {
        PairedDevice(id: id, name: name, publicKey: publicKey, keyVerified: verified, pairedAt: pairedAt, revokedAt: revokedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case publicKey
        case keyVerified
        case pairedAt
        case revokedAt
    }
}

// MARK: - Pairing v2 (code + Numeric Comparison)

/// Where one pairing session is, as the Relay reports it.
public enum PairingSessionState: String, Codable, Hashable, Sendable {
    /// The Mac created it; the code is on screen and unclaimed.
    case offered
    /// An iPhone spent the code and knows the session.
    case claimed
    /// The iPhone submitted its identity and public key.
    case submitted
    /// The Mac revealed its nonce; both ends can show the SAS.
    case revealed
    /// The Mac pressed Match: the device is paired and has a token.
    case approved
    /// The Mac pressed Don't match (or did nothing for 60 s).
    case rejected
    /// Either end cancelled.
    case cancelled
    /// Nobody finished in time.
    case expired

    public var isTerminal: Bool {
        switch self {
        case .approved, .rejected, .cancelled, .expired: true
        case .offered, .claimed, .submitted, .revealed: false
        }
    }
}

/// An iPhone that submitted itself to the Mac's live pairing session: what
/// the Mac shows above the Match / Don't match buttons.
public struct RelayPairingPending: Codable, Hashable, Sendable {
    public let deviceID: DeviceID
    public let deviceName: String
    /// Six decimal digits, zero-padded (`"482913"`); the Mac shows `482 913`.
    public let sas: String
    public let receivedAt: Date

    public init(deviceID: DeviceID, deviceName: String, sas: String, receivedAt: Date) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.sas = sas
        self.receivedAt = receivedAt
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID
        case deviceName
        case sas
        case receivedAt
    }
}

/// How the last pairing attempt on this session ended: the Mac pressed Match
/// or Don't match (or let the 60 s pass). An iPhone cancelling leaves no
/// outcome — the session is simply gone and a fresh code starts.
public enum RelayPairingOutcomeKind: String, Codable, Hashable, Sendable {
    case approved
    case rejected
}

/// How the last pairing attempt on this session ended (the Mac shows the
/// result in place of the pending card for a moment).
public struct RelayPairingOutcome: Codable, Hashable, Sendable {
    public let kind: RelayPairingOutcomeKind
    public let deviceName: String
    public let at: Date

    public init(kind: RelayPairingOutcomeKind, deviceName: String, at: Date) {
        self.kind = kind
        self.deviceName = deviceName
        self.at = at
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case deviceName
        case at
    }
}

/// The daemon's live pairing session as the Mac app shows it
/// (`relay_pairing_start` / `relay_pairing_state`). The code is the only
/// thing a person types; the Relay URL is what the Mac's daemon is on.
public struct RelayPairingSession: Codable, Hashable, Sendable {
    public let sessionID: String
    /// Six Crockford Base32 characters (`"7KF3QP"`); shown as `7KF 3QP`.
    public let code: String
    public let relayURL: URL
    public let expiresAt: Date
    public let pending: RelayPairingPending?
    public let outcome: RelayPairingOutcome?

    public init(
        sessionID: String,
        code: String,
        relayURL: URL,
        expiresAt: Date,
        pending: RelayPairingPending? = nil,
        outcome: RelayPairingOutcome? = nil
    ) {
        self.sessionID = sessionID
        self.code = code
        self.relayURL = relayURL
        self.expiresAt = expiresAt
        self.pending = pending
        self.outcome = outcome
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case code
        case relayURL
        case expiresAt
        case pending
        case outcome
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        code = try c.decode(String.self, forKey: .code)
        relayURL = try c.decode(URL.self, forKey: .relayURL)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        pending = try c.decodeIfPresent(RelayPairingPending.self, forKey: .pending)
        outcome = try c.decodeIfPresent(RelayPairingOutcome.self, forKey: .outcome)
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
