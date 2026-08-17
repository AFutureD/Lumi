import AgentStatusCore
import AgentStatusTransport
import CryptoKit
import Foundation

public struct CodexAdapter: AgentAdapter {
    public let agentKind: AgentKind = .codex
    private let threads: any CodexThreadIdentityProviding

    public init(
        threads: any CodexThreadIdentityProviding = CodexThreadIdentityStore()
    ) {
        self.threads = threads
    }

    public func events(fromHookData data: Data) throws -> [AgentIngressEvent] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentAdapterError.malformedJSON
        }
        guard let session = root.string("session_id"), !session.isEmpty else {
            throw AgentAdapterError.missingSessionID
        }

        let eventName = root.string("hook_event_name") ?? root.string("event_name") ?? "Unknown"
        let sessionID = SessionID(session)
        let turnID = root.string("turn_id").map(TurnID.init)
        let occurredAt = root.date("timestamp") ?? Date()
        let eventID = EventID(Self.digest(data: data, prefix: "hook:"))
        let timelineID = TimelineItemID(eventID.rawValue + ":timeline")
        let workspace = root.string("cwd")
        let threadIdentity = threads.identity(for: sessionID)

        func event(
            lifecycle: SessionLifecycle? = nil,
            phase: TurnPhase? = nil,
            timeline: TimelinePayload? = nil
        ) -> AgentIngressEvent {
            let item = timeline.map {
                TimelineItem(
                    id: timelineID,
                    sessionID: sessionID,
                    turnID: turnID,
                    occurredAt: occurredAt,
                    payload: $0
                )
            }
            return AgentIngressEvent(
                eventID: eventID,
                sessionID: sessionID,
                turnID: turnID,
                agent: threadIdentity?.agentKind ?? .codex,
                occurredAt: occurredAt,
                title: threadIdentity?.displayTitle,
                workspace: workspace,
                lifecycle: lifecycle,
                phase: phase,
                timelineItem: item,
                lineage: threadIdentity?.lineage
            )
        }

        return switch eventName {
        case "SessionStart":
            [event(lifecycle: .starting, phase: .idle)]
        case "UserPromptSubmit":
            [event(
                lifecycle: .running,
                phase: .thinking,
                timeline: root.string("prompt").map {
                    .message(MessageTimelinePayload(role: .user, text: $0))
                }
            )]
        case "PreToolUse":
            [event(
                lifecycle: .running,
                phase: .executing,
                timeline: .tool(ToolTimelinePayload(
                    name: root.string("tool_name") ?? "Tool",
                    status: .started
                ))
            )]
        case "PostToolUse":
            [event(
                lifecycle: .running,
                phase: .responding,
                timeline: .tool(ToolTimelinePayload(
                    name: root.string("tool_name") ?? "Tool",
                    status: root.containsFailure ? .failed : .succeeded
                ))
            )]
        case "PermissionRequest":
            [event(
                lifecycle: .waitingForInput,
                phase: .waitingForApproval,
                timeline: .tool(ToolTimelinePayload(
                    name: root.string("tool_name") ?? "Tool",
                    summary: "Waiting for approval",
                    status: .started
                ))
            )]
        case "SubagentStart":
            [event(
                lifecycle: .running,
                phase: .executing,
                timeline: .subagent(SubagentTimelinePayload(
                    name: root.string("agent_type") ?? "Subagent",
                    agentSessionID: root.string("agent_id"),
                    status: .started
                ))
            )]
        case "SubagentStop":
            [event(
                lifecycle: .running,
                phase: .responding,
                timeline: .subagent(SubagentTimelinePayload(
                    name: root.string("agent_type") ?? "Subagent",
                    agentSessionID: root.string("agent_id"),
                    status: .completed
                ))
            )]
        case "Stop":
            [event(
                lifecycle: .waitingForInput,
                phase: .idle,
                timeline: root.string("last_assistant_message").map {
                    .message(MessageTimelinePayload(role: .assistant, text: $0))
                }
            )]
        case "SessionEnd":
            [event(lifecycle: .completed, phase: .idle)]
        case "PreCompact", "PostCompact":
            [event(lifecycle: .running)]
        default:
            []
        }
    }

    public func events(
        fromRolloutLine data: Data,
        context: RolloutRecordContext
    ) throws -> [AgentIngressEvent] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recordType = root.string("type"),
              let payload = root.dictionary("payload") else {
            throw AgentAdapterError.malformedJSON
        }

        let occurredAt = root.date("timestamp") ?? Date()
        let stableID = Self.digest(
            data: Data("\(context.path):\(context.byteOffset):".utf8) + data,
            prefix: "rollout:"
        )

        if recordType == "session_meta" {
            guard let rawID = payload.string("id") ?? payload.string("session_id") else {
                throw AgentAdapterError.missingSessionID
            }
            let sessionID = SessionID(rawID)
            let threadIdentity = threads.identity(for: sessionID)
            var events = [AgentIngressEvent(
                eventID: EventID(stableID),
                sessionID: sessionID,
                agent: threadIdentity?.agentKind ?? .codex,
                occurredAt: occurredAt,
                title: threadIdentity?.displayTitle,
                workspace: payload.string("cwd"),
                lifecycle: .starting,
                phase: .idle,
                lineage: threadIdentity?.lineage
            )]

            let modelKeys = [
                "model_provider", "cli_version", "source", "originator", "history_mode",
                "memory_mode", "context_window", "dynamic_tools",
            ]
            if let settings = payload.jsonValue(keys: modelKeys) {
                events.append(AgentIngressEvent(
                    eventID: EventID(stableID + ":model_configuration"),
                    sessionID: sessionID,
                    agent: threadIdentity?.agentKind ?? .codex,
                    occurredAt: occurredAt,
                    timelineItem: TimelineItem(
                        id: TimelineItemID("diagnostic:\(sessionID.rawValue):model_configuration:session_meta"),
                        sessionID: sessionID,
                        occurredAt: occurredAt,
                        payload: .modelConfiguration(ModelConfigurationTimelinePayload(
                            source: "session_meta",
                            provider: payload.string("model_provider"),
                            clientVersion: payload.string("cli_version"),
                            settings: settings
                        ))
                    )
                ))
            }

            if let baseInstructions = payload.jsonValue("base_instructions") {
                events.append(AgentIngressEvent(
                    eventID: EventID(stableID + ":internal_context:base_instructions"),
                    sessionID: sessionID,
                    agent: threadIdentity?.agentKind ?? .codex,
                    occurredAt: occurredAt,
                    timelineItem: TimelineItem(
                        id: TimelineItemID("diagnostic:\(sessionID.rawValue):internal_context:base_instructions"),
                        sessionID: sessionID,
                        occurredAt: occurredAt,
                        payload: .internalContext(InternalContextTimelinePayload(
                            kind: "base_instructions",
                            content: baseInstructions
                        ))
                    )
                ))
            }
            return events
        }

        guard let sessionID = context.sessionID else { return [] }
        let turnID = payload.string("turn_id").map(TurnID.init)
        let threadIdentity = threads.identity(for: sessionID)

        func makeEvent(
            lifecycle: SessionLifecycle? = nil,
            phase: TurnPhase? = nil,
            timeline: TimelinePayload? = nil,
            suffix: String = "",
            diagnosticKey: String? = nil
        ) -> AgentIngressEvent {
            let eventID = EventID(stableID + suffix)
            let timelineItem = timeline.map {
                TimelineItem(
                    id: diagnosticKey.map {
                        TimelineItemID("diagnostic:\(sessionID.rawValue):\($0)")
                    } ?? TimelineItemID(eventID.rawValue + ":timeline"),
                    sessionID: sessionID,
                    turnID: turnID,
                    occurredAt: occurredAt,
                    payload: $0
                )
            }
            return AgentIngressEvent(
                eventID: eventID,
                sessionID: sessionID,
                turnID: turnID,
                agent: threadIdentity?.agentKind ?? .codex,
                occurredAt: occurredAt,
                title: threadIdentity?.displayTitle,
                lifecycle: lifecycle,
                phase: phase,
                timelineItem: timelineItem,
                lineage: threadIdentity?.lineage
            )
        }

        if recordType == "turn_context" {
            var events: [AgentIngressEvent] = []
            let modelKeys = [
                "model", "effort", "personality", "collaboration_mode", "multi_agent_version",
                "realtime_active",
            ]
            if let settings = payload.jsonValue(keys: modelKeys) {
                events.append(makeEvent(
                    timeline: .modelConfiguration(ModelConfigurationTimelinePayload(
                        source: "turn_context",
                        model: payload.string("model"),
                        reasoningEffort: payload.string("effort"),
                        settings: settings
                    )),
                    suffix: ":model_configuration",
                    diagnosticKey: "model_configuration:turn_context"
                ))
            }
            if let content = try? JSONValue(jsonObject: payload) {
                events.append(makeEvent(
                    timeline: .internalContext(InternalContextTimelinePayload(
                        kind: "turn_context",
                        content: content
                    )),
                    suffix: ":internal_context",
                    diagnosticKey: "internal_context:turn_context"
                ))
            }
            return events
        }

        if recordType == "world_state" || recordType == "compacted" {
            guard let content = try? JSONValue(jsonObject: payload) else { return [] }
            let diagnosticKey: String
            if recordType == "world_state" {
                if payload.bool("full") == true {
                    diagnosticKey = "internal_context:world_state:full"
                } else {
                    let stateKeys = payload.dictionary("state")?.keys.sorted().joined(separator: ",") ?? "unknown"
                    let keyDigest = Self.digest(data: Data(stateKeys.utf8), prefix: "")
                    diagnosticKey = "internal_context:world_state:delta:\(keyDigest)"
                }
            } else {
                diagnosticKey = "internal_context:compacted"
            }
            return [makeEvent(
                timeline: .internalContext(InternalContextTimelinePayload(
                    kind: recordType,
                    content: content
                )),
                suffix: ":internal_context",
                diagnosticKey: diagnosticKey
            )]
        }

        if recordType == "event_msg", let type = payload.string("type") {
            switch type {
            case "user_message":
                guard let message = payload.string("message"), !message.isEmpty else { return [] }
                return [makeEvent(
                    lifecycle: .running,
                    phase: .thinking,
                    timeline: .message(MessageTimelinePayload(role: .user, text: message))
                )]
            case "agent_message":
                guard let message = payload.string("message"), !message.isEmpty else { return [] }
                return [makeEvent(
                    lifecycle: .running,
                    phase: .responding,
                    timeline: .message(MessageTimelinePayload(role: .assistant, text: message))
                )]
            case "task_started":
                return [makeEvent(lifecycle: .running, phase: .thinking)]
            case "agent_reasoning", "context_compacted":
                guard let content = try? JSONValue(jsonObject: payload) else { return [] }
                return [makeEvent(
                    timeline: .internalContext(InternalContextTimelinePayload(
                        kind: type,
                        content: content
                    )),
                    suffix: ":internal_context",
                    diagnosticKey: "internal_context:\(type)"
                )]
            case "thread_settings_applied":
                guard let settingsDictionary = payload.dictionary("thread_settings"),
                      let settings = try? JSONValue(jsonObject: settingsDictionary) else { return [] }
                return [makeEvent(
                    timeline: .modelConfiguration(ModelConfigurationTimelinePayload(
                        source: "thread_settings_applied",
                        model: settingsDictionary.string("model"),
                        provider: settingsDictionary.string("model_provider_id"),
                        reasoningEffort: settingsDictionary.string("reasoning_effort"),
                        settings: settings
                    )),
                    suffix: ":model_configuration",
                    diagnosticKey: "model_configuration:thread_settings"
                )]
            case "token_count":
                let info = payload.dictionary("info")
                let last = info?.dictionary("last_token_usage").map(TokenUsage.init(codexPayload:))
                let total = info?.dictionary("total_token_usage").map(TokenUsage.init(codexPayload:))
                let rateLimits = payload.jsonValue("rate_limits")
                guard last != nil || total != nil || info?.int64("model_context_window") != nil || rateLimits != nil else {
                    return []
                }
                return [makeEvent(
                    timeline: .usageMetrics(UsageMetricsTimelinePayload(
                        last: last,
                        total: total,
                        modelContextWindow: info?.int64("model_context_window"),
                        rateLimits: rateLimits
                    )),
                    suffix: ":usage_metrics",
                    diagnosticKey: "usage_metrics"
                )]
            case "task_complete":
                if let error = payload.string("error"), !error.isEmpty {
                    return [makeEvent(
                        lifecycle: .failed,
                        phase: .idle,
                        timeline: .error(ErrorTimelinePayload(
                            title: "Codex turn failed",
                            message: error,
                            recoverable: true
                        ))
                    )]
                }
                return [makeEvent(lifecycle: .waitingForInput, phase: .idle)]
            case "turn_aborted":
                return [makeEvent(
                    lifecycle: .interrupted,
                    phase: .idle,
                    timeline: .error(ErrorTimelinePayload(
                        title: "Turn interrupted",
                        message: payload.string("reason") ?? "The Codex turn was interrupted.",
                        recoverable: true
                    ))
                )]
            case "exec_command_begin":
                return [makeEvent(
                    lifecycle: .running,
                    phase: .executing,
                    timeline: .tool(ToolTimelinePayload(name: "Shell command", status: .started))
                )]
            case "exec_command_end":
                let succeeded = (payload.int("exit_code") ?? 0) == 0
                return [makeEvent(
                    lifecycle: .running,
                    phase: .responding,
                    timeline: .tool(ToolTimelinePayload(
                        name: "Shell command",
                        status: succeeded ? .succeeded : .failed,
                        durationMilliseconds: payload.durationMilliseconds
                    ))
                )]
            case "patch_apply_begin":
                return [makeEvent(
                    lifecycle: .running,
                    phase: .executing,
                    timeline: .tool(ToolTimelinePayload(name: "Apply patch", status: .started))
                )]
            case "patch_apply_end":
                return [makeEvent(
                    lifecycle: .running,
                    phase: .responding,
                    timeline: .tool(ToolTimelinePayload(
                        name: "Apply patch",
                        status: payload.bool("success") == false ? .failed : .succeeded,
                        durationMilliseconds: payload.durationMilliseconds
                    ))
                )]
            case "dynamic_tool_call_request":
                return [makeEvent(
                    lifecycle: .running,
                    phase: .executing,
                    timeline: .tool(ToolTimelinePayload(
                        name: payload.string("tool") ?? "Tool",
                        status: .started
                    ))
                )]
            case "dynamic_tool_call_response":
                return [makeEvent(
                    lifecycle: .running,
                    phase: .responding,
                    timeline: .tool(ToolTimelinePayload(
                        name: payload.string("tool") ?? "Tool",
                        status: payload.bool("success") == false ? .failed : .succeeded,
                        durationMilliseconds: payload.durationMilliseconds
                    ))
                )]
            case "mcp_tool_call_begin":
                return [makeEvent(
                    lifecycle: .running,
                    phase: .executing,
                    timeline: .tool(ToolTimelinePayload(name: "MCP tool", status: .started))
                )]
            case "mcp_tool_call_end":
                return [makeEvent(
                    lifecycle: .running,
                    phase: .responding,
                    timeline: .tool(ToolTimelinePayload(
                        name: payload.dictionary("invocation")?.string("tool") ?? "MCP tool",
                        status: payload.containsFailure ? .failed : .succeeded,
                        durationMilliseconds: payload.durationMilliseconds
                    ))
                )]
            case "sub_agent_activity":
                let kind = payload.string("kind") ?? "started"
                let status: SubagentTimelinePayload.Status = switch kind {
                case "completed", "stopped": .completed
                case "failed": .failed
                case "waiting": .waiting
                default: .started
                }
                return [makeEvent(
                    lifecycle: .running,
                    phase: status == .started ? .executing : .responding,
                    timeline: .subagent(SubagentTimelinePayload(
                        name: payload.string("agent_path") ?? "Subagent",
                        agentSessionID: payload.string("agent_thread_id"),
                        status: status
                    ))
                )]
            case "web_search_begin", "image_generation_begin":
                let name = type == "web_search_begin" ? "Web search" : "Image generation"
                return [makeEvent(
                    lifecycle: .running,
                    phase: .executing,
                    timeline: .tool(ToolTimelinePayload(name: name, status: .started))
                )]
            case "web_search_end", "image_generation_end", "view_image_tool_call":
                let name = type == "web_search_end" ? "Web search" : (type == "image_generation_end" ? "Image generation" : "View image")
                return [makeEvent(
                    lifecycle: .running,
                    phase: .responding,
                    timeline: .tool(ToolTimelinePayload(
                        name: name,
                        status: payload.containsFailure ? .failed : .succeeded,
                        durationMilliseconds: payload.durationMilliseconds
                    ))
                )]
            default:
                return []
            }
        }

        if recordType == "response_item",
           payload.string("type") == "custom_tool_call",
           payload.string("name") == "update_plan",
           let input = payload.string("input"),
           let inputData = input.data(using: .utf8),
           let planRoot = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any],
           let rawSteps = planRoot["plan"] as? [[String: Any]] {
            let steps = rawSteps.compactMap { step -> PlanTimelinePayload.Step? in
                guard let text = step.string("step") else { return nil }
                let status: PlanTimelinePayload.Step.Status = switch step.string("status") {
                case "in_progress": .inProgress
                case "completed": .completed
                default: .pending
                }
                return PlanTimelinePayload.Step(text: text, status: status)
            }
            return [makeEvent(
                lifecycle: .running,
                phase: .thinking,
                timeline: .plan(PlanTimelinePayload(
                    explanation: planRoot.string("explanation"),
                    steps: steps
                ))
            )]
        }

        if recordType == "response_item", payload.string("type") == "reasoning",
           let content = try? JSONValue(jsonObject: payload) {
            return [makeEvent(
                timeline: .internalContext(InternalContextTimelinePayload(
                    kind: "reasoning",
                    content: content
                )),
                suffix: ":internal_context",
                diagnosticKey: "internal_context:reasoning"
            )]
        }

        // Unknown rollout records remain excluded until their shape and privacy
        // boundary are explicitly modeled.
        return []
    }

    private static func digest(data: Data, prefix: String) -> String {
        prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

}

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        self[key] as? String
    }

    func dictionary(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func bool(_ key: String) -> Bool? {
        self[key] as? Bool
    }

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
        return try? Date(value, strategy: .iso8601)
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

private extension TokenUsage {
    init(codexPayload payload: [String: Any]) {
        self.init(
            inputTokens: payload.int64("input_tokens") ?? 0,
            cachedInputTokens: payload.int64("cached_input_tokens") ?? 0,
            cacheWriteInputTokens: payload.int64("cache_write_input_tokens") ?? 0,
            outputTokens: payload.int64("output_tokens") ?? 0,
            reasoningOutputTokens: payload.int64("reasoning_output_tokens") ?? 0,
            totalTokens: payload.int64("total_tokens") ?? 0
        )
    }
}
