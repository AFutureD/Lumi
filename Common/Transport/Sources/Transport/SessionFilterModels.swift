import Foundation

// Session filter rules: the daemon-owned settings that hide ghost sessions.
// A session is hidden when ANY enabled rule matches; within a rule EVERY
// condition must match. The verdict is evaluated once per session — when its
// first Turn begins — and then frozen on `SessionSummary.hiddenByFilter`;
// editing rules never re-evaluates existing sessions.
//
// These types cross the daemon ↔ Mac IPC boundary (get/set operations) and
// are persisted by the daemon, so they live in Transport. Not to be confused
// with the Activity timeline filter (`SessionActivityFilter` on the Mac),
// which is display-time and per-view.

public struct SessionFilterRuleID: TypedIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// What a condition inspects. Every field reads session identity that is
/// settled by the time the first Turn begins.
public enum SessionFilterField: Hashable, Sendable {
    /// The agent engine (`AgentProvider` raw values: "codex" / "claude").
    case agent
    /// The owning AaaS (`AaaSKind` raw values for `is`; free text matched
    /// case-insensitively against the display name for `contains`). Sessions
    /// without ownership (watcher-created) never match this field.
    case application
    /// The session's first user message.
    case message
    /// The session workspace: one absolute path, matched as a path prefix
    /// (the folder itself and everything under it).
    case folder

    public var rawValue: String {
        switch self {
        case .agent: "agent"
        case .application: "application"
        case .message: "message"
        case .folder: "folder"
        }
    }

    /// The operators a condition on this field may carry, first one is the
    /// editor default. The daemon rejects rules outside this table.
    public var allowedOperators: [SessionFilterOperator] {
        switch self {
        case .agent, .application: [.is, .contains]
        case .message: [.contains, .startsWith]
        case .folder: [.is]
        }
    }
}

extension SessionFilterField: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = switch value {
        case "agent": .agent
        case "application": .application
        case "message": .message
        case "folder": .folder
        default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown filter field: \(value)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum SessionFilterOperator: Hashable, Sendable {
    case `is`
    case contains
    case startsWith

    public var rawValue: String {
        switch self {
        case .is: "is"
        case .contains: "contains"
        case .startsWith: "starts_with"
        }
    }
}

extension SessionFilterOperator: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = switch value {
        case "is": .is
        case "contains": .contains
        case "starts_with": .startsWith
        default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown filter operator: \(value)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A condition value: single text (`is` on folder, message text) or a list of
/// options (`contains` on the enum fields, where the values are OR-ed).
/// Encodes as a bare string or a bare array — the shape is the tag.
public enum SessionFilterValue: Hashable, Sendable {
    case text(String)
    case options([String])

    /// An empty value never matches anything (the editor allows saving one).
    public var isEmpty: Bool {
        switch self {
        case .text(let value): value.isEmpty
        case .options(let values): values.allSatisfy(\.isEmpty)
        }
    }
}

extension SessionFilterValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let options = try? container.decode([String].self) {
            self = .options(options)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Filter value is neither a string nor an array of strings")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .options(let values): try container.encode(values)
        }
    }
}

public struct SessionFilterCondition: Codable, Hashable, Sendable {
    public var field: SessionFilterField
    public var op: SessionFilterOperator
    public var value: SessionFilterValue

    public init(field: SessionFilterField, op: SessionFilterOperator, value: SessionFilterValue) {
        self.field = field
        self.op = op
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case field
        case op
        case value
    }
}

public struct SessionFilterRule: Codable, Hashable, Sendable, Identifiable {
    public let id: SessionFilterRuleID
    /// A disabled rule is kept but never evaluated.
    public var isEnabled: Bool
    public var conditions: [SessionFilterCondition]

    public init(
        id: SessionFilterRuleID = SessionFilterRuleID(),
        isEnabled: Bool = true,
        conditions: [SessionFilterCondition]
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.conditions = conditions
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case isEnabled
        case conditions
    }
}
