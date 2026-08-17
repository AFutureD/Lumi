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
        case unknown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        self = switch type {
        case "message": .message(try container.decode(MessageTimelinePayload.self, forKey: .message))
        case "tool": .tool(try container.decode(ToolTimelinePayload.self, forKey: .tool))
        case "plan": .plan(try container.decode(PlanTimelinePayload.self, forKey: .plan))
        case "subagent": .subagent(try container.decode(SubagentTimelinePayload.self, forKey: .subagent))
        case "error": .error(try container.decode(ErrorTimelinePayload.self, forKey: .error))
        default: .unknown(
            try container.decodeIfPresent(UnknownTimelinePayload.self, forKey: .unknown)
                ?? UnknownTimelinePayload(kind: type)
        )
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
