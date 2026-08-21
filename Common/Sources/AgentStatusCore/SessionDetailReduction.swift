import AgentStatusTransport
import Foundation

/// The in-memory twin of the repository's write paths, for mirrors that keep
/// a loaded `SessionDetail` next to their cache: fold one event in the way
/// `apply` does, or merge a partial copy the way `mergeSession` does.
public enum SessionDetailReduction {
    /// `apply(event)` on a loaded detail: summary and turn through the shared
    /// reducers, the timeline item upserted by id under the `occurredAt >=`
    /// rule, rows kept in `(occurredAt, id)` order.
    public static func applying(_ event: AgentIngressEvent, to detail: SessionDetail) -> SessionDetail {
        let summary = SessionReduction.summary(applying: event, to: detail.summary)
        var turns = detail.turns
        if let turnID = event.turnID ?? event.turn?.id {
            let current = turns.first { $0.id == turnID }
            if let turn = TurnReduction.summary(applying: event, to: current) {
                turns.removeAll { $0.id == turnID }
                turns.append(turn)
                turns.sort { lhs, rhs in
                    if lhs.startedAt == rhs.startedAt { return lhs.id.rawValue < rhs.id.rawValue }
                    return lhs.startedAt < rhs.startedAt
                }
            }
        }
        let timeline = event.timelineItem.map { merge([$0], into: detail.timeline) } ?? detail.timeline
        return SessionDetail(summary: summary, turns: turns, timeline: timeline)
    }

    /// `mergeSession(partial)` on a loaded detail: the partial's summary wins,
    /// its turns replace same-id turns, its rows upsert into the timeline.
    public static func merging(_ partial: SessionDetail, into detail: SessionDetail) -> SessionDetail {
        var turnsByID = Dictionary(detail.turns.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for turn in partial.turns { turnsByID[turn.id] = turn }
        let turns = turnsByID.values.sorted { lhs, rhs in
            if lhs.startedAt == rhs.startedAt { return lhs.id.rawValue < rhs.id.rawValue }
            return lhs.startedAt < rhs.startedAt
        }
        return SessionDetail(
            summary: partial.summary,
            turns: turns,
            timeline: merge(partial.timeline, into: detail.timeline)
        )
    }

    /// Upsert by id; an older copy never regresses a newer row.
    public static func merge(_ items: [TimelineItem], into timeline: [TimelineItem]) -> [TimelineItem] {
        guard !items.isEmpty else { return timeline }
        var merged = timeline
        var indexByID = Dictionary(merged.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for item in items {
            if let index = indexByID[item.id] {
                if item.occurredAt >= merged[index].occurredAt { merged[index] = item }
            } else {
                indexByID[item.id] = merged.count
                merged.append(item)
            }
        }
        merged.sort { lhs, rhs in
            if lhs.occurredAt == rhs.occurredAt { return lhs.id.rawValue < rhs.id.rawValue }
            return lhs.occurredAt < rhs.occurredAt
        }
        return merged
    }
}
