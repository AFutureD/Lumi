import Core
import Logging
import Transport
import Foundation

private let dbLog = Logger(label: "db")

/// The store's bounded, recency-ordered set of complete `SessionDetail`s.
///
/// Every entry is a whole session — summary, turns and the entire timeline —
/// exactly as `SQLiteSessionRepository.sessionDetail` pages it out. There is
/// no partial entry: a session is either fully resident or not resident at
/// all, and anything not resident is re-read from the cache database. The
/// working set is small (the selected session plus the Notch's active
/// sessions), so the capacity counts sessions, not bytes; the log line on
/// every miss and eviction carries the timeline length so an unusually
/// large session stays observable.
///
/// The selected session's lead is pinned: eviction skips it, so the detail
/// pane never blanks because the Notch's working set happened to fill the
/// remaining slots.
struct SessionDetailCache {
    struct Statistics: Equatable, Sendable {
        var hits = 0
        var misses = 0
        var evictions = 0
    }

    static let defaultCapacity = 8

    let capacity: Int
    private(set) var pinnedID: SessionID?
    private(set) var statistics = Statistics()
    private var entries: [SessionID: SessionDetail] = [:]
    /// Least recently used first.
    private var recency: [SessionID] = []

    init(capacity: Int = SessionDetailCache.defaultCapacity) {
        precondition(capacity > 0, "a detail cache needs at least one slot")
        self.capacity = capacity
    }

    var count: Int { entries.count }

    /// Least recently used first.
    var residentIDs: [SessionID] { recency }

    // MARK: - Reads

    /// The entry without touching its recency: for reads that merely
    /// observe the selection, not for a consumer claiming the session.
    func peek(_ id: SessionID) -> SessionDetail? {
        entries[id]
    }

    /// A consumer read: a hit becomes the most recent entry.
    mutating func touch(_ id: SessionID) -> SessionDetail? {
        guard let detail = entries[id] else {
            statistics.misses += 1
            return nil
        }
        statistics.hits += 1
        markRecent(id)
        return detail
    }

    // MARK: - Writes

    /// Upserts a whole session as the most recent entry, evicting the least
    /// recent unpinned entries beyond the capacity.
    mutating func insert(_ detail: SessionDetail) {
        let id = detail.summary.id
        entries[id] = detail
        markRecent(id)
        trim()
    }

    /// A fresh whole copy for a session that is already resident — the
    /// reconcile's or the rebuild's daemon page — without pulling absent
    /// sessions in. Returns whether the session was resident.
    @discardableResult
    mutating func replaceIfPresent(_ detail: SessionDetail) -> Bool {
        let id = detail.summary.id
        guard entries[id] != nil else { return false }
        entries[id] = detail
        markRecent(id)
        return true
    }

    /// A summary-only change (reviewed, archived from the Notch) applied to
    /// the resident copy so it agrees with the list at once.
    @discardableResult
    mutating func patchSummary(
        _ id: SessionID,
        _ transform: (SessionSummary) -> SessionSummary
    ) -> Bool {
        guard let detail = entries[id] else { return false }
        entries[id] = SessionDetail(
            summary: transform(detail.summary),
            turns: detail.turns,
            timeline: detail.timeline,
            nextCursor: detail.nextCursor
        )
        return true
    }

    @discardableResult
    mutating func evict(_ id: SessionID) -> Bool {
        guard let detail = entries.removeValue(forKey: id) else { return false }
        recency.removeAll { $0 == id }
        statistics.evictions += 1
        dbLog.debug("detail_cache_evict", metadata: .fields([
            "session": id.rawValue,
            "timeline": detail.timeline.count,
            "resident": entries.count,
        ]))
        return true
    }

    /// The pinned entry survives capacity trimming; it still leaves through
    /// `evict` and `fold` (a deleted or hidden lead is gone for real).
    mutating func pin(_ id: SessionID?) {
        pinnedID = id
    }

    /// One reload's worth of change from the cache database, folded into
    /// the resident copies so they need no re-read:
    ///
    /// - a `.discard` evicts the session (the repository tombstones it;
    ///   events after the discard belong to a session that must be reloaded
    ///   from the database, not reduced from the stale copy);
    /// - the other events of a resident session upsert through
    ///   `SessionDetailReduction` in one batch;
    /// - every resident session then takes its summary from `summaries`
    ///   (the row the database now holds, filter verdict included), and a
    ///   session absent from `summaries` — deleted, pruned, hidden — is
    ///   evicted.
    ///
    /// Returns the ids whose resident copy changed.
    mutating func fold(
        events: [AgentIngressEvent],
        summaries: [SessionID: SessionSummary]
    ) -> Set<SessionID> {
        var changed: Set<SessionID> = []
        var pending: [SessionID: [AgentIngressEvent]] = [:]
        for event in events {
            if event.disposition == .discard {
                pending[event.sessionID] = nil
                if evict(event.sessionID) { changed.insert(event.sessionID) }
            } else if entries[event.sessionID] != nil {
                pending[event.sessionID, default: []].append(event)
            }
        }
        for (id, batch) in pending {
            guard let detail = entries[id] else { continue }
            entries[id] = SessionDetailReduction.applying(batch, to: detail)
            changed.insert(id)
        }
        for id in recency {
            guard let summary = summaries[id] else {
                if evict(id) { changed.insert(id) }
                continue
            }
            if let detail = entries[id], detail.summary != summary {
                entries[id] = SessionDetail(
                    summary: summary,
                    turns: detail.turns,
                    timeline: detail.timeline,
                    nextCursor: detail.nextCursor
                )
                changed.insert(id)
            }
        }
        return changed
    }

    // MARK: - Recency

    private mutating func markRecent(_ id: SessionID) {
        recency.removeAll { $0 == id }
        recency.append(id)
    }

    private mutating func trim() {
        var index = 0
        while entries.count > capacity, index < recency.count {
            let candidate = recency[index]
            if candidate == pinnedID {
                index += 1
                continue
            }
            evict(candidate)
        }
    }
}
