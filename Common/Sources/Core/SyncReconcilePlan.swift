import Transport
import Foundation

/// What a mirror must do to converge its cached sessions onto an
/// authoritative index. Pure: the iPhone feeds it `cache.sessionIndex()` and
/// the daemon's `session_index`; the same rule would serve any other mirror.
///
/// - `prune`: cached sessions the index no longer lists.
/// - `fetchFull`: sessions to take whole — unknown locally, or whose timeline
///   differs too much to patch (local empty, more rows locally than remotely,
///   or a gap above `largeDeltaThreshold`).
/// - `fetchSince`: sessions whose timeline grew or moved; ask for rows from
///   `since` on (the local `lastItemAt` minus a small overlap, so late-arriving
///   rows are not missed — upserts by id make the overlap harmless).
/// - `infoOnly`: sessions whose timeline facts match but whose summary
///   changed (phase flip, reviewed, archived); write the summary, nothing else.
/// - `insert`: sessions unknown locally that the mirror keeps summary-only
///   (lazy mirrors: the timeline is taken only when the person opens it).
///
/// A lazy mirror passes `materialized`: the sessions whose timeline it
/// holds (or is showing). Every other session is reconciled by summary
/// alone — unknown ones are inserted summary-only, known ones get
/// `infoOnly` when the summary moved — and never fetched here; the mirror
/// fetches on open. `nil` is the eager mirror: everything is fetched.
public struct SyncReconcilePlan: Hashable, Sendable {
    public struct SinceRequest: Hashable, Sendable {
        public let sessionID: SessionID
        public let since: Date

        public init(sessionID: SessionID, since: Date) {
            self.sessionID = sessionID
            self.since = since
        }
    }

    public let prune: Set<SessionID>
    public let fetchFull: [SessionID]
    public let fetchSince: [SinceRequest]
    public let infoOnly: [SessionSummary]
    public let insert: [SessionSummary]

    public var isEmpty: Bool {
        prune.isEmpty && fetchFull.isEmpty && fetchSince.isEmpty && infoOnly.isEmpty && insert.isEmpty
    }

    /// Rows beyond this many missing locally are cheaper to replace than to patch.
    public static let defaultLargeDeltaThreshold = 200
    /// Overlap subtracted from the local high-water mark when patching.
    public static let sinceOverlap: TimeInterval = 60

    public static func make(
        local: [SessionIndexEntry],
        remote: [SessionIndexEntry],
        largeDeltaThreshold: Int = defaultLargeDeltaThreshold,
        materialized: Set<SessionID>? = nil
    ) -> SyncReconcilePlan {
        let localByID = Dictionary(local.map { ($0.summary.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteIDs = Set(remote.map(\.summary.id))

        var fetchFull: [SessionID] = []
        var fetchSince: [SinceRequest] = []
        var infoOnly: [SessionSummary] = []
        var insert: [SessionSummary] = []
        for entry in remote {
            let id = entry.summary.id
            guard let cached = localByID[id] else {
                if materialized == nil { fetchFull.append(id) } else { insert.append(entry.summary) }
                continue
            }
            if let materialized, !materialized.contains(id) {
                if cached.summary != entry.summary { infoOnly.append(entry.summary) }
                continue
            }
            let timelineMatches = cached.timelineItemCount == entry.timelineItemCount
                && cached.lastItemAt == entry.lastItemAt
            if timelineMatches {
                if cached.summary != entry.summary { infoOnly.append(entry.summary) }
                continue
            }
            let delta = entry.timelineItemCount - cached.timelineItemCount
            if cached.timelineItemCount == 0 || delta < 0 || delta > largeDeltaThreshold {
                fetchFull.append(id)
            } else {
                let since = (cached.lastItemAt ?? .distantPast).addingTimeInterval(-sinceOverlap)
                fetchSince.append(SinceRequest(sessionID: id, since: since))
            }
        }
        let prune = Set(localByID.keys.filter { !remoteIDs.contains($0) })
        return SyncReconcilePlan(prune: prune, fetchFull: fetchFull, fetchSince: fetchSince, infoOnly: infoOnly, insert: insert)
    }

    public init(prune: Set<SessionID>, fetchFull: [SessionID], fetchSince: [SinceRequest], infoOnly: [SessionSummary], insert: [SessionSummary] = []) {
        self.prune = prune
        self.fetchFull = fetchFull
        self.fetchSince = fetchSince
        self.insert = insert
        self.infoOnly = infoOnly
    }
}
