import Transport

/// The pure diff behind a reconcile pass: the daemon's summary index against
/// the local cache decides which sessions to refetch in full and which to
/// drop. Summary equality is the staleness signal — any event that changes
/// visible state changes the summary; diagnostic-only drift while offline is
/// accepted and heals with the next advancing event.
enum SessionReconcilePlan {
    struct Plan: Equatable {
        /// Daemon order (latest activity first) so the visible list converges first.
        let fetch: [SessionID]
        let prune: Set<SessionID>
    }

    static func make(local: [SessionSummary], daemon: [SessionSummary]) -> Plan {
        let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let daemonIDs = Set(daemon.map(\.id))
        let fetch = daemon.filter { localByID[$0.id] != $0 }.map(\.id)
        let prune = Set(local.map(\.id).filter { !daemonIDs.contains($0) })
        return Plan(fetch: fetch, prune: prune)
    }
}
