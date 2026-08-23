import Core
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
}

extension DaemonIPCClient: MacDaemonClient {
    public func request(_ request: IPCRequest, socketPath: String, timeoutSeconds: Int64) throws -> IPCResponse {
        try self.request(request, socketPath: socketPath, timeout: .seconds(timeoutSeconds))
    }
}

@MainActor
public final class MacSessionStore {
    public private(set) var sessions: [SessionSummary] = []
    public private(set) var selectedSession: SessionDetail?
    public private(set) var health: DaemonHealth?
    public private(set) var connectionError: String?
    public private(set) var dataRevision: UInt64 = 0

    private let client: any MacDaemonClient
    private let eventSubscriber = DaemonEventSubscriber()
    private let socketPath: String
    private let cache: SQLiteSessionRepository?
    private let cachePath: String
    private var started = false
    private var observers: [UUID: () -> Void] = [:]
    private var pendingSelectionID: SessionID?
    private var reconcileTask: Task<Void, Never>?
    private var reconcilePending = false
    private var eventApplyTask: Task<Void, Never>?
    /// Kept in arrival order: the daemon's order is the only correct one once
    /// a batch can contain a session discard next to a resurrecting prompt.
    private var pendingEvents: [AgentIngressEvent] = []
    private var pendingEventIDs: Set<EventID> = []
    private var reconnectTask: Task<Void, Never>?
    private var cachedSnapshotDetails: [SessionID: SessionDetail]?

    public init(
        socketPath: String = DaemonEndpoint.defaultSocketPath(),
        cachePath: String? = nil,
        client: any MacDaemonClient = DaemonIPCClient()
    ) {
        self.socketPath = socketPath
        self.client = client
        let resolvedCachePath = cachePath ?? Self.defaultCachePath()
        self.cachePath = resolvedCachePath
        do {
            cache = try SQLiteSessionRepository(path: resolvedCachePath)
        } catch {
            cache = nil
            connectionError = "Unable to open the macOS sync database: \(error)"
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
            await self.reloadFromCache(reloadSelected: true)
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
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func select(_ sessionID: SessionID?) {
        guard let sessionID else {
            guard pendingSelectionID != nil || selectedSession != nil else { return }
            pendingSelectionID = nil
            selectedSession = nil
            notifyObservers()
            return
        }
        // Selecting is viewing — even a re-click of the already selected row
        // clears a review flag a fresh turn end may have raised.
        markSessionReviewed(sessionID)
        guard pendingSelectionID != sessionID || selectedSession?.summary.id != sessionID else { return }
        pendingSelectionID = sessionID
        guard let cache else { return }
        Task {
            do {
                let detail = try await Self.loadSessionDetail(repository: cache, sessionID: sessionID)
                guard pendingSelectionID == sessionID else { return }
                selectedSession = detail
                notifyObservers()
            } catch {
                connectionError = "Unable to read the macOS sync database: \(error)"
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
                let response = try await request(
                    IPCRequest(operation: .reingestSession, sessionID: sessionID),
                    extendedTimeout: true
                )
                if let failure = response.failure { throw failure }
                // The rebuild is not streamed; the returned detail is the
                // wiped-and-rebuilt session.
                if let detail = response.session, let cache {
                    try await cache.replaceSession(detail)
                    cachedSnapshotDetails = nil
                    convertLog.info("session_refreshed", metadata: .fields([
                        "session": sessionID.rawValue,
                        "timeline": detail.timeline.count,
                        "turns": detail.turns.count,
                    ]))
                    await reloadFromCache(reloadSelected: true, persistedDataChanged: true)
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
        if let selected = selectedSession, selected.summary.id == sessionID {
            selectedSession = SessionDetail(
                summary: selected.summary.reviewed,
                turns: selected.turns,
                timeline: selected.timeline,
                nextCursor: selected.nextCursor
            )
        }
        cachedSnapshotDetails = nil
        notifyObservers(dataChanged: true)
        Task {
            do {
                if let cache { try await cache.markSessionReviewed(sessionID) }
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
        if let selected = selectedSession, selected.summary.id == sessionID {
            selectedSession = SessionDetail(
                summary: selected.summary.withHiddenInNotch(true),
                turns: selected.turns,
                timeline: selected.timeline,
                nextCursor: selected.nextCursor
            )
        }
        cachedSnapshotDetails = nil
        notifyObservers(dataChanged: true)
        Task {
            do {
                if let cache { try await cache.markSessionHiddenInNotch(sessionID) }
                let response = try await request(IPCRequest(operation: .markSessionHiddenInNotch, sessionID: sessionID))
                if let failure = response.failure { throw failure }
            } catch {
                handleConnectionFailure(error, action: "hide_in_notch")
            }
        }
    }

    public func deleteSession(_ sessionID: SessionID) {
        Task {
            do {
                // Optimistic local delete: the row leaves the UI at once; the
                // local tombstone swallows in-flight stragglers exactly like
                // the daemon's, and reconcile converges on the daemon's truth
                // either way.
                if let cache {
                    _ = try await cache.deleteSession(id: sessionID)
                    cachedSnapshotDetails = nil
                    await reloadFromCache(reloadSelected: true, persistedDataChanged: true)
                }
                let response = try await request(IPCRequest(operation: .deleteSession, sessionID: sessionID))
                if let failure = response.failure { throw failure }
                dbLog.info("session_delete_requested", metadata: .fields(["session": sessionID.rawValue]))
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
                    cachedSnapshotDetails = nil
                    await reloadFromCache(reloadSelected: true, persistedDataChanged: true)
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

    /// Reads the already-synchronized macOS GRDB cache for Relay publishing.
    /// This never performs an additional daemon refresh.
    public func snapshotDetails() async throws -> [SessionDetail] {
        guard let cache else { throw MacSessionStoreError.cacheUnavailable }
        let summaries = SessionSummary.visible(try await cache.listSessions(limit: 10_000))
        if let cachedSnapshotDetails,
           cachedSnapshotDetails.count == summaries.count,
           summaries.allSatisfy({ cachedSnapshotDetails[$0.id] != nil }) {
            return summaries.compactMap { cachedSnapshotDetails[$0.id] }
        }
        let details = try await cachedSessionDetails(ids: summaries.map(\.id))
        cachedSnapshotDetails = Dictionary(
            uniqueKeysWithValues: details.map { ($0.summary.id, $0) }
        )
        return details
    }

    /// Reads selected Session details from the already-synchronized Mac cache.
    /// OpenNook uses this to render a bounded glance without polling the daemon.
    public func cachedSessionDetails(ids: [SessionID]) async throws -> [SessionDetail] {
        guard let cache else { throw MacSessionStoreError.cacheUnavailable }
        var details: [SessionDetail] = []
        details.reserveCapacity(ids.count)
        for id in ids {
            if let detail = try await Self.loadSessionDetail(repository: cache, sessionID: id) {
                details.append(detail)
            }
        }
        return details
    }

    /// Resolves the compact Notch subtitle without decoding complete timelines.
    public func cachedCurrentTurnUserMessages(
        ids: [SessionID]
    ) async throws -> [SessionID: String] {
        if let cachedSnapshotDetails,
           ids.allSatisfy({ cachedSnapshotDetails[$0] != nil }) {
            return Dictionary(uniqueKeysWithValues: ids.compactMap { id in
                guard let detail = cachedSnapshotDetails[id],
                      let message = HaloSnapshot.currentTurnUserMessage(in: detail) else {
                    return nil
                }
                return (id, message)
            })
        }
        guard let cache else { throw MacSessionStoreError.cacheUnavailable }
        return try await cache.currentTurnUserMessages(sessionIDs: ids)
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
            fetched += 1
        }
        let changed = fetched > 0
        let pruned = try await cache.pruneSessions(keeping: Set(index.map(\.id)))
        if changed || pruned > 0 { cachedSnapshotDetails = nil }
        health = healthResponse.health
        connectionError = nil
        dbLog.info("reconciled", metadata: .fields([
            "daemon_sessions": index.count,
            "local_sessions": local.count,
            "planned": plan.fetch.count,
            "fetched": fetched,
            "missing": missing,
            "pruned": pruned,
            "ms": LogClock.milliseconds(since: started),
        ]))
        await reloadFromCache(
            reloadSelected: true,
            persistedDataChanged: changed || pruned > 0
        )
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
                extendedTimeout: true
            )
            if let failure = response.failure {
                if failure.code == "session_not_found" { return nil }
                if failure.code == "response_too_large", limit > 25 {
                    log.warning("session_page_too_large", metadata: .fields(["session": id.rawValue, "limit": limit]))
                    limit = 25
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
                cachedSnapshotDetails = nil
                agentLog.debug("summary_applied", metadata: .fields(["session": summary.id.rawValue]))
                await reloadFromCache(
                    reloadSelected: selectedSession?.summary.id == summary.id,
                    persistedDataChanged: true
                )
            } catch {
                connectionError = "Unable to apply the daemon summary: \(error)"
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
                            appliedAny = true
                            appliedEvents.append(event)
                        }
                    } catch {
                        failed += 1
                        self.connectionError = "Unable to apply the daemon event: \(error)"
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
                self.connectionError = nil
                await self.reloadFromCache(
                    reloadSelected: false,
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

    private func reloadFromCache(
        reloadSelected: Bool,
        persistedDataChanged: Bool = false,
        appliedEvents: [AgentIngressEvent] = []
    ) async {
        guard let cache else { return }
        do {
            // Provisional sessions (no Turn yet) stay in the cache but never
            // reach the list, the Notch or the Relay — except a provisional
            // parent of a visible subagent, which stays so the tree holds and
            // the user can refresh (reingest) it.
            let updated = SessionSummary.visible(try await cache.listSessions(limit: 10_000))
            let previousSessions = sessions
            let previousDetail = selectedSession
            let previousID = pendingSelectionID ?? selectedSession?.summary.id
            let selectedID = previousID.flatMap { id in
                updated.contains(where: { $0.id == id }) ? id : nil
            } ?? updated.first?.id
            updateSnapshotCache(summaries: updated, events: appliedEvents)
            let detail: SessionDetail? = if let selectedID {
                if reloadSelected || selectedID != previousDetail?.summary.id || previousDetail == nil {
                    try await Self.loadSessionDetail(repository: cache, sessionID: selectedID)
                } else if let previousDetail,
                          let summary = updated.first(where: { $0.id == selectedID }) {
                    Self.merging(previousDetail, summary: summary, events: appliedEvents)
                } else {
                    previousDetail
                }
            } else {
                nil
            }

            sessions = updated
            pendingSelectionID = selectedID
            selectedSession = detail
            notifyObservers(
                dataChanged: persistedDataChanged
                    || previousSessions != updated
                    || previousDetail != detail
            )
        } catch {
            connectionError = "Unable to read the macOS sync database: \(error)"
            dbLog.error("cache_reload_failed", metadata: .fields(["error": error]))
            notifyObservers()
        }
    }

    private func connectEventStream() {
        guard started, !eventSubscriber.isRunning else { return }
        let subscriber = eventSubscriber
        let socketPath = socketPath
        let storeReference = WeakMacSessionStoreReference(self)
        Task.detached {
            do {
                try subscriber.start(
                    socketPath: socketPath,
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
                            store.connectionError = nil
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

    private func eventStreamDisconnected(_ error: Error? = nil) {
        guard started else { return }
        health = nil
        connectionError = error.map(String.init(describing:)) ?? "Daemon event stream disconnected"
        log.warning("daemon_stream_disconnected", metadata: .fields(["reconnect_in_s": 2, "error": error]))
        notifyObservers()
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.started, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.connectEventStream()
        }
    }

    private func request(_ request: IPCRequest, extendedTimeout: Bool = false) async throws -> IPCResponse {
        let client = client
        let socketPath = socketPath
        return try await Task.detached {
            try client.request(
                request,
                socketPath: socketPath,
                timeoutSeconds: extendedTimeout ? 15 : 2
            )
        }.value
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

    static func merging(
        _ detail: SessionDetail,
        summary: SessionSummary,
        events: [AgentIngressEvent]
    ) -> SessionDetail {
        var timeline = detail.timeline
        var indices = Dictionary(
            uniqueKeysWithValues: timeline.enumerated().map { ($0.element.id, $0.offset) }
        )
        var changedTimeline = false

        for event in events where event.sessionID == summary.id {
            guard let item = event.timelineItem else { continue }
            if let index = indices[item.id] {
                guard item.occurredAt >= timeline[index].occurredAt else { continue }
                timeline[index] = item
            } else {
                indices[item.id] = timeline.count
                timeline.append(item)
            }
            changedTimeline = true
        }

        if changedTimeline {
            timeline.sort {
                if $0.occurredAt == $1.occurredAt { return $0.id.rawValue < $1.id.rawValue }
                return $0.occurredAt < $1.occurredAt
            }
        }
        return SessionDetail(
            summary: summary,
            turns: detail.turns,
            timeline: timeline,
            nextCursor: detail.nextCursor
        )
    }

    private func updateSnapshotCache(
        summaries: [SessionSummary],
        events: [AgentIngressEvent]
    ) {
        guard var cachedSnapshotDetails else { return }
        let summariesByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        cachedSnapshotDetails = cachedSnapshotDetails.filter { summariesByID[$0.key] != nil }
        let eventsBySession = Dictionary(grouping: events, by: \.sessionID)

        for summary in summaries {
            let sessionEvents = eventsBySession[summary.id] ?? []
            if let detail = cachedSnapshotDetails[summary.id] {
                cachedSnapshotDetails[summary.id] = Self.merging(
                    detail,
                    summary: summary,
                    events: sessionEvents
                )
            } else if !sessionEvents.isEmpty {
                cachedSnapshotDetails[summary.id] = Self.merging(
                    SessionDetail(summary: summary, timeline: []),
                    summary: summary,
                    events: sessionEvents
                )
            } else {
                self.cachedSnapshotDetails = nil
                return
            }
        }
        self.cachedSnapshotDetails = cachedSnapshotDetails
    }

    private func handleConnectionFailure(_ error: Error, action: String) {
        connectionError = String(describing: error)
        health = nil
        log.warning("daemon_request_failed", metadata: .fields(["action": action, "error": error]))
        notifyObservers()
    }

    private func notifyObservers(dataChanged: Bool = false) {
        if dataChanged { dataRevision &+= 1 }
        observers.values.forEach { $0() }
    }

    private static func defaultCachePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lumi/Mac", isDirectory: true)
            .appendingPathComponent("sessions.sqlite3")
            .path
    }
}

private final class WeakMacSessionStoreReference: @unchecked Sendable {
    weak var value: MacSessionStore?

    init(_ value: MacSessionStore) {
        self.value = value
    }
}

private enum MacSessionStoreError: Error {
    case cacheUnavailable
}
