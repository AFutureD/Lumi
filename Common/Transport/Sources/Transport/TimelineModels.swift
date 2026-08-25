import Foundation

public struct MessageTimelinePayload: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Hashable, Sendable {
        case user
        case assistant
    }

    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case text
    }
}

/// One tool message. `started` is the *call* (PreToolUse / `assistant.tool_use`);
/// `succeeded` / `failed` is the *result* (PostToolUse / `user.tool_result`).
/// Call and result are separate timeline items paired by `toolUseID`.
public struct ToolTimelinePayload: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case started
        case succeeded
        case failed
    }

    public let name: String
    /// One-line rendering for the activity list row.
    public let summary: String?
    /// The complete raw input (started) or result (succeeded / failed) as it
    /// appeared at the source — what the Raw Data view shows.
    public let content: JSONValue?
    public let status: Status
    public let durationMilliseconds: Int64?
    public let toolUseID: String?

    public init(
        name: String,
        summary: String? = nil,
        content: JSONValue? = nil,
        status: Status,
        durationMilliseconds: Int64? = nil,
        toolUseID: String? = nil
    ) {
        self.name = name
        self.summary = summary
        self.content = content
        self.status = status
        self.durationMilliseconds = durationMilliseconds
        self.toolUseID = toolUseID
    }

    public var isCall: Bool { status == .started }
    public var isResult: Bool { status != .started }

    private enum CodingKeys: String, CodingKey {
        case name
        case summary
        case content
        case status
        case durationMilliseconds
        case toolUseID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        content = try c.decodeIfPresent(JSONValue.self, forKey: .content)
        status = try c.decode(Status.self, forKey: .status)
        durationMilliseconds = try c.decodeIfPresent(Int64.self, forKey: .durationMilliseconds)
        toolUseID = try c.decodeIfPresent(String.self, forKey: .toolUseID)
    }
}

/// Model reasoning / thinking text (Claude `thinking` block, Codex reasoning).
public struct ReasoningTimelinePayload: Codable, Hashable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// Context injected into the model that the user did not type: instructions
/// files, attachments, system reminders, hook-injected context, expanded
/// skills, compaction summaries. Always turn-level.
public struct ContextTimelinePayload: Codable, Hashable, Sendable {
    public let kind: String
    public let summary: String?
    public let content: JSONValue?

    public init(kind: String, summary: String? = nil, content: JSONValue? = nil) {
        self.kind = kind
        self.summary = summary
        self.content = content
    }
}

/// How the agent runs rather than what it reads: settings files, working
/// directory, model / effort / sandbox of a turn.
public struct ConfigTimelinePayload: Codable, Hashable, Sendable {
    public let kind: String
    public let summary: String?
    public let content: JSONValue?

    public init(kind: String, summary: String? = nil, content: JSONValue? = nil) {
        self.kind = kind
        self.summary = summary
        self.content = content
    }
}

/// Session lifecycle boundary rendered as a full-width marker row.
public struct SessionMarkerTimelinePayload: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case sessionStarted = "session_started"
        case sessionEnded = "session_ended"
        case compactionStarted = "compaction_started"
        case compactionEnded = "compaction_ended"
    }

    public let kind: Kind
    /// `source` for start, `reason` for end, `trigger` for compaction.
    public let detail: String?
    public let model: String?

    public init(kind: Kind, detail: String? = nil, model: String? = nil) {
        self.kind = kind
        self.detail = detail
        self.model = model
    }
}

/// Closes a turn (Stop hook / `task_complete` / `turn_aborted`).
public struct TurnEndTimelinePayload: Codable, Hashable, Sendable {
    public let outcome: TurnOutcome
    public let message: String?

    public init(outcome: TurnOutcome, message: String? = nil) {
        self.outcome = outcome
        self.message = message
    }
}

public struct PlanTimelinePayload: Codable, Hashable, Sendable {
    public struct Step: Codable, Hashable, Sendable {
        public enum Status: String, Codable, Hashable, Sendable {
            case pending
            case inProgress = "in_progress"
            case completed
        }

        public let text: String
        public let status: Status

        public init(text: String, status: Status) {
            self.text = text
            self.status = status
        }
    }

    public let explanation: String?
    public let steps: [Step]

    public init(explanation: String? = nil, steps: [Step]) {
        self.explanation = explanation
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey {
        case explanation
        case steps
    }
}

public struct SubagentTimelinePayload: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case started
        case waiting
        case completed
        case failed
    }

    public let name: String
    public let agentSessionID: String?
    public let status: Status

    public init(name: String, agentSessionID: String? = nil, status: Status) {
        self.name = name
        self.agentSessionID = agentSessionID
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case agentSessionID
        case status
    }
}

public struct ErrorTimelinePayload: Codable, Hashable, Sendable {
    public let title: String
    public let message: String
    public let recoverable: Bool

    public init(title: String, message: String, recoverable: Bool) {
        self.title = title
        self.message = message
        self.recoverable = recoverable
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case message
        case recoverable
    }
}

public struct ModelConfigurationTimelinePayload: Codable, Hashable, Sendable {
    public let source: String
    public let model: String?
    public let provider: String?
    public let contextWindow: Int64?
    public let reasoningEffort: String?
    public let clientVersion: String?
    public let settings: JSONValue

    public init(
        source: String,
        model: String? = nil,
        provider: String? = nil,
        contextWindow: Int64? = nil,
        reasoningEffort: String? = nil,
        clientVersion: String? = nil,
        settings: JSONValue
    ) {
        self.source = source
        self.model = model
        self.provider = provider
        self.contextWindow = contextWindow
        self.reasoningEffort = reasoningEffort
        self.clientVersion = clientVersion
        self.settings = settings
    }
}

public struct InternalContextTimelinePayload: Codable, Hashable, Sendable {
    public let kind: String
    public let content: JSONValue

    public init(kind: String, content: JSONValue) {
        self.kind = kind
        self.content = content
    }
}

public struct TokenUsage: Codable, Hashable, Sendable {
    public let inputTokens: Int64
    public let cachedInputTokens: Int64
    public let cacheWriteInputTokens: Int64
    public let outputTokens: Int64
    public let reasoningOutputTokens: Int64
    public let totalTokens: Int64

    public init(
        inputTokens: Int64 = 0,
        cachedInputTokens: Int64 = 0,
        cacheWriteInputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        reasoningOutputTokens: Int64 = 0,
        totalTokens: Int64 = 0
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }
}

public struct UsageMetricsTimelinePayload: Codable, Hashable, Sendable {
    public let last: TokenUsage?
    public let total: TokenUsage?
    public let modelContextWindow: Int64?
    public let rateLimits: JSONValue?

    public init(
        last: TokenUsage? = nil,
        total: TokenUsage? = nil,
        modelContextWindow: Int64? = nil,
        rateLimits: JSONValue? = nil
    ) {
        self.last = last
        self.total = total
        self.modelContextWindow = modelContextWindow
        self.rateLimits = rateLimits
    }
}

public enum TimelinePayload: Hashable, Sendable {
    case message(MessageTimelinePayload)
    case reasoning(ReasoningTimelinePayload)
    case tool(ToolTimelinePayload)
    case plan(PlanTimelinePayload)
    case subagent(SubagentTimelinePayload)
    case error(ErrorTimelinePayload)
    case context(ContextTimelinePayload)
    case config(ConfigTimelinePayload)
    case sessionMarker(SessionMarkerTimelinePayload)
    case turnEnd(TurnEndTimelinePayload)
    case modelConfiguration(ModelConfigurationTimelinePayload)
    case internalContext(InternalContextTimelinePayload)
    case usageMetrics(UsageMetricsTimelinePayload)
}

extension TimelinePayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case message
        case reasoning
        case tool
        case plan
        case subagent
        case error
        case context
        case config
        case sessionMarker
        case turnEnd
        case modelConfiguration
        case internalContext
        case usageMetrics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "message": self = .message(try container.decode(MessageTimelinePayload.self, forKey: .message))
        case "reasoning": self = .reasoning(try container.decode(ReasoningTimelinePayload.self, forKey: .reasoning))
        case "tool": self = .tool(try container.decode(ToolTimelinePayload.self, forKey: .tool))
        case "plan": self = .plan(try container.decode(PlanTimelinePayload.self, forKey: .plan))
        case "subagent": self = .subagent(try container.decode(SubagentTimelinePayload.self, forKey: .subagent))
        case "error": self = .error(try container.decode(ErrorTimelinePayload.self, forKey: .error))
        case "context": self = .context(try container.decode(ContextTimelinePayload.self, forKey: .context))
        case "config": self = .config(try container.decode(ConfigTimelinePayload.self, forKey: .config))
        case "session_marker": self = .sessionMarker(try container.decode(SessionMarkerTimelinePayload.self, forKey: .sessionMarker))
        case "turn_end": self = .turnEnd(try container.decode(TurnEndTimelinePayload.self, forKey: .turnEnd))
        case "model_configuration":
            self = .modelConfiguration(try container.decode(ModelConfigurationTimelinePayload.self, forKey: .modelConfiguration))
        case "internal_context":
            self = .internalContext(try container.decode(InternalContextTimelinePayload.self, forKey: .internalContext))
        case "usage_metrics":
            self = .usageMetrics(try container.decode(UsageMetricsTimelinePayload.self, forKey: .usageMetrics))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown timeline payload type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .message(payload):
            try container.encode("message", forKey: .type)
            try container.encode(payload, forKey: .message)
        case let .reasoning(payload):
            try container.encode("reasoning", forKey: .type)
            try container.encode(payload, forKey: .reasoning)
        case let .context(payload):
            try container.encode("context", forKey: .type)
            try container.encode(payload, forKey: .context)
        case let .config(payload):
            try container.encode("config", forKey: .type)
            try container.encode(payload, forKey: .config)
        case let .sessionMarker(payload):
            try container.encode("session_marker", forKey: .type)
            try container.encode(payload, forKey: .sessionMarker)
        case let .turnEnd(payload):
            try container.encode("turn_end", forKey: .type)
            try container.encode(payload, forKey: .turnEnd)
        case let .tool(payload):
            try container.encode("tool", forKey: .type)
            try container.encode(payload, forKey: .tool)
        case let .plan(payload):
            try container.encode("plan", forKey: .type)
            try container.encode(payload, forKey: .plan)
        case let .subagent(payload):
            try container.encode("subagent", forKey: .type)
            try container.encode(payload, forKey: .subagent)
        case let .error(payload):
            try container.encode("error", forKey: .type)
            try container.encode(payload, forKey: .error)
        case let .modelConfiguration(payload):
            try container.encode("model_configuration", forKey: .type)
            try container.encode(payload, forKey: .modelConfiguration)
        case let .internalContext(payload):
            try container.encode("internal_context", forKey: .type)
            try container.encode(payload, forKey: .internalContext)
        case let .usageMetrics(payload):
            try container.encode("usage_metrics", forKey: .type)
            try container.encode(payload, forKey: .usageMetrics)
        }
    }
}

public struct TimelineItem: Codable, Hashable, Sendable {
    public let id: TimelineItemID
    public let sessionID: SessionID
    public let turnID: TurnID?
    public let occurredAt: Date
    public let payload: TimelinePayload

    public init(
        id: TimelineItemID,
        sessionID: SessionID,
        turnID: TurnID? = nil,
        occurredAt: Date,
        payload: TimelinePayload
    ) {
        self.id = id
        self.sessionID = sessionID
        self.turnID = turnID
        self.occurredAt = occurredAt
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID
        case turnID
        case occurredAt
        case payload
    }
}
