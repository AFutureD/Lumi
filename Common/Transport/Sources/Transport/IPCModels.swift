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
    public var eventID: EventID
    public var sessionID: SessionID
    public var turnID: TurnID?
    public var agent: AgentKind
    public var occurredAt: Date
    public var title: String?
    public var workspace: String?
    public var lifecycle: SessionLifecycle?
    public var phase: TurnPhase?
    public var turn: TurnSummary?
    public var timelineItem: TimelineItem?
    public var lineage: SessionLineage?
    /// AaaS ownership asserted by the hook path; events from other sources
    /// (watchers, replays) carry `nil` and never clear a stored ownership.
    public var aaas: SessionAaaS?
    public var disposition: SessionDisposition?

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
        aaas: SessionAaaS? = nil,
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
        self.aaas = aaas
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
        case aaas
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
        aaas = try c.decodeIfPresent(SessionAaaS.self, forKey: .aaas)
        disposition = try c.decodeIfPresent(SessionDisposition.self, forKey: .disposition)
    }
}

/// Byte-offset watermark into an agent transcript / rollout file. Owned and
/// advanced exclusively by the daemon (hook-triggered catch-up, watchers,
/// backfill); it never crosses the IPC surface.
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
    /// One hook invocation, forwarded verbatim by the helper: the raw stdin
    /// bytes plus the agent kind and a whitelisted environment subset. The
    /// daemon does all parsing and domain reduction.
    case ingestHook
    case listSessions
    case getSession
    case deleteSession
    case markSessionReviewed
    case markSessionHiddenInNotch
    case subscribe
    case health
    case clearHistory
    case reingestSession
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
        case .ingestHook: "ingest_hook"
        case .listSessions: "list_sessions"
        case .getSession: "get_session"
        case .deleteSession: "delete_session"
        case .markSessionReviewed: "mark_session_reviewed"
        case .markSessionHiddenInNotch: "mark_session_hidden_in_notch"
        case .subscribe: "subscribe"
        case .health: "health"
        case .clearHistory: "clear_history"
        case .reingestSession: "reingest_session"
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
        case "ingest_hook": .ingestHook
        case "list_sessions": .listSessions
        case "get_session": .getSession
        case "delete_session": .deleteSession
        case "mark_session_reviewed": .markSessionReviewed
        case "mark_session_hidden_in_notch": .markSessionHiddenInNotch
        case "subscribe": .subscribe
        case "health": .health
        case "clear_history": .clearHistory
        case "reingest_session": .reingestSession
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
    public let sessionID: SessionID?
    public let cursor: PaginationCursor?
    public let limit: Int?
    /// `ingest_hook`: frame creation time (RFC 3339 on the wire). Observes
    /// forwarding latency and is the fallback clock for payloads that carry
    /// no `timestamp` of their own.
    public let createdAt: Date?
    /// `ingest_hook`: which agent's hook fired, from the helper's `--agent`.
    public let agent: AgentProvider?
    /// `ingest_hook`: whitelisted environment subset of the hook process.
    /// Never the whole environment — it carries API keys.
    public let env: [String: String]?
    /// `ingest_hook`: the hook's stdin, verbatim. Hook event IDs are a
    /// SHA-256 of these exact bytes, so no re-encoding is allowed. The
    /// helper's own `hook_frame` log carries a JSON rendering; the frame
    /// itself ships the bytes once.
    public let data: Data?
    /// `relay_revoke_device` / `relay_remove_device`: the paired iPhone.
    public let deviceID: DeviceID?
    /// `relay_pairing_decide`: Match (`true`) or Don't match (`false`).
    public let approved: Bool?

    public init(
        operation: IPCOperation,
        sessionID: SessionID? = nil,
        cursor: PaginationCursor? = nil,
        limit: Int? = nil,
        createdAt: Date? = nil,
        agent: AgentProvider? = nil,
        env: [String: String]? = nil,
        data: Data? = nil,
        deviceID: DeviceID? = nil,
        approved: Bool? = nil
    ) {
        self.operation = operation
        self.sessionID = sessionID
        self.cursor = cursor
        self.limit = limit
        self.createdAt = createdAt
        self.agent = agent
        self.env = env
        self.data = data
        self.deviceID = deviceID
        self.approved = approved
    }

    private enum CodingKeys: String, CodingKey {
        case operation
        case sessionID
        case cursor
        case limit
        case createdAt
        case agent
        case env
        case data
        case deviceID
        case approved
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operation = try c.decode(IPCOperation.self, forKey: .operation)
        sessionID = try c.decodeIfPresent(SessionID.self, forKey: .sessionID)
        cursor = try c.decodeIfPresent(PaginationCursor.self, forKey: .cursor)
        limit = try c.decodeIfPresent(Int.self, forKey: .limit)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        agent = try c.decodeIfPresent(AgentProvider.self, forKey: .agent)
        env = try c.decodeIfPresent([String: String].self, forKey: .env)
        data = try c.decodeIfPresent(Data.self, forKey: .data)
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
        failure = try c.decodeIfPresent(IPCFailure.self, forKey: .failure)
        relay = try c.decodeIfPresent(RelayHostStatus.self, forKey: .relay)
        pairing = try c.decodeIfPresent(RelayPairingSession.self, forKey: .pairing)
    }
}
