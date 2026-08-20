import AgentStatusCore
import AgentStatusTransport
import CryptoKit
import Foundation

/// Reduces Claude Code hook payloads and transcript JSONL records
/// (`~/.claude/projects/<slug>/<session>.jsonl`) into Agent-domain events.
///
/// Turn identity is Claude's `prompt_id` (hooks) / `promptId` (transcript
/// user records). Transcript records without one belong to the current turn.
public struct ClaudeAdapter: AgentAdapter {
    public let agentKind: AgentKind = .claude

    public init() {}

    // MARK: - Hooks

    public func events(fromHookData data: Data, options: HookIngestOptions) throws -> [AgentIngressEvent] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentAdapterError.malformedJSON
        }
        guard let session = root.string("session_id"), !session.isEmpty else {
            throw AgentAdapterError.missingSessionID
        }

        let eventName = root.string("hook_event_name") ?? "Unknown"
        let parentSessionID = SessionID(session)
        let occurredAt = root.date("timestamp") ?? Date()
        let eventID = EventID(Self.digest(data: data, prefix: "claude-hook:"))
        let workspace = root.string("cwd")
        // Hooks fired *inside* a subagent (tool calls etc.) carry the parent's
        // `session_id` plus `agent_id` / `agent_type`; they drive the derived
        // child session, not the parent. SubagentStart / Stop are the parent's
        // own events and are handled below (they also open / close the child).
        let agentID = root.string("agent_id")
        let isSubagent = agentID != nil && Self.isRealSubagent(root)
            && eventName != "SubagentStart" && eventName != "SubagentStop"
        let sessionID = isSubagent
            ? ClaudeSubagentIdentity.sessionID(parent: parentSessionID, agentID: agentID!)
            : parentSessionID
        let agent: AgentKind = isSubagent ? .claudeSubagent : .claude
        // The hook's `prompt_id` is the parent's turn; a subagent's own turn id
        // only comes from its transcript.
        let turnID = isSubagent ? nil : root.string("prompt_id").map(TurnID.init)
        let subagentLineage = isSubagent
            ? ClaudeSubagentIdentity.lineage(parent: parentSessionID, agentType: root.string("agent_type"), meta: nil)
            : nil
        let rich = options.richSourceAvailable

        func event(
            lifecycle: SessionLifecycle? = nil,
            phase: TurnPhase? = nil,
            turn: TurnSummary? = nil,
            timeline: TimelinePayload? = nil,
            itemID: TimelineItemID? = nil,
            title: String? = nil,
            lineage: SessionLineage? = nil,
            disposition: SessionDisposition? = nil
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
                agent: agent,
                occurredAt: occurredAt,
                title: title,
                workspace: workspace,
                lifecycle: lifecycle,
                phase: phase,
                turn: turn,
                timelineItem: item,
                lineage: lineage ?? subagentLineage,
                disposition: disposition
            )
        }

        /// Lifecycle event for the derived child session of `agent_id`
        /// (SubagentStart opens it running, SubagentStop completes it).
        func childEvent(
            agentID: String,
            lifecycle: SessionLifecycle,
            phase: TurnPhase,
            suffix: String
        ) -> AgentIngressEvent {
            let agentType = root.string("agent_type")
            return AgentIngressEvent(
                eventID: EventID(eventID.rawValue + suffix),
                sessionID: ClaudeSubagentIdentity.sessionID(parent: parentSessionID, agentID: agentID),
                agent: .claudeSubagent,
                occurredAt: occurredAt,
                title: ClaudeSubagentIdentity.title(agentType: agentType, meta: nil),
                workspace: workspace,
                lifecycle: lifecycle,
                phase: phase,
                lineage: ClaudeSubagentIdentity.lineage(parent: parentSessionID, agentType: agentType, meta: nil)
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
                index: root.int("turn_number"),
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
                    model: root.string("model")
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

        case "UserPromptExpansion":
            guard let expanded = root.string("expanded_prompt") else { return [] }
            return [event(
                lifecycle: .running,
                phase: .thinking,
                timeline: .context(ContextTimelinePayload(
                    scope: .turn,
                    kind: "command_expansion",
                    summary: ["/" + (root.string("command_name") ?? "command"), AdapterText.excerpt(expanded)].compactMap { $0 }.joined(separator: " · "),
                    content: .string(expanded)
                ))
            )]

        case "PreToolUse":
            return [event(
                lifecycle: .running,
                phase: .executing,
                timeline: rich ? nil : .tool(ToolTimelinePayload(
                    name: toolName,
                    summary: AdapterText.summary(ofToolInput: root["tool_input"]),
                    status: .started,
                    toolUseID: toolUseID
                )),
                itemID: toolUseID.map { TimelineItemIDs.toolCall(sessionID, toolUseID: $0) }
            )]

        case "PostToolUse":
            let result = root["tool_result"] ?? root["tool_response"]
            let failed = (result as? [String: Any])?.containsFailure ?? false
            return [event(
                lifecycle: .running,
                phase: .thinking,
                timeline: rich ? nil : .tool(ToolTimelinePayload(
                    name: toolName,
                    summary: AdapterText.excerpt(CodexAdapter.responseText(result)),
                    status: failed ? .failed : .succeeded,
                    toolUseID: toolUseID
                )),
                itemID: toolUseID.map { TimelineItemIDs.toolResult(sessionID, toolUseID: $0) }
            )]

        case "PostToolUseFailure":
            return [event(
                lifecycle: .running,
                phase: .thinking,
                timeline: rich ? nil : .tool(ToolTimelinePayload(
                    name: toolName,
                    summary: AdapterText.excerpt(root.string("error")) ?? "failed",
                    status: .failed,
                    toolUseID: toolUseID
                )),
                itemID: toolUseID.map { TimelineItemIDs.toolResult(sessionID, toolUseID: $0) }
            )]

        case "PermissionRequest":
            return [event(lifecycle: .waitingForInput, phase: .waitingForApproval)]

        case "PermissionDenied":
            return [event(lifecycle: .running, phase: .thinking)]

        case "SubagentStart":
            guard Self.isRealSubagent(root) else { return [] }
            let agentID = root.string("agent_id") ?? eventID.rawValue
            let childSessionID = root.string("agent_id").map {
                ClaudeSubagentIdentity.sessionID(parent: parentSessionID, agentID: $0)
            }
            var events = [event(
                lifecycle: .running,
                phase: .subagentRunning,
                timeline: .subagent(SubagentTimelinePayload(
                    name: root.string("agent_type") ?? "Subagent",
                    agentSessionID: childSessionID?.rawValue,
                    status: .started
                )),
                itemID: TimelineItemIDs.subagent(sessionID, agentID: agentID, phase: "started")
            )]
            if let agentID = root.string("agent_id") {
                events.append(childEvent(agentID: agentID, lifecycle: .running, phase: .thinking, suffix: ":child"))
            }
            return events

        case "SubagentStop":
            guard Self.isRealSubagent(root) else { return [] }
            let agentID = root.string("agent_id") ?? eventID.rawValue
            let childSessionID = root.string("agent_id").map {
                ClaudeSubagentIdentity.sessionID(parent: parentSessionID, agentID: $0)
            }
            var events = [event(
                lifecycle: .running,
                phase: .thinking,
                timeline: .subagent(SubagentTimelinePayload(
                    name: root.string("agent_type") ?? "Subagent",
                    agentSessionID: childSessionID?.rawValue,
                    status: .completed
                )),
                itemID: TimelineItemIDs.subagent(sessionID, agentID: agentID, phase: "stopped")
            )]
            if let agentID = root.string("agent_id") {
                events.append(childEvent(agentID: agentID, lifecycle: .completed, phase: .idle, suffix: ":child"))
            }
            return events

        case "Stop":
            let last = root.string("last_assistant_message")
            return [event(
                lifecycle: .waitingForInput,
                phase: .idle,
                turn: turnUpdate(phase: .idle, endedAt: occurredAt, outcome: .completed, lastAssistantMessage: last),
                timeline: .turnEnd(TurnEndTimelinePayload(outcome: .completed, message: last)),
                itemID: turnID.map { TimelineItemIDs.turnEnd(sessionID, turnID: $0) }
            )]

        case "StopFailure":
            let message = [root.string("error_type"), root.string("error_message")].compactMap { $0 }.joined(separator: " · ")
            return [event(
                lifecycle: .failed,
                phase: .idle,
                turn: turnUpdate(phase: .idle, endedAt: occurredAt, outcome: .failed),
                timeline: .turnEnd(TurnEndTimelinePayload(outcome: .failed, message: message.isEmpty ? nil : message)),
                itemID: turnID.map { TimelineItemIDs.turnEnd(sessionID, turnID: $0) }
            )]

        case "SessionEnd":
            // Ended before its first Turn: not a session. The pipeline sets
            // this from daemon state + transcript absence; see HookIngestOptions.
            if options.sessionNeverUsed {
                return [event(disposition: .discard)]
            }
            return [event(
                lifecycle: .completed,
                phase: .idle,
                timeline: .sessionMarker(SessionMarkerTimelinePayload(kind: .sessionEnded, detail: root.string("reason"))),
                itemID: TimelineItemIDs.sessionMarker(sessionID, .sessionEnded)
            )]

        case "PreCompact":
            return [event(
                lifecycle: .compacting,
                phase: .compacting,
                timeline: .sessionMarker(SessionMarkerTimelinePayload(kind: .compactionStarted, detail: root.string("trigger")))
            )]

        case "PostCompact":
            return [event(
                lifecycle: .running,
                phase: .thinking,
                timeline: .sessionMarker(SessionMarkerTimelinePayload(kind: .compactionEnded, detail: root.string("trigger")))
            )]

        case "InstructionsLoaded":
            let path = root.string("file_path") ?? "instructions"
            return [event(
                timeline: .context(ContextTimelinePayload(
                    scope: .session,
                    kind: "instructions",
                    summary: [URL(fileURLWithPath: path).lastPathComponent, root.string("load_reason")].compactMap { $0 }.joined(separator: " · "),
                    content: .string(path)
                )),
                itemID: TimelineItemIDs.diagnostic(sessionID, key: "context:instructions:\(path)")
            )]

        case "ConfigChange":
            let path = root.string("file_path") ?? ""
            return [event(
                timeline: .context(ContextTimelinePayload(
                    scope: .session,
                    kind: "config_change",
                    summary: [root.string("source"), URL(fileURLWithPath: path).lastPathComponent].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                    content: .string(path)
                ))
            )]

        case "CwdChanged":
            let newCwd = root.string("new_cwd")
            return [AgentIngressEvent(
                eventID: eventID,
                sessionID: sessionID,
                turnID: turnID,
                agent: agent,
                occurredAt: occurredAt,
                workspace: newCwd,
                timelineItem: TimelineItem(
                    id: TimelineItemID(eventID.rawValue + ":timeline"),
                    sessionID: sessionID,
                    turnID: turnID,
                    occurredAt: occurredAt,
                    payload: .context(ContextTimelinePayload(
                        scope: .session,
                        kind: "cwd_changed",
                        summary: newCwd,
                        content: root.jsonValue(keys: ["old_cwd", "new_cwd"])
                    ))
                )
            )]

        case "Notification":
            // Notification types that mean "a human is needed" surface as
            // waiting; the rest are not modeled.
            switch root.string("notification_type") {
            case "permission_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog":
                return [event(lifecycle: .waitingForInput, phase: .waitingForApproval)]
            case "idle_prompt":
                return [event(lifecycle: .waitingForInput, phase: .idle)]
            default:
                return []
            }

        default:
            return []
        }
    }

    // MARK: - Transcript JSONL

    public func events(
        fromRolloutLine data: Data,
        context: RolloutRecordContext,
        state: inout RolloutReadState
    ) throws -> [AgentIngressEvent] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recordType = root.string("type") else {
            throw AgentAdapterError.malformedJSON
        }
        // A read of `subagents/agent-<id>.jsonl` is keyed by the derived child
        // session; its sidechain records belong to that child. Sidechain
        // records met anywhere else (the parent's own transcript) are skipped:
        // the parent shows the subagent through SubagentStart / Stop.
        let subagentSessionID = context.sessionID.flatMap {
            ClaudeSubagentIdentity.isSubagentSession($0) ? $0 : nil
        }
        let sessionID: SessionID
        if let subagentSessionID {
            sessionID = subagentSessionID
        } else {
            guard let rawSession = root.string("sessionId") ?? context.sessionID?.rawValue else {
                throw AgentAdapterError.missingSessionID
            }
            if root.bool("isSidechain") == true { return [] }
            sessionID = SessionID(rawSession)
        }
        let agent: AgentKind = subagentSessionID == nil ? .claude : .claudeSubagent

        let occurredAt = root.date("timestamp") ?? state.lastTimestamp ?? Date()
        state.lastTimestamp = occurredAt
        let stableID = Self.digest(
            data: Data("\(context.path):\(context.byteOffset):".utf8) + data,
            prefix: "claude-transcript:"
        )
        if let prompt = root.string("promptId"), !prompt.isEmpty {
            state.currentTurnID = TurnID(prompt)
        }
        let turnID = state.currentTurnID
        let workspace = root.string("cwd")

        func makeEvent(
            lifecycle: SessionLifecycle? = nil,
            phase: TurnPhase? = nil,
            turn: TurnSummary? = nil,
            timeline: TimelinePayload? = nil,
            suffix: String = "",
            itemID: TimelineItemID? = nil,
            title: String? = nil,
            includeWorkspace: Bool = false
        ) -> AgentIngressEvent {
            let eventID = EventID(stableID + suffix)
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
                agent: agent,
                occurredAt: occurredAt,
                title: title,
                workspace: includeWorkspace ? workspace : nil,
                lifecycle: lifecycle,
                phase: phase,
                turn: turn,
                timelineItem: item
            )
        }

        switch recordType {
        case "custom-title":
            guard let title = root.string("customTitle"), !title.isEmpty else { return [] }
            return [makeEvent(title: title)]

        case "user":
            guard let message = root.dictionary("message") else { return [] }
            var events: [AgentIngressEvent] = []
            var index = 0
            func next() -> String { defer { index += 1 }; return ":\(index)" }

            let blocks = Self.blocks(message["content"])
            for block in blocks {
                switch block.type {
                case "text":
                    let (prompt, reminders) = Self.splitSystemReminders(block.text ?? "")
                    for reminder in reminders {
                        events.append(makeEvent(
                            timeline: .context(ContextTimelinePayload(
                                scope: .turn,
                                kind: "system_reminder",
                                summary: AdapterText.excerpt(reminder),
                                content: .string(reminder)
                            )),
                            suffix: next()
                        ))
                    }
                    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    if Self.interruptMarkers.contains(trimmed) {
                        // The user pressed stop. No Stop hook fires for an
                        // interrupt; this transcript marker is the only signal
                        // that the turn is over.
                        events.append(makeEvent(
                            lifecycle: .interrupted,
                            phase: .idle,
                            turn: turnID.map {
                                TurnSummary(id: $0, sessionID: sessionID, phase: .idle, startedAt: occurredAt, endedAt: occurredAt, outcome: .aborted)
                            },
                            timeline: .turnEnd(TurnEndTimelinePayload(outcome: .aborted, message: trimmed)),
                            suffix: next(),
                            itemID: turnID.map { TimelineItemIDs.turnEnd(sessionID, turnID: $0) }
                        ))
                    } else if let kind = Self.injectedKind(trimmed) {
                        events.append(makeEvent(
                            timeline: .context(ContextTimelinePayload(
                                scope: .turn,
                                kind: kind,
                                summary: AdapterText.excerpt(trimmed),
                                content: .string(trimmed)
                            )),
                            suffix: next()
                        ))
                    } else {
                        events.append(makeEvent(
                            lifecycle: .running,
                            phase: .thinking,
                            turn: turnID.map {
                                TurnSummary(id: $0, sessionID: sessionID, phase: .thinking, prompt: trimmed, startedAt: occurredAt)
                            },
                            timeline: .message(MessageTimelinePayload(role: .user, text: trimmed)),
                            suffix: next(),
                            itemID: turnID.map { TimelineItemIDs.userPrompt(sessionID, turnID: $0) },
                            includeWorkspace: true
                        ))
                    }

                case "tool_result":
                    let toolUseID = block.raw.string("tool_use_id")
                    let failed = block.raw.bool("is_error") == true
                        || (root.dictionary("toolUseResult")?.bool("interrupted") == true)
                    let output = CodexAdapter.responseText(block.raw["content"])
                        ?? root.dictionary("toolUseResult")?.string("stdout")
                    let name = toolUseID.flatMap { state.toolNames[$0] } ?? "Tool"
                    if let toolUseID { state.openToolUseIDs.removeAll { $0 == toolUseID } }
                    events.append(makeEvent(
                        lifecycle: .running,
                        phase: .thinking,
                        timeline: .tool(ToolTimelinePayload(
                            name: name,
                            summary: AdapterText.excerpt(output),
                            status: failed ? .failed : .succeeded,
                            toolUseID: toolUseID
                        )),
                        suffix: next(),
                        itemID: toolUseID.map { TimelineItemIDs.toolResult(sessionID, toolUseID: $0) }
                    ))

                case "image", "document":
                    events.append(makeEvent(
                        timeline: .context(ContextTimelinePayload(scope: .turn, kind: block.type, summary: block.type.capitalized)),
                        suffix: next()
                    ))

                default:
                    continue
                }
            }
            return events

        case "assistant":
            guard let message = root.dictionary("message") else { return [] }
            var events: [AgentIngressEvent] = []
            var index = 0
            func next() -> String { defer { index += 1 }; return ":\(index)" }
            let model = message.string("model")
            // The transcript's own turn boundary: the final assistant message
            // of a turn carries a non-tool stop reason. Emitting the turn end
            // here keeps the state correct even when the Stop hook is missed
            // or overridden, and lets a rebuild from the transcript alone
            // land on waiting_for_input instead of an open turn.
            let endsTurn = Self.turnEndingStopReasons.contains(message.string("stop_reason") ?? "")
            var lastText: String?

            for block in Self.blocks(message["content"]) {
                switch block.type {
                case "thinking":
                    guard let text = block.raw.string("thinking") ?? block.text, !text.isEmpty else { continue }
                    events.append(makeEvent(
                        lifecycle: .running,
                        phase: .thinking,
                        timeline: .reasoning(ReasoningTimelinePayload(text: text)),
                        suffix: next()
                    ))
                case "text":
                    guard let text = block.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    lastText = text
                    events.append(makeEvent(
                        lifecycle: .running,
                        phase: .responding,
                        timeline: .message(MessageTimelinePayload(role: .assistant, text: text)),
                        suffix: next()
                    ))
                case "tool_use":
                    let name = block.raw.string("name") ?? "Tool"
                    let toolUseID = block.raw.string("id")
                    if let toolUseID {
                        state.toolNames[toolUseID] = name
                        state.openToolUseIDs.append(toolUseID)
                    }
                    events.append(makeEvent(
                        lifecycle: .running,
                        phase: .executing,
                        timeline: .tool(ToolTimelinePayload(
                            name: name,
                            summary: AdapterText.summary(ofToolInput: block.raw["input"]),
                            status: .started,
                            toolUseID: toolUseID
                        )),
                        suffix: next(),
                        itemID: toolUseID.map { TimelineItemIDs.toolCall(sessionID, toolUseID: $0) }
                    ))
                default:
                    continue
                }
            }

            if endsTurn {
                // A subagent never waits for input: its final message completes it.
                events.append(makeEvent(
                    lifecycle: subagentSessionID == nil ? .waitingForInput : .completed,
                    phase: .idle,
                    turn: turnID.map {
                        TurnSummary(
                            id: $0,
                            sessionID: sessionID,
                            phase: .idle,
                            startedAt: occurredAt,
                            endedAt: occurredAt,
                            outcome: .completed,
                            lastAssistantMessage: lastText
                        )
                    },
                    timeline: .turnEnd(TurnEndTimelinePayload(outcome: .completed, message: lastText)),
                    suffix: ":end",
                    itemID: turnID.map { TimelineItemIDs.turnEnd(sessionID, turnID: $0) }
                ))
            }

            if let usage = message.dictionary("usage") {
                let input = usage.int64("input_tokens") ?? 0
                let cached = usage.int64("cache_read_input_tokens") ?? 0
                let cacheWrite = usage.int64("cache_creation_input_tokens") ?? 0
                let output = usage.int64("output_tokens") ?? 0
                let thinking = usage.dictionary("output_tokens_details")?.int64("thinking_tokens") ?? 0
                let last = TokenUsage(
                    inputTokens: input,
                    cachedInputTokens: cached,
                    cacheWriteInputTokens: cacheWrite,
                    outputTokens: output,
                    reasoningOutputTokens: thinking,
                    totalTokens: input + cached + cacheWrite + output
                )
                events.append(makeEvent(
                    timeline: .usageMetrics(UsageMetricsTimelinePayload(
                        last: last,
                        modelContextWindow: Self.contextWindow(forModel: model)
                    )),
                    suffix: ":usage",
                    itemID: TimelineItemIDs.diagnostic(sessionID, key: "usage_metrics")
                ))
            }
            if let model, !model.isEmpty {
                events.append(makeEvent(
                    timeline: .modelConfiguration(ModelConfigurationTimelinePayload(
                        source: "transcript",
                        model: model,
                        provider: "anthropic",
                        contextWindow: Self.contextWindow(forModel: model),
                        reasoningEffort: root.string("effort"),
                        clientVersion: root.string("version"),
                        settings: .object(["model": .string(model)])
                    )),
                    suffix: ":model",
                    itemID: TimelineItemIDs.diagnostic(sessionID, key: "model_configuration:transcript")
                ))
            }
            return events

        case "attachment":
            let attachment = root.dictionary("attachment")
            let kind = attachment?.string("type") ?? "attachment"
            return [makeEvent(
                timeline: .context(ContextTimelinePayload(
                    scope: .turn,
                    kind: kind,
                    summary: attachment.flatMap { Self.attachmentSummary($0) } ?? kind.replacingOccurrences(of: "_", with: " "),
                    content: root.jsonValue("attachment")
                ))
            )]

        case "system":
            let subtype = root.string("subtype") ?? "system"
            let content = root.string("content")
            return [makeEvent(
                timeline: .context(ContextTimelinePayload(
                    scope: .turn,
                    kind: subtype,
                    summary: AdapterText.excerpt(content) ?? subtype.replacingOccurrences(of: "_", with: " "),
                    content: content.map(JSONValue.string)
                ))
            )]

        case "summary":
            guard let summary = root.string("summary") else { return [] }
            return [makeEvent(
                timeline: .context(ContextTimelinePayload(
                    scope: .session,
                    kind: "summary",
                    summary: AdapterText.excerpt(summary),
                    content: .string(summary)
                ))
            )]

        default:
            // queue-operation, last-prompt, file-history-snapshot, …
            return []
        }
    }

    // MARK: - Helpers

    /// Claude Code forks an internal query after every Stop (a few seconds
    /// later) that fires `SubagentStop` with an empty `agent_type`, no paired
    /// `SubagentStart` and no subagent transcript. It is not a subagent of the
    /// session; folding it in would flip a finished turn back to running.
    /// `tool_use` continues the turn; anything else the API returns ends it.
    static let turnEndingStopReasons: Set<String> = ["end_turn", "stop_sequence", "max_tokens", "refusal"]

    /// Transcript user-text markers Claude Code writes when the user presses
    /// stop. An interrupt fires no Stop hook, so these are the only turn-end
    /// signal for an aborted turn.
    static let interruptMarkers: Set<String> = [
        "[Request interrupted by user]",
        "[Request interrupted by user for tool use]",
    ]

    public static func isRealSubagent(_ root: [String: Any]) -> Bool {
        guard let type = root.string("agent_type") else { return false }
        return !type.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func digest(data: Data, prefix: String) -> String {
        prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    struct Block {
        let type: String
        let text: String?
        let raw: [String: Any]
    }

    static func blocks(_ content: Any?) -> [Block] {
        if let text = content as? String {
            return [Block(type: "text", text: text, raw: ["type": "text", "text": text])]
        }
        guard let array = content as? [Any] else { return [] }
        return array.compactMap { element in
            guard let raw = element as? [String: Any], let type = raw.string("type") else { return nil }
            return Block(type: type, text: raw.string("text"), raw: raw)
        }
    }

    /// Splits `<system-reminder>…</system-reminder>` blocks out of user text.
    static func splitSystemReminders(_ text: String) -> (String, [String]) {
        var remaining = text
        var reminders: [String] = []
        while let open = remaining.range(of: "<system-reminder>") {
            guard let close = remaining.range(of: "</system-reminder>", range: open.upperBound..<remaining.endIndex) else {
                reminders.append(String(remaining[open.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
                remaining.removeSubrange(open.lowerBound...)
                break
            }
            reminders.append(String(remaining[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
            remaining.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return (remaining, reminders)
    }

    /// `<command-name>` / `<local-command-stdout>` / `<task-notification>` etc.
    static func injectedKind(_ text: String) -> String? {
        guard text.hasPrefix("<"), let close = text.firstIndex(of: ">") else { return nil }
        let tag = text[text.index(after: text.startIndex)..<close]
        guard !tag.contains(" "), !tag.hasPrefix("/"), !tag.isEmpty else { return nil }
        return String(tag).replacingOccurrences(of: "-", with: "_")
    }

    static func attachmentSummary(_ attachment: [String: Any]) -> String? {
        let type = attachment.string("type") ?? "attachment"
        if let names = attachment["addedNames"] as? [String], !names.isEmpty {
            return "\(type.replacingOccurrences(of: "_", with: " ")) · \(names.count) tools"
        }
        if let path = attachment.string("filename") ?? attachment.string("path") { return "\(type) · \(path)" }
        if let content = attachment.string("content") { return AdapterText.excerpt(content) }
        return type.replacingOccurrences(of: "_", with: " ")
    }

    static func contextWindow(forModel model: String?) -> Int64? {
        guard let model else { return nil }
        if model.contains("[1m]") { return 1_000_000 }
        return 200_000
    }
}
