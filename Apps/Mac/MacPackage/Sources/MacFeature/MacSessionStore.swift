import Core
import Persistence
import IPCClient
import Diagnostics
import Logging
import Transport
import Foundation

private let log = Logger(label: "ipc")
private let agentLog = Logger(label: "agent")
private let convertLog = Logger(label: "convert")
private let dbLog = Logger(label: "db")

/// The store's daemon request seam; production is `DaemonIPCClient`, tests
/// inject a scripted stub.
public protocol MacDaemonClient: Sendable {
    func request(_ request: IPCRequest, socketPath: String, timeoutSeconds: Int64) throws -> IPCResponse
    /// Same round trip, allowed to start a stopped daemon first (`wake`) and
    /// to log an expected failure below warning (`failureLogLevel`).
    func request(
        _ request: IPCRequest,
        socketPath: String,
        timeoutSeconds: Int64,
        wake: DaemonWakePolicy?,
        failureLogLevel: Logger.Level
    ) throws -> IPCResponse
}

extension MacDaemonClient {
    /// Stubs without a wake path answer as if none were asked for.
    public func request(
        _ request: IPCRequest,
        socketPath: String,
        timeoutSeconds: Int64,
        wake: DaemonWakePolicy?,
        failureLogLevel: Logger.Level
    ) throws -> IPCResponse {
        try self.request(request, socketPath: socketPath, timeoutSeconds: timeoutSeconds)
    }

    /// The blocking socket round trip off the main actor.
    func send(
        _ request: IPCRequest,
        socketPath: String,
        timeoutSeconds: Int64 = 15,
        wake: DaemonWakePolicy? = nil,
        failureLogLevel: Logger.Level = .warning
    ) async throws -> IPCResponse {
        try await Task.detached {
            try self.request(
                request, socketPath: socketPath, timeoutSeconds: timeoutSeconds, wake: wake, failureLogLevel: failureLogLevel
            )
        }.value
    }
}

extension DaemonIPCClient: MacDaemonClient {
    public func request(_ request: IPCRequest, socketPath: String, timeoutSeconds: Int64) throws -> IPCResponse {
        try self.request(request, socketPath: socketPath, timeout: .seconds(timeoutSeconds))
    }

    public func request(
        _ request: IPCRequest,
        socketPath: String,
        timeoutSeconds: Int64,
        wake: DaemonWakePolicy?,
        failureLogLevel: Logger.Level
    ) throws -> IPCResponse {
        try self.request(
            request, socketPath: socketPath, timeout: .seconds(timeoutSeconds), wake: wake, failureLogLevel: failureLogLevel
        )
    }
}

/// A `health` request that came back without one.
public enum DaemonProbeError: Error, Sendable {
    case healthMissing
}

@MainActor
public final class MacSessionStore {
    public private(set) var sessions: [SessionSummary] = []
    /// Latest CLI-reported model / reasoning effort per visible session (the
    /// Sessions list subtitle). Filled from the local cache alongside
    /// `sessions`; kept current from streamed model-configuration events and
    /// re-read for sessions the reconcile replaced.
    public private(set) var modelStamps: [SessionID: SessionModelStamp] = [:]
    /// Bumped by every stamp invalidation; a cache read that straddled an
    /// invalidation is discarded instead of resurrecting the stale value.
    private var modelStampEpoch: UInt64 = 0
    /// The selected lead's whole detail, when resident. Loads land in
    /// `detailCache`; there is no second copy.
    public var selectedSession: SessionDetail? {
        pendingSelectionID.flatMap { detailCache.peek($0) }
    }
    /// The whole selection, in selection-recency order: session blocks from
    /// a multi-select, or a single subagent line. The last element is the
    /// natural lead fallback when the lead itself is deselected.
    public private(set) var selectedIDs: [SessionID] = []
    public private(set) var health: DaemonHealth?
    /// Why the daemon is not answering, classified; `nil` while it is.
    public private(set) var connectionFailure: DaemonConnectionFailure?
    /// The Mac's own sync database failing — separate from the daemon, which
    /// may be perfectly fine.
    public private(set) var cacheError: String?
    /// The failure as one line, for places that only show text.
    public var connectionError: String? { connectionFailure?.description }
    /// Pacing of the event stream's reconnects; reset by every answer.
    private var reconnectBackoff = DaemonReconnectBackoff()
    /// Whether this store talks to the installed daemon (the one launchd
    /// runs for the app's LaunchAgent). False under `LUMI_SOCKET` /
    /// `LUMI_SUPPORT_DIRECTORY` and in tests, where the daemon on the socket
    /// is some other process and the registered service must be left alone.
    /// Decided from the socket, not from the wake policy: `LUMI_WAKE_SERVICE=0`
    /// only turns the wake off.
    public let talksToInstalledDaemon: Bool
    public private(set) var dataRevision: UInt64 = 0

    private let client: any MacDaemonClient
    private let eventSubscriber = DaemonEventSubscriber()
    private let socketPath: String
    /// The stream is the one app-side client that wakes a stopped daemon:
    /// its reconnect loop keeps trying, so short requests never need to.
    /// Derived from the socket path unless given: only the installed
    /// daemon's socket wakes the installed daemon.
    private let wake: DaemonWakePolicy?
    private let cache: SQLiteSessionRepository?
    private let cachePath: String
    private var started = false
    private var observers = ObserverRegistry()
    private var pendingSelectionID: SessionID?
    private var reconcileTask: Task<Void, Never>?
    private var reconcilePending = false
    private var eventApplyTask: Task<Void, Never>?
    /// Kept in arrival order: the daemon's order is the only correct one once
    /// a batch can contain a session discard next to a resurrecting prompt.
    private var pendingEvents: [AgentIngressEvent] = []
    private var pendingEventIDs: Set<EventID> = []
    private var reconnectTask: Task<Void, Never>?
    /// Whole sessions resident in memory: the selected lead (pinned) and
    /// whatever the Notch's working set last claimed. Everything else is
    /// re-read from the cache database on demand.
    private var detailCache = SessionDetailCache()
    /// Bumped by every write to the cache database. A detail load pages the
    /// database in several reads; one that straddled a write is re-read so
    /// the resident copy never misses a row the fold did not see.
    private var detailEpoch: UInt64 = 0

    public init(
        socketPath: String = DaemonEndpoint.defaultSocketPath(),
        wake: DaemonWakePolicy? = nil,
        cachePath: String? = nil,
        client: any MacDaemonClient = DaemonIPCClient()
    ) {
        self.socketPath = socketPath
        self.wake = wake ?? .default(socketPath: socketPath, timeout: .seconds(8))
        self.talksToInstalledDaemon = DaemonEndpoint.isInstalledDaemonSocket(socketPath)
        self.client = client
        let resolvedCachePath: String
        if let cachePath {
            resolvedCachePath = cachePath
        } else {
            resolvedCachePath = Self.defaultCachePath()
            // Only the default path retires the older cache files: an
            // explicit path (parameter or `LUMI_MAC_CACHE`) is an isolated
            // cache with no predecessor.
            if ProcessInfo.processInfo.environment["LUMI_MAC_CACHE"]?.isEmpty != false {
                Self.discardRetiredCaches(Self.retiredDefaultCachePaths())
            }
        }
        self.cachePath = resolvedCachePath
        do {
            cache = try SQLiteSessionRepository(path: resolvedCachePath)
        } catch {
            cache = nil
            cacheError = "Unable to open the macOS sync database: \(error)"
            dbLog.error("cache_open_failed", metadata: .fields(["path": resolvedCachePath, "error": error]))
        }
    }

    /// Session data refreshes only here (startup), in `refresh()` (manual), or
    /// from the daemon event stream (`enqueueAgentEvent`).
    public func start() {
        guard !started else { return }
        started = true
        Task { [weak self] in
            guard let self else { return }
            await self.reloadFromCache()
            self.scheduleReconcile()
            self.connectEventStream()
        }
    }

    public func stop() {
        started = false
        reconcileTask?.cancel()
        reconcileTask = nil
        eventApplyTask?.cancel()
        eventApplyTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        eventSubscriber.stop()
    }

    @discardableResult
    public func observe(_ observer: @escaping () -> Void) -> UUID {
        observers.add(observer)
    }

    /// The session driving the detail pane, synchronously — set before the
    /// async detail load lands, so views can paint selection immediately.
    public var leadSelectedID: SessionID? {
        pendingSelectionID
    }

    /// Hit / miss / eviction counters of the resident detail set.
    var detailCacheStatistics: SessionDetailCache.Statistics {
        detailCache.statistics
    }

    public func select(_ sessionID: SessionID?) {
        setSelection(sessionID.map { [$0] } ?? [], lead: sessionID)
    }

    /// Replaces the selection as a whole. `ids` keeps selection-recency
    /// order; `lead` (one of `ids`, or nil to clear the detail pane) is the
    /// session whose detail loads.
    public func setSelection(_ ids: [SessionID], lead: SessionID?) {
        var seen = Set<SessionID>()
        let unique = ids.filter { seen.insert($0).inserted }
        let selectionChanged = unique != selectedIDs
        selectedIDs = unique
        guard let lead else {
            if pendingSelectionID != nil {
                pendingSelectionID = nil
                detailCache.pin(nil)
                notifyObservers()
            } else if selectionChanged {
                notifyObservers()
            }
            return
        }
        // Selecting is viewing — even a re-click of the already selected row
        // clears a review flag a fresh turn end may have raised.
        markSessionReviewed(lead)
        if selectionChanged { notifyObservers() }
        guard pendingSelectionID != lead || detailCache.peek(lead) == nil else { return }
        let sessionID = lead
        pendingSelectionID = sessionID
        detailCache.pin(sessionID)
        if detailCache.touch(sessionID) != nil {
            // The Notch loaded it moments ago; the pane paints from the
            // resident copy without another page through the database.
            notifyObservers()
            return
        }
        guard cache != nil else { return }
        Task {
            do {
                let detail = try await loadDetail(sessionID)
                guard pendingSelectionID == sessionID else { return }
                if let detail { detailCache.insert(detail) } else { detailCache.evict(sessionID) }
                notifyObservers()
            } catch {
                cacheError = "Unable to read the macOS sync database: \(error)"
                dbLog.error("cache_read_failed", metadata: .fields(["session": sessionID.rawValue, "error": error]))
                notifyObservers()
            }
        }
    }

    /// Size of the local sync database on disk (Settings › Daemon › Session history).
    public func cacheDatabaseSizeBytes() -> Int64? {
        let manager = FileManager.default
        var total: Int64 = 0
        var found = false
        for suffix in ["", "-wal", "-shm"] {
            guard let attributes = try? manager.attributesOfItem(atPath: cachePath + suffix),
                  let size = attributes[.size] as? NSNumber else { continue }
            total += size.int64Value
            found = true
        }
        return found ? total : nil
    }

    /// Daemon-management actions: resync from the daemon as it is.
    public func refresh() {
        guard started else { return }
        scheduleReconcile()
        connectEventStream()
    }

    /// The toolbar refresh: the selected session is first rebuilt by the
    /// daemon from its transcript / rollout (`reingest_session`), then the
    /// whole snapshot is resynced so the wiped-and-rebuilt session replaces
    /// the cached one. Without a selection this is a plain `refresh()`.
    public func refreshSelectedSession() {
        guard let sessionID = pendingSelectionID ?? selectedSession?.summary.id else {
            refresh()
            return
        }
        Task {
            do {
                // The rebuild replays the whole transcript before replying.
                let response = try await request(
                    IPCRequest(operation: .reingestSession, sessionID: sessionID),
                    timeoutSeconds: 60
                )
                if let failure = response.failure { throw failure }
                // The rebuild is not streamed, and the reply is only the
                // completion signal (summary + turns): the rebuilt timeline
                // is paged back here — whole, unlike a mid-rebuild snapshot,
                // and within the frame limit, unlike a single-frame detail.
                if response.session != nil, let cache,
                   let detail = try await fetchFullDetail(id: sessionID) {
                    try await cache.replaceSession(detail)
                    noteCacheWrite()
                    detailCache.replaceIfPresent(detail)
                    invalidateModelStamp(sessionID)
                    convertLog.info("session_refreshed", metadata: .fields([
                        "session": sessionID.rawValue,
                        "timeline": detail.timeline.count,
                        "turns": detail.turns.count,
                    ]))
                    await reloadFromCache(persistedDataChanged: true)
                }
            } catch {
                handleConnectionFailure(error, action: "refresh_session")
            }
            refresh()
        }
    }

    /// The human opened the session: clear its review flag in the in-memory
    /// list at once (the tier steps down while they look), then in the local
    /// cache and the daemon so every mirror agrees.
    public func markSessionReviewed(_ sessionID: SessionID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              sessions[index].needsReview else { return }
        sessions[index] = sessions[index].reviewed
        detailCache.patchSummary(sessionID) { $0.reviewed }
        notifyObservers(dataChanged: true)
        Task {
            do {
                if let cache {
                    try await cache.markSessionReviewed(sessionID)
                    noteCacheWrite()
                }
                let response = try await request(IPCRequest(operation: .markSessionReviewed, sessionID: sessionID))
                if let failure = response.failure { throw failure }
            } catch {
                handleConnectionFailure(error, action: "mark_reviewed")
            }
        }
    }

    /// The human archived the session from the Notch: raise its
    /// `hiddenInNotch` flag in the in-memory list at once (the Notch row
    /// disappears immediately), then in the local cache and the daemon so
    /// every mirror agrees. The Mac window keeps showing the session.
    public func markSessionHiddenInNotch(_ sessionID: SessionID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              !sessions[index].hiddenInNotch else { return }
        sessions[index] = sessions[index].withHiddenInNotch(true)
        detailCache.patchSummary(sessionID) { $0.withHiddenInNotch(true) }
        notifyObservers(dataChanged: true)
        Task {
            do {
                if let cache {
                    try await cache.markSessionHiddenInNotch(sessionID)
                    noteCacheWrite()
                }
                let response = try await request(IPCRequest(operation: .markSessionHiddenInNotch, sessionID: sessionID))
                if let failure = response.failure { throw failure }
            } catch {
                handleConnectionFailure(error, action: "hide_in_notch")
            }
        }
    }

    public func deleteSession(_ sessionID: SessionID) {
        deleteSessions([sessionID])
    }

    /// One batch for a multi-selection: all cache rows go in one pass with a
    /// single reload, then one IPC round per session and a single reconcile.
    /// A daemon failure mid-batch surfaces as a connection error and the
    /// reconcile restores whatever the daemon still holds.
    public func deleteSessions(_ sessionIDs: [SessionID]) {
        guard !sessionIDs.isEmpty else { return }
        Task {
            do {
                // Optimistic local delete: the rows leave the UI at once; the
                // local tombstone swallows in-flight stragglers exactly like
                // the daemon's, and reconcile converges on the daemon's truth
                // either way.
                if let cache {
                    for sessionID in sessionIDs {
                        _ = try await cache.deleteSession(id: sessionID)
                        detailCache.evict(sessionID)
                    }
                    noteCacheWrite()
                    await reloadFromCache(persistedDataChanged: true)
                }
                for sessionID in sessionIDs {
                    let response = try await request(IPCRequest(operation: .deleteSession, sessionID: sessionID))
                    if let failure = response.failure { throw failure }
                    dbLog.info("session_delete_requested", metadata: .fields(["session": sessionID.rawValue]))
                }
                scheduleReconcile()
            } catch {
                handleConnectionFailure(error, action: "delete_session")
            }
        }
    }

    public func clearHistory() {
        Task {
            do {
                if let cache {
                    _ = try await cache.deleteAllSessions()
                    for id in detailCache.residentIDs { detailCache.evict(id) }
                    noteCacheWrite()
                    await reloadFromCache(persistedDataChanged: true)
                }
                let response = try await request(IPCRequest(operation: .clearHistory))
                if let failure = response.failure { throw failure }
                dbLog.info("history_clear_requested")
                scheduleReconcile()
            } catch {
                handleConnectionFailure(error, action: "clear_history")
            }
        }
    }

    /// Whole session details for the Notch's working set, from the resident
    /// copies where they exist and the already-synchronized cache database
    /// where they do not. A loaded session becomes resident (most recent
    /// first), so the next reload folds streamed events into it instead of
    /// paging the database again. Never touches the daemon. A session the
    /// database no longer holds is left out; a database failure is thrown
    /// after being logged.
    public func cachedSessionDetails(ids: [SessionID]) async throws -> [SessionDetail] {
        guard cache != nil else { throw MacSessionStoreError.cacheUnavailable }
        var details: [SessionDetail] = []
        details.reserveCapacity(ids.count)
        for id in ids {
            if let resident = detailCache.touch(id) {
                details.append(resident)
                continue
            }
            do {
                guard let detail = try await loadDetail(id) else { continue }
                detailCache.insert(detail)
                details.append(detail)
            } catch {
                dbLog.error("cache_read_failed", metadata: .fields(["session": id.rawValue, "error": error]))
                throw error
            }
        }
        return details
    }

    /// The whole form of each row the cache holds trimmed, straight from the
    /// daemon (`get_timeline_items`); rows that fit the budget come back as
    /// they are. One request per row, so one large row never shares a frame
    /// with another. The whole rows are not cached — the cache keeps mirror
    /// rows only. Any failure is thrown for the caller to show.
    public func wholeTimelineItems(_ items: [TimelineItem]) async throws -> [TimelineItem] {
        let started = ContinuousClock.now
        var whole: [TimelineItem] = []
        whole.reserveCapacity(items.count)
        var fetched = 0
        do {
            for item in items {
                guard item.isTruncated else {
                    whole.append(item)
                    continue
                }
                let response = try await request(
                    IPCRequest(operation: .getTimelineItems, sessionID: item.sessionID, itemIDs: [item.id]),
                    timeoutSeconds: 15
                )
                if let failure = response.failure { throw failure }
                guard let row = response.session?.timeline.first(where: { $0.id == item.id }) else {
                    throw MacSessionStoreError.timelineItemMissing(item.id)
                }
                whole.append(row)
                fetched += 1
            }
        } catch {
            dbLog.error("timeline_items_fetch_failed", metadata: .fields([
                "session": items.first?.sessionID.rawValue,
                "items": items.count,
                "error": error,
            ]))
            throw error
        }
        dbLog.info("timeline_items_fetched", metadata: .fields([
            "session": items.first?.sessionID.rawValue,
            "fetched": fetched,
            "ms": LogClock.milliseconds(since: started),
        ]))
        return whole
    }

    /// Reconciles the local cache with the daemon at session granularity: a
    /// summary index decides which sessions to refetch in full (paged
    /// `get_session`) and which to prune. Full state never crosses the socket
    /// in one frame — the whole-snapshot pull outgrew the IPC frame limit.
    private func scheduleReconcile() {
        guard cache != nil else { return }
        reconcilePending = true
        guard reconcileTask == nil else { return }
        reconcileTask = Task { [weak self] in
            guard let self else { return }
            while self.reconcilePending, !Task.isCancelled {
                self.reconcilePending = false
                if let eventApplyTask = self.eventApplyTask {
                    await eventApplyTask.value
                }
                // One reconcile pass is one unit of work; its id rides on
                // every IPC request it makes, so the daemon's lines match.
                await withTrace(makeTraceID()) {
                    do {
                        try await self.reconcileOnce()
                    } catch {
                        self.handleConnectionFailure(error, action: "reconcile")
                    }
                }
            }
            self.reconcileTask = nil
            if self.reconcilePending, !Task.isCancelled {
                self.scheduleReconcile()
            } else if !self.pendingEvents.isEmpty, !Task.isCancelled {
                self.scheduleEventApply()
            }
        }
    }

    private func reconcileOnce() async throws {
        guard let cache else { return }
        let started = ContinuousClock.now
        let healthResponse = try await request(IPCRequest(operation: .health))
        if let failure = healthResponse.failure { throw failure }
        let indexResponse = try await request(IPCRequest(operation: .listSessions, limit: 10_000))
        if let failure = indexResponse.failure { throw failure }
        // The cache keeps everything (a provisional session must still be
        // there when its first Turn arrives); visibility is filtered at read
        // time, so the index and the fetches carry all sessions.
        let index = indexResponse.sessions ?? []
        // The daemon rewrote rows it already held (`HistoryRevision`): no
        // summary and no clock moved, so the diff below cannot see it. A copy
        // taken from another revision is dropped and taken again.
        let daemonRevision = healthResponse.health?.historyRevision ?? HistoryRevision.first
        // A cache from before revisions were recorded was taken from a
        // daemon at the first one.
        let cacheRevision = try await cache.historyRevision() ?? HistoryRevision.first
        if cacheRevision != daemonRevision {
            let dropped = try await cache.pruneSessions(keeping: [])
            try await cache.setHistoryRevision(daemonRevision)
            if dropped > 0 { noteCacheWrite() }
            dbLog.info("cache_rebuilt_for_history_revision", metadata: .fields([
                "from": cacheRevision,
                "to": daemonRevision,
                "dropped": dropped,
            ]))
        }
        let local = try await cache.listSessions(limit: 10_000)
        let plan = SessionReconcilePlan.make(local: local, daemon: index)
        var fetched = 0
        var missing = 0
        for id in plan.fetch {
            guard let detail = try await fetchFullDetail(id: id) else {
                missing += 1
                continue
            }
            try await cache.replaceSession(detail)
            noteCacheWrite()
            // The resident copy, if any, takes the daemon's whole page; an
            // absent session stays absent rather than pulling every
            // reconciled session into memory.
            detailCache.replaceIfPresent(detail)
            // The replace may have rewritten model-configuration items; the
            // stamp is re-read from the cache on the reload below.
            invalidateModelStamp(id)
            fetched += 1
        }
        let changed = fetched > 0
        let pruned = try await cache.pruneSessions(keeping: Set(index.map(\.id)))
        if pruned > 0 { noteCacheWrite() }
        health = healthResponse.health
        daemonAnswered()
        dbLog.info("reconciled", metadata: .fields([
            "daemon_sessions": index.count,
            "local_sessions": local.count,
            "planned": plan.fetch.count,
            "fetched": fetched,
            "missing": missing,
            "pruned": pruned,
            "ms": LogClock.milliseconds(since: started),
        ]))
        await reloadFromCache(persistedDataChanged: changed || pruned > 0)
    }

    /// Pages one session out of the daemon. A page that overflows the IPC
    /// frame limit is retried with a much smaller page; a session deleted
    /// mid-reconcile is skipped (the next index prunes it).
    private func fetchFullDetail(id: SessionID) async throws -> SessionDetail? {
        var cursor: PaginationCursor?
        var timeline: [TimelineItem] = []
        var turns: [TurnSummary] = []
        var summary: SessionSummary?
        var limit = 200
        var done = false
        while !done {
            let response = try await request(
                IPCRequest(operation: .getSession, sessionID: id, cursor: cursor, limit: limit),
                timeoutSeconds: 15
            )
            if let failure = response.failure {
                if failure.code == "session_not_found" { return nil }
                // Rows arrive trimmed to the mirror budget, but a page of
                // them can still overflow the frame; shrink all the way down
                // to one item per page.
                if failure.code == "response_too_large", limit > 1 {
                    log.warning("session_page_too_large", metadata: .fields(["session": id.rawValue, "limit": limit]))
                    limit = max(1, limit / 8)
                    continue
                }
                throw failure
            }
            guard let page = response.session else { return nil }
            summary = page.summary
            if !page.turns.isEmpty { turns = page.turns }
            timeline.append(contentsOf: page.timeline)
            cursor = page.nextCursor
            done = cursor == nil
        }
        return summary.map { SessionDetail(summary: $0, turns: turns, timeline: timeline) }
    }

    func enqueueAgentEvent(_ event: AgentIngressEvent) {
        guard pendingEventIDs.insert(event.eventID).inserted else { return }
        pendingEvents.append(event)
        scheduleEventApply()
    }

    /// A summary-only change streamed by the daemon (reviewed on an iPhone,
    /// archived from another window): written to the local cache and shown
    /// at once, so the window and the Notch turn grey together with the
    /// iPhone that opened the session.
    func applyStreamedSummary(_ summary: SessionSummary) {
        guard let cache else { return }
        Task {
            do {
                try await cache.updateSummary(summary)
                noteCacheWrite()
                agentLog.debug("summary_applied", metadata: .fields(["session": summary.id.rawValue]))
                // The reload's fold hands every resident copy the summary
                // row the database now holds.
                await reloadFromCache(persistedDataChanged: true)
            } catch {
                cacheError = "Unable to apply the daemon summary: \(error)"
                dbLog.error("summary_apply_failed", metadata: .fields(["session": summary.id.rawValue, "error": error]))
                notifyObservers()
            }
        }
    }

    /// Test hook: waits until every queued daemon event has been applied and
    /// the visible session list reloaded.
    func flushPendingEventsForTesting() async {
        while let task = eventApplyTask {
            await task.value
        }
    }

    /// Test hook: runs one reconcile pass to completion without touching the
    /// event stream.
    func reconcileForTesting() async {
        scheduleReconcile()
        while let task = reconcileTask {
            await task.value
        }
    }

    private func scheduleEventApply() {
        guard eventApplyTask == nil, reconcileTask == nil else { return }
        eventApplyTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(50))
            var appliedAny = false
            var appliedEvents: [AgentIngressEvent] = []
            var received = 0
            var failed = 0
            while !self.pendingEvents.isEmpty, !Task.isCancelled {
                let batch = self.pendingEvents
                self.pendingEvents.removeAll(keepingCapacity: true)
                self.pendingEventIDs.removeAll(keepingCapacity: true)
                guard let cache = self.cache else { break }
                received += batch.count
                for event in batch {
                    do {
                        if try await cache.apply(event) {
                            noteCacheWrite()
                            appliedAny = true
                            appliedEvents.append(event)
                        }
                    } catch {
                        failed += 1
                        self.cacheError = "Unable to apply the daemon event: \(error)"
                        dbLog.error("event_apply_failed", metadata: .fields([
                            "session": event.sessionID.rawValue,
                            "event": event.eventID.rawValue,
                            "error": error,
                        ]))
                    }
                }
            }
            if received > 0 {
                agentLog.debug("events_applied", metadata: .fields([
                    "received": received,
                    "applied": appliedEvents.count,
                    "failed": failed,
                ]))
            }
            if appliedAny {
                self.cacheError = nil
                await self.reloadFromCache(
                    persistedDataChanged: true,
                    appliedEvents: appliedEvents
                )
            }
            self.eventApplyTask = nil
            if !self.pendingEvents.isEmpty, !Task.isCancelled {
                self.scheduleEventApply()
            }
        }
    }

    /// The one path that re-derives the visible list and the resident
    /// details from the cache database after any of its writes. The
    /// resident copies are not re-read: `appliedEvents` fold into them and
    /// every copy takes the summary row the database now holds; only a
    /// missing lead pages the database.
    private func reloadFromCache(
        persistedDataChanged: Bool = false,
        appliedEvents: [AgentIngressEvent] = []
    ) async {
        guard let cache else { return }
        do {
            // Provisional sessions (no Turn yet) stay in the cache but never
            // reach the list, the Notch or the Relay — except a provisional
            // parent of a visible subagent, which stays so the tree holds and
            // the user can refresh (reingest) it. Filter-hidden sessions (and
            // their subagent groups) stay cached too — reconcile keeps them,
            // and a future "show hidden" toggle only needs to skip this line —
            // but reach neither the list nor the Notch, which both feed from
            // `sessions`.
            let visible = SessionSummary.visible(try await cache.listSessions(limit: 10_000))
            let hiddenByFilter = SessionSummary.filterHiddenIDs(visible)
            let updated = visible.filter { !hiddenByFilter.contains($0.id) }
            try await refreshModelStamps(for: updated, events: appliedEvents)
            let previousSessions = sessions
            let selectedID = pendingSelectionID.flatMap { id in
                updated.contains(where: { $0.id == id }) ? id : nil
            } ?? updated.first?.id
            let summariesByID = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var detailChanged = !detailCache.fold(events: appliedEvents, summaries: summariesByID).isEmpty
            detailCache.pin(selectedID)
            // The lead is in use on every reload: a hit keeps it most recent,
            // a miss pages it in.
            if let selectedID, detailCache.touch(selectedID) == nil {
                if let detail = try await loadDetail(selectedID) {
                    detailCache.insert(detail)
                    detailChanged = true
                }
            }

            sessions = updated
            pendingSelectionID = selectedID
            // Sessions that left the cache leave the multi-selection too; a
            // lead that had to fall back collapses the set to itself.
            let prunedSelection = selectedIDs.filter { id in updated.contains { $0.id == id } }
            selectedIDs = if let selectedID, prunedSelection.contains(selectedID) {
                prunedSelection
            } else {
                selectedID.map { [$0] } ?? []
            }
            notifyObservers(
                dataChanged: persistedDataChanged
                    || previousSessions != updated
                    || detailChanged
            )
        } catch {
            cacheError = "Unable to read the macOS sync database: \(error)"
            dbLog.error("cache_reload_failed", metadata: .fields(["error": error]))
            notifyObservers()
        }
    }

    /// Keeps `modelStamps` covering exactly the visible sessions. Sessions
    /// already stamped fold streamed model-configuration events on top;
    /// unstamped ones (new, or invalidated after a reconcile replace) are
    /// resolved from the cache in one targeted read.
    private func refreshModelStamps(
        for visible: [SessionSummary],
        events: [AgentIngressEvent]
    ) async throws {
        guard let cache else { return }
        let visibleIDs = Set(visible.map(\.id))
        var stamps = modelStamps.filter { visibleIDs.contains($0.key) }
        for event in events {
            guard let item = event.timelineItem,
                  case let .modelConfiguration(payload) = item.payload,
                  let existing = stamps[event.sessionID] else { continue }
            stamps[event.sessionID] = existing.updating(with: payload)
        }
        let missing = visible.map(\.id).filter { stamps[$0] == nil }
        if !missing.isEmpty {
            let epoch = modelStampEpoch
            let fetched = try await cache.latestModelStamps(sessionIDs: missing)
            guard epoch == modelStampEpoch else {
                // An invalidation raced the read; the pass that invalidated
                // ends in its own reload, which re-reads with fresh data.
                return
            }
            stamps.merge(fetched) { _, new in new }
            dbLog.debug("model_stamps_loaded", metadata: .fields([
                "sessions": missing.count,
                "with_model": fetched.values.count { $0.model != nil },
            ]))
        }
        modelStamps = stamps
    }

    private func invalidateModelStamp(_ id: SessionID) {
        modelStamps.removeValue(forKey: id)
        modelStampEpoch &+= 1
    }

    /// One `health` round trip fresh from the socket — what the lifecycle
    /// controller trusts after a restart instead of this store's last
    /// reading, which a slow reconcile may still be writing. `wake` lets the
    /// request start a stopped daemon through launchd; it is never granted
    /// for an isolated daemon (`self.wake` is nil there).
    /// `quietly` logs a failed probe at debug: a restart verification
    /// expects failures while the daemon comes up and reports the outcome
    /// once itself.
    public func probeHealth(wake: Bool, quietly: Bool = false) async throws -> DaemonHealth {
        let response = try await client.send(
            IPCRequest(operation: .health),
            socketPath: socketPath,
            timeoutSeconds: 2,
            wake: wake ? self.wake : nil,
            failureLogLevel: quietly ? .debug : .warning
        )
        if let failure = response.failure { throw failure }
        guard let health = response.health else { throw DaemonProbeError.healthMissing }
        return health
    }

    private func connectEventStream() {
        guard started, !eventSubscriber.isRunning else { return }
        let subscriber = eventSubscriber
        let socketPath = socketPath
        let wake = wake
        // Once the outage is announced, the connect layer's own failure
        // lines follow this store's to debug.
        let failureLogLevel: Logger.Level = reconnectBackoff.isLoud ? .warning : .debug
        let storeReference = WeakMacSessionStoreReference(self)
        Task.detached {
            do {
                try subscriber.start(
                    socketPath: socketPath,
                    wake: wake,
                    failureLogLevel: failureLogLevel,
                    onEvent: { event in
                        Task { @MainActor in storeReference.value?.enqueueAgentEvent(event) }
                    },
                    onSummary: { summary in
                        Task { @MainActor in storeReference.value?.applyStreamedSummary(summary) }
                    },
                    onHealth: { health in
                        Task { @MainActor in
                            guard let store = storeReference.value else { return }
                            store.health = health
                            store.daemonAnswered()
                            store.notifyObservers()
                            // The stream just (re)connected; catch up on
                            // whatever it missed while down.
                            store.scheduleReconcile()
                        }
                    },
                    onDisconnect: {
                        Task { @MainActor in storeReference.value?.eventStreamDisconnected() }
                    }
                )
            } catch {
                await MainActor.run {
                    storeReference.value?.eventStreamDisconnected(error)
                }
            }
        }
    }

    /// A health frame or an answered request: the daemon is reachable, any
    /// outage is over, and the next one starts the reconnect series over.
    private func daemonAnswered() {
        connectionFailure = nil
        let attempts = reconnectBackoff.recordConnected()
        if attempts > 0 {
            log.info("daemon_stream_recovered", metadata: .fields(["attempts": attempts]))
        }
    }

    /// The stream failed to connect or dropped. Reconnects back off from 2 s
    /// to 30 s; the first few disconnects are warnings, then one line marks
    /// the outage and the rest go to debug until the daemon answers again.
    private func eventStreamDisconnected(_ error: Error? = nil) {
        guard started else { return }
        health = nil
        connectionFailure = error.map(DaemonConnectionFailure.init) ?? .streamClosed
        reconnectBackoff.recordDisconnect()
        let delay = reconnectBackoff.delay
        let fields: Logger.Metadata = .fields([
            "attempt": reconnectBackoff.consecutiveFailures,
            "reconnect_in_s": delay.components.seconds,
            "error": error,
        ])
        if reconnectBackoff.isLoud {
            log.warning("daemon_stream_disconnected", metadata: fields)
        } else if reconnectBackoff.isGoingQuiet {
            log.warning("daemon_stream_unavailable", metadata: .fields([
                "attempts": reconnectBackoff.consecutiveFailures,
                "max_reconnect_in_s": DaemonReconnectBackoff.maximumDelay.components.seconds,
                "detail": "further disconnects log at debug until the daemon answers",
                "error": error,
            ]))
        } else {
            log.debug("daemon_stream_disconnected", metadata: fields)
        }
        notifyObservers()
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.started, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.connectEventStream()
        }
    }

    private func request(_ request: IPCRequest, timeoutSeconds: Int64 = 2) async throws -> IPCResponse {
        try await client.send(request, socketPath: socketPath, timeoutSeconds: timeoutSeconds)
    }

    private static func loadSessionDetail(
        repository: SQLiteSessionRepository,
        sessionID: SessionID
    ) async throws -> SessionDetail? {
        var cursor: PaginationCursor?
        var summary: SessionSummary?
        var turns: [TurnSummary] = []
        var timeline: [TimelineItem] = []
        repeat {
            guard let page = try await repository.sessionDetail(
                id: sessionID,
                cursor: cursor,
                limit: 500
            ) else { return nil }
            summary = page.summary
            turns = page.turns
            timeline.append(contentsOf: page.timeline)
            cursor = page.nextCursor
        } while cursor != nil
        return summary.map { SessionDetail(summary: $0, turns: turns, timeline: timeline) }
    }

    /// Pages one whole session out of the cache database. The pages are
    /// separate reads, so a write landing between them (an applied event, a
    /// reconcile replace) could leave the copy one row short — and a resident
    /// copy is never re-read. A load that straddled a write is repeated once;
    /// a second straddle is kept and logged so the gap stays visible.
    private func loadDetail(_ id: SessionID) async throws -> SessionDetail? {
        guard let cache else { throw MacSessionStoreError.cacheUnavailable }
        var attempts = 0
        while true {
            let epoch = detailEpoch
            let started = ContinuousClock.now
            let detail = try await Self.loadSessionDetail(repository: cache, sessionID: id)
            attempts += 1
            if epoch == detailEpoch {
                dbLog.debug("detail_cache_miss", metadata: .fields([
                    "session": id.rawValue,
                    "timeline": detail?.timeline.count ?? 0,
                    "resident": detailCache.count,
                    "ms": LogClock.milliseconds(since: started),
                ]))
                return detail
            }
            guard attempts < 2 else {
                dbLog.warning("detail_load_straddled_write", metadata: .fields([
                    "session": id.rawValue,
                    "timeline": detail?.timeline.count ?? 0,
                ]))
                return detail
            }
        }
    }

    /// Every write to the cache database passes here, so an in-flight detail
    /// load can tell it straddled one.
    private func noteCacheWrite() {
        detailEpoch &+= 1
    }

    private func handleConnectionFailure(_ error: Error, action: String) {
        connectionFailure = DaemonConnectionFailure(error)
        health = nil
        log.warning("daemon_request_failed", metadata: .fields(["action": action, "error": error]))
        notifyObservers()
    }

    private func notifyObservers(dataChanged: Bool = false) {
        if dataChanged { dataRevision &+= 1 }
        observers.notify()
    }

    /// The app's synchronized session cache, by function under the shared
    /// support root. It holds mirror rows — trimmed to the per-row budget by
    /// the daemon (`TimelineContentBudget`) — and is rebuilt from the daemon
    /// whenever this file is new.
    private static let cacheRelativePath = "Storage/session-cache.sqlite"

    private static func defaultCachePath() -> String {
        // `LUMI_MAC_CACHE` isolates the Mac cache the way `LUMI_SOCKET`
        // isolates the daemon: an app pointed at a scratch daemon must not
        // reconcile (and prune) the real cache.
        if let override = ProcessInfo.processInfo.environment["LUMI_MAC_CACHE"], !override.isEmpty {
            return override
        }
        return LumiPaths.supportDirectory()
            .appendingPathComponent(cacheRelativePath)
            .path
    }

    /// Cache files of earlier layouts, newest first. Each held whole rows,
    /// which the mirror no longer stores, so none is carried over: the
    /// current file starts empty and the first reconcile refills it.
    /// - `Storage/cache.sqlite` (2026-08-31 – 2026-11-11): whole rows.
    /// - `Mac/sessions.sqlite3` (before 2026-08-31).
    private static func retiredDefaultCachePaths() -> [String] {
        let root = LumiPaths.supportDirectory()
        return [
            root.appendingPathComponent("Storage/cache.sqlite").path,
            root.appendingPathComponent("Mac/sessions.sqlite3").path,
        ]
    }

    /// Deletes each retired cache with its SQLite sidecars (sidecars first,
    /// main file last, so an interrupted run re-enters on the next launch),
    /// then its directory if nothing else is left in it. The cache is
    /// rebuildable from the daemon; a failure is logged and retried on the
    /// next launch.
    nonisolated static func discardRetiredCaches(
        _ paths: [String],
        fileManager: FileManager = .default
    ) {
        for path in paths where fileManager.fileExists(atPath: path) {
            do {
                let bytes = (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
                for suffix in ["-wal", "-shm", "-journal", ""] where fileManager.fileExists(atPath: path + suffix) {
                    try fileManager.removeItem(atPath: path + suffix)
                }
                dbLog.info("cache_retired", metadata: .fields(["path": path, "bytes": bytes]))
                let directory = (path as NSString).deletingLastPathComponent
                if let remaining = try? fileManager.contentsOfDirectory(atPath: directory), remaining.isEmpty {
                    try fileManager.removeItem(atPath: directory)
                }
            } catch {
                dbLog.error("cache_retire_failed", metadata: .fields(["path": path, "error": error]))
            }
        }
    }
}

private final class WeakMacSessionStoreReference: @unchecked Sendable {
    weak var value: MacSessionStore?

    init(_ value: MacSessionStore) {
        self.value = value
    }
}

private enum MacSessionStoreError: Error, CustomStringConvertible {
    case cacheUnavailable
    /// The daemon answered `get_timeline_items` without the row: it was
    /// deleted or rebuilt since the cache took its trimmed copy.
    case timelineItemMissing(TimelineItemID)

    var description: String {
        switch self {
        case .cacheUnavailable: "the session cache is unavailable"
        case let .timelineItemMissing(id): "the daemon no longer has row \(id.rawValue)"
        }
    }
}
