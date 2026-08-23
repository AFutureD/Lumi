import Core
import Remote
import Transport
import Foundation

/// What one paired Mac looks like to the UI.
struct MacChannelState: Sendable {
    let hostID: HostID
    let displayName: String
    /// The Relay this Mac is reached through (each Mac remembers its own).
    let relayURL: URL
    let pairedAt: Date
    let isConnected: Bool
    let isHostOnline: Bool
    /// The Relay refused this iPhone's credentials (the Mac revoked it):
    /// reconnecting stopped; the cache stays readable; pair again to resume.
    let accessRevoked: Bool
    /// The latest index was reconciled and every fetch it needed has landed.
    let hasCompleteSync: Bool
    /// Every session cached for this Mac (loaded from disk at launch, kept
    /// current by the sync), online or not.
    let sessions: [SessionDetail]
    /// When the last complete sync landed (persists across launches).
    let lastSyncAt: Date?
    let lastError: String?
    /// The daemon's last reported health, while connected.
    let health: DaemonHealth?
    /// The cache file has been read into memory (false only during launch).
    let hasLoadedCache: Bool

    var isOnline: Bool { isConnected && isHostOnline }
    /// Sessions the lists show: the cache, always — staleness is shown per
    /// Mac (online dot, "last sync"), never by hiding content.
    var visibleSessions: [SessionDetail] { sessions }
}

/// How a controller builds a channel's cache and Relay socket; tests inject
/// in-memory doubles.
struct RelayDeviceDependencies: Sendable {
    /// The Relay used when a person types a code without a Relay URL; a
    /// scanned link or the Advanced field can name another one. Each paired
    /// Mac remembers its own.
    var defaultRelayURL: URL
    var transportFactory: any RelayFrameTransportFactory
    var pairingAPI: any RelayPairingAPI = LiveRelayPairingAPI()
    /// How often a pairing attempt asks the Relay where the session is.
    var pairingPollInterval: Duration = .seconds(1)
    var makeRepository: @Sendable (HostID) throws -> any SessionRepository
    var removeRepository: @Sendable (HostID) throws -> Void
    /// Drops cache files of Macs that are no longer paired (launch housekeeping).
    var pruneRepositories: @Sendable (Set<HostID>) throws -> Void = { _ in }
    var requestTimeouts: RelayDeviceChannel.Timeouts
    /// Tests keep credentials out of the Keychain.
    var persistsCredentials = true

    /// Production: `RelayWebSocketClient`, one SQLite file per Mac under
    /// `Application Support/Lumi/Channels/<hostID>.sqlite3`.
    static func live(defaultRelayURL: URL = RelayBuildConfiguration.url) -> RelayDeviceDependencies {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumi", isDirectory: true)
            .appendingPathComponent("Channels", isDirectory: true)
        return RelayDeviceDependencies(
            defaultRelayURL: defaultRelayURL,
            transportFactory: RelayWebSocketTransportFactory(),
            makeRepository: { hostID in
                try SQLiteSessionRepository(path: directory.appendingPathComponent("\(hostID.rawValue).sqlite3").path)
            },
            removeRepository: { hostID in
                let base = directory.appendingPathComponent("\(hostID.rawValue).sqlite3").path
                for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: base + suffix) {
                    try FileManager.default.removeItem(atPath: base + suffix)
                }
            },
            pruneRepositories: { keep in
                let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
                for file in files {
                    guard let stem = file.components(separatedBy: ".sqlite3").first, stem != file else { continue }
                    if !keep.contains(HostID(stem)) {
                        try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
                    }
                }
            },
            requestTimeouts: .init()
        )
    }
}

/// All paired Macs. Credentials live in the Keychain; each Mac's sessions
/// live in that Mac's SQLite cache (the shared repository) and are loaded
/// into memory at launch, then kept current by index reconciles and the
/// daemon's event stream.
@MainActor
final class RelayDeviceController {
    private let secureStore = SecureStore(service: "app.huanan.lumi.ios.relay")
    private let credentialsAccount = "device-channels-v4"
    private let settings: LocalSettings
    private let dependencies: RelayDeviceDependencies
    private var channelOrder: [HostID] = []
    private var channels: [HostID: RelayDeviceChannel] = [:]
    private var observers: [UUID: () -> Void] = [:]
    /// Developer preview (`-LumiPreviewData`): fixed states instead of Relay.
    private var previewStates: [MacChannelState]?

    init(settings: LocalSettings = .shared, dependencies: RelayDeviceDependencies = .live(), loadStoredCredentials: Bool = true) {
        self.settings = settings
        self.dependencies = dependencies
        guard loadStoredCredentials else { return }
        let stored = (try? secureStore.load(RelayDeviceCredentialCollection.self, account: credentialsAccount))?.channels ?? []
        try? dependencies.pruneRepositories(Set(stored.map(\.hostID)))
        for credentials in stored {
            guard let channel = makeChannel(credentials) else { continue }
            channelOrder.append(credentials.hostID)
            channels[credentials.hostID] = channel
        }
    }

    // MARK: - Observation

    @discardableResult
    func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func notify() {
        for handler in observers.values { handler() }
    }

    // MARK: - Reading

    var isPaired: Bool { previewStates != nil || !channels.isEmpty }

    var channelStates: [MacChannelState] {
        if let previewStates { return previewStates }
        return channelOrder.compactMap { channels[$0]?.state }
    }

    func channelState(for hostID: HostID) -> MacChannelState? {
        channelStates.first { $0.hostID == hostID }
    }

    func session(hostID: HostID, id: SessionID) -> SessionDetail? {
        channelState(for: hostID)?.sessions.first { $0.summary.id == id }
    }

    // MARK: - Lifecycle

    func start() {
        for channel in channels.values { channel.start() }
    }

    /// Ask every Mac for its index again (pull-to-refresh, `Refresh list`).
    func refreshAll() {
        for channel in channels.values { channel.refresh() }
        notify()
    }

    func refresh(hostID: HostID) {
        channels[hostID]?.refresh()
        notify()
    }

    /// Take one session whole again (`Refresh session` in the detail).
    func refreshSession(hostID: HostID, id: SessionID) {
        channels[hostID]?.refreshSession(id)
        notify()
    }

    func usePreview(_ states: [MacChannelState]) {
        previewStates = states
        notify()
    }

    // MARK: - Pairing

    var defaultRelayURL: URL { dependencies.defaultRelayURL }

    /// A pairing attempt against `relayURL` with `code`. Start it, watch
    /// `progress`, cancel it if the person leaves. Failures are
    /// `PairingFailure`; nothing touches the Keychain before `.paired`.
    func makePairingAttempt(relayURL: URL, code: String) -> RelayPairingAttempt {
        RelayPairingAttempt(controller: self, relayURL: relayURL, code: code)
    }

    /// Pairing the same Mac again keeps this iPhone's device id, so the Relay
    /// and the Mac update the one record (new key, new token, revocation
    /// lifted) instead of listing a second "Active" iPhone.
    func deviceID(forPairingWith hostID: HostID) -> DeviceID {
        channels[hostID]?.credentials.deviceID ?? DeviceID("device-\(UUID().uuidString.lowercased())")
    }

    var pairingAPI: any RelayPairingAPI { dependencies.pairingAPI }
    var pairingPollInterval: Duration { dependencies.pairingPollInterval }
    var pairingDeviceName: String { settings.deviceName }

    /// Installs a paired channel (also the test seam around `pair`).
    func addChannel(_ credentials: RelayDeviceCredentials) async throws {
        if let existing = channels[credentials.hostID] { await existing.stop(removeLocalData: false) }
        channelOrder.removeAll { $0 == credentials.hostID }
        channelOrder.append(credentials.hostID)
        guard let channel = makeChannel(credentials) else { throw ChannelCacheError.unavailable }
        channels[credentials.hostID] = channel
        settings.setLastSync(nil, for: credentials.hostID)
        try saveCredentials()
        channel.start()
        notify()
    }

    /// Removes one Mac: its channel, credentials and cache file. The Mac's
    /// own pairing record stays until revoked there.
    func unpair(hostID: HostID) {
        if previewStates != nil {
            previewStates?.removeAll { $0.hostID == hostID }
            notify()
            return
        }
        guard let channel = channels.removeValue(forKey: hostID) else { return }
        channelOrder.removeAll { $0 == hostID }
        channel.cancelTasks()
        Task { await channel.stop(removeLocalData: true) }
        settings.setLastSync(nil, for: hostID)
        try? saveCredentials()
        notify()
    }

    // MARK: - Review

    /// Opening a session on the iPhone counts as reviewing it everywhere:
    /// the row turns grey here at once, and the daemon is told so the Mac,
    /// the Notch and other iPhones follow.
    func markReviewed(hostID: HostID, id: SessionID) {
        if previewStates != nil {
            previewStates = previewStates?.map { state in
                guard state.hostID == hostID else { return state }
                return state.replacingSessions(state.sessions.map { detail in
                    guard detail.summary.id == id, detail.summary.needsReview else { return detail }
                    return SessionDetail(summary: detail.summary.reviewed, turns: detail.turns, timeline: detail.timeline)
                })
            }
            notify()
            return
        }
        guard let channel = channels[hostID], channel.markReviewed(id) else { return }
        notify()
    }

    // MARK: - Local data

    /// Hides one session on this iPhone until the daemon sends a newer
    /// version of it. The Mac keeps the session; the iPhone is read-only.
    func dismissSession(hostID: HostID, id: SessionID) {
        if previewStates != nil {
            previewStates = previewStates?.map { state in
                guard state.hostID == hostID else { return state }
                return state.replacingSessions(state.sessions.filter { $0.summary.id != id })
            }
            notify()
            return
        }
        channels[hostID]?.dismiss(id)
        notify()
    }

    /// Drops every cached session; each Mac is asked for its index again so
    /// the caches refill from the daemons.
    func clearReceivedData() {
        if previewStates != nil {
            previewStates = previewStates?.map { $0.replacingSessions([]) }
            notify()
            return
        }
        for channel in channels.values { channel.clear() }
        notify()
    }

    // MARK: - Private

    private func makeChannel(_ credentials: RelayDeviceCredentials) -> RelayDeviceChannel? {
        guard let cache = try? dependencies.makeRepository(credentials.hostID) else { return nil }
        return RelayDeviceChannel(
            credentials: credentials,
            cache: cache,
            removeCache: dependencies.removeRepository,
            transportFactory: dependencies.transportFactory,
            timeouts: dependencies.requestTimeouts,
            settings: settings
        ) { [weak self] in
            self?.notify()
        }
    }

    private func saveCredentials() throws {
        guard dependencies.persistsCredentials else { return }
        let collection = RelayDeviceCredentialCollection(
            channels: channelOrder.compactMap { channels[$0]?.credentials }
        )
        if collection.channels.isEmpty {
            try secureStore.delete(account: credentialsAccount)
        } else {
            try secureStore.save(collection, account: credentialsAccount)
        }
    }
}

extension MacChannelState {
    func replacingSessions(_ sessions: [SessionDetail]) -> MacChannelState {
        MacChannelState(
            hostID: hostID,
            displayName: displayName,
            relayURL: relayURL,
            pairedAt: pairedAt,
            isConnected: isConnected,
            isHostOnline: isHostOnline,
            accessRevoked: accessRevoked,
            hasCompleteSync: hasCompleteSync,
            sessions: sessions,
            lastSyncAt: lastSyncAt,
            lastError: lastError,
            health: health,
            hasLoadedCache: hasLoadedCache
        )
    }
}

/// One Mac-to-iPhone channel: this Mac's SQLite cache, the in-memory copy
/// the screens read, and the one Relay socket every session of that Mac is
/// multiplexed through.
///
/// Sync is index-first: every connect (and pull-to-refresh, and any sequence
/// gap) asks the daemon for `session_index`; `SyncReconcilePlan` turns the
/// difference against `cache.sessionIndex()` into prunes, summary writes,
/// whole-session fetches and timeline-tail fetches; afterwards the daemon's
/// event stream (`session_message`) is applied through the same
/// `SessionRepository.apply` reducer the daemon and the Mac run.
@MainActor
final class RelayDeviceChannel {
    /// As many sessions as the daemon's `list_sessions` serves.
    static let indexLimit = 10_000

    struct Timeouts: Sendable {
        var index: Duration = .seconds(20)
        var fetch: Duration = .seconds(30)
        var tick: Duration = .seconds(1)
        var retryDelay: Duration = .seconds(10)
    }

    private enum PendingKind {
        case index
        case fetchSession(remaining: Set<SessionID>)
        case fetchTimeline(SessionID)
    }

    private struct PendingRequest {
        var kind: PendingKind
        var payload: RemoteSessionPayload
        var sentAt: Date
        var attempts: Int
    }

    private let onChange: () -> Void
    private let settings: LocalSettings
    private let cache: any SessionRepository
    private let removeCache: @Sendable (HostID) throws -> Void
    private let transportFactory: any RelayFrameTransportFactory
    private let timeouts: Timeouts
    private var transport: (any RelayFrameTransport)?
    private var startTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    private(set) var credentials: RelayDeviceCredentials
    /// Latest activity first, mirroring `cache.listSessions`.
    private var sessions: [SessionDetail] = []
    private var cacheLoaded = false
    private var isHostOnline = false
    private var isConnected = false
    private var accessRevoked = false
    private var hasCompleteSync = false
    private var lastError: String?
    private var health: DaemonHealth?
    /// Highest frame sequence seen on this connection, for gap detection.
    private var lastReceivedSequence: UInt64 = 0
    /// Sequence of device → host `request` frames on this connection.
    private var requestSequence: UInt64 = 0
    private var pending: [RequestID: PendingRequest] = [:]
    private var indexParts: [RequestID: [RemoteSessionPayload]] = [:]
    private var partBuffers: [SessionID: [RemoteSessionPayload]] = [:]
    /// `generatedAt` of the index whose fetches are still landing.
    private var indexGeneratedAt: Date?
    /// Sessions hidden on this iPhone (`Delete`), kept out of `sessions` but
    /// still in the cache and still fed by the daemon; one rule on every
    /// path — event, summary, whole session, index — shows a hidden session
    /// again: its `updatedAt` moved past the moment it was hidden.
    private var hidden: [SessionID: HiddenSession] = [:]
    /// Serialises cache writes against each other (applies, replaces, prunes).
    private var applyQueue: Task<Void, Never>?

    private struct HiddenSession {
        let hiddenAt: Date
        var detail: SessionDetail
    }

    init(
        credentials: RelayDeviceCredentials,
        cache: any SessionRepository,
        removeCache: @escaping @Sendable (HostID) throws -> Void,
        transportFactory: any RelayFrameTransportFactory,
        timeouts: Timeouts,
        settings: LocalSettings,
        onChange: @escaping () -> Void
    ) {
        self.credentials = credentials
        self.cache = cache
        self.removeCache = removeCache
        self.transportFactory = transportFactory
        self.timeouts = timeouts
        self.settings = settings
        self.onChange = onChange
    }

    var state: MacChannelState {
        MacChannelState(
            hostID: credentials.hostID,
            displayName: credentials.displayName,
            relayURL: credentials.relayURL,
            pairedAt: credentials.pairedAt,
            isConnected: isConnected,
            isHostOnline: isHostOnline,
            accessRevoked: accessRevoked,
            hasCompleteSync: hasCompleteSync,
            sessions: sessions,
            lastSyncAt: settings.lastSync(for: credentials.hostID),
            lastError: lastError,
            health: health,
            hasLoadedCache: cacheLoaded
        )
    }

    // MARK: - Lifecycle

    /// Loads the cache (first run only), then connects. Idempotent.
    func start() {
        guard startTask == nil else { return }
        if isConnected {
            // Foreground again: the socket may have been suspended; ask for
            // the index so whatever was dropped meanwhile is healed.
            requestIndex()
            return
        }
        startTask = Task { [weak self] in
            guard let self else { return }
            if !self.cacheLoaded { await self.loadCache() }
            await self.connect()
            self.startTask = nil
        }
    }

    /// Connected: ask for the index. Otherwise: connect (which asks).
    func refresh() {
        if isConnected {
            requestIndex()
        } else {
            start()
        }
    }

    func refreshSession(_ id: SessionID) {
        guard isConnected else { return }
        send(kind: .fetchSession(remaining: [id]), payload: RemoteSessionPayload(kind: .fetchSession, sessionIDs: [id]))
    }

    func stop(removeLocalData: Bool) async {
        cancelTasks()
        let transport = self.transport
        self.transport = nil
        await transport?.disconnect()
        isConnected = false
        isHostOnline = false
        pending = [:]
        indexParts = [:]
        partBuffers = [:]
        if removeLocalData {
            sessions = []
            try? removeCache(credentials.hostID)
        }
        onChange()
    }

    func cancelTasks() {
        startTask?.cancel()
        receiveTask?.cancel()
        reconnectTask?.cancel()
        tickTask?.cancel()
        retryTask?.cancel()
        startTask = nil
        receiveTask = nil
        reconnectTask = nil
        tickTask = nil
        retryTask = nil
    }

    /// Clears the review flag locally and tells the daemon. Returns false
    /// when the session is unknown or already reviewed.
    func markReviewed(_ id: SessionID) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.summary.id == id }),
              sessions[index].summary.needsReview else { return false }
        let detail = sessions[index]
        sessions[index] = SessionDetail(summary: detail.summary.reviewed, turns: detail.turns, timeline: detail.timeline)
        enqueueCacheWrite { [cache] in try await cache.markSessionReviewed(id) }
        if isConnected {
            sendRequest(RemoteSessionPayload(kind: .sessionReviewed, sessionIDs: [id]))
        }
        return true
    }

    func dismiss(_ id: SessionID) {
        guard let detail = sessions.first(where: { $0.summary.id == id }) else { return }
        hidden[id] = HiddenSession(hiddenAt: detail.summary.updatedAt, detail: detail)
        sessions.removeAll { $0.summary.id == id }
        partBuffers[id] = nil
    }

    /// Empties the cache (no tombstones, no dedupe reset) and re-indexes.
    func clear() {
        sessions = []
        hidden = [:]
        partBuffers = [:]
        hasCompleteSync = false
        enqueueCacheWrite { [cache] in _ = try await cache.pruneSessions(keeping: []) }
        if isConnected { requestIndex() }
        onChange()
    }

    // MARK: - Cache

    private func loadCache() async {
        do {
            var loaded: [SessionDetail] = []
            for summary in try await cache.listSessions(limit: Self.indexLimit) {
                if let detail = try await Self.loadFullDetail(cache, id: summary.id) {
                    loaded.append(detail)
                }
            }
            sessions = loaded
            cacheLoaded = true
        } catch {
            lastError = "Unable to read the session cache: \(error)"
        }
        onChange()
    }

    private static func loadFullDetail(_ cache: any SessionRepository, id: SessionID) async throws -> SessionDetail? {
        var cursor: PaginationCursor?
        var turns: [TurnSummary] = []
        var timeline: [TimelineItem] = []
        var summary: SessionSummary?
        repeat {
            guard let page = try await cache.sessionDetail(id: id, cursor: cursor, limit: 500) else { return nil }
            summary = page.summary
            if !page.turns.isEmpty { turns = page.turns }
            timeline += page.timeline
            cursor = page.nextCursor
        } while cursor != nil
        guard let summary else { return nil }
        return SessionDetail(summary: summary, turns: turns, timeline: timeline)
    }

    /// Cache writes run one after another, in order, off the frame handler.
    private func enqueueCacheWrite(_ body: @escaping @Sendable () async throws -> Void) {
        let previous = applyQueue
        applyQueue = Task { [weak self] in
            await previous?.value
            do {
                try await body()
            } catch {
                self?.lastError = "Unable to write the session cache: \(error)"
            }
        }
    }

    /// A cache operation whose result the caller needs, run in queue order
    /// (after every write enqueued before it, before every write after it).
    private func cacheWrite<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = applyQueue
        let task = Task<T, Error> {
            await previous?.value
            return try await body()
        }
        applyQueue = Task { _ = try? await task.value }
        return try await task.value
    }

    // MARK: - Connection

    private func connect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        await transport?.disconnect()
        let transport = transportFactory.makeTransport(baseURL: credentials.relayURL)
        self.transport = transport
        isConnected = false
        isHostOnline = false
        hasCompleteSync = false
        lastReceivedSequence = 0
        requestSequence = 0
        pending = [:]
        indexParts = [:]
        partBuffers = [:]
        do {
            try await transport.connect(
                hostID: credentials.hostID,
                role: .device(credentials.deviceID),
                token: credentials.deviceToken
            )
            isConnected = true
            accessRevoked = false
            lastError = nil
            receiveTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        let message = try await transport.next()
                        await self?.handle(message)
                    } catch {
                        guard !Task.isCancelled else { return }
                        self?.connectionFailed(error)
                        return
                    }
                }
            }
            startTicker()
            // The worker answers the connect with presence; the index request
            // goes out as soon as the host is known to be online (`handle`).
        } catch {
            connectionFailed(error)
        }
        onChange()
    }

    private func connectionFailed(_ error: Error) {
        isConnected = false
        isHostOnline = false
        hasCompleteSync = false
        pending = [:]
        indexParts = [:]
        partBuffers = [:]
        tickTask?.cancel()
        tickTask = nil
        if case RelayClientError.unauthorized = error {
            // The Mac revoked this iPhone (or the pairing record is gone):
            // no retry loop — the Macs screen says so and offers re-pairing.
            accessRevoked = true
            lastError = "This iPhone was revoked on the Mac. Pair again to reconnect."
        } else {
            lastError = String(describing: error)
        }
        onChange()
        scheduleReconnect(after: error)
    }

    private func scheduleReconnect(after error: Error) {
        guard Self.shouldReconnect(after: error), reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await self.connect()
        }
    }

    private static func shouldReconnect(after error: Error) -> Bool {
        guard let relayError = error as? RelayClientError else { return true }
        switch relayError {
        case .unauthorized:
            return false
        case let .server(status, _):
            return status != 401 && status != 403
        default:
            return true
        }
    }

    // MARK: - Requests

    private func requestIndex() {
        guard isConnected, isHostOnline else { return }
        // One index request in flight at a time.
        guard !pending.values.contains(where: { if case .index = $0.kind { true } else { false } }) else { return }
        send(kind: .index, payload: RemoteSessionPayload(kind: .syncIndex))
    }

    private func send(kind: PendingKind, payload: RemoteSessionPayload, attempts: Int = 1) {
        let requestID = RequestID()
        let stamped = RemoteSessionPayload(
            kind: payload.kind,
            generatedAt: Date(),
            requestID: requestID,
            sessionIDs: payload.sessionIDs,
            since: payload.since
        )
        pending[requestID] = PendingRequest(kind: kind, payload: stamped, sentAt: Date(), attempts: attempts)
        sendRequest(stamped)
    }

    private func sendRequest(_ payload: RemoteSessionPayload) {
        guard let transport else { return }
        requestSequence &+= 1
        let credentials = self.credentials
        let sequence = requestSequence
        Task { [weak self] in
            do {
                let frame = try RelayCryptography.seal(
                    payload,
                    hostID: credentials.hostID,
                    deviceID: credentials.deviceID,
                    sequence: sequence,
                    kind: .request,
                    privateKey: credentials.keyPair.privateKey,
                    peerPublicKey: credentials.hostPublicKey
                )
                try await transport.send(frame)
            } catch {
                self?.lastError = "Unable to send request: \(error)"
                self?.onChange()
            }
        }
    }

    private func startTicker() {
        tickTask?.cancel()
        tickTask = Task { [weak self, timeouts] in
            while !Task.isCancelled {
                try? await Task.sleep(for: timeouts.tick)
                guard !Task.isCancelled else { return }
                self?.expirePendingRequests()
            }
        }
    }

    /// A request that got no complete answer is re-sent once; a second
    /// miss drops everything in flight and re-indexes after a pause.
    private func expirePendingRequests() {
        let now = Date()
        var expired: [(RequestID, PendingRequest)] = []
        for (id, request) in pending {
            let limit: Duration = if case .index = request.kind { timeouts.index } else { timeouts.fetch }
            if Duration.seconds(now.timeIntervalSince(request.sentAt)) > limit { expired.append((id, request)) }
        }
        guard !expired.isEmpty else { return }
        var giveUp = false
        for (id, request) in expired {
            pending[id] = nil
            indexParts[id] = nil
            if request.attempts < 2 {
                send(kind: request.kind, payload: request.payload, attempts: request.attempts + 1)
            } else {
                giveUp = true
            }
        }
        if giveUp {
            pending = [:]
            indexParts = [:]
            partBuffers = [:]
            lastError = "The Mac did not answer; retrying."
            onChange()
            retryTask?.cancel()
            retryTask = Task { [weak self, timeouts] in
                try? await Task.sleep(for: timeouts.retryDelay)
                guard !Task.isCancelled else { return }
                self?.requestIndex()
            }
        }
    }

    // MARK: - Inbound

    private func handle(_ message: RelayIncomingMessage) async {
        switch message {
        case let .presence(online):
            let wasOnline = isHostOnline
            isHostOnline = online
            if online {
                // First sight of the daemon — or the daemon reconnected behind
                // the Relay (which repeats `online`) and forgot who had synced,
                // so its pushes stop until we index again. Either way: index.
                if !wasOnline { lastReceivedSequence = 0 }
                hasCompleteSync = false
                requestIndex()
            } else {
                hasCompleteSync = false
                pending = [:]
                indexParts = [:]
                partBuffers = [:]
            }
        case let .frame(frame):
            guard frame.hostID == credentials.hostID,
                  frame.deviceID == credentials.deviceID,
                  frame.kind == .data,
                  frame.sequence > lastReceivedSequence else { return }
            let gap = lastReceivedSequence != 0 && frame.sequence > lastReceivedSequence + 1
            lastReceivedSequence = frame.sequence
            isHostOnline = true
            do {
                let payload = try RelayCryptography.open(
                    frame,
                    privateKey: credentials.keyPair.privateKey,
                    peerPublicKey: credentials.hostPublicKey
                )
                await apply(payload)
                lastError = nil
            } catch {
                lastError = "Unable to decrypt relay update: \(error)"
            }
            if gap {
                // Dropped frames: whatever they carried is healed by the index.
                hasCompleteSync = false
                requestIndex()
            }
        case let .error(error):
            lastError = "Relay: \(error.code)"
        case .pairingDevice, .pairingClosed:
            // Host-socket control messages; a device socket never gets them.
            return
        }
        onChange()
    }

    private func apply(_ payload: RemoteSessionPayload) async {
        switch payload.kind {
        case .sessionIndex:
            guard let requestID = payload.requestID, pending[requestID] != nil else { return }
            indexParts[requestID, default: []].append(payload)
            guard let entries = RelayFrameReduction.assembleIndex(parts: indexParts[requestID] ?? []) else { return }
            indexParts[requestID] = nil
            pending[requestID] = nil
            await reconcile(entries, generatedAt: payload.generatedAt)
        case .sessionFull, .sessionTimeline:
            guard let page = payload.session else { return }
            let id = page.summary.id
            if (payload.part ?? 0) == 0 { partBuffers[id] = [] }
            partBuffers[id, default: []].append(payload)
            guard page.nextCursor == nil,
                  let detail = RelayFrameReduction.assemble(parts: partBuffers[id] ?? []) else { return }
            partBuffers[id] = nil
            if payload.kind == .sessionFull {
                install(detail, replacing: true)
            } else {
                install(detail, replacing: false)
            }
            settle(requestID: payload.requestID, sessionID: id)
        case .sessionMessage:
            await applyEvents(payload.events ?? [])
        case .sessionInfo:
            var missing: [SessionID] = []
            for summary in payload.summaries ?? [] {
                if updateSummary(summary) {
                    enqueueCacheWrite { [cache] in try await cache.updateSummary(summary) }
                } else {
                    missing.append(summary.id)
                }
            }
            sortSessions()
            requestMissing(missing)
        case .sessionRemoved:
            let ids = payload.sessionIDs ?? []
            for id in ids {
                sessions.removeAll { $0.summary.id == id }
                partBuffers[id] = nil
                hidden[id] = nil
                enqueueCacheWrite { [cache] in _ = try await cache.deleteSession(id: id) }
                settle(requestID: payload.requestID, sessionID: id)
            }
        case .health:
            health = payload.health
        case .syncIndex, .fetchSession, .fetchTimelineSince, .sessionReviewed:
            // Device → host only; never expected from the daemon.
            return
        }
    }

    private func applyEvents(_ events: [AgentIngressEvent]) async {
        var missing: [SessionID] = []
        for event in events {
            let id = event.sessionID
            let known = hidden[id] != nil || sessions.contains { $0.summary.id == id }
            let inFlight = pending.values.contains {
                if case let .fetchSession(remaining) = $0.kind { return remaining.contains(id) }
                return false
            }
            guard known || inFlight else {
                missing.append(id)
                continue
            }
            let applied: Bool
            do {
                // Through the write queue: a whole-session replace enqueued a
                // moment ago must land before this event, or it would erase it.
                applied = try await cacheWrite { [cache] in try await cache.apply(event) }
            } catch {
                lastError = "Unable to apply an update: \(error)"
                continue
            }
            guard applied else { continue }
            if event.disposition == .discard {
                sessions.removeAll { $0.summary.id == id }
                hidden[id] = nil
                continue
            }
            if let index = sessions.firstIndex(where: { $0.summary.id == id }) {
                sessions[index] = SessionDetailReduction.applying(event, to: sessions[index])
            } else if var entry = hidden[id] {
                entry.detail = SessionDetailReduction.applying(event, to: entry.detail)
                hidden[id] = entry
                revealIfNewer(id)
            }
        }
        sortSessions()
        requestMissing(missing)
    }

    /// Summary-only change (reviewed, archived, index reconcile): updates the
    /// visible or hidden copy; false when this Mac's session is not cached.
    private func updateSummary(_ summary: SessionSummary) -> Bool {
        let id = summary.id
        if let index = sessions.firstIndex(where: { $0.summary.id == id }) {
            let detail = sessions[index]
            sessions[index] = SessionDetail(summary: summary, turns: detail.turns, timeline: detail.timeline)
            return true
        }
        if var entry = hidden[id] {
            entry.detail = SessionDetail(summary: summary, turns: entry.detail.turns, timeline: entry.detail.timeline)
            hidden[id] = entry
            revealIfNewer(id)
            return true
        }
        return false
    }

    /// IOS-R-012: a hidden session comes back once the daemon's copy is
    /// newer than the one the user hid.
    private func revealIfNewer(_ id: SessionID) {
        guard let entry = hidden[id], entry.detail.summary.updatedAt > entry.hiddenAt else { return }
        hidden[id] = nil
        sessions.removeAll { $0.summary.id == id }
        sessions.append(entry.detail)
    }

    private func sortSessions() {
        sessions.sort { $0.summary.lastActivityAt > $1.summary.lastActivityAt }
    }

    /// A session the daemon talks about but the cache does not hold: take it whole.
    private func requestMissing(_ ids: [SessionID]) {
        let inFlight = Set(pending.values.flatMap { request -> [SessionID] in
            if case let .fetchSession(remaining) = request.kind { return Array(remaining) }
            return []
        })
        let wanted = Array(Set(ids).subtracting(inFlight))
        guard !wanted.isEmpty, isConnected else { return }
        for chunk in stride(from: 0, to: wanted.count, by: 20).map({ Array(wanted[$0..<min($0 + 20, wanted.count)]) }) {
            send(kind: .fetchSession(remaining: Set(chunk)), payload: RemoteSessionPayload(kind: .fetchSession, sessionIDs: chunk))
        }
    }

    /// Writes a whole (`replacing`) or partial session into cache and memory.
    private func install(_ detail: SessionDetail, replacing: Bool) {
        let id = detail.summary.id
        if replacing {
            enqueueCacheWrite { [cache] in try await cache.replaceSession(detail) }
        } else {
            enqueueCacheWrite { [cache] in try await cache.mergeSession(detail) }
        }
        if var entry = hidden[id] {
            entry.detail = replacing ? detail : SessionDetailReduction.merging(detail, into: entry.detail)
            hidden[id] = entry
            revealIfNewer(id)
        } else if let index = sessions.firstIndex(where: { $0.summary.id == id }) {
            sessions[index] = replacing ? detail : SessionDetailReduction.merging(detail, into: sessions[index])
        } else {
            sessions.append(detail)
        }
        sortSessions()
    }

    /// Marks one session of a pending fetch as answered; completes the sync
    /// when nothing is left in flight.
    private func settle(requestID: RequestID?, sessionID: SessionID) {
        guard let requestID, var request = pending[requestID] else { return }
        switch request.kind {
        case var .fetchSession(remaining):
            remaining.remove(sessionID)
            if remaining.isEmpty {
                pending[requestID] = nil
            } else {
                request.kind = .fetchSession(remaining: remaining)
                pending[requestID] = request
            }
        case .fetchTimeline:
            pending[requestID] = nil
        case .index:
            break
        }
        completeSyncIfSettled()
    }

    private func completeSyncIfSettled() {
        guard pending.isEmpty, let generatedAt = indexGeneratedAt else { return }
        indexGeneratedAt = nil
        hasCompleteSync = true
        settings.setLastSync(generatedAt, for: credentials.hostID)
    }

    // MARK: - Reconcile

    private func reconcile(_ remote: [SessionIndexEntry], generatedAt: Date) async {
        let local: [SessionIndexEntry]
        do {
            // Let queued writes land first so the local index is current.
            await applyQueue?.value
            local = try await cache.sessionIndex(limit: Self.indexLimit)
        } catch {
            lastError = "Unable to read the session cache: \(error)"
            return
        }
        let plan = SyncReconcilePlan.make(local: local, remote: remote)
        let remoteIDs = Set(remote.map(\.summary.id))
        if !plan.prune.isEmpty {
            sessions.removeAll { plan.prune.contains($0.summary.id) }
            hidden = hidden.filter { !plan.prune.contains($0.key) }
            enqueueCacheWrite { [cache] in _ = try await cache.pruneSessions(keeping: remoteIDs) }
        }
        for summary in plan.infoOnly {
            _ = updateSummary(summary)
            enqueueCacheWrite { [cache] in try await cache.updateSummary(summary) }
        }
        sortSessions()

        indexGeneratedAt = generatedAt
        // A hidden session is fetched whole only when the daemon's copy is
        // newer (then `install` shows it); otherwise it stays as it is.
        let fetchFull = plan.fetchFull.filter { id in
            guard let entry = hidden[id], let remoteEntry = remote.first(where: { $0.summary.id == id }) else { return true }
            return remoteEntry.summary.updatedAt > entry.hiddenAt
        }
        for chunk in stride(from: 0, to: fetchFull.count, by: 20).map({ Array(fetchFull[$0..<min($0 + 20, fetchFull.count)]) }) {
            send(kind: .fetchSession(remaining: Set(chunk)), payload: RemoteSessionPayload(kind: .fetchSession, sessionIDs: chunk))
        }
        for request in plan.fetchSince {
            send(
                kind: .fetchTimeline(request.sessionID),
                payload: RemoteSessionPayload(kind: .fetchTimelineSince, sessionIDs: [request.sessionID], since: request.since)
            )
        }
        completeSyncIfSettled()
    }
}

/// One pairing attempt, iPhone side: claim the code → submit our identity
/// and key → poll → verify the commitment and show the SAS → poll → on
/// `approved`, install the channel. Cancel at any point tells the Relay.
@MainActor
final class RelayPairingAttempt {
    private weak var controller: RelayDeviceController?
    let relayURL: URL
    let code: String
    private let api: any RelayPairingAPI
    private let pollInterval: Duration
    private var task: Task<Void, Never>?
    /// Set once the code was spent; `Try again` after `hostOffline` resumes here.
    private var claim: RelayPairingClaim?
    private var deviceID: DeviceID?
    private var keyPair: RelayKeyPair?

    private(set) var progress: PairingProgress?
    private(set) var failure: PairingFailure?
    var onChange: (() -> Void)?

    init(controller: RelayDeviceController, relayURL: URL, code: String) {
        self.controller = controller
        self.relayURL = relayURL
        self.code = code
        api = controller.pairingAPI
        pollInterval = controller.pairingPollInterval
    }

    var relayHost: String { RelayURLValidation.displayHost(relayURL) }
    var isRunning: Bool { task != nil }

    /// Runs (or, after `hostOffline`, resumes) the attempt.
    func start() {
        guard task == nil else { return }
        failure = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run()
            } catch let failure as PairingFailure {
                self.failure = failure
            } catch is CancellationError {
                // Told the Relay in `cancel()`.
            } catch {
                self.failure = Self.failure(for: error, claiming: false)
            }
            self.task = nil
            self.onChange?()
        }
    }

    /// Stops polling and releases the session at the Relay (best effort).
    func cancel() {
        task?.cancel()
        task = nil
        if let claim {
            let api = api, relayURL = relayURL
            Task { try? await api.cancel(relayURL: relayURL, hostID: claim.hostID, sessionID: claim.sessionID) }
        }
        claim = nil
    }

    private func set(_ progress: PairingProgress) {
        self.progress = progress
        onChange?()
    }

    private func run() async throws {
        guard let controller else { return }
        if claim == nil {
            set(.claiming)
            do {
                claim = try await api.claim(relayURL: relayURL, code: code)
            } catch {
                throw Self.failure(for: error, claiming: true)
            }
        }
        guard let claim else { return }
        let deviceID = self.deviceID ?? controller.deviceID(forPairingWith: claim.hostID)
        let keyPair = self.keyPair ?? RelayCryptography.makeKeyPair()
        self.deviceID = deviceID
        self.keyPair = keyPair
        set(.waitingForMac(hostName: claim.hostName, relayHost: relayHost))
        do {
            try await api.submit(
                relayURL: relayURL, hostID: claim.hostID, sessionID: claim.sessionID,
                deviceID: deviceID, deviceName: controller.pairingDeviceName, devicePublicKey: keyPair.publicKey
            )
        } catch let error as RelayClientError {
            // Already submitted (a resume after a network blip): just poll.
            if case let .relay(_, code) = error, code == "invalid_state" {
                // Fall through to polling; the state tells us where we are.
            } else {
                throw Self.failure(for: error, claiming: false)
            }
        } catch {
            throw Self.failure(for: error, claiming: false)
        }

        var hostPublicKey: Data?
        while true {
            try Task.checkCancellation()
            let status: RelayPairingSessionStatus
            do {
                status = try await api.status(relayURL: relayURL, hostID: claim.hostID, sessionID: claim.sessionID)
            } catch {
                throw Self.failure(for: error, claiming: false)
            }
            switch status.state {
            case .offered, .claimed, .submitted:
                break
            case .revealed, .approved:
                if hostPublicKey == nil, let key = status.hostPublicKey, let nonce = status.hostNonce {
                    // The key and nonce the Relay hands us must be the ones the
                    // Mac committed to before it ever saw our key — otherwise
                    // someone in the middle is choosing keys.
                    guard RelayCryptography.verifyPairingCommitment(claim.commit, hostPublicKey: key, hostNonce: nonce) else {
                        let api = api, relayURL = relayURL
                        Task { try? await api.cancel(relayURL: relayURL, hostID: claim.hostID, sessionID: claim.sessionID) }
                        throw PairingFailure.commitMismatch
                    }
                    hostPublicKey = key
                    let sas = RelayCryptography.pairingSAS(
                        hostID: claim.hostID, deviceID: deviceID,
                        hostPublicKey: key, devicePublicKey: keyPair.publicKey, hostNonce: nonce
                    )
                    set(.comparing(sas: sas, hostName: status.hostName ?? claim.hostName, relayHost: relayHost))
                }
                if status.state == .approved, let token = status.deviceToken, let hostPublicKey {
                    let credentials = RelayDeviceCredentials(
                        relayURL: relayURL,
                        hostID: claim.hostID,
                        hostName: status.hostName ?? claim.hostName,
                        deviceID: deviceID,
                        deviceToken: token,
                        keyPair: keyPair,
                        hostPublicKey: hostPublicKey,
                        pairedAt: status.pairedAt ?? Date()
                    )
                    try await controller.addChannel(credentials)
                    self.claim = nil
                    set(.paired(hostID: claim.hostID, hostName: credentials.hostName, relayHost: relayHost))
                    return
                }
            case .rejected:
                self.claim = nil
                throw PairingFailure.rejected
            case .cancelled, .expired:
                // The Mac rotated or dropped the code under us: same as a
                // spent code — back to the entry screen.
                self.claim = nil
                throw PairingFailure.badCode
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// Folds whatever ended the attempt into one of the four designed states.
    private static func failure(for error: Error, claiming: Bool) -> PairingFailure {
        if let failure = error as? PairingFailure { return failure }
        guard let relayError = error as? RelayClientError else {
            // Unreachable Relay, a cache file that would not open, …:
            // retryable, and `Try again` resumes where we were.
            return .hostOffline
        }
        switch relayError {
        case let .relay(_, code):
            switch code {
            case "invalid_or_expired_code": return .badCode
            case "host_offline": return .hostOffline
            // The session is gone at the Relay (rotated, expired, never
            // there): the code is no good any more.
            case "invalid_state", "expired", "not_found": return .badCode
            default: return .hostOffline
            }
        case .unauthorized:
            return .badCode
        case .server, .invalidResponse, .notConnected, .unsupportedMessage:
            return .hostOffline
        }
    }
}

/// The per-Mac cache file could not be created (disk / sandbox); the pairing
/// attempt reports it as a retryable failure.
enum ChannelCacheError: Error {
    case unavailable
}
