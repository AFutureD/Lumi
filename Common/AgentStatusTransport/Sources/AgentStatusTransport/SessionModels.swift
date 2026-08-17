import Foundation

public enum AgentKind: Hashable, Sendable {
    case codex
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .codex: "codex"
        case let .unknown(value): value
        }
    }
}

extension AgentKind: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = value == "codex" ? .codex : .unknown(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum SessionLifecycle: Hashable, Sendable {
    case starting
    case running
    case waitingForInput
    case completed
    case failed
    case interrupted
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .starting: "starting"
        case .running: "running"
        case .waitingForInput: "waiting_for_input"
        case .completed: "completed"
        case .failed: "failed"
        case .interrupted: "interrupted"
        case let .unknown(value): value
        }
    }
}

extension SessionLifecycle: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = switch value {
        case "starting": .starting
        case "running": .running
        case "waiting_for_input": .waitingForInput
        case "completed": .completed
        case "failed": .failed
        case "interrupted": .interrupted
        default: .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum TurnPhase: Hashable, Sendable {
    case idle
    case thinking
    case executing
    case responding
    case waitingForApproval
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .idle: "idle"
        case .thinking: "thinking"
        case .executing: "executing"
        case .responding: "responding"
        case .waitingForApproval: "waiting_for_approval"
        case let .unknown(value): value
        }
    }
}

extension TurnPhase: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = switch value {
        case "idle": .idle
        case "thinking": .thinking
        case "executing": .executing
        case "responding": .responding
        case "waiting_for_approval": .waitingForApproval
        default: .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct SessionSummary: Codable, Hashable, Sendable {
    public let id: SessionID
    public let agent: AgentKind
    public let title: String
    public let workspace: String?
    public let lifecycle: SessionLifecycle
    public let phase: TurnPhase
    public let startedAt: Date
    public let updatedAt: Date
    public let lastActivityAt: Date
    public let needsAttention: Bool

    public init(
        id: SessionID,
        agent: AgentKind,
        title: String,
        workspace: String? = nil,
        lifecycle: SessionLifecycle,
        phase: TurnPhase,
        startedAt: Date,
        updatedAt: Date,
        lastActivityAt: Date,
        needsAttention: Bool = false
    ) {
        self.id = id
        self.agent = agent
        self.title = title
        self.workspace = workspace
        self.lifecycle = lifecycle
        self.phase = phase
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.lastActivityAt = lastActivityAt
        self.needsAttention = needsAttention
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case agent
        case title
        case workspace
        case lifecycle
        case phase
        case startedAt
        case updatedAt
        case lastActivityAt
        case needsAttention
    }
}

public struct SessionDetail: Codable, Hashable, Sendable {
    public let summary: SessionSummary
    public let timeline: [TimelineItem]
    public let nextCursor: PaginationCursor?

    public init(
        summary: SessionSummary,
        timeline: [TimelineItem],
        nextCursor: PaginationCursor? = nil
    ) {
        self.summary = summary
        self.timeline = timeline
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey {
        case summary
        case timeline
        case nextCursor
    }
}

public struct PaginationCursor: Codable, Hashable, Sendable {
    public let value: String

    public init(value: String) {
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case value
    }
}
