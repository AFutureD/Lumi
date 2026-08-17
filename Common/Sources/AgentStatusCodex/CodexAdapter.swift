import AgentStatusCore
import AgentStatusTransport
import CryptoKit
import Foundation

public struct CodexAdapter: AgentAdapter {
    public let agentKind: AgentKind = .codex

    public init() {}

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
                agent: .codex,
                occurredAt: occurredAt,
                workspace: workspace,
                lifecycle: lifecycle,
                phase: phase,
                timelineItem: item
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
            return [AgentIngressEvent(
                eventID: EventID(stableID),
                sessionID: SessionID(rawID),
                agent: .codex,
                occurredAt: occurredAt,
                workspace: payload.string("cwd"),
                lifecycle: .starting,
                phase: .idle
            )]
        }

        guard let sessionID = context.sessionID else { return [] }
        let turnID = payload.string("turn_id").map(TurnID.init)

        func makeEvent(
            lifecycle: SessionLifecycle? = nil,
            phase: TurnPhase? = nil,
            timeline: TimelinePayload? = nil,
            suffix: String = ""
        ) -> AgentIngressEvent {
            let eventID = EventID(stableID + suffix)
            let timelineItem = timeline.map {
                TimelineItem(
                    id: TimelineItemID(eventID.rawValue + ":timeline"),
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
                agent: .codex,
                occurredAt: occurredAt,
                lifecycle: lifecycle,
                phase: phase,
                timelineItem: timelineItem
            )
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

        // reasoning, system context, world_state, compacted history, and unknown records
        // are intentionally excluded from the product model.
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
