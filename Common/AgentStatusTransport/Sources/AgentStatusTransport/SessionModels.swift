import Foundation

public enum AgentKind: Hashable, Sendable {
    case codex
    case codexSubagent
    case claude
    case claudeSubagent
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .codex: "codex"
        case .codexSubagent: "codex_subagent"
        case .claude: "claude"
        case .claudeSubagent: "claude_subagent"
        case let .unknown(value): value
        }
    }

    /// The provider family regardless of parent/subagent role.
    public var provider: AgentProvider {
        switch self {
        case .codex, .codexSubagent: .codex
        case .claude, .claudeSubagent: .claude
        case .unknown: .unknown
        }
    }

    public var isSubagent: Bool {
        switch self {
        case .codexSubagent, .claudeSubagent: true
        case .codex, .claude, .unknown: false
        }
    }
}

public enum AgentProvider: String, Codable, Hashable, Sendable {
    case codex
    case claude
    case unknown
}

extension AgentKind: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = switch value {
        case "codex": .codex
        case "codex_subagent": .codexSubagent
        case "claude": .claude
        case "claude_subagent": .claudeSubagent
        default: .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Session-level lifecycle (Agent domain, layer A).
/// `waitingForInput` doubles as "idle between turns"; `completed` is "ended".
public enum SessionLifecycle: Hashable, Sendable {
    case starting
    case running
    case waitingForInput
    case compacting
    case completed
    case failed
    case interrupted
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .starting: "starting"
        case .running: "running"
        case .waitingForInput: "waiting_for_input"
        case .compacting: "compacting"
        case .completed: "completed"
        case .failed: "failed"
        case .interrupted: "interrupted"
        case let .unknown(value): value
        }
    }

    /// True while the agent process is expected to still be alive.
    public var isLive: Bool {
        switch self {
        case .starting, .running, .waitingForInput, .compacting: true
        case .completed, .failed, .interrupted, .unknown: false
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
        case "compacting": .compacting
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

/// Turn-level phase (Agent domain, layer A). `idle` means no turn is in flight.
public enum TurnPhase: Hashable, Sendable {
    case idle
    case thinking
    case executing
    case responding
    case waitingForApproval
    case subagentRunning
    case compacting
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .idle: "idle"
        case .thinking: "thinking"
        case .executing: "executing"
        case .responding: "responding"
        case .waitingForApproval: "waiting_for_approval"
        case .subagentRunning: "subagent_running"
        case .compacting: "compacting"
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
        case "subagent_running": .subagentRunning
        case "compacting": .compacting
        default: .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// How a turn ended. `nil` on `TurnSummary` means the turn is still open.
public enum TurnOutcome: String, Codable, Hashable, Sendable {
    case completed
    case failed
    case aborted
}

/// Agent-domain Turn aggregate. Produced by the helper, merged by the daemon
/// (later fields win; counters take the maximum), read by clients.
public struct TurnSummary: Codable, Hashable, Sendable {
    public let id: TurnID
    public let sessionID: SessionID
    public let index: Int?
    public let phase: TurnPhase
    public let prompt: String?
    public let startedAt: Date
    public let endedAt: Date?
    public let outcome: TurnOutcome?
    public let toolCallCount: Int
    public let subagentCount: Int
    public let lastAssistantMessage: String?

    public init(
        id: TurnID,
        sessionID: SessionID,
        index: Int? = nil,
        phase: TurnPhase,
        prompt: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        outcome: TurnOutcome? = nil,
        toolCallCount: Int = 0,
        subagentCount: Int = 0,
        lastAssistantMessage: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.index = index
        self.phase = phase
        self.prompt = prompt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.toolCallCount = toolCallCount
        self.subagentCount = subagentCount
        self.lastAssistantMessage = lastAssistantMessage
    }

    public var isOpen: Bool { endedAt == nil && outcome == nil }

    /// Folds a newer partial update into the stored aggregate.
    public func merging(_ update: TurnSummary) -> TurnSummary {
        TurnSummary(
            id: id,
            sessionID: sessionID,
            index: update.index ?? index,
            phase: update.phase,
            prompt: update.prompt ?? prompt,
            startedAt: min(startedAt, update.startedAt),
            endedAt: update.endedAt ?? endedAt,
            outcome: update.outcome ?? outcome,
            toolCallCount: max(toolCallCount, update.toolCallCount),
            subagentCount: max(subagentCount, update.subagentCount),
            lastAssistantMessage: update.lastAssistantMessage ?? lastAssistantMessage
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, index, phase, prompt, startedAt, endedAt, outcome
        case toolCallCount, subagentCount, lastAssistantMessage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(TurnID.self, forKey: .id)
        sessionID = try c.decode(SessionID.self, forKey: .sessionID)
        index = try c.decodeIfPresent(Int.self, forKey: .index)
        phase = try c.decodeIfPresent(TurnPhase.self, forKey: .phase) ?? .idle
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        outcome = try c.decodeIfPresent(TurnOutcome.self, forKey: .outcome)
        toolCallCount = try c.decodeIfPresent(Int.self, forKey: .toolCallCount) ?? 0
        subagentCount = try c.decodeIfPresent(Int.self, forKey: .subagentCount) ?? 0
        lastAssistantMessage = try c.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
    }
}

public struct SessionLineage: Codable, Hashable, Sendable {
    public let threadSource: String?
    public let parentSessionID: SessionID?
    public let subagentDepth: Int?
    public let agentNickname: String?
    public let agentRole: String?
    public let agentPath: String?
    public let subagentKind: String?

    public init(
        threadSource: String? = nil,
        parentSessionID: SessionID? = nil,
        subagentDepth: Int? = nil,
        agentNickname: String? = nil,
        agentRole: String? = nil,
        agentPath: String? = nil,
        subagentKind: String? = nil
    ) {
        self.threadSource = threadSource
        self.parentSessionID = parentSessionID
        self.subagentDepth = subagentDepth
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.agentPath = agentPath
        self.subagentKind = subagentKind
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
    public let lineage: SessionLineage?

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
        needsAttention: Bool = false,
        lineage: SessionLineage? = nil
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
        self.lineage = lineage
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
        case lineage
    }
}

public struct SessionDetail: Codable, Hashable, Sendable {
    public let summary: SessionSummary
    public let turns: [TurnSummary]
    public let timeline: [TimelineItem]
    public let nextCursor: PaginationCursor?

    public init(
        summary: SessionSummary,
        turns: [TurnSummary] = [],
        timeline: [TimelineItem],
        nextCursor: PaginationCursor? = nil
    ) {
        self.summary = summary
        self.turns = turns
        self.timeline = timeline
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey {
        case summary
        case turns
        case timeline
        case nextCursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(SessionSummary.self, forKey: .summary)
        turns = try c.decodeIfPresent([TurnSummary].self, forKey: .turns) ?? []
        timeline = try c.decodeIfPresent([TimelineItem].self, forKey: .timeline) ?? []
        nextCursor = try c.decodeIfPresent(PaginationCursor.self, forKey: .nextCursor)
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
