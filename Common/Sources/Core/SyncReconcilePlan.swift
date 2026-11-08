import Transport
import Foundation

/// What a lazy mirror remembers about one session whose rows it holds: the
/// daemon's timeline facts as of the last sync that completed, and the
/// window of rows it has loaded. Persisted by the mirror next to its cache;
/// the index reconcile and `openSession` both read it.
///
/// The facts are the daemon's, not the mirror's own row count: a mirror
/// holds a tail, so its count says nothing about whether the daemon's copy
/// changed. The window says how far back the loaded rows reach, so paging
/// older history asks for exactly what is missing.
public struct SessionSyncMark: Codable, Hashable, Sendable {
    /// `COUNT(*)` the daemon reported when this mark was taken; `nil` once
    /// live events moved the copy on without a fresh index.
    public var timelineItemCount: Int?
    /// `MAX(occurred_at)` the daemon reported, or the newest row received.
    public var lastItemAt: Date?
    /// The oldest row the mirror has loaded contiguously up from the newest;
    /// `nil` while nothing (or nothing known) is loaded.
    public var oldest: TimelineCursor?
    /// The daemon holds rows older than `oldest`.
    public var hasOlder: Bool

    public init(timelineItemCount: Int? = nil, lastItemAt: Date? = nil, oldest: TimelineCursor? = nil, hasOlder: Bool = true) {
        self.timelineItemCount = timelineItemCount
        self.lastItemAt = lastItemAt
        self.oldest = oldest
        self.hasOlder = hasOlder
    }

    /// Rows are loaded and the window is known.
    public var isLoaded: Bool { oldest != nil }
}

/// What a mirror must do to converge its cached sessions onto an
/// authoritative index. Pure; two mirrors use it two ways:
///
/// - `make` is the eager mirror: every session's rows are held in full and
///   compared by the mirror's own row facts (`cache.sessionIndex()`).
/// - `lazy` is the iPhone: rows are held as a tail, only for sessions the
///   person opened, and compared by the `SessionSyncMark` taken when they
///   were last synced. Everything else is reconciled by summary alone.
///
/// - `prune`: cached sessions the index no longer lists.
/// - `fetchFull`: sessions to take whole (eager) — unknown locally, or whose
///   timeline differs too much to patch.
/// - `rebuild`: held sessions whose daemon copy changed under the mark (rows
///   removed, the newest row moved back, the count changed in place): erase
///   the loaded rows and take the tail again.
/// - `fetchSince`: sessions whose timeline grew; ask for rows from `since`
///   on (the mark's `lastItemAt` minus a small overlap — upserts by id make
///   the overlap harmless).
/// - `infoOnly`: sessions whose rows are current but whose summary changed
///   (phase flip, reviewed, archived); write the summary, nothing else.
/// - `insert`: sessions unknown locally that the mirror keeps summary-only.
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
    public let rebuild: [SessionID]
    public let fetchSince: [SinceRequest]
    public let infoOnly: [SessionSummary]
    public let insert: [SessionSummary]

    public var isEmpty: Bool {
        prune.isEmpty && fetchFull.isEmpty && rebuild.isEmpty && fetchSince.isEmpty && infoOnly.isEmpty && insert.isEmpty
    }

    /// Rows beyond this many missing locally are cheaper to replace than to patch (eager mirrors).
    public static let defaultLargeDeltaThreshold = 200
    /// Overlap subtracted from the high-water mark when patching.
    public static let sinceOverlap: TimeInterval = 60

    /// The eager mirror: every session's rows are held in full.
    public static func make(
        local: [SessionIndexEntry],
        remote: [SessionIndexEntry],
        largeDeltaThreshold: Int = defaultLargeDeltaThreshold
    ) -> SyncReconcilePlan {
        let localByID = Dictionary(local.map { ($0.summary.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteIDs = Set(remote.map(\.summary.id))

        var fetchFull: [SessionID] = []
        var fetchSince: [SinceRequest] = []
        var infoOnly: [SessionSummary] = []
        for entry in remote {
            let id = entry.summary.id
            guard let cached = localByID[id] else {
                fetchFull.append(id)
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
        return SyncReconcilePlan(prune: prune, fetchFull: fetchFull, rebuild: [], fetchSince: fetchSince, infoOnly: infoOnly, insert: [])
    }

    /// The lazy mirror. `local` is the cache's index (which sessions are
    /// cached and with what summary); `marks` are the sync marks of the
    /// sessions whose rows are loaded. A cached session without a loaded
    /// mark moves by summary alone — its rows are taken when it is opened.
    public static func lazy(
        local: [SessionIndexEntry],
        remote: [SessionIndexEntry],
        marks: [SessionID: SessionSyncMark]
    ) -> SyncReconcilePlan {
        let localByID = Dictionary(local.map { ($0.summary.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteIDs = Set(remote.map(\.summary.id))

        var rebuild: [SessionID] = []
        var fetchSince: [SinceRequest] = []
        var infoOnly: [SessionSummary] = []
        var insert: [SessionSummary] = []
        for entry in remote {
            let id = entry.summary.id
            guard let cached = localByID[id] else {
                insert.append(entry.summary)
                continue
            }
            if let mark = marks[id], mark.isLoaded {
                switch classify(remote: entry, mark: mark) {
                case .rebuild:
                    rebuild.append(id)
                    continue
                case let .fetchSince(since):
                    fetchSince.append(SinceRequest(sessionID: id, since: since))
                    continue
                case .upToDate:
                    break
                }
            }
            if cached.summary != entry.summary { infoOnly.append(entry.summary) }
        }
        let prune = Set(localByID.keys.filter { !remoteIDs.contains($0) })
        return SyncReconcilePlan(prune: prune, fetchFull: [], rebuild: rebuild, fetchSince: fetchSince, infoOnly: infoOnly, insert: insert)
    }

    /// How a held session's daemon facts relate to the mark taken when it
    /// was last synced.
    public enum HeldAction: Hashable, Sendable {
        /// The daemon's copy changed under the mark: erase the loaded rows
        /// and take the tail again.
        case rebuild
        /// Rows were added: ask for them from `since` on.
        case fetchSince(Date)
        case upToDate
    }

    public static func classify(remote: SessionIndexEntry, mark: SessionSyncMark) -> HeldAction {
        switch (mark.lastItemAt, remote.lastItemAt) {
        case (nil, nil):
            return .upToDate
        case (nil, .some):
            return .fetchSince(.distantPast)
        case (.some, nil):
            return .rebuild
        case let (.some(marked), .some(current)):
            if current < marked { return .rebuild }
            if current > marked { return .fetchSince(marked.addingTimeInterval(-sinceOverlap)) }
            if let count = mark.timelineItemCount, count != remote.timelineItemCount { return .rebuild }
            return .upToDate
        }
    }

    public init(
        prune: Set<SessionID>,
        fetchFull: [SessionID],
        rebuild: [SessionID] = [],
        fetchSince: [SinceRequest],
        infoOnly: [SessionSummary],
        insert: [SessionSummary] = []
    ) {
        self.prune = prune
        self.fetchFull = fetchFull
        self.rebuild = rebuild
        self.fetchSince = fetchSince
        self.insert = insert
        self.infoOnly = infoOnly
    }
}
