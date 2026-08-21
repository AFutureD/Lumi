import AgentStatusCore
import AgentStatusRemote
import AgentStatusTransport
import Foundation

/// What one paired Mac looks like to the UI.
struct MacChannelState: Sendable {
    let hostID: HostID
    let displayName: String
    let pairedAt: Date
    let isConnected: Bool
    let isHostOnline: Bool
    /// The latest index arrived and every session it names was received.
    let hasCompleteSync: Bool
    /// Every session held in memory for this Mac, online or not.
    let sessions: [SessionDetail]
    /// When the last complete sync landed (persists across launches).
    let lastSyncAt: Date?
    let lastError: String?

    var isOnline: Bool { isConnected && isHostOnline }
    /// Sessions the lists show: only while the Mac is online and the current
    /// sync is complete, so stale data never reads as live state.
    var visibleSessions: [SessionDetail] { isOnline && hasCompleteSync ? sessions : [] }
}

/// All paired Macs. Credentials live in the Keychain; session content lives
/// only in memory and is re-fetched from each Mac on every connect.
@MainActor
final class RelayDeviceController {
    private let secureStore = SecureStore(service: "com.huanan.AgentStatusIOS.relay")
    private let credentialsAccount = "device-channels-v3"
    private let settings: LocalSettings
    private var channelOrder: [HostID] = []
    private var channels: [HostID: RelayDeviceChannel] = [:]
    private var observers: [UUID: () -> Void] = [:]
    /// Developer preview (`-AgentStatusPreviewData`): fixed states instead of Relay.
    private var previewStates: [MacChannelState]?

    init(settings: LocalSettings = .shared) {
        self.settings = settings
        let stored = (try? secureStore.load(RelayDeviceCredentialCollection.self, account: credentialsAccount))?.channels ?? []
        for credentials in stored {
            let channel = makeChannel(credentials)
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

    /// Ask every Mac for its current state again (pull-to-refresh, `Refresh list`).
    func refreshAll() {
        for channel in channels.values { channel.refresh() }
        notify()
    }

    func refresh(hostID: HostID) {
        channels[hostID]?.refresh()
        notify()
    }

    func usePreview(_ states: [MacChannelState]) {
        previewStates = states
        notify()
    }

    // MARK: - Pairing

    func pair(using offer: PairingOffer) async throws {
        guard previewStates == nil else { return }
        guard offer.version.isCompatible(with: .current), offer.expiresAt > Date() else {
            throw PairingError.expiredOrIncompatible
        }
        guard offer.relayURL == RelayBuildConfiguration.url else {
            throw PairingError.unexpectedRelay
        }
        let keyPair = RelayCryptography.makeKeyPair()
        let deviceID = DeviceID("device-\(UUID().uuidString.lowercased())")
        let relayURL = RelayBuildConfiguration.url
        let result = try await RelayRESTClient(baseURL: relayURL).pair(PairingRequest(
            hostID: offer.hostID,
            deviceID: deviceID,
            challenge: offer.challenge,
            deviceName: settings.deviceName,
            devicePublicKey: keyPair.publicKey
        ))
        let credentials = RelayDeviceCredentials(
            relayURL: relayURL,
            hostID: offer.hostID,
            hostName: offer.hostName,
            deviceID: deviceID,
            deviceToken: result.deviceToken,
            keyPair: keyPair,
            hostPublicKey: result.hostPublicKey,
            pairedAt: result.pairedAt
        )

        if let existing = channels[offer.hostID] { await existing.stop() }
        channelOrder.removeAll { $0 == offer.hostID }
        channelOrder.append(offer.hostID)
        let channel = makeChannel(credentials)
        channels[offer.hostID] = channel
        settings.setLastSync(nil, for: offer.hostID)
        try saveCredentials()
        await channel.connect()
        notify()
    }

    /// Removes one Mac: its channel, credentials and in-memory sessions. The
    /// Mac's own pairing record stays until revoked there.
    func unpair(hostID: HostID) {
        if previewStates != nil {
            previewStates?.removeAll { $0.hostID == hostID }
            notify()
            return
        }
        guard let channel = channels.removeValue(forKey: hostID) else { return }
        channelOrder.removeAll { $0 == hostID }
        channel.cancelTasks()
        Task { await channel.stop() }
        settings.setLastSync(nil, for: hostID)
        try? saveCredentials()
        notify()
    }

    // MARK: - Review

    /// Opening a session on the iPhone counts as reviewing it everywhere:
    /// the row turns grey here at once, and the Mac is told so it, the Notch
    /// and other iPhones follow (the Mac republishes the summary).
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

    /// Hides one session on this iPhone until the Mac sends a newer version
    /// of it. The Mac keeps the session; the iPhone is read-only.
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

    /// Drops every received session from memory. Nothing is fetched back
    /// until the next refresh or the next update from a Mac.
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

    private func makeChannel(_ credentials: RelayDeviceCredentials) -> RelayDeviceChannel {
        let credentials = RelayDeviceCredentials(
            relayURL: RelayBuildConfiguration.url,
            hostID: credentials.hostID,
            hostName: credentials.hostName,
            deviceID: credentials.deviceID,
            deviceToken: credentials.deviceToken,
            keyPair: credentials.keyPair,
            hostPublicKey: credentials.hostPublicKey,
            pairedAt: credentials.pairedAt,
            lastAcknowledgedSequence: credentials.lastAcknowledgedSequence
        )
        return RelayDeviceChannel(credentials: credentials, settings: settings) { [weak self] in
            guard let self else { return }
            try? self.saveCredentials()
            self.notify()
        }
    }

    private func saveCredentials() throws {
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
            pairedAt: pairedAt,
            isConnected: isConnected,
            isHostOnline: isHostOnline,
            hasCompleteSync: hasCompleteSync,
            sessions: sessions,
            lastSyncAt: lastSyncAt,
            lastError: lastError
        )
    }
}

/// One Mac-to-iPhone channel. Every session for that Mac is multiplexed
/// through this single WebSocket; no session creates a connection.
@MainActor
private final class RelayDeviceChannel {
    private let onChange: () -> Void
    private let settings: LocalSettings
    private var socket: RelayWebSocketClient?
    private var connectTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private(set) var credentials: RelayDeviceCredentials
    private var sessions: [SessionDetail] = []
    private var isHostOnline = false
    private var isConnected = false
    /// The visible id set promised by the latest `.index` frame; `nil` until
    /// one arrives on this connection.
    private var indexIDs: Set<SessionID>?
    /// Parts of sessions still in flight, keyed by session.
    private var partBuffers: [SessionID: [RemoteSessionPayload]] = [:]
    /// Highest frame sequence seen on this connection, for gap detection.
    private var lastReceivedSequence: UInt64 = 0
    private var needsResync = false
    private var lastError: String?
    /// Sessions hidden on this iPhone, with the `updatedAt` they had when
    /// hidden; a newer copy from the Mac shows them again.
    private var dismissed: [SessionID: Date] = [:]
    /// Sequence of device → host `attention` frames on this connection.
    private var commandSequence: UInt64 = 0

    /// The sync is current when the latest index has arrived and every
    /// session it references (that is not dismissed) was fully received.
    private var hasCompleteSync: Bool {
        guard let indexIDs else { return false }
        return RelayFrameReduction.missingIDs(index: indexIDs.subtracting(dismissed.keys), sessions: sessions).isEmpty
    }

    init(credentials: RelayDeviceCredentials, settings: LocalSettings, onChange: @escaping () -> Void) {
        self.credentials = credentials
        self.settings = settings
        self.onChange = onChange
    }

    var state: MacChannelState {
        MacChannelState(
            hostID: credentials.hostID,
            displayName: credentials.displayName,
            pairedAt: credentials.pairedAt,
            isConnected: isConnected,
            isHostOnline: isHostOnline,
            hasCompleteSync: hasCompleteSync,
            sessions: sessions,
            lastSyncAt: settings.lastSync(for: credentials.hostID),
            lastError: lastError
        )
    }

    func start() {
        guard !isConnected, connectTask == nil else { return }
        connectTask = Task { [weak self] in
            guard let self else { return }
            await self.connect()
            self.connectTask = nil
        }
    }

    /// Connected: ask the Mac for a full resend. Otherwise: connect (which asks).
    func refresh() {
        if isConnected, let socket {
            Task { try? await self.requestFullResend(socket) }
        } else {
            start()
        }
    }

    func connect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        await socket?.disconnect()
        let socket = RelayWebSocketClient(baseURL: credentials.relayURL)
        self.socket = socket
        isConnected = false
        isHostOnline = false
        indexIDs = nil
        partBuffers = [:]
        lastReceivedSequence = 0
        needsResync = false
        do {
            try await socket.connect(
                hostID: credentials.hostID,
                role: .device(credentials.deviceID),
                token: credentials.deviceToken
            )
            isConnected = true
            lastError = nil
            // Nothing is cached on the iPhone, so every connection starts by
            // asking the Mac for everything it has.
            try await requestFullResend(socket)
            receiveTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await socket.next()
                        await self?.handle(message, socket: socket)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.connectionFailed(error)
                }
            }
        } catch {
            connectionFailed(error)
        }
        onChange()
    }

    func stop() async {
        cancelTasks()
        await socket?.disconnect()
        socket = nil
        sessions = []
        isConnected = false
        isHostOnline = false
        indexIDs = nil
        partBuffers = [:]
        onChange()
    }

    func cancelTasks() {
        connectTask?.cancel()
        receiveTask?.cancel()
        reconnectTask?.cancel()
        connectTask = nil
        receiveTask = nil
        reconnectTask = nil
    }

    /// Clears the review flag locally and tells the Mac. Returns false when
    /// the session is unknown or already reviewed.
    func markReviewed(_ id: SessionID) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.summary.id == id }),
              sessions[index].summary.needsReview else { return false }
        let detail = sessions[index]
        sessions[index] = SessionDetail(summary: detail.summary.reviewed, turns: detail.turns, timeline: detail.timeline)
        guard isConnected, let socket else { return true }
        let credentials = self.credentials
        commandSequence &+= 1
        let sequence = commandSequence
        Task {
            do {
                let frame = try RelayCryptography.seal(
                    RemoteSessionPayload(kind: .sessionReviewed, sessionIDs: [id]),
                    hostID: credentials.hostID,
                    deviceID: credentials.deviceID,
                    sequence: sequence,
                    kind: .attention,
                    privateKey: credentials.keyPair.privateKey,
                    peerPublicKey: credentials.hostPublicKey
                )
                try await socket.send(frame)
            } catch {
                self.lastError = "Unable to send review state: \(error)"
            }
        }
        return true
    }

    func dismiss(_ id: SessionID) {
        guard let detail = sessions.first(where: { $0.summary.id == id }) else { return }
        dismissed[id] = detail.summary.updatedAt
        sessions.removeAll { $0.summary.id == id }
        partBuffers[id] = nil
    }

    func clear() {
        sessions = []
        indexIDs = nil
        partBuffers = [:]
        dismissed = [:]
    }

    // MARK: - Private

    /// A `hello` behind the Mac's channel sequence makes it resend every
    /// session plus the index.
    private func requestFullResend(_ socket: RelayWebSocketClient) async throws {
        try await socket.send(RelayRoutingFrame(
            hostID: credentials.hostID,
            deviceID: credentials.deviceID,
            sequence: 0,
            kind: .hello,
            acknowledgedSequence: 0
        ))
    }

    private func connectionFailed(_ error: Error) {
        isConnected = false
        isHostOnline = false
        indexIDs = nil
        partBuffers = [:]
        lastError = String(describing: error)
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

    private func handle(_ message: RelayIncomingMessage, socket: RelayWebSocketClient) async {
        switch message {
        case let .presence(online):
            isHostOnline = online
            if !online { indexIDs = nil }
        case let .frame(frame):
            guard frame.hostID == credentials.hostID,
                  frame.deviceID == credentials.deviceID,
                  frame.sequence > lastReceivedSequence else { return }
            do {
                let payload = try RelayCryptography.open(
                    frame,
                    privateKey: credentials.keyPair.privateKey,
                    peerPublicKey: credentials.hostPublicKey
                )
                // A hole in the sequence means dropped frames: finish this
                // batch, then ask the Mac for a full resend at the index.
                if lastReceivedSequence != 0, frame.sequence > lastReceivedSequence + 1 {
                    needsResync = true
                }
                lastReceivedSequence = frame.sequence
                try await apply(payload, socket: socket)
                credentials.lastAcknowledgedSequence = frame.sequence
                try await socket.send(RelayRoutingFrame(
                    hostID: credentials.hostID,
                    deviceID: credentials.deviceID,
                    sequence: frame.sequence,
                    kind: .acknowledgement,
                    acknowledgedSequence: frame.sequence
                ))
                lastError = nil
            } catch {
                lastError = "Unable to decrypt relay update: \(error)"
            }
        }
        onChange()
    }

    private func apply(_ payload: RemoteSessionPayload, socket: RelayWebSocketClient) async throws {
        switch payload.kind {
        case .session:
            guard let page = payload.session else { return }
            let id = page.summary.id
            if (payload.part ?? 0) == 0 { partBuffers[id] = [] }
            partBuffers[id, default: []].append(payload)
            guard page.nextCursor == nil,
                  let detail = RelayFrameReduction.assemble(parts: partBuffers[id] ?? []) else { return }
            partBuffers[id] = nil
            if let hiddenAt = dismissed[id], detail.summary.updatedAt <= hiddenAt { return }
            dismissed[id] = nil
            sessions = RelayFrameReduction.upsert(detail, into: sessions)
            isHostOnline = true
        case .index:
            let ids = Set(payload.sessionIDs ?? [])
            sessions = RelayFrameReduction.prune(sessions, keeping: ids)
            partBuffers = partBuffers.filter { ids.contains($0.key) }
            dismissed = dismissed.filter { ids.contains($0.key) }
            indexIDs = ids
            isHostOnline = true
            // The index closes a batch. Anything still missing (partial
            // delivery, dropped frames) is healed by a full resend.
            if needsResync || !hasCompleteSync {
                needsResync = false
                try await requestFullResend(socket)
            } else {
                settings.setLastSync(payload.generatedAt, for: credentials.hostID)
            }
        case .unavailable:
            isHostOnline = false
            indexIDs = nil
        case .sessionReviewed:
            // Device → host only; never expected from the Mac.
            return
        case .unknown:
            // A newer host build; fail safe into the syncing state.
            isHostOnline = false
            indexIDs = nil
        }
    }
}

enum PairingError: LocalizedError {
    case expiredOrIncompatible
    case unexpectedRelay

    var errorDescription: String? {
        switch self {
        case .expiredOrIncompatible:
            "The pairing code has expired or uses an incompatible protocol."
        case .unexpectedRelay:
            "The pairing code was created for a different Relay build configuration."
        }
    }
}
