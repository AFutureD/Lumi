import Transport
import Foundation

/// The in-memory twin of the repository's write paths, for mirrors that keep
/// a loaded `SessionDetail` next to their cache: fold one event in the way
/// `apply` does, or merge a partial copy the way `mergeSession` does.
public enum SessionDetailReduction {
    /// `apply(event)` on a loaded detail: summary through the shared reducer,
    /// the timeline item upserted by id under the `occurredAt >=` rule, rows
    /// kept in `(occurredAt, id)` order, and turns projected back from the
    /// merged timeline — the same pure fold every store uses.
    public static func applying(_ event: AgentIngressEvent, to detail: SessionDetail) -> SessionDetail {
        let summary = SessionReduction.summary(applying: event, to: detail.summary)
        let timeline = event.timelineItem.map { merge([$0], into: detail.timeline) } ?? detail.timeline
        return SessionDetail(
            summary: summary,
            turns: TurnProjection.turns(from: timeline, sessionID: summary.id),
            timeline: timeline
        )
    }

    /// `mergeSession(partial)` on a loaded detail: the partial's summary wins,
    /// its rows upsert into the timeline, and turns are re-projected from the
    /// merged rows (the partial's own `turns` are derivable and ignored).
    public static func merging(_ partial: SessionDetail, into detail: SessionDetail) -> SessionDetail {
        let timeline = merge(partial.timeline, into: detail.timeline)
        return SessionDetail(
            summary: partial.summary,
            turns: TurnProjection.turns(from: timeline, sessionID: partial.summary.id),
            timeline: timeline
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
