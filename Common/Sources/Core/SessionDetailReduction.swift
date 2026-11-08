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
        applying([event], to: detail)
    }

    /// One batch of events in arrival order, folded as `apply` would fold
    /// them one by one but with a single merge and a single turn projection:
    /// the summary reduces through every event, the items upsert together.
    /// A `.discard` event is the caller's job — it removes the session, it
    /// does not reduce it — so a batch must be split at a discard before it
    /// reaches this fold.
    public static func applying(_ events: [AgentIngressEvent], to detail: SessionDetail) -> SessionDetail {
        guard !events.isEmpty else { return detail }
        let summary = events.reduce(detail.summary) { SessionReduction.summary(applying: $1, to: $0) }
        let timeline = merge(events.compactMap(\.timelineItem), into: detail.timeline)
        return SessionDetail(
            summary: summary,
            turns: TurnProjection.turns(from: timeline, sessionID: summary.id),
            timeline: timeline
        )
    }

    /// `mergeSession(partial)` on a loaded detail: the partial's summary wins
    /// and its rows upsert into the timeline. Turns: the daemon's own list
    /// when the partial carries one (part 0 of a page — the one view that
    /// knows turns the loaded tail does not reach), otherwise re-projected
    /// from the merged rows.
    public static func merging(_ partial: SessionDetail, into detail: SessionDetail) -> SessionDetail {
        let timeline = merge(partial.timeline, into: detail.timeline)
        return SessionDetail(
            summary: partial.summary,
            turns: partial.turns.isEmpty ? TurnProjection.turns(from: timeline, sessionID: partial.summary.id) : partial.turns,
            timeline: timeline
        )
    }

    /// Upsert by id under one rule every store shares: an older copy never
    /// regresses a newer row, and a trimmed Relay copy never replaces a
    /// whole one (`TimelineItem.truncated`).
    public static func supersedes(_ incoming: TimelineItem, _ existing: TimelineItem) -> Bool {
        incoming.occurredAt >= existing.occurredAt && !(incoming.isTruncated && !existing.isTruncated)
    }

    public static func merge(_ items: [TimelineItem], into timeline: [TimelineItem]) -> [TimelineItem] {
        guard !items.isEmpty else { return timeline }
        var merged = timeline
        var indexByID = Dictionary(merged.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for item in items {
            if let index = indexByID[item.id] {
                if supersedes(item, merged[index]) { merged[index] = item }
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
