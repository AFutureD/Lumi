import AgentStatusTransport

/// Pure reduction behind the per-session relay stream: part assembly, the
/// in-memory list upsert, index pruning and the completeness gate.
enum RelayFrameReduction {
    /// One session arrives as ordered `.session` parts; part 0 carries the
    /// summary and turns, later parts append timeline. `nil` when the buffer
    /// is empty or carries no detail.
    static func assemble(parts: [RemoteSessionPayload]) -> SessionDetail? {
        let ordered = parts.sorted { ($0.part ?? 0) < ($1.part ?? 0) }
        guard let first = ordered.first?.session else { return nil }
        let timeline = ordered.compactMap(\.session).flatMap(\.timeline)
        return SessionDetail(summary: first.summary, turns: first.turns, timeline: timeline)
    }

    /// Replaces or inserts by id, keeping the list in latest-activity order —
    /// the same order the cache's `listSessions` produces.
    static func upsert(_ detail: SessionDetail, into sessions: [SessionDetail]) -> [SessionDetail] {
        var updated = sessions.filter { $0.summary.id != detail.summary.id }
        updated.append(detail)
        updated.sort { $0.summary.lastActivityAt > $1.summary.lastActivityAt }
        return updated
    }

    static func prune(_ sessions: [SessionDetail], keeping ids: Set<SessionID>) -> [SessionDetail] {
        sessions.filter { ids.contains($0.summary.id) }
    }

    /// Sessions the index promises but the device never fully received; a
    /// non-empty result means the sync is incomplete and a resync hello is due.
    static func missingIDs(index: some Collection<SessionID>, sessions: [SessionDetail]) -> Set<SessionID> {
        Set(index).subtracting(sessions.map(\.summary.id))
    }
}
