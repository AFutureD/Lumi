import AgentStatusCore
import AgentStatusIPCClient
import AgentStatusTransport
import Foundation

@MainActor
public final class MacSessionStore {
    public private(set) var sessions: [SessionSummary] = []
    public private(set) var selectedSession: SessionDetail?
    public private(set) var health: DaemonHealth?
    public private(set) var connectionError: String?
    public private(set) var dataRevision: UInt64 = 0

    private let client = DaemonIPCClient()
    private let eventSubscriber = DaemonEventSubscriber()
    private let socketPath: String
    private let cache: SQLiteSessionRepository?
    private let cachePath: String
    private var started = false
    private var observers: [UUID: () -> Void] = [:]
    private var pendingSelectionID: SessionID?
    private var snapshotTask: Task<Void, Never>?
    private var snapshotPending = false
    private var eventApplyTask: Task<Void, Never>?
    /// Kept in arrival order: the daemon's order is the only correct one once
    /// a batch can contain a session discard next to a resurrecting prompt.
    private var pendingEvents: [AgentIngressEvent] = []
    private var pendingEventIDs: Set<EventID> = []
    private var reconnectTask: Task<Void, Never>?
    private var cachedSnapshotDetails: [SessionID: SessionDetail]?

    public init(
        socketPath: String = DaemonEndpoint.defaultSocketPath(),
        cachePath: String? = nil
    ) {
        self.socketPath = socketPath
        let resolvedCachePath = cachePath ?? Self.defaultCachePath()
        self.cachePath = resolvedCachePath
        do {
            cache = try SQLiteSessionRepository(path: resolvedCachePath)
        } catch {
            cache = nil
            connectionError = "Unable to open the macOS sync database: \(error)"
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
            self.scheduleSnapshotRefresh()
            self.connectEventStream()
        }
    }

    public func stop() {
        started = false
        snapshotTask?.cancel()
        snapshotTask = nil
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
        scheduleSnapshotRefresh()
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
            } catch {
                handleConnectionFailure(error)
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
                handleConnectionFailure(error)
            }
        }
    }

    public func deleteSession(_ sessionID: SessionID) {
        Task {
            do {
                let response = try await request(IPCRequest(operation: .deleteSession, sessionID: sessionID))
                if let failure = response.failure { throw failure }
                scheduleSnapshotRefresh()
            } catch {
                handleConnectionFailure(error)
            }
        }
    }

    public func clearHistory() {
        Task {
            do {
                let response = try await request(IPCRequest(operation: .clearHistory))
                if let failure = response.failure { throw failure }
                scheduleSnapshotRefresh()
            } catch {
                handleConnectionFailure(error)
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
                      let message = AgentStatusNookSnapshot.currentTurnUserMessage(in: detail) else {
                    return nil
                }
                return (id, message)
            })
        }
        guard let cache else { throw MacSessionStoreError.cacheUnavailable }
        return try await cache.currentTurnUserMessages(sessionIDs: ids)
    }

    private func scheduleSnapshotRefresh() {
        guard cache != nil else { return }
        snapshotPending = true
        guard snapshotTask == nil else { return }
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            while self.snapshotPending, !Task.isCancelled {
                self.snapshotPending = false
                if let eventApplyTask = self.eventApplyTask {
                    await eventApplyTask.value
                }
                do {
                    let response = try await self.request(
                        IPCRequest(operation: .snapshotSessions, limit: 10_000),
                        extendedTimeout: true
                    )
                    if let failure = response.failure { throw failure }
                    let details = (response.sessionDetails ?? [])
                        .sorted { $0.summary.updatedAt > $1.summary.updatedAt }
                    // The cache keeps everything (a provisional session must
                    // still be there when its first Turn arrives); the visible
                    // snapshot excludes provisional sessions (unless one is the
                    // parent of a visible subagent).
                    let visibleIDs = Set(SessionSummary.visible(details.map(\.summary)).map(\.id))
                    let visibleDetails = details.filter { visibleIDs.contains($0.summary.id) }
                    let previousDetails = try await self.snapshotDetails()
                    let snapshotDataChanged = Dictionary(
                        uniqueKeysWithValues: previousDetails.map { ($0.summary.id, $0) }
                    ) != Dictionary(
                        uniqueKeysWithValues: visibleDetails.map { ($0.summary.id, $0) }
                    )
                    if let cache = self.cache { try await cache.replaceSnapshot(details) }
                    self.cachedSnapshotDetails = Dictionary(
                        uniqueKeysWithValues: visibleDetails.map { ($0.summary.id, $0) }
                    )
                    self.health = response.health
                    self.connectionError = nil
                    await self.reloadFromCache(
                        reloadSelected: true,
                        persistedDataChanged: snapshotDataChanged
                    )
                } catch {
                    self.handleConnectionFailure(error)
                }
            }
            self.snapshotTask = nil
            if self.snapshotPending, !Task.isCancelled {
                self.scheduleSnapshotRefresh()
            } else if !self.pendingEvents.isEmpty, !Task.isCancelled {
                self.scheduleEventApply()
            }
        }
    }

    func enqueueAgentEvent(_ event: AgentIngressEvent) {
        guard pendingEventIDs.insert(event.eventID).inserted else { return }
        pendingEvents.append(event)
        scheduleEventApply()
    }

    /// Test hook: waits until every queued daemon event has been applied and
    /// the visible session list reloaded.
    func flushPendingEventsForTesting() async {
        while let task = eventApplyTask {
            await task.value
        }
    }

    private func scheduleEventApply() {
        guard eventApplyTask == nil, snapshotTask == nil else { return }
        eventApplyTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(50))
            var appliedAny = false
            var appliedEvents: [AgentIngressEvent] = []
            while !self.pendingEvents.isEmpty, !Task.isCancelled {
                let batch = self.pendingEvents
                self.pendingEvents.removeAll(keepingCapacity: true)
                self.pendingEventIDs.removeAll(keepingCapacity: true)
                guard let cache = self.cache else { break }
                for event in batch {
                    do {
                        if try await cache.apply(event) {
                            appliedAny = true
                            appliedEvents.append(event)
                        }
                    } catch {
                        self.connectionError = "Unable to apply the daemon event: \(error)"
                    }
                }
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
                    onHealth: { health in
                        Task { @MainActor in
                            storeReference.value?.health = health
                            storeReference.value?.connectionError = nil
                            storeReference.value?.notifyObservers()
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
                timeout: extendedTimeout ? .seconds(15) : .seconds(2)
            )
        }.value
    }

    private static func loadSessionDetail(
        repository: SQLiteSessionRepository,
        sessionID: SessionID
    ) async throws -> SessionDetail? {
        var cursor: PaginationCursor?
        var summary: SessionSummary?
        var timeline: [TimelineItem] = []
        repeat {
            guard let page = try await repository.sessionDetail(
                id: sessionID,
                cursor: cursor,
                limit: 500
            ) else { return nil }
            summary = page.summary
            timeline.append(contentsOf: page.timeline)
            cursor = page.nextCursor
        } while cursor != nil
        return summary.map { SessionDetail(summary: $0, timeline: timeline) }
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

    private func handleConnectionFailure(_ error: Error) {
        connectionError = String(describing: error)
        health = nil
        notifyObservers()
    }

    private func notifyObservers(dataChanged: Bool = false) {
        if dataChanged { dataRevision &+= 1 }
        observers.values.forEach { $0() }
    }

    private static func defaultCachePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Agent Status Mac", isDirectory: true)
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
