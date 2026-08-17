import Foundation

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
    public let timelineItem: TimelineItem?
    public let lineage: SessionLineage?

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
        timelineItem: TimelineItem? = nil,
        lineage: SessionLineage? = nil
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
        self.timelineItem = timelineItem
        self.lineage = lineage
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
        case timelineItem
        case lineage
    }
}

public enum IPCOperation: Hashable, Sendable {
    case ingest
    case listSessions
    case getSession
    case deleteSession
    case snapshotSessions
    case subscribe
    case health
    case clearHistory
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .ingest: "ingest"
        case .listSessions: "list_sessions"
        case .getSession: "get_session"
        case .deleteSession: "delete_session"
        case .snapshotSessions: "snapshot_sessions"
        case .subscribe: "subscribe"
        case .health: "health"
        case .clearHistory: "clear_history"
        case let .unknown(value): value
        }
    }
}

extension IPCOperation: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = switch value {
        case "ingest": .ingest
        case "list_sessions": .listSessions
        case "get_session": .getSession
        case "delete_session": .deleteSession
        case "snapshot_sessions": .snapshotSessions
        case "subscribe": .subscribe
        case "health": .health
        case "clear_history": .clearHistory
        default: .unknown(value)
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
    public let sessionID: SessionID?
    public let cursor: PaginationCursor?
    public let limit: Int?

    public init(
        operation: IPCOperation,
        event: AgentIngressEvent? = nil,
        sessionID: SessionID? = nil,
        cursor: PaginationCursor? = nil,
        limit: Int? = nil
    ) {
        self.operation = operation
        self.event = event
        self.sessionID = sessionID
        self.cursor = cursor
        self.limit = limit
    }

    private enum CodingKeys: String, CodingKey {
        case operation
        case event
        case sessionID
        case cursor
        case limit
    }
}

public enum IPCResponseStatus: String, Codable, Hashable, Sendable {
    case ok
    case accepted
    case error
}

public struct DaemonHealth: Codable, Hashable, Sendable {
    public let daemonVersion: String
    public let uptimeSeconds: Int64
    public let activeSessionCount: Int
    public let retainedSessionCount: Int
    public let socketPath: String
    public let relayConnected: Bool

    public init(
        daemonVersion: String,
        uptimeSeconds: Int64,
        activeSessionCount: Int,
        retainedSessionCount: Int,
        socketPath: String,
        relayConnected: Bool
    ) {
        self.daemonVersion = daemonVersion
        self.uptimeSeconds = uptimeSeconds
        self.activeSessionCount = activeSessionCount
        self.retainedSessionCount = retainedSessionCount
        self.socketPath = socketPath
        self.relayConnected = relayConnected
    }

    private enum CodingKeys: String, CodingKey {
        case daemonVersion
        case uptimeSeconds
        case activeSessionCount
        case retainedSessionCount
        case socketPath
        case relayConnected
    }
}

public struct IPCFailure: Codable, Hashable, Sendable, Error {
    public let code: String
    public let message: String
    public let retryable: Bool

    public init(code: String, message: String, retryable: Bool) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }

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
    public let sessionDetails: [SessionDetail]?
    public let health: DaemonHealth?
    public let event: AgentIngressEvent?
    public let failure: IPCFailure?

    public init(
        status: IPCResponseStatus,
        sessions: [SessionSummary]? = nil,
        session: SessionDetail? = nil,
        sessionDetails: [SessionDetail]? = nil,
        health: DaemonHealth? = nil,
        event: AgentIngressEvent? = nil,
        failure: IPCFailure? = nil
    ) {
        self.status = status
        self.sessions = sessions
        self.session = session
        self.sessionDetails = sessionDetails
        self.health = health
        self.event = event
        self.failure = failure
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case sessions
        case session
        case sessionDetails
        case health
        case event
        case failure
    }
}
