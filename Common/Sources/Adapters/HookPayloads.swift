import Core
import Transport
import Foundation

/// Typed contracts for the hook stdin the agents write. The daemon decodes
/// the frame's raw bytes into one of these per `agent`; the helper never
/// parses. Field names drop the `hook` prefix — the context is given — and
/// the coding keys are the agents' own snake_case names.
///
/// Claude Code has renamed a few keys across versions; those fields decode
/// the observed-live key first and the documented alternative as fallback.

/// The minimal facts recoverable from a hook whose event name is outside the
/// closed vocabulary: a mis-registered hook degrades to increment-only — its
/// rich-source read window must not be lost with the frame.
public enum HookFallback {
    public static func context(data: Data) -> (sessionID: String, transcriptPath: String?, cwd: String?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = root.string("session_id"), !session.isEmpty else { return nil }
        return (session, root.string("transcript_path"), root.string("cwd"))
    }
}

/// Codex hook stdin (mirrors codex-rs hooks/schema/generated).
public struct CodexHookPayload: Sendable {
    public var eventName: HookEventName
    public var sessionID: String
    /// Codex extension: the active turn id, on every turn-scoped hook.
    public var turnID: String?
    /// Not part of the generated schema today; kept for forward compatibility.
    /// Callers fall back to the frame's `createdAt` when absent.
    public var timestamp: Date?
    public var cwd: String?
    public var model: String?
    /// SessionStart source / SessionEnd reason / compaction trigger.
    public var source: String?
    public var reason: String?
    public var trigger: String?
    public var prompt: String?
    public var toolName: String?
    public var toolUseID: String?
    public var toolInput: JSONValue?
    public var toolResponse: JSONValue?
    public var lastAssistantMessage: String?
    public var agentID: String?
    public var agentType: String?
    /// Failure markers on the payload root itself (`success: false`,
    /// `is_error`, a top-level `error` string) — some Codex builds report a
    /// tool failure there rather than inside `tool_response`.
    public var rootIndicatesFailure: Bool

    public init(data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentAdapterError.malformedJSON
        }
        guard let session = root.string("session_id"), !session.isEmpty else {
            throw AgentAdapterError.missingSessionID
        }
        guard let name = root.string("hook_event_name") ?? root.string("event_name"),
              let eventName = HookEventName(rawValue: name) else {
            throw AgentAdapterError.unsupportedEvent(
                root.string("hook_event_name") ?? root.string("event_name") ?? "missing"
            )
        }
        rootIndicatesFailure = root.containsFailure
        self.eventName = eventName
        sessionID = session
        turnID = root.string("turn_id")
        timestamp = root.date("timestamp")
        cwd = root.string("cwd")
        model = root.string("model")
        source = root.string("source")
        reason = root.string("reason")
        trigger = root.string("trigger")
        prompt = root.string("prompt")
        toolName = root.string("tool_name")
        toolUseID = root.string("tool_use_id")
        toolInput = root.jsonValue("tool_input")
        toolResponse = root.jsonValue("tool_response")
        lastAssistantMessage = root.string("last_assistant_message")
        agentID = root.string("agent_id")
        agentType = root.string("agent_type")
    }
}

/// Claude Code hook stdin (code.claude.com/docs/en/hooks).
public struct ClaudeHookPayload: Sendable {
    public var eventName: HookEventName
    public var sessionID: String
    /// Hook-only turn fallback; injected resumes mint fresh ids, so a
    /// transcript-derived turn always wins over this.
    public var promptID: String?
    public var turnNumber: Int?
    public var timestamp: Date?
    public var cwd: String?
    public var newCwd: String?
    public var oldCwd: String?
    public var transcriptPath: String?
    public var agentTranscriptPath: String?
    public var agentID: String?
    public var agentType: String?
    public var toolName: String?
    public var toolUseID: String?
    public var toolInput: JSONValue?
    /// `tool_response`, with the newer string-typed `tool_output` folded in.
    public var toolResponse: JSONValue?
    public var toolResult: JSONValue?
    public var prompt: String?
    public var lastAssistantMessage: String?
    public var model: String?
    /// SessionStart source (`how` in newer docs) / SessionEnd reason (`why`) /
    /// compaction trigger.
    public var source: String?
    public var reason: String?
    public var trigger: String?
    public var notificationType: String?
    public var error: String?
    public var errorMessage: String?
    public var errorType: String?
    /// InstructionsLoaded (`file_path`, documented as `path`).
    public var filePath: String?
    public var loadReason: String?
    /// ConfigChange source, distinct from the SessionStart `source` fallback.
    public var configSource: String?

    public init(data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentAdapterError.malformedJSON
        }
        guard let session = root.string("session_id"), !session.isEmpty else {
            throw AgentAdapterError.missingSessionID
        }
        guard let name = root.string("hook_event_name"),
              let eventName = HookEventName(rawValue: name) else {
            throw AgentAdapterError.unsupportedEvent(root.string("hook_event_name") ?? "missing")
        }
        self.eventName = eventName
        sessionID = session
        promptID = root.string("prompt_id")
        turnNumber = root.int("turn_number")
        timestamp = root.date("timestamp")
        cwd = root.string("cwd")
        newCwd = root.string("new_cwd")
        oldCwd = root.string("old_cwd")
        transcriptPath = root.string("transcript_path")
        agentTranscriptPath = root.string("agent_transcript_path")
        agentID = root.string("agent_id")
        agentType = root.string("agent_type")
        toolName = root.string("tool_name")
        toolUseID = root.string("tool_use_id")
        toolInput = root.jsonValue("tool_input")
        toolResponse = root.jsonValue("tool_response")
            ?? root.string("tool_output").map(JSONValue.string)
        toolResult = root.jsonValue("tool_result")
        prompt = root.string("prompt") ?? root.string("prompt_text")
        lastAssistantMessage = root.string("last_assistant_message")
        model = root.string("model")
        source = root.string("source") ?? root.string("how")
        reason = root.string("reason") ?? root.string("why")
        trigger = root.string("trigger")
        notificationType = root.string("notification_type")
        error = root.string("error")
        errorMessage = root.string("error_message")
        errorType = root.string("error_type")
        filePath = root.string("file_path") ?? root.string("path")
        loadReason = root.string("load_reason")
        configSource = root.string("source")
    }

    /// Claude Code forks an internal query after every Stop (a few seconds
    /// later) that fires `SubagentStop` with an empty `agent_type`, no paired
    /// `SubagentStart` and no subagent transcript. It is not a subagent of the
    /// session; folding it in would flip a finished turn back to running.
    public var isRealSubagent: Bool {
        guard let type = agentType else { return false }
        return !type.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
