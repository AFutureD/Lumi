import Core
import Transport
import CryptoKit
import Foundation

/// Reduces Claude Code hook payloads and transcript JSONL records
/// (`~/.claude/projects/<slug>/<session>.jsonl`) into Agent-domain events.
///
/// Turn boundaries are content-driven, not `prompt_id`-driven: a human
/// prompt (`origin.kind == "human"`; any plain prompt text on a subagent
/// transcript) opens a Turn, and the closing assistant record's terminal
/// `stop_reason` ends it. Injected resumes — task notifications, queued
/// companion prompts — carry fresh `promptId`s but stay inside the Turn
/// they resumed. The opening record's `promptId` still names the Turn so
/// hook-fallback events land on the same id.
public struct ClaudeAdapter: AgentAdapter {
    public let agentKind: AgentKind = .claude

    public init() {}

    // MARK: - Hooks

    public func events(
        fromHook payload: ClaudeHookPayload,
        raw data: Data,
        options: HookIngestOptions
    ) throws -> [AgentIngressEvent] {
        let parentSessionID = SessionID(payload.sessionID)
        let occurredAt = payload.timestamp ?? options.receivedAt
        let eventID = EventID(Self.digest(data: data, prefix: "claude-hook:"))
        let workspace = payload.cwd
        // Hooks fired *inside* a subagent (tool calls etc.) carry the parent's
        // `session_id` plus `agent_id` / `agent_type`; they drive the derived
        // child session, not the parent. SubagentStart / Stop are the parent's
        // own events and are handled below (they also open / close the child).
        let agentID = payload.agentID
        let isSubagent = agentID != nil && payload.isRealSubagent
            && payload.eventName != .subagentStart && payload.eventName != .subagentStop
        let sessionID = isSubagent
            ? ClaudeSubagentIdentity.sessionID(parent: parentSessionID, agentID: agentID!)
            : parentSessionID
        let agent: AgentKind = isSubagent ? .claudeSubagent : .claude
        let rich = options.richSourceAvailable
        // Hook events attach to the Turn the transcript reader holds open
        // (`options.currentTurnID`): the hook's `prompt_id` changes on every
        // injected resume (task notifications), so using it as the turn id
        // would mint ghost Turns. `prompt_id` remains the hook-only fallback —
        // when no transcript read produced a turn (`currentTurnID == nil`) and
        // none is readable at all (`!rich`, e.g. SubagentStart firing before
        // the child transcript exists still finds the parent's turn above) —
        // and on the first prompt of a session it matches the transcript's
        // `promptId`. A subagent's own turn id only comes from its transcript.
        let turnID: TurnID? = isSubagent
            ? nil
            : (options.currentTurnID ?? (rich ? nil : payload.promptID.map(TurnID.init)))
        let subagentLineage = isSubagent
            ? ClaudeSubagentIdentity.lineage(parent: parentSessionID, agentType: payload.agentType, meta: nil)
            : nil

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
            let agentType = payload.agentType
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
                index: payload.turnNumber,
                phase: phase,
                prompt: prompt,
                startedAt: occurredAt,
                endedAt: endedAt,
                outcome: outcome,
                lastAssistantMessage: lastAssistantMessage
            )
        }

        let toolName = payload.toolName ?? "Tool"
        let toolUseID = payload.toolUseID

        switch payload.eventName {
        case .sessionStart:
            return [event(
                lifecycle: .starting,
                phase: .idle,
                timeline: .sessionMarker(SessionMarkerTimelinePayload(
                    kind: .sessionStarted,
                    detail: payload.source,
                    model: payload.model
                )),
                itemID: TimelineItemIDs.sessionMarker(sessionID, .sessionStarted)
            )]

        case .userPromptSubmit:
            // Turn opening (and the prompt) belongs to the transcript when it
            // is readable: this hook also fires for injected resumes, whose
            // text must not overwrite the human prompt of the open Turn.
            let prompt = payload.prompt
            return [event(
                lifecycle: .running,
                phase: .thinking,
                turn: rich ? nil : turnUpdate(phase: .thinking, prompt: prompt),
                timeline: rich ? nil : prompt.map { .message(MessageTimelinePayload(role: .user, text: $0)) },
                itemID: turnID.map { TimelineItemIDs.userPrompt(sessionID, turnID: $0) }
            )]

        case .preToolUse:
            return [event(
                lifecycle: .running,
                phase: .executing,
                timeline: rich ? nil : .tool(ToolTimelinePayload(
                    name: toolName,
                    summary: AdapterText.summary(ofToolInput: payload.toolInput?.foundationObject),
                    content: payload.toolInput,
                    status: .started,
                    toolUseID: toolUseID
                )),
                itemID: toolUseID.map { TimelineItemIDs.toolCall(sessionID, toolUseID: $0) }
            )]

        case .postToolUse:
            let result = payload.toolResult ?? payload.toolResponse
            let failed = (result?.foundationObject as? [String: Any])?.containsFailure ?? false
            var content = [String: JSONValue]()
            content["tool_result"] = payload.toolResult
            content["tool_response"] = payload.toolResponse
            return [event(
                lifecycle: .running,
                phase: .thinking,
                timeline: rich ? nil : .tool(ToolTimelinePayload(
                    name: toolName,
                    summary: AdapterText.excerpt(CodexAdapter.responseText(result?.foundationObject)),
                    content: content.isEmpty ? nil : .object(content),
                    status: failed ? .failed : .succeeded,
                    toolUseID: toolUseID
                )),
                itemID: toolUseID.map { TimelineItemIDs.toolResult(sessionID, toolUseID: $0) }
            )]

        case .postToolUseFailure:
            return [event(
                lifecycle: .running,
                phase: .thinking,
                timeline: rich ? nil : .tool(ToolTimelinePayload(
                    name: toolName,
                    summary: AdapterText.excerpt(payload.error) ?? "failed",
                    content: payload.error.map(JSONValue.string),
                    status: .failed,
                    toolUseID: toolUseID
                )),
                itemID: toolUseID.map { TimelineItemIDs.toolResult(sessionID, toolUseID: $0) }
            )]

        case .permissionRequest:
            return [event(lifecycle: .waitingForInput, phase: .waitingForApproval)]

        case .permissionDenied:
            return [event(lifecycle: .running, phase: .thinking)]

        case .subagentStart:
            guard payload.isRealSubagent else { return [] }
            let agentID = payload.agentID ?? eventID.rawValue
            let childSessionID = payload.agentID.map {
                ClaudeSubagentIdentity.sessionID(parent: parentSessionID, agentID: $0)
            }
            var events = [event(
                lifecycle: .running,
                phase: .executing,
                timeline: .subagent(SubagentTimelinePayload(
                    name: payload.agentType ?? "Subagent",
                    agentSessionID: childSessionID?.rawValue,
                    status: .started
                )),
                itemID: TimelineItemIDs.subagent(sessionID, agentID: agentID, phase: "started")
            )]
            if let agentID = payload.agentID {
                events.append(childEvent(agentID: agentID, lifecycle: .running, phase: .thinking, suffix: ":child"))
            }
            return events

        case .subagentStop:
            guard payload.isRealSubagent else { return [] }
            let agentID = payload.agentID ?? eventID.rawValue
            let childSessionID = payload.agentID.map {
                ClaudeSubagentIdentity.sessionID(parent: parentSessionID, agentID: $0)
            }
            var events = [event(
                lifecycle: .running,
                phase: .thinking,
                timeline: .subagent(SubagentTimelinePayload(
                    name: payload.agentType ?? "Subagent",
                    agentSessionID: childSessionID?.rawValue,
                    status: .completed
                )),
                itemID: TimelineItemIDs.subagent(sessionID, agentID: agentID, phase: "stopped")
            )]
            if let agentID = payload.agentID {
                events.append(childEvent(agentID: agentID, lifecycle: .completed, phase: .idle, suffix: ":child"))
            }
            return events

        case .stop:
            // Closes the current Turn even when the terminal transcript record
            // has not been flushed by hook time — the watcher skips a parked
            // session, so the hook is the only guaranteed close. When the
            // transcript record was (or is later) read, both sides target the
            // same Turn and turn-end item id, so the close is idempotent.
            let last = payload.lastAssistantMessage
            return [event(
                lifecycle: .waitingForInput,
                phase: .idle,
                turn: turnUpdate(phase: .idle, endedAt: occurredAt, outcome: .completed, lastAssistantMessage: last),
                timeline: .turnEnd(TurnEndTimelinePayload(outcome: .completed, message: last)),
                itemID: turnID.map { TimelineItemIDs.turnEnd(sessionID, turnID: $0) }
            )]

        case .stopFailure:
            // Same close-guarantee as Stop: the transcript's API-error record
            // may lag the hook, and a failed session is not polled again.
            let message = [payload.errorType, payload.errorMessage].compactMap { $0 }.joined(separator: " · ")
            return [event(
                lifecycle: .failed,
                phase: .idle,
                turn: turnUpdate(phase: .idle, endedAt: occurredAt, outcome: .failed),
                timeline: .turnEnd(TurnEndTimelinePayload(outcome: .failed, message: message.isEmpty ? nil : message)),
                itemID: turnID.map { TimelineItemIDs.turnEnd(sessionID, turnID: $0) }
            )]

        case .sessionEnd:
            // Ended before its first Turn: not a session. The service sets
            // this from daemon state + transcript absence; see HookIngestOptions.
            if options.sessionNeverUsed {
                return [event(disposition: .discard)]
            }
            return [event(
                lifecycle: .completed,
                phase: .idle,
                timeline: .sessionMarker(SessionMarkerTimelinePayload(kind: .sessionEnded, detail: payload.reason)),
                itemID: TimelineItemIDs.sessionMarker(sessionID, .sessionEnded)
            )]

        case .preCompact:
            return [event(
                lifecycle: .compacting,
                phase: .compacting,
                timeline: .sessionMarker(SessionMarkerTimelinePayload(kind: .compactionStarted, detail: payload.trigger))
            )]

        case .postCompact:
            return [event(
                lifecycle: .running,
                phase: .thinking,
                timeline: .sessionMarker(SessionMarkerTimelinePayload(kind: .compactionEnded, detail: payload.trigger))
            )]

        case .instructionsLoaded:
            let path = payload.filePath ?? "instructions"
            return [event(
                timeline: .context(ContextTimelinePayload(
                    kind: "instructions",
                    summary: [URL(fileURLWithPath: path).lastPathComponent, payload.loadReason ?? payload.reason]
                        .compactMap { $0 }.joined(separator: " · "),
                    content: .string(path)
                )),
                itemID: TimelineItemIDs.diagnostic(sessionID, key: "context:instructions:\(path)")
            )]

        case .configChange:
            let path = payload.filePath ?? ""
            return [event(
                timeline: .config(ConfigTimelinePayload(
                    kind: "config_change",
                    summary: [payload.configSource, URL(fileURLWithPath: path).lastPathComponent]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                    content: .string(path)
                ))
            )]

        case .cwdChanged:
            let newCwd = payload.newCwd
            var content = [String: JSONValue]()
            content["old_cwd"] = payload.oldCwd.map(JSONValue.string)
            content["new_cwd"] = newCwd.map(JSONValue.string)
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
                    payload: .config(ConfigTimelinePayload(
                        kind: "cwd_changed",
                        summary: newCwd,
                        content: content.isEmpty ? nil : .object(content)
                    ))
                )
            )]

        case .notification:
            // Notification types that mean "a human is needed" surface as
            // waiting; the rest are not modeled.
            switch payload.notificationType {
            case "permission_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog":
                return [event(lifecycle: .waitingForInput, phase: .waitingForApproval)]
            case "idle_prompt":
                return [event(lifecycle: .waitingForInput, phase: .idle)]
            default:
                return []
            }
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
        // A Turn opens on a prompt, not on `promptId`: injected resumes (task
        // notifications, queued companion prompts) carry fresh promptIds but
        // stay inside the Turn they resumed. The opening record's promptId
        // still names the Turn so hook-fallback events land on the same id.
        let opensTurn = recordType == "user" && Self.opensTurn(root, isSubagentSession: subagentSessionID != nil)
        if opensTurn {
            state.currentTurnID = TurnID(root.string("promptId") ?? root.string("uuid") ?? stableID)
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

            // Only the first plain prompt text of an opening record writes the
            // Turn's prompt and claims the stable prompt item id; any further
            // text block is its own row.
            var turnClaimed = false
            let blocks = Self.blocks(message["content"])
            for block in blocks {
                switch block.type {
                case "text":
                    let (prompt, reminders) = Self.splitSystemReminders(block.text ?? "")
                    for reminder in reminders {
                        events.append(makeEvent(
                            timeline: .context(ContextTimelinePayload(
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
                    } else if trimmed.hasPrefix("<command-name>") {
                        // The user typed this slash command; Claude Code
                        // serialized it as XML-ish tags. Kept as an ordinary
                        // user message with its raw content — deliberately
                        // unparsed — and turn-neutral: a local command never
                        // reaches the model, and a prompt-expanding one opens
                        // its Turn on the expanded prompt record.
                        events.append(makeEvent(
                            timeline: .message(MessageTimelinePayload(role: .user, text: trimmed)),
                            suffix: next(),
                            includeWorkspace: true
                        ))
                    } else if let kind = Self.injectedKind(trimmed) {
                        events.append(makeEvent(
                            timeline: .context(ContextTimelinePayload(
                                kind: kind,
                                summary: AdapterText.excerpt(trimmed),
                                content: .string(trimmed)
                            )),
                            suffix: next()
                        ))
                    } else {
                        let claims = opensTurn && !turnClaimed
                        turnClaimed = turnClaimed || claims
                        events.append(makeEvent(
                            lifecycle: .running,
                            phase: .thinking,
                            turn: claims ? turnID.map {
                                TurnSummary(id: $0, sessionID: sessionID, phase: .thinking, prompt: trimmed, startedAt: occurredAt)
                            } : nil,
                            timeline: .message(MessageTimelinePayload(role: .user, text: trimmed)),
                            suffix: next(),
                            itemID: claims ? turnID.map { TimelineItemIDs.userPrompt(sessionID, turnID: $0) } : nil,
                            includeWorkspace: true
                        ))
                    }

                case "tool_result":
                    let toolUseID = block.raw.string("tool_use_id")
                    let failed = block.raw.bool("is_error") == true
                        || (root.dictionary("toolUseResult")?.bool("interrupted") == true)
                    let output = CodexAdapter.responseText(block.raw["content"])
                        ?? root.dictionary("toolUseResult")?.string("stdout")
                    var raw: [String: JSONValue] = [:]
                    if let value = block.raw.jsonValue("content") { raw["content"] = value }
                    if let value = root.jsonValue("toolUseResult") { raw["toolUseResult"] = value }
                    let name = toolUseID.flatMap { state.toolNames[$0] } ?? "Tool"
                    if let toolUseID { state.openToolUseIDs.removeAll { $0 == toolUseID } }
                    events.append(makeEvent(
                        lifecycle: .running,
                        phase: .thinking,
                        timeline: .tool(ToolTimelinePayload(
                            name: name,
                            summary: AdapterText.excerpt(output),
                            content: raw.isEmpty ? nil : .object(raw),
                            status: failed ? .failed : .succeeded,
                            toolUseID: toolUseID
                        )),
                        suffix: next(),
                        itemID: toolUseID.map { TimelineItemIDs.toolResult(sessionID, toolUseID: $0) }
                    ))

                case "image", "document":
                    events.append(makeEvent(
                        timeline: .context(ContextTimelinePayload(kind: block.type, summary: block.type.capitalized)),
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
            // The transcript's own turn boundary: the final assistant record
            // of a turn carries a terminal stop_reason — `end_turn` normally;
            // truncation, refusal, or a synthetic API-error record (top-level
            // `error` such as rate_limit / server_error, written with
            // stop_reason "stop_sequence") abnormally. Emitting the turn end
            // here keeps the state correct even when the Stop hook is missed,
            // and lets a rebuild from the transcript alone land on
            // waiting_for_input instead of an open turn.
            let stopReason = message.string("stop_reason")
            let apiError = root.string("error")
            let endsTurn = stopReason.map { !Self.continuingStopReasons.contains($0) } ?? false
            let turnFailed = endsTurn && (apiError != nil || Self.abnormalStopReasons.contains(stopReason ?? ""))
            var lastText: String?

            for block in Self.blocks(message["content"]) {
                switch block.type {
                case "thinking":
                    // Claude Code may persist a thinking block with only its
                    // signature and no text. The block still marks a thinking
                    // step, so it always yields one REASONING row; the
                    // projection renders empty text as a placeholder.
                    let text = (block.raw.string("thinking") ?? block.text ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
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
                            content: block.raw.jsonValue("input"),
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
                let outcome: TurnOutcome = turnFailed ? .failed : .completed
                let failureMessage = [apiError, lastText].compactMap { $0 }.joined(separator: " · ")
                // A subagent never waits for input: its final message completes it.
                let lifecycle: SessionLifecycle = turnFailed
                    ? .failed
                    : (subagentSessionID == nil ? .waitingForInput : .completed)
                events.append(makeEvent(
                    lifecycle: lifecycle,
                    phase: .idle,
                    turn: turnID.map {
                        TurnSummary(
                            id: $0,
                            sessionID: sessionID,
                            phase: .idle,
                            startedAt: occurredAt,
                            endedAt: occurredAt,
                            outcome: outcome,
                            lastAssistantMessage: lastText
                        )
                    },
                    timeline: .turnEnd(TurnEndTimelinePayload(
                        outcome: outcome,
                        message: turnFailed ? (failureMessage.isEmpty ? nil : failureMessage) : lastText
                    )),
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
            let summary = attachment.flatMap { Self.attachmentSummary($0) } ?? kind.replacingOccurrences(of: "_", with: " ")
            let content = root.jsonValue("attachment")
            // Run-mode attachments are how the agent runs, not model input.
            if Self.configAttachmentKinds.contains(kind) {
                return [makeEvent(timeline: .config(ConfigTimelinePayload(kind: kind, summary: summary, content: content)))]
            }
            return [makeEvent(
                timeline: .context(ContextTimelinePayload(kind: kind, summary: summary, content: content))
            )]

        case "system":
            let subtype = root.string("subtype") ?? "system"
            let content = root.string("content")
            return [makeEvent(
                timeline: .context(ContextTimelinePayload(
                    kind: subtype,
                    summary: AdapterText.excerpt(content) ?? subtype.replacingOccurrences(of: "_", with: " "),
                    content: content.map(JSONValue.string)
                ))
            )]

        case "summary":
            guard let summary = root.string("summary") else { return [] }
            return [makeEvent(
                timeline: .context(ContextTimelinePayload(
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

    /// `stop_reason` values after which the same turn continues: the tool
    /// loop (`tool_use`, `tool_deferred`) or a paused server-tool loop the
    /// harness resumes on its own (`pause_turn`). Any other stop reason is
    /// terminal and ends the turn.
    static let continuingStopReasons: Set<String> = ["tool_use", "tool_deferred", "pause_turn"]

    /// Terminal `stop_reason` values that end a turn abnormally: the output
    /// was truncated or refused. Independent of these, a terminal record with
    /// a top-level `error` (rate_limit, server_error, …) fails the turn it
    /// ends.
    static let abnormalStopReasons: Set<String> = ["max_tokens", "refusal", "model_context_window_exceeded"]

    /// A Turn opens on a prompt. On the main session that is a human one —
    /// `origin.kind == "human"` (slash commands included); injected resumes
    /// carry other kinds or none, and an interrupt marker closes a Turn, so it
    /// never opens one even if a future Claude Code stamps it as human. A
    /// subagent transcript has no human origin: its seed and follow-up
    /// prompts are plain user text records, told apart from injected content
    /// and interrupt markers by their text.
    static func opensTurn(_ root: [String: Any], isSubagentSession: Bool) -> Bool {
        let texts = blocks(root.dictionary("message")?["content"]).compactMap { block -> String? in
            guard block.type == "text", let text = block.text else { return nil }
            return splitSystemReminders(text).0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard isSubagentSession else {
            return root.dictionary("origin")?.string("kind") == "human"
                && !texts.contains(where: interruptMarkers.contains)
        }
        return texts.contains { !$0.isEmpty && !interruptMarkers.contains($0) && injectedKind($0) == nil }
    }

    /// Transcript user-text markers Claude Code writes when the user presses
    /// stop. An interrupt fires no Stop hook, so these are the only turn-end
    /// signal for an aborted turn.
    static let interruptMarkers: Set<String> = [
        "[Request interrupted by user]",
        "[Request interrupted by user for tool use]",
    ]

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

    /// `<local-command-caveat>` / `<local-command-stdout>` / `<task-notification>` etc.
    /// (`<command-name>` records never reach here — the user typed those, so
    /// the block loop keeps them as plain user messages, raw.)
    static func injectedKind(_ text: String) -> String? {
        guard text.hasPrefix("<"), let close = text.firstIndex(of: ">") else { return nil }
        let tag = text[text.index(after: text.startIndex)..<close]
        guard !tag.contains(" "), !tag.hasPrefix("/"), !tag.isEmpty else { return nil }
        return String(tag).replacingOccurrences(of: "-", with: "_")
    }

    /// Attachment types that describe the run mode (CONFIG), not injected
    /// model input (CONTEXT): permission / plan mode and allowed commands.
    static let configAttachmentKinds: Set<String> = [
        "auto_mode", "plan_mode", "plan_mode_exit", "command_permissions",
    ]

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
