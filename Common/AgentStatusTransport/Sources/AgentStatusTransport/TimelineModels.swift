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

public struct ToolTimelinePayload: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case started
        case succeeded
        case failed
    }

    public let name: String
    public let summary: String?
    public let status: Status
    public let durationMilliseconds: Int64?

    public init(
        name: String,
        summary: String? = nil,
        status: Status,
        durationMilliseconds: Int64? = nil
    ) {
        self.name = name
        self.summary = summary
        self.status = status
        self.durationMilliseconds = durationMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case summary
        case status
        case durationMilliseconds
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

public struct UnknownTimelinePayload: Codable, Hashable, Sendable {
    public let kind: String
    public let summary: String?

    public init(kind: String, summary: String? = nil) {
        self.kind = kind
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case summary
    }
}

public enum TimelinePayload: Hashable, Sendable {
    case message(MessageTimelinePayload)
    case tool(ToolTimelinePayload)
    case plan(PlanTimelinePayload)
    case subagent(SubagentTimelinePayload)
    case error(ErrorTimelinePayload)
    case modelConfiguration(ModelConfigurationTimelinePayload)
    case internalContext(InternalContextTimelinePayload)
    case usageMetrics(UsageMetricsTimelinePayload)
    case unknown(UnknownTimelinePayload)
}

extension TimelinePayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case message
        case tool
        case plan
        case subagent
        case error
        case modelConfiguration
        case internalContext
        case usageMetrics
        case unknown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let unknown = try container.decodeIfPresent(UnknownTimelinePayload.self, forKey: .unknown)
            ?? UnknownTimelinePayload(kind: type)
        switch type {
        case "message": self = .message(try container.decode(MessageTimelinePayload.self, forKey: .message))
        case "tool": self = .tool(try container.decode(ToolTimelinePayload.self, forKey: .tool))
        case "plan": self = .plan(try container.decode(PlanTimelinePayload.self, forKey: .plan))
        case "subagent": self = .subagent(try container.decode(SubagentTimelinePayload.self, forKey: .subagent))
        case "error": self = .error(try container.decode(ErrorTimelinePayload.self, forKey: .error))
        case "model_configuration":
            self = try container.decodeIfPresent(
                ModelConfigurationTimelinePayload.self,
                forKey: .modelConfiguration
            ).map(TimelinePayload.modelConfiguration) ?? .unknown(unknown)
        case "internal_context":
            self = try container.decodeIfPresent(
                InternalContextTimelinePayload.self,
                forKey: .internalContext
            ).map(TimelinePayload.internalContext) ?? .unknown(unknown)
        case "usage_metrics":
            self = try container.decodeIfPresent(
                UsageMetricsTimelinePayload.self,
                forKey: .usageMetrics
            ).map(TimelinePayload.usageMetrics) ?? .unknown(unknown)
        default: self = .unknown(unknown)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .message(payload):
            try container.encode("message", forKey: .type)
            try container.encode(payload, forKey: .message)
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
        case let .unknown(payload):
            try container.encode(payload.kind, forKey: .type)
            try container.encode(payload, forKey: .unknown)
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
