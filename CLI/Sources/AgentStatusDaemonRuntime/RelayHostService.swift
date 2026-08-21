import AgentStatusCore
import AgentStatusRemote
import AgentStatusTransport
import Foundation

/// The daemon's Relay host: registers the Mac with the Relay, keeps the host
/// WebSocket up, answers paired iPhones' sealed requests (index, whole
/// sessions, timeline tails, reviewed marks) from the repository, and pushes
/// what the repository just changed (events, summary-only changes, removals,
/// health) to every device that has synced on this connection.
///
/// One serial send loop does all outbound work — read → prepare once → seal
/// per device → reserve sequences (persisted first) → send — so an answer is
/// always on the wire before any push that follows it.
public actor RelayHostService {
    public typealias HealthProvider = @Sendable () async -> DaemonHealth?
    public typealias ConnectionObserver = @Sendable (Bool) async -> Void
    public typealias Logger = @Sendable (String) -> Void

    public static let indexLimit = 10_000
    public static let detailPageSize = 500

    private enum WorkItem {
        case index(device: DeviceID, requestID: RequestID?)
        case fetch(device: DeviceID, requestID: RequestID?, ids: [SessionID])
        case timeline(device: DeviceID, requestID: RequestID?, id: SessionID, since: Date)
        case events([AgentIngressEvent])
        case summaries([SessionID])
        case removed([SessionID], requestID: RequestID?, device: DeviceID?)
        case health(DaemonHealth, device: DeviceID?)
    }

    private let repository: any SessionRepository
    private let subscriptions: DaemonSubscriptionHub
    private let relayURL: URL
    private let credentialStore: any RelayHostCredentialStoring
    private var sequences: RelayHostSequenceStore
    private let transportFactory: any RelayFrameTransportFactory
    private let rest: any RelayHostREST
    private let hostName: @Sendable () -> String?
    private let healthProvider: HealthProvider
    private let onConnectionChange: ConnectionObserver
    private let log: Logger
    private let eventCoalesceInterval: Duration
    private let reconnectDelay: Duration
    private let deviceRefreshInterval: Duration
    private let healthInterval: Duration
    /// Floor between two on-demand device refreshes (unknown device, stale key).
    private let deviceRefreshOnDemandInterval: TimeInterval = 2
    private var lastOnDemandDeviceRefresh: Date?

    private var credentials: RelayHostCredentials?
    private var registeredThisProcess = false
    private var transport: (any RelayFrameTransport)?
    private var isConnected = false
    private var lastError: String?
    private var devices: [PairedDevice] = []
    /// Devices that asked for the index on this connection: pushes go only to them.
    private var activeDevices: Set<DeviceID> = []
    private var subscriptionID: UUID?
    private var pendingEvents: [AgentIngressEvent] = []
    private var eventFlushTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var lastHealth: DaemonHealth?
    private var queue: [WorkItem] = []
    private var drainTask: Task<Void, Never>?
    private var stopped = false

    public init(
        repository: any SessionRepository,
        subscriptions: DaemonSubscriptionHub,
        relayURL: URL,
        credentialStore: any RelayHostCredentialStoring,
        sequenceStatePath: String,
        transportFactory: any RelayFrameTransportFactory,
        rest: any RelayHostREST,
        hostName: @escaping @Sendable () -> String? = { Host.current().localizedName },
        healthProvider: @escaping HealthProvider,
        onConnectionChange: @escaping ConnectionObserver,
        logger: @escaping Logger,
        eventCoalesceInterval: Duration = .seconds(1),
        reconnectDelay: Duration = .seconds(2),
        deviceRefreshInterval: Duration = .seconds(10),
        healthInterval: Duration = .seconds(30)
    ) {
        self.repository = repository
        self.subscriptions = subscriptions
        self.relayURL = relayURL
        self.credentialStore = credentialStore
        sequences = RelayHostSequenceStore(path: sequenceStatePath)
        self.transportFactory = transportFactory
        self.rest = rest
        self.hostName = hostName
        self.healthProvider = healthProvider
        self.onConnectionChange = onConnectionChange
        log = logger
        self.eventCoalesceInterval = eventCoalesceInterval
        self.reconnectDelay = reconnectDelay
        self.deviceRefreshInterval = deviceRefreshInterval
        self.healthInterval = healthInterval
    }

    // MARK: - Lifecycle

    public func start() async {
        guard !stopped else { return }
        if subscriptionID == nil {
            subscriptionID = subscriptions.subscribe { [weak self] message in
                guard let self, case let .event(event) = message else { return }
                Task { await self.enqueueEvent(event) }
            }
        }
        await connect()
    }

    public func stop() async {
        stopped = true
        if let subscriptionID { subscriptions.unsubscribe(subscriptionID) }
        subscriptionID = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        await tearDownConnection()
    }

    public func status() -> RelayHostStatus {
        RelayHostStatus(
            connected: isConnected,
            hostID: credentials?.hostID,
            relayURL: credentials?.relayURL ?? relayURL,
            lastError: lastError,
            devices: devices
        )
    }

    public func createPairingOffer() async throws -> PairingOffer {
        let credentials = try await ensureCredentials()
        let offer = PairingOffer(
            relayURL: credentials.relayURL,
            hostID: credentials.hostID,
            hostName: hostName(),
            challenge: Self.credential(),
            hostPublicKey: credentials.keyPair.publicKey,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
        try await rest.createPairingOffer(offer, hostSecret: credentials.hostSecret)
        return offer
    }

    public func refreshDevices() async {
        guard let credentials else { return }
        do {
            devices = try await rest.devices(hostID: credentials.hostID, hostSecret: credentials.hostSecret)
            let revoked = Set(devices.filter { $0.revokedAt != nil }.map(\.id))
            activeDevices.subtract(revoked)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    public func revoke(deviceID: DeviceID) async throws {
        guard let credentials else { throw RelayClientError.notConnected }
        try await rest.revoke(hostID: credentials.hostID, deviceID: deviceID, hostSecret: credentials.hostSecret)
        activeDevices.remove(deviceID)
        await refreshDevices()
    }

    // MARK: - Repository change notifications (from DaemonService)

    /// Summaries changed without an event (reviewed, archived): `session_info`.
    public func summariesChanged(_ ids: [SessionID]) {
        guard !ids.isEmpty, !activeDevices.isEmpty else { return }
        enqueue(.summaries(ids))
    }

    /// Sessions the daemon no longer retains: `session_removed`.
    public func sessionsRemoved(_ ids: [SessionID]) {
        guard !ids.isEmpty, !activeDevices.isEmpty else { return }
        enqueue(.removed(ids, requestID: nil, device: nil))
    }

    /// Sessions the daemon wiped and rebuilt (`Refresh session`): every
    /// synced iPhone gets each one whole again (`session_full`, unsolicited),
    /// the way it would after asking for it — instead of waiting for its next
    /// index to notice the rows changed.
    public func sessionsRebuilt(_ ids: [SessionID]) {
        guard !ids.isEmpty, !activeDevices.isEmpty else { return }
        for device in activeDevices {
            enqueue(.fetch(device: device, requestID: nil, ids: ids))
        }
    }

    // MARK: - Connection

    private func connect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        guard !stopped else { return }
        do {
            let credentials = try await ensureCredentials()
            let transport = transportFactory.makeTransport(baseURL: credentials.relayURL)
            try await transport.connect(hostID: credentials.hostID, role: .host, token: credentials.hostSecret)
            self.transport = transport
            isConnected = true
            lastError = nil
            activeDevices = []
            await onConnectionChange(true)
            await refreshDevices()
            startReceiveLoop(transport)
            startRefreshLoop()
            startHealthLoop()
        } catch {
            isConnected = false
            lastError = String(describing: error)
            log("relay: connect failed: \(error)")
            scheduleReconnect(after: error)
        }
    }

    private func ensureCredentials() async throws -> RelayHostCredentials {
        if let credentials, credentials.relayURL == relayURL, registeredThisProcess {
            return credentials
        }
        var current = try credentials ?? credentialStore.load()
        if current?.relayURL != relayURL {
            current = RelayHostCredentials(
                relayURL: relayURL,
                hostID: HostID("host-\(UUID().uuidString.lowercased())"),
                hostSecret: Self.credential(),
                keyPair: RelayCryptography.makeKeyPair()
            )
        }
        guard let current else { throw RelayClientError.notConnected }
        // Idempotent: the Relay keeps the secret's hash and answers 200 to
        // the same secret, 401 to a different one.
        try await rest.registerHost(hostID: current.hostID, hostSecret: current.hostSecret)
        if credentials != current {
            try credentialStore.save(current)
        }
        credentials = current
        registeredThisProcess = true
        return current
    }

    private func startReceiveLoop(_ transport: any RelayFrameTransport) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await transport.next()
                    await self?.handle(message)
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.connectionLost(error)
                    return
                }
            }
        }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self, deviceRefreshInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: deviceRefreshInterval)
                guard !Task.isCancelled else { return }
                await self?.refreshDevices()
            }
        }
    }

    private func startHealthLoop() {
        healthTask?.cancel()
        healthTask = Task { [weak self, healthInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: healthInterval)
                guard !Task.isCancelled else { return }
                await self?.pushHealthIfChanged()
            }
        }
    }

    private func connectionLost(_ error: Error) async {
        guard isConnected || transport != nil else { return }
        isConnected = false
        lastError = String(describing: error)
        log("relay: connection lost: \(error)")
        await tearDownConnection()
        await onConnectionChange(false)
        scheduleReconnect(after: error)
    }

    private func tearDownConnection() async {
        receiveTask?.cancel()
        receiveTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        healthTask?.cancel()
        healthTask = nil
        activeDevices = []
        let transport = self.transport
        self.transport = nil
        isConnected = false
        await transport?.disconnect()
    }

    private func scheduleReconnect(after error: Error) {
        guard !stopped, Self.shouldReconnect(after: error), reconnectTask == nil else { return }
        reconnectTask = Task { [weak self, reconnectDelay] in
            try? await Task.sleep(for: reconnectDelay)
            guard !Task.isCancelled, let self else { return }
            await self.clearReconnectAndConnect()
        }
    }

    private func clearReconnectAndConnect() async {
        reconnectTask = nil
        await connect()
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

    // MARK: - Inbound

    private func handle(_ message: RelayIncomingMessage) async {
        switch message {
        case let .frame(frame):
            await handle(frame)
        case let .error(error):
            handleRelayError(error)
        case .presence:
            break
        }
    }

    private func handle(_ frame: RelayRoutingFrame) async {
        guard frame.kind == .request, let deviceID = frame.deviceID, let credentials else { return }
        // A just-paired iPhone (or one that re-paired with a new key) sends
        // its first request before the 10 s device refresh has seen it: look
        // the device list up again before giving up on the request.
        var device = activeDevice(deviceID)
        if device == nil, await refreshDevicesOnDemand() {
            device = activeDevice(deviceID)
        }
        guard let device else {
            log("relay: request from unknown or revoked device \(deviceID.rawValue)")
            return
        }
        let payload: RemoteSessionPayload
        do {
            payload = try open(frame, from: device, credentials: credentials)
        } catch {
            guard await refreshDevicesOnDemand(),
                  let refreshed = activeDevice(deviceID),
                  refreshed.publicKey != device.publicKey,
                  let reopened = try? open(frame, from: refreshed, credentials: credentials) else {
                log("relay: could not open request from \(deviceID.rawValue): \(error)")
                return
            }
            payload = reopened
        }
        switch payload.kind {
        case .syncIndex:
            enqueue(.index(device: deviceID, requestID: payload.requestID))
        case .fetchSession:
            enqueue(.fetch(device: deviceID, requestID: payload.requestID, ids: payload.sessionIDs ?? []))
        case .fetchTimelineSince:
            guard let id = payload.sessionIDs?.first, let since = payload.since else { return }
            enqueue(.timeline(device: deviceID, requestID: payload.requestID, id: id, since: since))
        case .sessionReviewed:
            // An iPhone opened the session: the Mac window and the Notch turn
            // grey through the local stream, other iPhones through `session_info`.
            let ids = payload.sessionIDs ?? []
            Task { [weak self] in
                guard let self else { return }
                for id in ids {
                    try? await self.repository.markSessionReviewed(id)
                    if let summary = try? await self.repository.sessionDetail(id: id, cursor: nil, limit: 1)?.summary {
                        self.subscriptions.publish(summary: summary)
                    }
                }
                await self.summariesChanged(ids)
            }
        default:
            log("relay: ignoring request kind \(payload.kind.rawValue) from \(deviceID.rawValue)")
        }
    }

    private func activeDevice(_ id: DeviceID) -> PairedDevice? {
        devices.first { $0.id == id && $0.revokedAt == nil }
    }

    private func open(_ frame: RelayRoutingFrame, from device: PairedDevice, credentials: RelayHostCredentials) throws -> RemoteSessionPayload {
        try RelayCryptography.open(
            frame,
            privateKey: credentials.keyPair.privateKey,
            peerPublicKey: device.publicKey
        )
    }

    /// Refreshes the device list outside the timer, at most once per
    /// `deviceRefreshOnDemandInterval`; false when throttled.
    private func refreshDevicesOnDemand() async -> Bool {
        let now = Date()
        if let last = lastOnDemandDeviceRefresh, now.timeIntervalSince(last) < deviceRefreshOnDemandInterval {
            return false
        }
        lastOnDemandDeviceRefresh = now
        await refreshDevices()
        return true
    }

    private func handleRelayError(_ error: RelayErrorMessage) {
        guard error.code == "non_monotonic_sequence" else {
            log("relay: worker error \(error.code)")
            return
        }
        guard let deviceID = error.deviceID, let lastSequence = error.lastSequence else { return }
        do {
            try sequences.advance(deviceID, past: lastSequence)
        } catch {
            log("relay: could not persist sequence state: \(error)")
        }
        // Whatever that device received is now suspect: it must re-index, and
        // it only notices when a frame arrives with a sequence past the hole.
        // The Relay forwards nothing about the rejection, so nudge it with a
        // health frame on the healed cursor; the gap makes the iPhone index.
        activeDevices.remove(deviceID)
        Task { [weak self] in
            guard let self, let health = await self.healthProvider() else { return }
            await self.enqueue(.health(health, device: deviceID))
        }
    }

    // MARK: - Events

    private func enqueueEvent(_ event: AgentIngressEvent) {
        pendingEvents.append(event)
        guard eventFlushTask == nil else { return }
        eventFlushTask = Task { [weak self, eventCoalesceInterval] in
            try? await Task.sleep(for: eventCoalesceInterval)
            await self?.flushEvents()
        }
    }

    private func flushEvents() {
        eventFlushTask = nil
        let events = pendingEvents
        pendingEvents = []
        guard !events.isEmpty, !activeDevices.isEmpty else { return }
        enqueue(.events(events))
    }

    private func pushHealthIfChanged() async {
        guard !activeDevices.isEmpty, let health = await healthProvider() else { return }
        if let lastHealth, Self.healthUnchanged(lastHealth, health) { return }
        lastHealth = health
        enqueue(.health(health, device: nil))
    }

    private static func healthUnchanged(_ lhs: DaemonHealth, _ rhs: DaemonHealth) -> Bool {
        lhs.daemonVersion == rhs.daemonVersion
            && lhs.executableHash == rhs.executableHash
            && lhs.activeSessionCount == rhs.activeSessionCount
            && lhs.retainedSessionCount == rhs.retainedSessionCount
            && lhs.relayConnected == rhs.relayConnected
    }

    // MARK: - Serial send loop

    private func enqueue(_ item: WorkItem) {
        queue.append(item)
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let item = queue.removeFirst()
            do {
                try await process(item)
            } catch {
                lastError = String(describing: error)
                log("relay: send failed: \(error)")
            }
        }
        drainTask = nil
    }

    private func process(_ item: WorkItem) async throws {
        let now = Date()
        switch item {
        case let .index(device, requestID):
            let entries = try await repository.sessionIndex(limit: Self.indexLimit)
            let parts = try RelayPayloadBatcher.indexParts(entries, requestID: requestID, generatedAt: now)
            try await send(parts.map(\.prepared), to: [device])
            activeDevices.insert(device)
            if let health = await healthProvider() {
                lastHealth = health
                let prepared = try RelayCryptography.prepare(RemoteSessionPayload(kind: .health, generatedAt: now, health: health))
                try await send([prepared], to: [device])
            }
        case let .fetch(device, requestID, ids):
            for id in ids {
                if let detail = try await fetchFullDetail(id) {
                    let parts = try RelaySessionPartitioner.parts(for: detail, kind: .sessionFull, requestID: requestID, generatedAt: now)
                    try await send(parts.map(\.prepared), to: [device])
                } else {
                    let prepared = try RelayCryptography.prepare(RemoteSessionPayload(
                        kind: .sessionRemoved, generatedAt: now, requestID: requestID, sessionIDs: [id]
                    ))
                    try await send([prepared], to: [device])
                }
            }
        case let .timeline(device, requestID, id, since):
            if let detail = try await fetchTimelineSince(id, since: since) {
                let parts = try RelaySessionPartitioner.parts(for: detail, kind: .sessionTimeline, requestID: requestID, generatedAt: now)
                try await send(parts.map(\.prepared), to: [device])
            } else {
                let prepared = try RelayCryptography.prepare(RemoteSessionPayload(
                    kind: .sessionRemoved, generatedAt: now, requestID: requestID, sessionIDs: [id]
                ))
                try await send([prepared], to: [device])
            }
        case let .events(events):
            guard !activeDevices.isEmpty else { return }
            let batches = try RelayPayloadBatcher.eventBatches(events, generatedAt: now)
            try await send(batches.map(\.prepared), to: Array(activeDevices))
        case let .summaries(ids):
            guard !activeDevices.isEmpty else { return }
            var summaries: [SessionSummary] = []
            for id in ids {
                if let detail = try await repository.sessionDetail(id: id, cursor: nil, limit: 1) {
                    summaries.append(detail.summary)
                }
            }
            guard !summaries.isEmpty else { return }
            let batches = try RelayPayloadBatcher.summaryBatches(summaries, generatedAt: now)
            try await send(batches.map(\.prepared), to: Array(activeDevices))
        case let .removed(ids, requestID, device):
            let targets = device.map { [$0] } ?? Array(activeDevices)
            guard !targets.isEmpty else { return }
            let prepared = try RelayCryptography.prepare(RemoteSessionPayload(
                kind: .sessionRemoved, generatedAt: now, requestID: requestID, sessionIDs: ids
            ))
            try await send([prepared], to: targets)
        case let .health(health, device):
            let targets = device.map { [$0] } ?? Array(activeDevices)
            guard !targets.isEmpty else { return }
            let prepared = try RelayCryptography.prepare(RemoteSessionPayload(kind: .health, generatedAt: now, health: health))
            try await send([prepared], to: targets)
        }
    }

    /// Seals and sends the prepared payloads to each device, reserving and
    /// persisting that device's sequences BEFORE anything hits the wire.
    private func send(_ prepared: [RelayPreparedPayload], to targets: [DeviceID]) async throws {
        guard !prepared.isEmpty, let credentials, let transport else { return }
        for deviceID in targets {
            guard let device = devices.first(where: { $0.id == deviceID && $0.revokedAt == nil }) else { continue }
            let first = try sequences.reserve(for: deviceID, count: prepared.count)
            for (offset, payload) in prepared.enumerated() {
                let frame = try RelayCryptography.seal(
                    payload,
                    hostID: credentials.hostID,
                    deviceID: deviceID,
                    sequence: first + UInt64(offset),
                    kind: .data,
                    privateKey: credentials.keyPair.privateKey,
                    peerPublicKey: device.publicKey
                )
                try await transport.send(frame)
            }
        }
    }

    // MARK: - Repository reads

    private func fetchFullDetail(_ id: SessionID) async throws -> SessionDetail? {
        var cursor: PaginationCursor?
        var turns: [TurnSummary] = []
        var timeline: [TimelineItem] = []
        var summary: SessionSummary?
        repeat {
            guard let page = try await repository.sessionDetail(id: id, cursor: cursor, limit: Self.detailPageSize) else {
                return nil
            }
            summary = page.summary
            if !page.turns.isEmpty { turns = page.turns }
            timeline += page.timeline
            cursor = page.nextCursor
        } while cursor != nil
        guard let summary else { return nil }
        return SessionDetail(summary: summary, turns: turns, timeline: timeline)
    }

    private func fetchTimelineSince(_ id: SessionID, since: Date) async throws -> SessionDetail? {
        var cursor: PaginationCursor?
        var turns: [TurnSummary] = []
        var timeline: [TimelineItem] = []
        var summary: SessionSummary?
        repeat {
            guard let page = try await repository.timelineSince(id: id, since: since, cursor: cursor, limit: Self.detailPageSize) else {
                return nil
            }
            summary = page.summary
            if !page.turns.isEmpty { turns = page.turns }
            timeline += page.timeline
            cursor = page.nextCursor
        } while cursor != nil
        guard let summary else { return nil }
        return SessionDetail(summary: summary, turns: turns, timeline: timeline)
    }

    private static func credential() -> String {
        RelayCryptography.makeKeyPair().privateKey
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
