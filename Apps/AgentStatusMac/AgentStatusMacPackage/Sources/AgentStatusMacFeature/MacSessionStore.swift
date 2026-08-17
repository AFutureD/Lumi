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
    private var started = false
    private var observers: [UUID: () -> Void] = [:]
    private var pendingSelectionID: SessionID?
    private var snapshotTask: Task<Void, Never>?
    private var snapshotPending = false
    private var eventApplyTask: Task<Void, Never>?
    private var pendingEvents: [EventID: AgentIngressEvent] = [:]
    private var reconnectTask: Task<Void, Never>?

    public init(
        socketPath: String = DaemonEndpoint.defaultSocketPath(),
        cachePath: String? = nil
    ) {
        self.socketPath = socketPath
        do {
            cache = try SQLiteSessionRepository(path: cachePath ?? Self.defaultCachePath())
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

    /// The toolbar and daemon-management actions are the only manual callers.
    public func refresh() {
        scheduleSnapshotRefresh()
        connectEventStream()
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
        let summaries = try await cache.listSessions(limit: 10_000)
        return try await cachedSessionDetails(ids: summaries.map(\.id))
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
                    if let cache = self.cache { try await cache.replaceSnapshot(details) }
                    self.health = response.health
                    self.connectionError = nil
                    await self.reloadFromCache(reloadSelected: true)
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

    private func enqueueAgentEvent(_ event: AgentIngressEvent) {
        pendingEvents[event.eventID] = event
        scheduleEventApply()
    }

    private func scheduleEventApply() {
        guard eventApplyTask == nil, snapshotTask == nil else { return }
        eventApplyTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(50))
            var selectedChanged = false
            var appliedAny = false
            while !self.pendingEvents.isEmpty, !Task.isCancelled {
                let batch = Array(self.pendingEvents.values)
                self.pendingEvents.removeAll(keepingCapacity: true)
                guard let cache = self.cache else { break }
                for event in batch {
                    do {
                        if try await cache.apply(event) {
                            appliedAny = true
                            selectedChanged = selectedChanged || event.sessionID == self.selectedSession?.summary.id
                        }
                    } catch {
                        self.connectionError = "Unable to apply the daemon event: \(error)"
                    }
                }
            }
            if appliedAny {
                self.connectionError = nil
                await self.reloadFromCache(reloadSelected: selectedChanged)
            }
            self.eventApplyTask = nil
            if !self.pendingEvents.isEmpty, !Task.isCancelled {
                self.scheduleEventApply()
            }
        }
    }

    private func reloadFromCache(reloadSelected: Bool) async {
        guard let cache else { return }
        do {
            let updated = try await cache.listSessions(limit: 10_000)
            let previousSessions = sessions
            let previousDetail = selectedSession
            let previousID = pendingSelectionID ?? selectedSession?.summary.id
            let selectedID = previousID.flatMap { id in
                updated.contains(where: { $0.id == id }) ? id : nil
            } ?? updated.first?.id
            let mustReloadDetail = reloadSelected
                || selectedID != previousDetail?.summary.id
                || selectedID.flatMap { id in updated.first(where: { $0.id == id }) } != previousDetail?.summary
            let detail: SessionDetail? = if let selectedID {
                mustReloadDetail
                    ? try await Self.loadSessionDetail(repository: cache, sessionID: selectedID)
                    : previousDetail
            } else {
                nil
            }

            sessions = updated
            pendingSelectionID = selectedID
            selectedSession = detail
            notifyObservers(dataChanged: previousSessions != updated || previousDetail != detail)
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
