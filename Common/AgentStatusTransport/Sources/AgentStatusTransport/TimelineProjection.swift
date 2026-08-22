import Foundation

// MARK: - Timeline domain (layer B)
//
// The Agent domain (layer A: `SessionSummary`, `TurnSummary`, `TimelineItem`)
// is what the helper produces and the daemon stores. The Timeline domain is
// what surfaces render: one `TimelineRow` per visible line, each tagged with a
// category (`TimelineTag`), an attention level (L1/L2/L3), a lane, and a
// status. `TimelineProjection.rows(from:)` is the only bridge between them.

/// Swim lane. `nil` on a row means the row spans all lanes (session markers).
public enum TimelineLane: String, Codable, Hashable, Sendable, CaseIterable {
    case user
    case model
    case exec

    public var title: String {
        switch self {
        case .user: "User"
        case .model: "Model"
        case .exec: "Exec"
        }
    }
}

/// How loud a tag chip is. Only L3 may push a Notch notification.
public enum TimelineAttentionLevel: Int, Codable, Hashable, Sendable, Comparable {
    case l1 = 1
    case l2 = 2
    case l3 = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Message taxonomy from the design handoff (L1 / L2 / L3).
public enum TimelineTag: String, Codable, Hashable, Sendable, CaseIterable {
    // L1 — general (low attention)
    case session
    case compact
    case contextGroup   // "CONTEXT ×N", session-scope context (merged), User lane
    case context        // turn-scope context, User lane
    case reasoning
    case tool
    // L2 — turn process (medium attention)
    case result
    case assistant
    case plan
    case subagent
    // L3 — phase (high attention)
    case user
    case turnEnd
    case failed         // a tool call failed (Exec lane)
    case turnFailed     // the turn / agent failed (Model lane); same FAILED chip
    case aborted

    public var level: TimelineAttentionLevel {
        switch self {
        case .session, .compact, .contextGroup, .context, .reasoning, .tool: .l1
        case .result, .assistant, .plan, .subagent: .l2
        case .user, .turnEnd, .failed, .turnFailed, .aborted: .l3
        }
    }

    /// `nil` spans all three lanes (session markers only). Context of either
    /// scope is input handed to the model, so it sits in the User lane. The
    /// lane follows the source of the row: a failed tool result stays in Exec
    /// next to its call, a failed turn sits in Model next to its TURN END.
    public var lane: TimelineLane? {
        switch self {
        case .session, .compact: nil
        case .user, .context, .contextGroup: .user
        case .reasoning, .assistant, .plan, .subagent, .turnEnd, .turnFailed, .aborted: .model
        case .tool, .result, .failed: .exec
        }
    }

    /// Chip label; `contextGroup` is rendered as `CONTEXT ×N` by the caller.
    public var label: String {
        switch self {
        case .session: "SESSION"
        case .compact: "COMPACT"
        case .contextGroup, .context: "CONTEXT"
        case .reasoning: "REASONING"
        case .tool: "TOOL"
        case .result: "RESULT"
        case .assistant: "ASSISTANT"
        case .plan: "PLAN"
        case .subagent: "SUBAGENT"
        case .user: "USER"
        case .turnEnd: "TURN END"
        case .failed, .turnFailed: "FAILED"
        case .aborted: "ABORTED"
        }
    }
}

public enum TimelineRowStatus: String, Codable, Hashable, Sendable {
    case info
    case started
    case running
    case succeeded
    case failed
    case cancelled
}

/// One visible line of the Timeline. `items` are the Agent-domain items that
/// were folded into this row (one, or several for merged CONTEXT ×N /
/// in-place SUBAGENT updates); `items.first` is the anchor.
public struct TimelineRow: Hashable, Sendable, Identifiable {
    public let id: String
    public let sessionID: SessionID
    public let turnID: TurnID?
    public let occurredAt: Date
    public let tag: TimelineTag
    public let status: TimelineRowStatus
    /// Untruncated, possibly multi-line body text; surfaces one-line it.
    public let text: String
    public let items: [TimelineItem]
    public let toolUseID: String?
    public let agentID: String?
    /// Merged-item count (`CONTEXT ×N`); 1 otherwise.
    public let count: Int

    public init(
        id: String,
        sessionID: SessionID,
        turnID: TurnID?,
        occurredAt: Date,
        tag: TimelineTag,
        status: TimelineRowStatus,
        text: String,
        items: [TimelineItem],
        toolUseID: String? = nil,
        agentID: String? = nil,
        count: Int = 1
    ) {
        self.id = id
        self.sessionID = sessionID
        self.turnID = turnID
        self.occurredAt = occurredAt
        self.tag = tag
        self.status = status
        self.text = text
        self.items = items
        self.toolUseID = toolUseID
        self.agentID = agentID
        self.count = count
    }

    public var lane: TimelineLane? { tag.lane }
    public var level: TimelineAttentionLevel { tag.level }
    public var spansLanes: Bool { tag.lane == nil }
    public var anchor: TimelineItem { items[0] }

    /// `CONTEXT ×3` / `TOOL` — the chip text.
    public var label: String {
        tag == .contextGroup && count > 1 ? "CONTEXT ×\(count)" : tag.label
    }

    fileprivate func replacing(
        tag: TimelineTag? = nil,
        status: TimelineRowStatus? = nil,
        text: String? = nil,
        appending item: TimelineItem? = nil
    ) -> TimelineRow {
        TimelineRow(
            id: id,
            sessionID: sessionID,
            turnID: turnID,
            occurredAt: occurredAt,
            tag: tag ?? self.tag,
            status: status ?? self.status,
            text: text ?? self.text,
            items: item.map { items + [$0] } ?? items,
            toolUseID: toolUseID,
            agentID: agentID,
            count: item == nil ? count : count + 1
        )
    }
}

public enum TimelineProjection {
    /// Layer A → layer B. Pure; stable for identical input.
    public static func rows(from items: [TimelineItem]) -> [TimelineRow] {
        let sorted = items.sorted {
            if $0.occurredAt == $1.occurredAt {
                let lhs = sortRank($0.payload), rhs = sortRank($1.payload)
                if lhs != rhs { return lhs < rhs }
                return $0.id.rawValue < $1.id.rawValue
            }
            return $0.occurredAt < $1.occurredAt
        }

        var rows: [TimelineRow] = []
        rows.reserveCapacity(sorted.count)
        var subagentRowIndex: [String: Int] = [:]
        var lastAssistantIndexByTurn: [TurnID?: Int] = [:]
        var toolNames: [String: String] = [:]
        // Codex re-emits every reasoning summary header of a turn with each
        // new reasoning item (`agent_reasoning` A, B, then A, B, C …); one row
        // per distinct header per turn is the readable form.
        var reasoningRowIndexByTurn: [TurnID?: [String: Int]] = [:]

        for item in sorted {
            guard let draft = draft(for: item, toolNames: &toolNames) else { continue }

            switch draft.tag {
            case .reasoning:
                // An empty block (Claude thinking with no recorded text) is a
                // thinking step of its own: one row per block, never merged.
                if !isEmptyReasoning(item),
                   let index = reasoningRowIndexByTurn[item.turnID]?[draft.text] {
                    rows[index] = rows[index].replacing(appending: item)
                    continue
                }
            case .contextGroup:
                // Adjacent session-scope context items merge into CONTEXT ×N.
                if let last = rows.last, last.tag == .contextGroup {
                    rows[rows.count - 1] = last.replacing(appending: item)
                    continue
                }
            case .subagent:
                if let agentID = draft.agentID, let index = subagentRowIndex[agentID] {
                    // Same agent: update state in place, no new row.
                    rows[index] = rows[index].replacing(
                        status: draft.status,
                        text: draft.text,
                        appending: item
                    )
                    continue
                }
            case .turnEnd:
                if draft.status == .succeeded,
                   let index = lastAssistantIndexByTurn[item.turnID],
                   rows[index].tag == .assistant {
                    rows[index] = rows[index].replacing(status: .succeeded)
                }
            default:
                break
            }

            let row = TimelineRow(
                id: "row:\(item.sessionID.rawValue):\(item.id.rawValue)",
                sessionID: item.sessionID,
                turnID: item.turnID,
                occurredAt: item.occurredAt,
                tag: draft.tag,
                status: draft.status,
                text: draft.text,
                items: [item],
                toolUseID: draft.toolUseID,
                agentID: draft.agentID
            )
            rows.append(row)
            if draft.tag == .subagent, let agentID = draft.agentID {
                subagentRowIndex[agentID] = rows.count - 1
            }
            if draft.tag == .assistant {
                lastAssistantIndexByTurn[item.turnID] = rows.count - 1
            }
            if draft.tag == .reasoning, !isEmptyReasoning(item) {
                reasoningRowIndexByTurn[item.turnID, default: [:]][draft.text] = rows.count - 1
            }
        }
        return rows
    }

    /// Row text for a reasoning item whose source recorded no text.
    public static let emptyReasoningText = "Empty"

    private static func isEmptyReasoning(_ item: TimelineItem) -> Bool {
        if case let .reasoning(payload) = item.payload { return payload.text.isEmpty }
        return false
    }

    /// Whether an item contributes a visible row at all. Model configuration
    /// and usage are header metadata, not timeline rows.
    public static func isVisible(_ payload: TimelinePayload) -> Bool {
        switch payload {
        case .usageMetrics, .modelConfiguration: false
        default: true
        }
    }

    /// Same-timestamp ordering: session boundaries first, then the user's
    /// prompt, then everything else.
    private static func sortRank(_ payload: TimelinePayload) -> Int {
        switch payload {
        case .sessionMarker: 0
        case .context, .modelConfiguration, .internalContext: 1
        case let .message(message): message.role == .user ? 2 : 3
        default: 3
        }
    }

    // MARK: - Per-item mapping (table C in the design doc)

    private struct Draft {
        var tag: TimelineTag
        var status: TimelineRowStatus
        var text: String
        var toolUseID: String?
        var agentID: String?
    }

    private static func draft(for item: TimelineItem, toolNames: inout [String: String]) -> Draft? {
        switch item.payload {
        case let .message(payload):
            return Draft(
                tag: payload.role == .user ? .user : .assistant,
                status: .info,
                text: payload.text
            )

        case let .reasoning(payload):
            return Draft(
                tag: .reasoning,
                status: .info,
                text: payload.text.isEmpty ? emptyReasoningText : payload.text
            )

        case let .tool(payload):
            // A result produced in a later read may only know its id; borrow
            // the name from the paired call.
            var name = payload.name
            if let id = payload.toolUseID {
                if payload.status == .started {
                    toolNames[id] = name
                } else if name.isEmpty || name == "Tool", let known = toolNames[id] {
                    name = known
                }
            }
            switch payload.status {
            case .started:
                return Draft(
                    tag: .tool,
                    status: .started,
                    text: joined([name, payload.summary]),
                    toolUseID: payload.toolUseID
                )
            case .succeeded:
                return Draft(
                    tag: .result,
                    status: .succeeded,
                    text: joined([name, payload.summary, duration(payload.durationMilliseconds)]),
                    toolUseID: payload.toolUseID
                )
            case .failed:
                return Draft(
                    tag: .failed,
                    status: .failed,
                    text: joined([name, payload.summary ?? "failed", duration(payload.durationMilliseconds)]),
                    toolUseID: payload.toolUseID
                )
            }

        case let .plan(payload):
            let done = payload.steps.allSatisfy { $0.status == .completed }
            let text = payload.explanation
                ?? payload.steps.first(where: { $0.status == .inProgress })?.text
                ?? "\(payload.steps.count) plan steps"
            return Draft(tag: .plan, status: done ? .succeeded : .running, text: text)

        case let .subagent(payload):
            let status: TimelineRowStatus = switch payload.status {
            case .started: .started
            case .waiting: .running
            case .completed: .succeeded
            case .failed: .failed
            }
            return Draft(
                tag: .subagent,
                status: status,
                text: joined([payload.name, payload.status.rawValue]),
                agentID: payload.agentSessionID
            )

        case let .error(payload):
            let lowered = (payload.title + " " + payload.message).lowercased()
            let aborted = lowered.contains("interrupt") || lowered.contains("abort") || lowered.contains("cancel")
            return Draft(
                tag: aborted ? .aborted : .turnFailed,
                status: aborted ? .cancelled : .failed,
                text: joined([payload.title, payload.message])
            )

        case let .context(payload):
            return Draft(
                tag: payload.scope == .session ? .contextGroup : .context,
                status: .info,
                text: payload.summary ?? humanized(payload.kind)
            )

        case let .sessionMarker(payload):
            switch payload.kind {
            case .sessionStarted:
                return Draft(tag: .session, status: .info, text: joined(["Session started", payload.detail, payload.model]))
            case .sessionEnded:
                return Draft(tag: .session, status: .info, text: joined(["Session ended", payload.detail]))
            case .compactionStarted:
                return Draft(tag: .compact, status: .running, text: joined(["Compacting context", payload.detail]))
            case .compactionEnded:
                return Draft(tag: .compact, status: .succeeded, text: joined(["Context compacted", payload.detail]))
            }

        case let .turnEnd(payload):
            switch payload.outcome {
            case .completed:
                return Draft(tag: .turnEnd, status: .succeeded, text: payload.message ?? "Turn complete")
            case .failed:
                return Draft(tag: .turnFailed, status: .failed, text: payload.message ?? "Turn failed")
            case .aborted:
                return Draft(tag: .aborted, status: .cancelled, text: payload.message ?? "Turn aborted")
            }

        case .modelConfiguration:
            return nil

        // Diagnostic payload kept as metadata (design record §G); the Codex
        // rollout reader still emits it for raw context it does not classify.
        case let .internalContext(payload):
            let kind = payload.kind.lowercased()
            if kind.contains("reasoning") {
                return Draft(tag: .reasoning, status: .info, text: jsonSummary(payload.content))
            }
            let sessionScoped = kind.contains("instruction") || kind == "session_meta" || kind == "system"
            return Draft(
                tag: sessionScoped ? .contextGroup : .context,
                status: .info,
                text: joined([humanized(payload.kind), jsonSummary(payload.content)])
            )

        case .usageMetrics:
            return nil
        }
    }

    // MARK: - Text helpers

    private static func joined(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func duration(_ milliseconds: Int64?) -> String? {
        guard let milliseconds else { return nil }
        if milliseconds < 1_000 { return "\(milliseconds)ms" }
        let seconds = Double(milliseconds) / 1_000
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }

    private static func humanized(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func jsonSummary(_ value: JSONValue) -> String {
        switch value {
        case let .string(value): return value
        case let .object(value):
            for key in ["text", "message", "summary", "type", "kind"] {
                if case let .string(candidate)? = value[key] { return candidate }
            }
            return value.keys.sorted().prefix(6).joined(separator: ", ")
        case let .array(value): return "\(value.count) items"
        case let .number(value): return String(describing: value)
        case let .boolean(value): return value ? "true" : "false"
        case .null: return "null"
        }
    }
}
