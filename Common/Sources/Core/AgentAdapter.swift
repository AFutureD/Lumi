import Transport
import Foundation

public struct RolloutRecordContext: Hashable, Sendable {
    public let path: String
    public let byteOffset: UInt64
    public let sessionID: SessionID?

    public init(path: String, byteOffset: UInt64, sessionID: SessionID? = nil) {
        self.path = path
        self.byteOffset = byteOffset
        self.sessionID = sessionID
    }
}

/// Mutable state carried across the lines of one transcript / rollout read.
/// Most records do not carry a turn id; the reader assigns the current one.
public struct RolloutReadState: Hashable, Sendable {
    public var currentTurnID: TurnID?
    /// `tool_use_id` → tool name, so results can be labelled like their call.
    public var toolNames: [String: String]
    /// Newest tool-call id whose call has been seen but not its result.
    public var openToolUseIDs: [String]
    /// The most recent resolved `occurredAt` seen in this read, real or
    /// inherited. A record with no `timestamp` field falls back to this
    /// instead of wall-clock `Date()`: during a replay of a historical file,
    /// "now" is never the right time for an untimed record, and stamping it
    /// with the ingestion moment can leave it later than every event that
    /// follows in the file, which then reads as out of order.
    public var lastTimestamp: Date?
    /// Channel arbitration: fact family → highest source priority that has
    /// produced rows in this read. Once a family emitted from a higher
    /// priority source, records from lower ones are dropped entirely.
    public var channelPriorities: [String: Int]

    public init(
        currentTurnID: TurnID? = nil,
        toolNames: [String: String] = [:],
        openToolUseIDs: [String] = [],
        lastTimestamp: Date? = nil,
        channelPriorities: [String: Int] = [:]
    ) {
        self.currentTurnID = currentTurnID
        self.toolNames = toolNames
        self.openToolUseIDs = openToolUseIDs
        self.lastTimestamp = lastTimestamp
        self.channelPriorities = channelPriorities
    }
}

/// How a hook payload should be reduced.
public struct HookIngestOptions: Hashable, Sendable {
    /// When the transcript / rollout channel is being read for this session,
    /// hooks only drive lifecycle, phase, turn boundaries and session markers;
    /// message and tool items come from the richer channel to avoid duplicates.
    public var richSourceAvailable: Bool
    /// Set by the pipeline on a session-ending hook when the daemon still
    /// holds the session as provisional (no Turn ever) and no transcript was
    /// written: the adapter then emits a discard instead of a session end.
    public var sessionNeverUsed: Bool
    /// The Turn the transcript reader holds open (or last held) for this
    /// session, set by the pipeline from the increment it just read. With the
    /// rich source available, hook events attach to this Turn — the hook's
    /// own `prompt_id` changes on injected resumes and would mint ghost Turns.
    public var currentTurnID: TurnID?
    /// When the hook frame was created (the helper's clock). Fallback
    /// `occurredAt` for payloads that carry no `timestamp` of their own.
    public var receivedAt: Date

    public init(
        richSourceAvailable: Bool = false,
        sessionNeverUsed: Bool = false,
        currentTurnID: TurnID? = nil,
        receivedAt: Date = Date()
    ) {
        self.richSourceAvailable = richSourceAvailable
        self.sessionNeverUsed = sessionNeverUsed
        self.currentTurnID = currentTurnID
        self.receivedAt = receivedAt
    }

    public static let hookOnly = HookIngestOptions(richSourceAvailable: false)
    public static let withRichSource = HookIngestOptions(richSourceAvailable: true)
}

/// The rollout / transcript side of an adapter. Hook reduction is typed per
/// provider (`CodexHookPayload` / `ClaudeHookPayload`) and lives on the
/// concrete adapters — providers share no hook payload shape.
public protocol AgentAdapter: Sendable {
    var agentKind: AgentKind { get }

    func events(
        fromRolloutLine data: Data,
        context: RolloutRecordContext,
        state: inout RolloutReadState
    ) throws -> [AgentIngressEvent]
}

public extension AgentAdapter {
    func events(fromRolloutLine data: Data, context: RolloutRecordContext) throws -> [AgentIngressEvent] {
        var state = RolloutReadState()
        return try events(fromRolloutLine: data, context: context, state: &state)
    }
}

public enum AgentAdapterError: Error, Equatable, Sendable {
    case malformedJSON
    case missingSessionID
    case unsupportedEvent(String)
}

/// Deterministic timeline item ids shared by every adapter, so the same
/// logical message arriving over two channels (hook + transcript) collapses
/// into one stored item.
public enum TimelineItemIDs {
    public static func sessionMarker(_ session: SessionID, _ kind: SessionMarkerTimelinePayload.Kind, discriminator: String? = nil) -> TimelineItemID {
        TimelineItemID("marker:\(session.rawValue):\(kind.rawValue)" + (discriminator.map { ":\($0)" } ?? ""))
    }

    public static func toolCall(_ session: SessionID, toolUseID: String) -> TimelineItemID {
        TimelineItemID("tool:\(session.rawValue):\(toolUseID):call")
    }

    public static func toolResult(_ session: SessionID, toolUseID: String) -> TimelineItemID {
        TimelineItemID("tool:\(session.rawValue):\(toolUseID):result")
    }

    public static func subagent(_ session: SessionID, agentID: String, phase: String) -> TimelineItemID {
        TimelineItemID("subagent:\(session.rawValue):\(agentID):\(phase)")
    }

    public static func turnEnd(_ session: SessionID, turnID: TurnID) -> TimelineItemID {
        TimelineItemID("turn_end:\(session.rawValue):\(turnID.rawValue)")
    }

    public static func userPrompt(_ session: SessionID, turnID: TurnID) -> TimelineItemID {
        TimelineItemID("user_prompt:\(session.rawValue):\(turnID.rawValue)")
    }

    public static func diagnostic(_ session: SessionID, key: String) -> TimelineItemID {
        TimelineItemID("diagnostic:\(session.rawValue):\(key)")
    }
}

/// Shared JSON helpers for adapters reading `[String: Any]` payloads.
public extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func dictionary(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func array(_ key: String) -> [Any]? { self[key] as? [Any] }
    func bool(_ key: String) -> Bool? { self[key] as? Bool }

    func int(_ key: String) -> Int? {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? NSNumber { return value.intValue }
        return nil
    }

    func int64(_ key: String) -> Int64? {
        if let value = self[key] as? Int64 { return value }
        if let value = self[key] as? Int { return Int64(value) }
        if let value = self[key] as? NSNumber { return value.int64Value }
        return nil
    }

    func jsonValue(_ key: String) -> JSONValue? {
        guard let value = self[key] else { return nil }
        return try? JSONValue(jsonObject: value)
    }

    func jsonValue(keys: [String]) -> JSONValue? {
        let values = keys.reduce(into: [String: JSONValue]()) { result, key in
            if let value = jsonValue(key) { result[key] = value }
        }
        return values.isEmpty ? nil : .object(values)
    }

    func date(_ key: String) -> Date? {
        guard let value = string(key) else { return nil }
        return AdapterDates.parse(value)
    }

    var containsFailure: Bool {
        if bool("success") == false { return true }
        if bool("is_error") == true { return true }
        if self["error"] is String { return true }
        if dictionary("result")?.bool("isError") == true { return true }
        return false
    }

    var durationMilliseconds: Int64? {
        if let milliseconds = self["duration_ms"] as? NSNumber {
            return milliseconds.int64Value
        }
        if let seconds = self["duration"] as? NSNumber {
            return Int64(seconds.doubleValue * 1_000)
        }
        return nil
    }
}

public enum AdapterDates {
    /// ISO-8601 with or without fractional seconds (`…29.893Z` / `…29Z`).
    public static func parse(_ value: String) -> Date? {
        if let date = try? Date(value, strategy: .iso8601.year().month().day()
            .timeZone(separator: .omitted).time(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(value, strategy: .iso8601)
    }
}

public enum AdapterText {
    /// First non-empty line, whitespace-collapsed, capped — for tool input /
    /// output excerpts and context summaries.
    public static func excerpt(_ value: String?, maximumCharacters: Int = 160) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= maximumCharacters { return collapsed }
        return String(collapsed.prefix(maximumCharacters)) + "…"
    }

    /// Compact one-line rendering of a tool input dictionary (`command`,
    /// `file_path`, `pattern`, … first; falls back to sorted keys).
    public static func summary(ofToolInput input: Any?) -> String? {
        guard let input else { return nil }
        if let text = input as? String { return excerpt(text) }
        guard let dictionary = input as? [String: Any] else { return nil }
        for key in ["command", "cmd", "file_path", "path", "pattern", "query", "url", "prompt", "description", "input", "text"] {
            if let value = dictionary[key] as? String, !value.isEmpty { return excerpt(value) }
            if let values = dictionary[key] as? [String], !values.isEmpty { return excerpt(values.joined(separator: " ")) }
        }
        let keys = dictionary.keys.sorted().prefix(4).joined(separator: ", ")
        return keys.isEmpty ? nil : keys
    }
}
