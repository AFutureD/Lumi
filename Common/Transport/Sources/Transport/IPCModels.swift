import Foundation

/// One Agent-domain event from the helper to the daemon. Carries any subset of:
/// session identity, session lifecycle, turn aggregate, and one timeline item.
/// The helper's verdict on whether a session is kept at all. `.discard`: the
/// session ended before its first Turn (a desktop config-loading probe, or a
/// launch that was quit before any prompt) — repositories delete it and
/// tombstone the id. The event is still published so every mirror converges.
public enum SessionDisposition: String, Codable, Hashable, Sendable {
    case discard
}

public struct AgentIngressEvent: Codable, Hashable, Sendable {
    public let eventID: EventID
    public let sessionID: SessionID
    public let turnID: TurnID?
    public let agent: AgentKind
    public let occurredAt: Date
    public let title: String?
    public let workspace: String?
    public let lifecycle: SessionLifecycle?
    public let phase: TurnPhase?
    public let turn: TurnSummary?
    public let timelineItem: TimelineItem?
    public let lineage: SessionLineage?
    public let disposition: SessionDisposition?

    public init(
        eventID: EventID,
        sessionID: SessionID,
        turnID: TurnID? = nil,
        agent: AgentKind,
        occurredAt: Date,
        title: String? = nil,
        workspace: String? = nil,
        lifecycle: SessionLifecycle? = nil,
        phase: TurnPhase? = nil,
        turn: TurnSummary? = nil,
        timelineItem: TimelineItem? = nil,
        lineage: SessionLineage? = nil,
        disposition: SessionDisposition? = nil
    ) {
        self.eventID = eventID
        self.sessionID = sessionID
        self.turnID = turnID
        self.agent = agent
        self.occurredAt = occurredAt
        self.title = title
        self.workspace = workspace
        self.lifecycle = lifecycle
        self.phase = phase
        self.turn = turn
        self.timelineItem = timelineItem
        self.lineage = lineage
        self.disposition = disposition
    }

    private enum CodingKeys: String, CodingKey {
        case eventID
        case sessionID
        case turnID
        case agent
        case occurredAt
        case title
        case workspace
        case lifecycle
        case phase
        case turn
        case timelineItem
        case lineage
        case disposition
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try c.decode(EventID.self, forKey: .eventID)
        sessionID = try c.decode(SessionID.self, forKey: .sessionID)
        turnID = try c.decodeIfPresent(TurnID.self, forKey: .turnID)
        agent = try c.decode(AgentKind.self, forKey: .agent)
        occurredAt = try c.decode(Date.self, forKey: .occurredAt)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace)
        lifecycle = try c.decodeIfPresent(SessionLifecycle.self, forKey: .lifecycle)
        phase = try c.decodeIfPresent(TurnPhase.self, forKey: .phase)
        turn = try c.decodeIfPresent(TurnSummary.self, forKey: .turn)
        timelineItem = try c.decodeIfPresent(TimelineItem.self, forKey: .timelineItem)
        lineage = try c.decodeIfPresent(SessionLineage.self, forKey: .lineage)
        disposition = try c.decodeIfPresent(SessionDisposition.self, forKey: .disposition)
    }
}

/// Byte-offset watermark into an agent transcript / rollout file. Owned by
/// the daemon; the helper reads and advances it over IPC.
public struct RolloutCursor: Codable, Hashable, Sendable {
    public let path: String
    public let byteOffset: UInt64
    public let fileSize: UInt64
    public let sessionID: SessionID?
    public let updatedAt: Date

    public init(
        path: String,
        byteOffset: UInt64,
        fileSize: UInt64,
        sessionID: SessionID? = nil,
        updatedAt: Date = Date()
    ) {
        self.path = path
        self.byteOffset = byteOffset
        self.fileSize = fileSize
        self.sessionID = sessionID
        self.updatedAt = updatedAt
    }
}

public enum IPCOperation: Hashable, Sendable {
    case ingest
    case ingestBatch
    case listSessions
    case getSession
    case deleteSession
    case markSessionReviewed
    case markSessionHiddenInNotch
    case subscribe
    case health
    case clearHistory
    case getRolloutCursor
    case saveRolloutCursor
    case reingestSession
    /// The helper found a session the daemon has no cursor for and a history
    /// too large to replay inside a hook: the daemon rebuilds it off the hook
    /// path, from the given transcript / rollout file.
    case backfillSession
    case relayStatus
    case relayRevokeDevice
    case relayRemoveDevice
    case relayRefreshDevices
    case relayPairingStart
    case relayPairingState
    case relayPairingDecide
    case relayPairingCancel

    public var rawValue: String {
        switch self {
        case .ingest: "ingest"
        case .ingestBatch: "ingest_batch"
        case .listSessions: "list_sessions"
        case .getSession: "get_session"
        case .deleteSession: "delete_session"
        case .markSessionReviewed: "mark_session_reviewed"
        case .markSessionHiddenInNotch: "mark_session_hidden_in_notch"
        case .subscribe: "subscribe"
        case .health: "health"
        case .clearHistory: "clear_history"
        case .getRolloutCursor: "get_rollout_cursor"
        case .saveRolloutCursor: "save_rollout_cursor"
        case .reingestSession: "reingest_session"
        case .backfillSession: "backfill_session"
        case .relayStatus: "relay_status"
        case .relayRevokeDevice: "relay_revoke_device"
        case .relayRemoveDevice: "relay_remove_device"
        case .relayRefreshDevices: "relay_refresh_devices"
        case .relayPairingStart: "relay_pairing_start"
        case .relayPairingState: "relay_pairing_state"
        case .relayPairingDecide: "relay_pairing_decide"
        case .relayPairingCancel: "relay_pairing_cancel"
        }
    }
}

extension IPCOperation: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = switch value {
        case "ingest": .ingest
        case "ingest_batch": .ingestBatch
        case "list_sessions": .listSessions
        case "get_session": .getSession
        case "delete_session": .deleteSession
        case "mark_session_reviewed": .markSessionReviewed
        case "mark_session_hidden_in_notch": .markSessionHiddenInNotch
        case "subscribe": .subscribe
        case "health": .health
        case "clear_history": .clearHistory
        case "get_rollout_cursor": .getRolloutCursor
        case "save_rollout_cursor": .saveRolloutCursor
        case "reingest_session": .reingestSession
        case "backfill_session": .backfillSession
        case "relay_status": .relayStatus
        case "relay_revoke_device": .relayRevokeDevice
        case "relay_remove_device": .relayRemoveDevice
        case "relay_refresh_devices": .relayRefreshDevices
        case "relay_pairing_start": .relayPairingStart
        case "relay_pairing_state": .relayPairingState
        case "relay_pairing_decide": .relayPairingDecide
        case "relay_pairing_cancel": .relayPairingCancel
        default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown IPC operation: \(value)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct IPCRequest: Codable, Hashable, Sendable {
    public let operation: IPCOperation
    public let event: AgentIngressEvent?
    public let events: [AgentIngressEvent]?
    public let sessionID: SessionID?
    public let cursor: PaginationCursor?
    public let limit: Int?
    public let path: String?
    public let rolloutCursor: RolloutCursor?
    /// `relay_revoke_device` / `relay_remove_device`: the paired iPhone.
    public let deviceID: DeviceID?
    /// `relay_pairing_decide`: Match (`true`) or Don't match (`false`).
    public let approved: Bool?

    public init(
        operation: IPCOperation,
        event: AgentIngressEvent? = nil,
        events: [AgentIngressEvent]? = nil,
        sessionID: SessionID? = nil,
        cursor: PaginationCursor? = nil,
        limit: Int? = nil,
        path: String? = nil,
        rolloutCursor: RolloutCursor? = nil,
        deviceID: DeviceID? = nil,
        approved: Bool? = nil
    ) {
        self.operation = operation
        self.event = event
        self.events = events
        self.sessionID = sessionID
        self.cursor = cursor
        self.limit = limit
        self.path = path
        self.rolloutCursor = rolloutCursor
        self.deviceID = deviceID
        self.approved = approved
    }

    private enum CodingKeys: String, CodingKey {
        case operation
        case event
        case events
        case sessionID
        case cursor
        case limit
        case path
        case rolloutCursor
        case deviceID
        case approved
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operation = try c.decode(IPCOperation.self, forKey: .operation)
        event = try c.decodeIfPresent(AgentIngressEvent.self, forKey: .event)
        events = try c.decodeIfPresent([AgentIngressEvent].self, forKey: .events)
        sessionID = try c.decodeIfPresent(SessionID.self, forKey: .sessionID)
        cursor = try c.decodeIfPresent(PaginationCursor.self, forKey: .cursor)
        limit = try c.decodeIfPresent(Int.self, forKey: .limit)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        rolloutCursor = try c.decodeIfPresent(RolloutCursor.self, forKey: .rolloutCursor)
        deviceID = try c.decodeIfPresent(DeviceID.self, forKey: .deviceID)
        approved = try c.decodeIfPresent(Bool.self, forKey: .approved)
    }
}

public enum IPCResponseStatus: String, Codable, Hashable, Sendable {
    case ok
    case accepted
    case error
}

public struct DaemonHealth: Codable, Hashable, Sendable {
    public let daemonVersion: String
    /// SHA-256 of the daemon's own executable, computed once at daemon startup.
    /// Optional on purpose: `nil` means the running daemon predates
    /// fingerprinting and is therefore stale — a required field would make the
    /// app fail to decode exactly the health message it needs to detect that.
    public let executableHash: String?
    public let uptimeSeconds: Int64
    public let activeSessionCount: Int
    public let retainedSessionCount: Int
    public let socketPath: String
    public let relayConnected: Bool

    public init(
        daemonVersion: String,
        executableHash: String?,
        uptimeSeconds: Int64,
        activeSessionCount: Int,
        retainedSessionCount: Int,
        socketPath: String,
        relayConnected: Bool
    ) {
        self.daemonVersion = daemonVersion
        self.executableHash = executableHash
        self.uptimeSeconds = uptimeSeconds
        self.activeSessionCount = activeSessionCount
        self.retainedSessionCount = retainedSessionCount
        self.socketPath = socketPath
        self.relayConnected = relayConnected
    }

    private enum CodingKeys: String, CodingKey {
        case daemonVersion
        case executableHash
        case uptimeSeconds
        case activeSessionCount
        case retainedSessionCount
        case socketPath
        case relayConnected
    }
}

public struct IPCFailure: Codable, Hashable, Sendable, Error, LocalizedError {
    public let code: String
    public let message: String
    public let retryable: Bool

    public init(code: String, message: String, retryable: Bool) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }

    public var errorDescription: String? { message }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case retryable
    }
}

public struct IPCResponse: Codable, Hashable, Sendable {
    public let status: IPCResponseStatus
    public let sessions: [SessionSummary]?
    public let session: SessionDetail?
    public let health: DaemonHealth?
    public let event: AgentIngressEvent?
    /// Stream frame: a summary-only change (reviewed, archived) on the
    /// daemon's side, possibly made from another end (an iPhone).
    public let summary: SessionSummary?
    public let acceptedCount: Int?
    public let rolloutCursor: RolloutCursor?
    public let failure: IPCFailure?
    /// `relay_status` / `relay_refresh_devices` / `relay_revoke_device`.
    public let relay: RelayHostStatus?
    /// `relay_pairing_start` / `relay_pairing_state` / `relay_pairing_decide`:
    /// the daemon's live pairing session, `nil` when there is none.
    public let pairing: RelayPairingSession?

    public init(
        status: IPCResponseStatus,
        sessions: [SessionSummary]? = nil,
        session: SessionDetail? = nil,
        health: DaemonHealth? = nil,
        event: AgentIngressEvent? = nil,
        summary: SessionSummary? = nil,
        acceptedCount: Int? = nil,
        rolloutCursor: RolloutCursor? = nil,
        failure: IPCFailure? = nil,
        relay: RelayHostStatus? = nil,
        pairing: RelayPairingSession? = nil
    ) {
        self.status = status
        self.sessions = sessions
        self.session = session
        self.health = health
        self.event = event
        self.summary = summary
        self.acceptedCount = acceptedCount
        self.rolloutCursor = rolloutCursor
        self.failure = failure
        self.relay = relay
        self.pairing = pairing
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case sessions
        case session
        case health
        case event
        case summary
        case acceptedCount
        case rolloutCursor
        case failure
        case relay
        case pairing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(IPCResponseStatus.self, forKey: .status)
        sessions = try c.decodeIfPresent([SessionSummary].self, forKey: .sessions)
        session = try c.decodeIfPresent(SessionDetail.self, forKey: .session)
        health = try c.decodeIfPresent(DaemonHealth.self, forKey: .health)
        event = try c.decodeIfPresent(AgentIngressEvent.self, forKey: .event)
        summary = try c.decodeIfPresent(SessionSummary.self, forKey: .summary)
        acceptedCount = try c.decodeIfPresent(Int.self, forKey: .acceptedCount)
        rolloutCursor = try c.decodeIfPresent(RolloutCursor.self, forKey: .rolloutCursor)
        failure = try c.decodeIfPresent(IPCFailure.self, forKey: .failure)
        relay = try c.decodeIfPresent(RelayHostStatus.self, forKey: .relay)
        pairing = try c.decodeIfPresent(RelayPairingSession.self, forKey: .pairing)
    }
}
