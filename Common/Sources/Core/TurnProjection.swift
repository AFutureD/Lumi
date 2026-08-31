import Transport
import Foundation

/// Turn aggregates derived from the timeline on read — the projection that
/// replaced the persisted `turns` table (dropped in `lumi-v8`): the timeline
/// is the single source of truth, and every mirror converges by folding the
/// same rows.
///
/// Only timeline items carrying a `turnID` participate. Two fields of
/// `TurnSummary` are not derivable and are fixed by contract: `index` is
/// always nil and `phase` is always `.idle` — nothing in production reads
/// either (the UI reads `SessionSummary.phase`). `startedAt` is the earliest
/// item of the turn, which can trail the old table's value by the gap to the
/// first item when a turn opened on an item-less event (Codex `task_started`,
/// permission requests) — cosmetic, elapsed display only.
public enum TurnProjection {
    /// The session's turns, sorted `(startedAt, id)` — the order the dropped
    /// table used to serve.
    public static func turns(from timeline: [TimelineItem], sessionID: SessionID) -> [TurnSummary] {
        let items = timeline.sorted { lhs, rhs in
            if lhs.occurredAt == rhs.occurredAt { return lhs.id.rawValue < rhs.id.rawValue }
            return lhs.occurredAt < rhs.occurredAt
        }
        var order: [TurnID] = []
        var accumulators: [TurnID: TurnSummary] = [:]
        for item in items {
            guard let turnID = item.turnID else { continue }
            var turn = accumulators[turnID] ?? {
                order.append(turnID)
                return TurnSummary(id: turnID, sessionID: sessionID, phase: .idle, startedAt: item.occurredAt)
            }()

            var prompt = turn.prompt
            var endedAt = turn.endedAt
            var outcome = turn.outcome
            var toolCalls = turn.toolCallCount
            var subagents = turn.subagentCount
            var lastAssistant = turn.lastAssistantMessage

            switch item.payload {
            case let .message(message):
                if message.role == .user, prompt == nil { prompt = message.text }
                if message.role == .assistant { lastAssistant = message.text }
            case let .tool(tool):
                if tool.status == .started { toolCalls += 1 }
            case let .subagent(subagent):
                if subagent.status == .started { subagents += 1 }
            case let .turnEnd(end):
                endedAt = endedAt ?? item.occurredAt
                outcome = outcome ?? end.outcome
                if let message = end.message { lastAssistant = message }
            case let .error(error):
                if outcome == nil, !error.recoverable {
                    outcome = .failed
                    endedAt = item.occurredAt
                }
            default:
                break
            }

            turn = TurnSummary(
                id: turnID,
                sessionID: sessionID,
                phase: .idle,
                prompt: prompt,
                startedAt: min(turn.startedAt, item.occurredAt),
                endedAt: endedAt,
                outcome: outcome,
                toolCallCount: toolCalls,
                subagentCount: subagents,
                lastAssistantMessage: lastAssistant
            )
            accumulators[turnID] = turn
        }
        return order.compactMap { accumulators[$0] }.sorted { lhs, rhs in
            if lhs.startedAt == rhs.startedAt { return lhs.id.rawValue < rhs.id.rawValue }
            return lhs.startedAt < rhs.startedAt
        }
    }

    /// The turn a transcript increment continues: the turnID of the newest
    /// turn-scoped item ("last open turn, else last turn" — a closed turn's
    /// newest item is its turn end, so the newest turn-scoped item always
    /// belongs to the turn the source was last writing).
    public static func currentTurnID(in timeline: [TimelineItem]) -> TurnID? {
        timeline
            .filter { $0.turnID != nil }
            .max { lhs, rhs in
                if lhs.occurredAt == rhs.occurredAt { return lhs.id.rawValue < rhs.id.rawValue }
                return lhs.occurredAt < rhs.occurredAt
            }?
            .turnID
    }
}
