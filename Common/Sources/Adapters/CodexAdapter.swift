import Core
import Transport
import CryptoKit
import Foundation

/// Reduces Codex hook payloads and rollout JSONL records into Agent-domain
/// events (`AgentIngressEvent`: lifecycle, phase, turn, timeline item).
public struct CodexAdapter: AgentAdapter {
    public let agentKind: AgentKind = .codex
    private let threads: any CodexThreadIdentityProviding

    public init(
        threads: any CodexThreadIdentityProviding = CodexThreadIdentityStore()
    ) {
        self.threads = threads
    }

    /// A user-visible fact that more than one rollout channel can carry:
    /// `item_completed` items from 0.149, their `event_msg` twins before.
    /// Within one family, the first channel to emit wins for the rest of the
    /// read (channels never coexist per file, so this is protection, not
    /// selection — see §3.3 of docs/research/codex-event-mapping.md).
    enum FactFamily: String {
        case assistantMessage
        case userMessage
        case reasoning
        case subagentActivity
        case mcpCall
        case fileChange
        case webSearch
        case imageView
    }

    // MARK: - Hooks

    public func events(fromHookData data: Data, options: HookIngestOptions) throws -> [AgentIngressEvent] {
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
        let workspace = root.string("cwd")
        let model = root.string("model")
        let threadIdentity = threads.identity(for: sessionID)
        let rich = options.richSourceAvailable

        func event(
            lifecycle: SessionLifecycle? = nil,
            phase: TurnPhase? = nil,
            turn: TurnSummary? = nil,
            timeline: TimelinePayload? = nil,
            itemID: TimelineItemID? = nil
        ) -> AgentIngressEvent {
            let item = timeline.map {
                TimelineItem(
                    id: itemID ?? TimelineItemID(eventID.rawValue + ":timeline"),
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
                turn: turn,
                timelineItem: item,
                lineage: threadIdentity?.lineage
            )
        }

        func turnUpdate(
            phase: TurnPhase,
            prompt: String? = nil,
            endedAt: Date? = nil,
            outcome: TurnOutcome? = nil,
            lastAssistantMessage: String? = nil
        ) -> TurnSummary? {
            guard let turnID else { return nil }
            return TurnSummary(
                id: turnID,
                sessionID: sessionID,
                phase: phase,
                prompt: prompt,
                startedAt: occurredAt,
                endedAt: endedAt,
                outcome: outcome,
                lastAssistantMessage: lastAssistantMessage
            )
        }

        let toolName = root.string("tool_name") ?? "Tool"
        let toolUseID = root.string("tool_use_id")

        switch eventName {
        case "SessionStart":
            return [event(
                lifecycle: .starting,
                phase: .idle,
                timeline: .sessionMarker(SessionMarkerTimelinePayload(
                    kind: .sessionStarted,
                    detail: root.string("source"),
                    model: model
                )),
                itemID: TimelineItemIDs.sessionMarker(sessionID, .sessionStarted)
            )]

        case "UserPromptSubmit":
            let prompt = root.string("prompt")
            return [event(
                lifecycle: .running,
                phase: .thinking,
                turn: turnUpdate(phase: .thinking, prompt: prompt),
                timeline: rich ? nil : prompt.map { .message(MessageTimelinePayload(role: .user, text: $0)) },
                itemID: turnID.map { TimelineItemIDs.userPrompt(sessionID, turnID: $0) }
            )]

        case "PreToolUse":
            return [event(
                lifecycle: .running,
                phase: .executing,
                timeline: rich ? nil : .tool(ToolTimelinePayload(
                    name: toolName,
                    summary: AdapterText.summary(ofToolInput: root["tool_input"]),
                    content: root.jsonValue("tool_input"),
                    status: .started,
                    toolUseID: toolUseID
                )),
                itemID: toolUseID.map { TimelineItemIDs.toolCall(sessionID, toolUseID: $0) }
            )]

        case "PostToolUse":
            let response = root.dictionary("tool_response") ?? root
            let failed = response.containsFailure || root.containsFailure
            return [event(
                lifecycle: .running,
                phase: .thinking,
                timeline: rich ? nil : .tool(ToolTimelinePayload(
                    name: toolName,
                    summary: AdapterText.excerpt(Self.responseText(root["tool_response"])),
                    content: root.jsonValue("tool_response"),
                    status: failed ? .failed : .succeeded,
                    toolUseID: toolUseID
                )),
                itemID: toolUseID.map { TimelineItemIDs.toolResult(sessionID, toolUseID: $0) }
            )]

        case "PermissionRequest":
            // Permission requests never enter the Timeline; they only mark
            // the session as waiting on the human.
            return [event(lifecycle: .waitingForInput, phase: .waitingForApproval)]

        case "SubagentStart":
            let agentID = root.string("agent_id") ?? eventID.rawValue
            return [event(
                lifecycle: .running,
                phase: .executing,
                timeline: .subagent(SubagentTimelinePayload(
                    name: root.string("agent_type") ?? "Subagent",
                    agentSessionID: root.string("agent_id"),
                    status: .started
                )),
                itemID: TimelineItemIDs.subagent(sessionID, agentID: agentID, phase: "started")
            )]

        case "SubagentStop":
            let agentID = root.string("agent_id") ?? eventID.rawValue
            return [event(
                lifecycle: .running,
                phase: .thinking,
                timeline: .subagent(SubagentTimelinePayload(
                    name: root.string("agent_type") ?? "Subagent",
                    agentSessionID: root.string("agent_id"),
                    status: .completed
                )),
                itemID: TimelineItemIDs.subagent(sessionID, agentID: agentID, phase: "stopped")
            )]

        case "Stop":
            let last = root.string("last_assistant_message")
            return [event(
                lifecycle: .waitingForInput,
                phase: .idle,
                turn: turnUpdate(phase: .idle, endedAt: occurredAt, outcome: .completed, lastAssistantMessage: last),
                timeline: .turnEnd(TurnEndTimelinePayload(outcome: .completed, message: last)),
                itemID: turnID.map { TimelineItemIDs.turnEnd(sessionID, turnID: $0) }
            )]

        case "SessionEnd":
            return [event(
                lifecycle: .completed,
                phase: .idle,
                timeline: .sessionMarker(SessionMarkerTimelinePayload(
                    kind: .sessionEnded,
                    detail: root.string("reason")
                )),
                itemID: TimelineItemIDs.sessionMarker(sessionID, .sessionEnded)
            )]

        case "PreCompact":
            return [event(
                lifecycle: .compacting,
                phase: .compacting,
                timeline: .sessionMarker(SessionMarkerTimelinePayload(
                    kind: .compactionStarted,
                    detail: root.string("trigger")
                ))
            )]

        case "PostCompact":
            return [event(
                lifecycle: .running,
                phase: .thinking,
                timeline: .sessionMarker(SessionMarkerTimelinePayload(
                    kind: .compactionEnded,
                    detail: root.string("trigger")
                ))
            )]

        default:
            return []
        }
    }

    // MARK: - Rollout JSONL

    public func events(
        fromRolloutLine data: Data,
        context: RolloutRecordContext,
        state: inout RolloutReadState
    ) throws -> [AgentIngressEvent] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recordType = root.string("type"),
              let payload = root.dictionary("payload") else {
            throw AgentAdapterError.malformedJSON
        }

        let occurredAt = root.date("timestamp") ?? state.lastTimestamp ?? Date()
        state.lastTimestamp = occurredAt
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
            let agent = threadIdentity?.agentKind ?? .codex
            var events = [AgentIngressEvent(
                eventID: EventID(stableID),
                sessionID: sessionID,
                agent: agent,
                occurredAt: occurredAt,
                title: threadIdentity?.displayTitle,
                workspace: payload.string("cwd"),
                lifecycle: .starting,
                phase: .idle,
                timelineItem: TimelineItem(
                    id: TimelineItemIDs.sessionMarker(sessionID, .sessionStarted),
                    sessionID: sessionID,
                    occurredAt: occurredAt,
                    payload: .sessionMarker(SessionMarkerTimelinePayload(
                        kind: .sessionStarted,
                        detail: payload.string("thread_source") ?? payload.string("source").flatMap { $0.isEmpty ? nil : $0 },
                        model: nil
                    ))
                ),
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
                    agent: agent,
                    occurredAt: occurredAt,
                    timelineItem: TimelineItem(
                        id: TimelineItemIDs.diagnostic(sessionID, key: "model_configuration:session_meta"),
                        sessionID: sessionID,
                        occurredAt: occurredAt,
                        payload: .modelConfiguration(ModelConfigurationTimelinePayload(
                            source: "session_meta",
                            provider: payload.string("model_provider"),
                            contextWindow: payload.int64("context_window"),
                            clientVersion: payload.string("cli_version"),
                            settings: settings
                        ))
                    )
                ))
            }

            if let baseInstructions = payload.jsonValue("base_instructions") {
                events.append(AgentIngressEvent(
                    eventID: EventID(stableID + ":context:base_instructions"),
                    sessionID: sessionID,
                    agent: agent,
                    occurredAt: occurredAt,
                    timelineItem: TimelineItem(
                        id: TimelineItemIDs.diagnostic(sessionID, key: "context:base_instructions"),
                        sessionID: sessionID,
                        occurredAt: occurredAt,
                        payload: .context(ContextTimelinePayload(
                            kind: "base_instructions",
                            summary: "Base instructions",
                            content: baseInstructions
                        ))
                    )
                ))
            }
            return events
        }

        guard let sessionID = context.sessionID else { return [] }
        if let explicitTurn = payload.string("turn_id"), !explicitTurn.isEmpty {
            state.currentTurnID = TurnID(explicitTurn)
        }
        let turnID = state.currentTurnID
        let threadIdentity = threads.identity(for: sessionID)
        let agent = threadIdentity?.agentKind ?? .codex

        func makeEvent(
            lifecycle: SessionLifecycle? = nil,
            phase: TurnPhase? = nil,
            turn: TurnSummary? = nil,
            timeline: TimelinePayload? = nil,
            suffix: String = "",
            itemID: TimelineItemID? = nil,
            diagnosticKey: String? = nil
        ) -> AgentIngressEvent {
            let eventID = EventID(stableID + suffix)
            let timelineItem = timeline.map {
                TimelineItem(
                    id: itemID
                        ?? diagnosticKey.map { TimelineItemIDs.diagnostic(sessionID, key: $0) }
                        ?? TimelineItemID(eventID.rawValue + ":timeline"),
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
                agent: agent,
                occurredAt: occurredAt,
                title: threadIdentity?.displayTitle,
                lifecycle: lifecycle,
                phase: phase,
                turn: turn,
                timelineItem: timelineItem,
                lineage: threadIdentity?.lineage
            )
        }

        func toolCall(name: String, callID: String?, input: Any?) -> AgentIngressEvent {
            if let callID {
                state.toolNames[callID] = name
                state.openToolUseIDs.append(callID)
            }
            return makeEvent(
                lifecycle: .running,
                phase: .executing,
                timeline: .tool(ToolTimelinePayload(
                    name: name,
                    summary: AdapterText.summary(ofToolInput: input),
                    content: input.flatMap { try? JSONValue(jsonObject: $0) },
                    status: .started,
                    toolUseID: callID
                )),
                itemID: callID.map { TimelineItemIDs.toolCall(sessionID, toolUseID: $0) }
            )
        }

        func toolResult(name: String?, callID: String?, failed: Bool, output: String?, duration: Int64?) -> AgentIngressEvent {
            let resolvedName = name ?? callID.flatMap { state.toolNames[$0] } ?? "Tool"
            if let callID { state.openToolUseIDs.removeAll { $0 == callID } }
            return makeEvent(
                lifecycle: .running,
                phase: .thinking,
                timeline: .tool(ToolTimelinePayload(
                    name: resolvedName,
                    summary: AdapterText.excerpt(output),
                    content: output.map(JSONValue.string),
                    status: failed ? .failed : .succeeded,
                    durationMilliseconds: duration,
                    toolUseID: callID
                )),
                itemID: callID.map { TimelineItemIDs.toolResult(sessionID, toolUseID: $0) }
            )
        }

        func admit(_ family: FactFamily, _ priority: Int) -> Bool {
            let seen = state.channelPriorities[family.rawValue] ?? Int.min
            guard priority >= seen else { return false }
            state.channelPriorities[family.rawValue] = priority
            return true
        }

        // Shared by `event_msg/sub_agent_activity` and
        // `item_completed(SubAgentActivity)`; the field names coincide.
        func subagentActivity(_ fields: [String: Any]) -> [AgentIngressEvent] {
            let kind = fields.string("kind") ?? "started"
            let status: SubagentTimelinePayload.Status = switch kind {
            case "completed", "stopped": .completed
            case "failed": .failed
            case "waiting": .waiting
            default: .started
            }
            let agentID = fields.string("agent_thread_id") ?? fields.string("event_id") ?? fields.string("id") ?? "\(context.byteOffset)"
            return [makeEvent(
                lifecycle: .running,
                phase: status == .started ? .executing : .thinking,
                timeline: .subagent(SubagentTimelinePayload(
                    name: fields.string("agent_path") ?? "Subagent",
                    agentSessionID: fields.string("agent_thread_id"),
                    status: status
                )),
                itemID: TimelineItemIDs.subagent(sessionID, agentID: agentID, phase: status == .started ? "started" : (status == .waiting ? "waiting" : "stopped"))
            )]
        }

        if recordType == "inter_agent_communication_metadata",
           payload.bool("trigger_turn") == true {
            return [makeEvent(lifecycle: .running, phase: .thinking)]
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
                let summary = [payload.string("model"), payload.string("effort"), payload.string("cwd")]
                    .compactMap { $0 }.joined(separator: " · ")
                events.append(makeEvent(
                    timeline: .config(ConfigTimelinePayload(
                        kind: "turn_context",
                        summary: summary.isEmpty ? nil : summary,
                        content: content
                    )),
                    suffix: ":config",
                    diagnosticKey: turnID.map { "config:turn_context:\($0.rawValue)" } ?? "config:turn_context"
                ))
            }
            return events
        }

        if recordType == "world_state" || recordType == "compacted" {
            guard let content = try? JSONValue(jsonObject: payload) else { return [] }
            let diagnosticKey: String
            if recordType == "world_state" {
                if payload.bool("full") == true {
                    diagnosticKey = "context:world_state:full"
                } else {
                    let stateKeys = payload.dictionary("state")?.keys.sorted().joined(separator: ",") ?? "unknown"
                    let keyDigest = Self.digest(data: Data(stateKeys.utf8), prefix: "")
                    diagnosticKey = "context:world_state:delta:\(keyDigest)"
                }
            } else {
                diagnosticKey = "context:compacted:\(context.byteOffset)"
            }
            return [makeEvent(
                timeline: .context(ContextTimelinePayload(
                    kind: recordType,
                    summary: recordType == "compacted" ? "Compaction summary" : "World state",
                    content: content
                )),
                suffix: ":context",
                diagnosticKey: diagnosticKey
            )]
        }

        if recordType == "event_msg", let type = payload.string("type") {
            switch type {
            case "task_started":
                let turn = turnID.map {
                    TurnSummary(id: $0, sessionID: sessionID, phase: .thinking, startedAt: occurredAt)
                }
                return [makeEvent(lifecycle: .running, phase: .thinking, turn: turn)]

            case "user_message":
                guard let message = payload.string("message"), !message.isEmpty,
                      admit(.userMessage, 0) else { return [] }
                return [makeEvent(
                    lifecycle: .running,
                    phase: .thinking,
                    turn: turnID.map {
                        TurnSummary(id: $0, sessionID: sessionID, phase: .thinking, prompt: message, startedAt: occurredAt)
                    },
                    timeline: .message(MessageTimelinePayload(role: .user, text: message)),
                    itemID: turnID.map { TimelineItemIDs.userPrompt(sessionID, turnID: $0) }
                )]

            case "agent_message":
                guard let message = payload.string("message"), !message.isEmpty,
                      admit(.assistantMessage, 0) else { return [] }
                return [makeEvent(
                    lifecycle: .running,
                    phase: .responding,
                    timeline: .message(MessageTimelinePayload(role: .assistant, text: message))
                )]

            case "agent_reasoning":
                guard let text = payload.string("text"), !text.isEmpty,
                      admit(.reasoning, 0) else { return [] }
                return [makeEvent(
                    lifecycle: .running,
                    phase: .thinking,
                    timeline: .reasoning(ReasoningTimelinePayload(text: text))
                )]

            case "context_compacted":
                guard let content = try? JSONValue(jsonObject: payload) else { return [] }
                return [makeEvent(
                    timeline: .context(ContextTimelinePayload(
                        kind: type,
                        summary: "Context compacted",
                        content: content
                    )),
                    suffix: ":context"
                )]

            case "thread_settings_applied":
                guard let settingsDictionary = payload.dictionary("thread_settings"),
                      let settings = try? JSONValue(jsonObject: settingsDictionary) else { return [] }
                let summary = [settingsDictionary.string("model"), settingsDictionary.string("reasoning_effort")]
                    .compactMap { $0 }.joined(separator: " · ")
                return [
                    makeEvent(
                        timeline: .modelConfiguration(ModelConfigurationTimelinePayload(
                            source: "thread_settings_applied",
                            model: settingsDictionary.string("model"),
                            provider: settingsDictionary.string("model_provider_id"),
                            reasoningEffort: settingsDictionary.string("reasoning_effort"),
                            settings: settings
                        )),
                        suffix: ":model_configuration",
                        diagnosticKey: "model_configuration:thread_settings"
                    ),
                    makeEvent(
                        timeline: .config(ConfigTimelinePayload(
                            kind: "thread_settings",
                            summary: summary.isEmpty ? "Thread settings" : summary,
                            content: settings
                        )),
                        suffix: ":config"
                    ),
                ]

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
                let last = payload.string("last_agent_message")
                if let error = payload.string("error"), !error.isEmpty {
                    return [makeEvent(
                        lifecycle: .failed,
                        phase: .idle,
                        turn: turnID.map {
                            TurnSummary(id: $0, sessionID: sessionID, phase: .idle, startedAt: occurredAt, endedAt: occurredAt, outcome: .failed)
                        },
                        timeline: .turnEnd(TurnEndTimelinePayload(outcome: .failed, message: error)),
                        itemID: turnID.map { TimelineItemIDs.turnEnd(sessionID, turnID: $0) }
                    )]
                }
                return [makeEvent(
                    lifecycle: .waitingForInput,
                    phase: .idle,
                    turn: turnID.map {
                        TurnSummary(id: $0, sessionID: sessionID, phase: .idle, startedAt: occurredAt, endedAt: occurredAt, outcome: .completed, lastAssistantMessage: last)
                    },
                    timeline: .turnEnd(TurnEndTimelinePayload(outcome: .completed, message: last)),
                    itemID: turnID.map { TimelineItemIDs.turnEnd(sessionID, turnID: $0) }
                )]

            case "turn_aborted":
                return [makeEvent(
                    lifecycle: .interrupted,
                    phase: .idle,
                    turn: turnID.map {
                        TurnSummary(id: $0, sessionID: sessionID, phase: .idle, startedAt: occurredAt, endedAt: occurredAt, outcome: .aborted)
                    },
                    timeline: .turnEnd(TurnEndTimelinePayload(
                        outcome: .aborted,
                        message: payload.string("reason") ?? "The Codex turn was interrupted."
                    )),
                    itemID: turnID.map { TimelineItemIDs.turnEnd(sessionID, turnID: $0) }
                )]

            case "exec_command_begin":
                let command = (payload.array("command") as? [String])?.joined(separator: " ")
                    ?? payload.string("command")
                return [toolCall(name: "Shell command", callID: payload.string("call_id"), input: command)]

            case "exec_command_end":
                let exitCode = payload.int("exit_code") ?? 0
                return [toolResult(
                    name: nil,
                    callID: payload.string("call_id"),
                    failed: exitCode != 0,
                    output: payload.string("formatted_output") ?? payload.string("aggregated_output") ?? payload.string("stdout") ?? (exitCode == 0 ? nil : payload.string("stderr")),
                    duration: payload.durationMilliseconds
                )]

            case "patch_apply_begin":
                guard admit(.fileChange, 0) else { return [] }
                return [toolCall(name: "Apply patch", callID: payload.string("call_id"), input: payload.dictionary("changes")?.keys.sorted().joined(separator: ", "))]

            case "patch_apply_end":
                guard admit(.fileChange, 0) else { return [] }
                return [toolResult(
                    name: nil,
                    callID: payload.string("call_id"),
                    failed: payload.bool("success") == false,
                    output: payload.string("stdout") ?? payload.string("stderr"),
                    duration: payload.durationMilliseconds
                )]

            case "dynamic_tool_call_request":
                return [toolCall(name: payload.string("tool") ?? "Tool", callID: payload.string("call_id"), input: payload["arguments"] ?? payload["input"])]

            case "dynamic_tool_call_response":
                return [toolResult(
                    name: payload.string("tool"),
                    callID: payload.string("call_id"),
                    failed: payload.bool("success") == false,
                    output: Self.responseText(payload["output"] ?? payload["result"]),
                    duration: payload.durationMilliseconds
                )]

            case "mcp_tool_call_begin":
                guard admit(.mcpCall, 0) else { return [] }
                let invocation = payload.dictionary("invocation")
                let name = [invocation?.string("server"), invocation?.string("tool")].compactMap { $0 }.joined(separator: "/")
                return [toolCall(name: name.isEmpty ? "MCP tool" : name, callID: payload.string("call_id"), input: invocation?["arguments"])]

            case "mcp_tool_call_end":
                guard admit(.mcpCall, 0) else { return [] }
                let invocation = payload.dictionary("invocation")
                let name = [invocation?.string("server"), invocation?.string("tool")].compactMap { $0 }.joined(separator: "/")
                return [toolResult(
                    name: name.isEmpty ? nil : name,
                    callID: payload.string("call_id"),
                    failed: payload.containsFailure,
                    output: Self.responseText(payload["result"]),
                    duration: payload.durationMilliseconds
                )]

            case "sub_agent_activity":
                guard admit(.subagentActivity, 0) else { return [] }
                return subagentActivity(payload)

            case "item_completed":
                guard let item = payload.dictionary("item"), let itemType = item.string("type") else { return [] }
                let rowID = item.string("id").map { TimelineItemID("codex_item:\(sessionID.rawValue):\($0)") }
                switch itemType {
                case "AgentMessage":
                    guard let text = Self.messageText(item["content"]), !text.isEmpty,
                          admit(.assistantMessage, 1) else { return [] }
                    return [makeEvent(
                        lifecycle: .running,
                        phase: .responding,
                        timeline: .message(MessageTimelinePayload(role: .assistant, text: text)),
                        itemID: rowID
                    )]

                case "UserMessage":
                    guard let text = Self.messageText(item["content"]), !text.isEmpty,
                          admit(.userMessage, 1) else { return [] }
                    return [makeEvent(
                        lifecycle: .running,
                        phase: .thinking,
                        turn: turnID.map {
                            TurnSummary(id: $0, sessionID: sessionID, phase: .thinking, prompt: text, startedAt: occurredAt)
                        },
                        timeline: .message(MessageTimelinePayload(role: .user, text: text)),
                        itemID: turnID.map { TimelineItemIDs.userPrompt(sessionID, turnID: $0) } ?? rowID
                    )]

                case "Reasoning":
                    let summary = (item["summary_text"] as? [String])?
                        .filter { !$0.isEmpty }.joined(separator: "\n\n")
                    guard let text = Self.messageText(item["raw_content"]) ?? summary, !text.isEmpty,
                          admit(.reasoning, 1) else { return [] }
                    return [makeEvent(
                        lifecycle: .running,
                        phase: .thinking,
                        timeline: .reasoning(ReasoningTimelinePayload(text: text)),
                        itemID: rowID
                    )]

                case "SubAgentActivity":
                    guard admit(.subagentActivity, 1) else { return [] }
                    return subagentActivity(item)

                case "McpToolCall":
                    guard admit(.mcpCall, 1) else { return [] }
                    let name = [item.string("server"), item.string("tool")].compactMap { $0 }.joined(separator: "/")
                    return [makeEvent(
                        lifecycle: .running,
                        phase: .thinking,
                        timeline: .tool(ToolTimelinePayload(
                            name: name.isEmpty ? "MCP tool" : name,
                            summary: AdapterText.excerpt(Self.responseText(item["result"]))
                                ?? AdapterText.summary(ofToolInput: item["arguments"]),
                            content: item.jsonValue(keys: ["arguments", "result"]),
                            status: item.string("status") == "failed" ? .failed : .succeeded,
                            durationMilliseconds: Self.itemDuration(item["duration"]),
                            toolUseID: item.string("id")
                        )),
                        itemID: rowID
                    )]

                case "Extension":
                    let kind = item.string("kind") ?? "Extension"
                    if kind == "web.search", !admit(.webSearch, 1) { return [] }
                    return [makeEvent(
                        lifecycle: .running,
                        phase: .thinking,
                        timeline: .tool(ToolTimelinePayload(
                            name: kind,
                            summary: AdapterText.excerpt(item.string("query")),
                            content: item.jsonValue("query"),
                            status: .succeeded,
                            toolUseID: item.string("id")
                        )),
                        itemID: rowID
                    )]

                case "FileChange":
                    guard admit(.fileChange, 1) else { return [] }
                    return [makeEvent(
                        lifecycle: .running,
                        phase: .thinking,
                        timeline: .tool(ToolTimelinePayload(
                            name: "Apply patch",
                            summary: AdapterText.excerpt(item.dictionary("changes")?.keys.sorted().joined(separator: ", ")),
                            content: item.jsonValue("changes"),
                            status: item.string("status") == "failed" ? .failed : .succeeded,
                            toolUseID: item.string("id")
                        )),
                        itemID: rowID
                    )]

                case "ImageView":
                    guard admit(.imageView, 1) else { return [] }
                    return [makeEvent(
                        lifecycle: .running,
                        phase: .thinking,
                        timeline: .tool(ToolTimelinePayload(
                            name: "View image",
                            summary: AdapterText.excerpt(item.string("path")),
                            content: item.jsonValue("path"),
                            status: .succeeded,
                            toolUseID: item.string("id")
                        )),
                        itemID: rowID
                    )]

                case "Plan":
                    guard let text = item.string("text"), !text.isEmpty else { return [] }
                    return [makeEvent(
                        lifecycle: .running,
                        phase: .thinking,
                        timeline: .plan(PlanTimelinePayload(explanation: text, steps: [])),
                        itemID: rowID
                    )]

                case "CommandExecution", "DynamicToolCall", "CollabAgentToolCall", "ContextCompaction":
                    // The `response_item` call/output pair stays the sole
                    // source of execution rows and the top-level `compacted`
                    // record of the compaction marker. These items use an
                    // unrelated id scheme (`exec-<uuid>` vs `call_…`), so
                    // they cannot upsert the same rows, and an incremental
                    // read boundary between call and item would turn
                    // arbitration into duplicate rows.
                    return []

                default:
                    return []
                }

            case "web_search_begin", "image_generation_begin":
                if type == "web_search_begin", !admit(.webSearch, 0) { return [] }
                let name = type == "web_search_begin" ? "Web search" : "Image generation"
                return [toolCall(name: name, callID: payload.string("call_id"), input: payload.string("query"))]

            case "web_search_end", "image_generation_end", "view_image_tool_call":
                if type == "web_search_end", !admit(.webSearch, 0) { return [] }
                if type == "view_image_tool_call", !admit(.imageView, 0) { return [] }
                let name = type == "web_search_end" ? "Web search" : (type == "image_generation_end" ? "Image generation" : "View image")
                return [toolResult(
                    name: name,
                    callID: payload.string("call_id"),
                    failed: payload.containsFailure,
                    output: payload.string("query"),
                    duration: payload.durationMilliseconds
                )]

            default:
                return []
            }
        }

        if recordType == "response_item", let type = payload.string("type") {
            switch type {
            case "custom_tool_call", "function_call":
                let name = payload.string("name") ?? "Tool"
                let callID = payload.string("call_id")
                if name == "update_plan", let plan = Self.plan(from: payload.string("input") ?? payload.string("arguments")) {
                    return [makeEvent(lifecycle: .running, phase: .thinking, timeline: .plan(plan))]
                }
                return [toolCall(name: name, callID: callID, input: payload["input"] ?? payload["arguments"])]

            case "custom_tool_call_output", "function_call_output":
                let output = Self.responseText(payload["output"])
                return [toolResult(
                    name: nil,
                    callID: payload.string("call_id"),
                    failed: Self.outputIndicatesFailure(payload["output"]),
                    output: output,
                    duration: nil
                )]

            case "message", "reasoning", "agent_message":
                // Message bodies come from the `event_msg` channel
                // (`user_message` / `agent_message` / `agent_reasoning`); the
                // response items are duplicates, injected instruction blocks,
                // or inter-agent frames that stay out of the Timeline.
                return []

            default:
                return []
            }
        }

        // Unknown rollout records remain excluded until their shape and privacy
        // boundary are explicitly modeled.
        return []
    }

    // MARK: - Helpers

    private static func digest(data: Data, prefix: String) -> String {
        prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Text of a `content` array (`[{type:input_text|output_text|text, text}]`) or string.
    static func messageText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [Any] else { return nil }
        let parts = blocks.compactMap { block -> String? in
            guard let block = block as? [String: Any] else { return nil }
            return block.string("text")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Best-effort readable output for tool results in their many shapes.
    static func responseText(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String {
            // `{"output":"...","metadata":{...}}` encoded as a JSON string.
            if text.hasPrefix("{"),
               let data = text.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let inner = object.string("output") {
                return inner
            }
            // Python-ish repr of a content array: pull the text field.
            if text.hasPrefix("[{"), let range = text.range(of: "'text': '") ?? text.range(of: "\"text\": \"") {
                let rest = text[range.upperBound...]
                let end = rest.firstIndex(where: { $0 == "'" || $0 == "\"" }) ?? rest.endIndex
                return String(rest[..<end]).replacingOccurrences(of: "\\n", with: "\n")
            }
            return text
        }
        if let dictionary = value as? [String: Any] {
            if let output = dictionary.string("output") { return output }
            if let content = dictionary["content"], let text = messageText(content) { return text }
            if let text = dictionary.string("text") { return text }
            return nil
        }
        if let array = value as? [Any] { return messageText(array) }
        return nil
    }

    /// `{secs, nanos}` duration dictionaries used by `item_completed` items.
    static func itemDuration(_ value: Any?) -> Int64? {
        guard let dictionary = value as? [String: Any],
              let secs = dictionary.int64("secs") else { return nil }
        return secs * 1_000 + (dictionary.int64("nanos") ?? 0) / 1_000_000
    }

    static func outputIndicatesFailure(_ value: Any?) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary.containsFailure { return true }
            if let exit = dictionary.dictionary("metadata")?.int("exit_code"), exit != 0 { return true }
            return false
        }
        guard let text = value as? String else { return false }
        if text.hasPrefix("{"),
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return outputIndicatesFailure(object)
        }
        return false
    }

    static func plan(from input: String?) -> PlanTimelinePayload? {
        guard let input,
              let inputData = input.data(using: .utf8),
              let planRoot = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any],
              let rawSteps = planRoot["plan"] as? [[String: Any]] else { return nil }
        let steps = rawSteps.compactMap { step -> PlanTimelinePayload.Step? in
            guard let text = step.string("step") else { return nil }
            let status: PlanTimelinePayload.Step.Status = switch step.string("status") {
            case "in_progress": .inProgress
            case "completed": .completed
            default: .pending
            }
            return PlanTimelinePayload.Step(text: text, status: status)
        }
        return PlanTimelinePayload(explanation: planRoot.string("explanation"), steps: steps)
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
