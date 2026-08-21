import AgentStatusRemote
import AgentStatusTransport
import Foundation

struct RelayHostCredentials: Codable, Sendable {
    let relayURL: URL
    let hostID: HostID
    let hostSecret: String
    let keyPair: RelayKeyPair
    /// Legacy global sequence retained for decoding credentials created by early builds.
    var lastSequence: UInt64
    /// Each paired iOS channel advances independently; sessions never own a sequence.
    var channelSequences: [String: UInt64]

    init(
        relayURL: URL,
        hostID: HostID,
        hostSecret: String,
        keyPair: RelayKeyPair,
        lastSequence: UInt64 = 0,
        channelSequences: [String: UInt64] = [:]
    ) {
        self.relayURL = relayURL
        self.hostID = hostID
        self.hostSecret = hostSecret
        self.keyPair = keyPair
        self.lastSequence = lastSequence
        self.channelSequences = channelSequences
    }

    private enum CodingKeys: String, CodingKey {
        case relayURL
        case hostID
        case hostSecret
        case keyPair
        case lastSequence
        case channelSequences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        relayURL = try container.decode(URL.self, forKey: .relayURL)
        hostID = try container.decode(HostID.self, forKey: .hostID)
        hostSecret = try container.decode(String.self, forKey: .hostSecret)
        keyPair = try container.decode(RelayKeyPair.self, forKey: .keyPair)
        lastSequence = try container.decodeIfPresent(UInt64.self, forKey: .lastSequence) ?? 0
        channelSequences = try container.decodeIfPresent([String: UInt64].self, forKey: .channelSequences) ?? [:]
    }
}

@MainActor
final class RelayHostController {
    private weak var store: MacSessionStore?
    private let secureStore = SecureStore(service: "com.huanan.AgentStatusMac.relay")
    private let credentialsAccount = "host-credentials-v1"
    private var credentials: RelayHostCredentials?
    private var socket: RelayWebSocketClient?
    private var connectionTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var publishPending = false
    /// Per-session copy of what every up-to-date device holds; `nil` forces a
    /// full resend (host reconnect).
    private var lastSentDetails: [SessionID: SessionDetail]?
    /// Devices that missed frames (fresh pairing, or a hello behind our
    /// sequence): they get every session plus the index on the next publish.
    private var devicesNeedingFullResend: Set<DeviceID> = []
    private var sentUnavailable = false
    private var lastObservedStoreRevision: UInt64 = 0
    private var lastObservedDaemonAvailable = false

    private(set) var devices: [RelayDeviceRecord] = []
    private(set) var isConnected = false
    private(set) var lastError: String?
    private var observers: [UUID: () -> Void] = [:]

    init(store: MacSessionStore, relayURL: URL = RelayBuildConfiguration.url) {
        self.store = store
        credentials = try? secureStore.load(RelayHostCredentials.self, account: credentialsAccount)
        lastObservedStoreRevision = store.dataRevision
        lastObservedDaemonAvailable = store.health != nil
        store.observe { [weak self, weak store] in
            guard let self, let store else { return }
            let daemonAvailable = store.health != nil
            guard RelayPublishDecision.shouldSchedule(
                previousRevision: self.lastObservedStoreRevision,
                currentRevision: store.dataRevision,
                wasDaemonAvailable: self.lastObservedDaemonAvailable,
                isDaemonAvailable: daemonAvailable
            ) else { return }
            self.lastObservedStoreRevision = store.dataRevision
            self.lastObservedDaemonAvailable = daemonAvailable
            self.schedulePublish(from: store)
        }
        Task {
            if credentials?.relayURL == relayURL {
                await startConnection()
            } else {
                await configure(relayURL: relayURL)
            }
        }
    }

    /// Multiple views (Pairing, sidebar, toolbar) observe connection and device changes.
    @discardableResult
    func observe(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    private func notifyObservers() {
        observers.values.forEach { $0() }
    }

    deinit {
        connectionTask?.cancel()
        refreshTask?.cancel()
        reconnectTask?.cancel()
        publishTask?.cancel()
    }

    func stop() async {
        connectionTask?.cancel()
        connectionTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        publishTask?.cancel()
        publishTask = nil
        await socket?.disconnect()
        socket = nil
        isConnected = false
        notifyObservers()
    }

    private func configure(relayURL: URL) async {
        do {
            var current = credentials
            if current?.relayURL != relayURL {
                let keyPair = RelayCryptography.makeKeyPair()
                current = RelayHostCredentials(
                    relayURL: relayURL,
                    hostID: HostID("host-\(UUID().uuidString.lowercased())"),
                    hostSecret: Self.credential(),
                    keyPair: keyPair,
                    lastSequence: 0
                )
            }
            guard let current else { return }
            try await RelayRESTClient(baseURL: relayURL).registerHost(
                hostID: current.hostID,
                hostSecret: current.hostSecret
            )
            credentials = current
            try secureStore.save(current, account: credentialsAccount)
            lastError = nil
            await startConnection()
        } catch {
            lastError = String(describing: error)
        }
        notifyObservers()
    }

    func createPairingOffer() async throws -> PairingOffer {
        guard let credentials else { throw RelayClientError.notConnected }
        let offer = PairingOffer(
            relayURL: credentials.relayURL,
            hostID: credentials.hostID,
            hostName: Host.current().localizedName,
            challenge: Self.credential(),
            hostPublicKey: credentials.keyPair.publicKey,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
        try await RelayRESTClient(baseURL: credentials.relayURL).createPairingOffer(
            offer,
            hostSecret: credentials.hostSecret
        )
        return offer
    }

    func refreshDevices() async {
        guard let credentials else { return }
        let previousDevices = devices
        let previousError = lastError
        do {
            let previousActiveIDs = Set(devices.filter { $0.revokedAt == nil }.map(\.id))
            let refreshed = try await RelayRESTClient(baseURL: credentials.relayURL).devices(
                hostID: credentials.hostID,
                hostSecret: credentials.hostSecret
            )
            devices = refreshed
            let activeIDs = Set(refreshed.filter { $0.revokedAt == nil }.map(\.id))
            if activeIDs != previousActiveIDs {
                // Only the newly paired devices need history; devices that
                // were already current keep receiving increments.
                devicesNeedingFullResend.formUnion(activeIDs.subtracting(previousActiveIDs))
                devicesNeedingFullResend.formIntersection(activeIDs)
                sentUnavailable = false
                if let store { schedulePublish(from: store) }
            }
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        if devices != previousDevices || lastError != previousError {
            notifyObservers()
        }
    }

    func revoke(deviceID: DeviceID) async {
        guard let credentials else { return }
        do {
            try await RelayRESTClient(baseURL: credentials.relayURL).revoke(
                hostID: credentials.hostID,
                deviceID: deviceID,
                hostSecret: credentials.hostSecret
            )
            await refreshDevices()
        } catch {
            lastError = String(describing: error)
            notifyObservers()
        }
    }

    private func startConnection() async {
        guard let credentials else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionTask?.cancel()
        refreshTask?.cancel()
        await socket?.disconnect()
        let socket = RelayWebSocketClient(baseURL: credentials.relayURL)
        self.socket = socket
        do {
            try await socket.connect(hostID: credentials.hostID, role: .host, token: credentials.hostSecret)
            isConnected = true
            lastError = nil
            lastSentDetails = nil
            sentUnavailable = false
            await refreshDevices()
            if let store { schedulePublish(from: store) }
            connectionTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await socket.next()
                        guard case let .frame(frame) = message else { continue }
                        self?.handleDeviceFrame(frame)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.isConnected = false
                    self?.lastError = String(describing: error)
                    self?.notifyObservers()
                    self?.scheduleReconnect(after: error)
                }
            }
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshDevices()
                    try? await Task.sleep(for: .seconds(10))
                }
            }
        } catch {
            isConnected = false
            lastError = String(describing: error)
            scheduleReconnect(after: error)
        }
        notifyObservers()
    }

    private func scheduleReconnect(after error: Error) {
        guard Self.shouldReconnect(after: error), reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await self.startConnection()
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

    /// A device's forwarded `hello` behind our channel sequence means it
    /// missed frames: queue a full resend. This is the recovery path — the
    /// relay keeps no replay buffer. An `attention` frame is a sealed
    /// device → host command (today: the iPhone opened a session, so it
    /// counts as reviewed everywhere, exactly like opening it on the Mac).
    private func handleDeviceFrame(_ frame: RelayRoutingFrame) {
        guard let deviceID = frame.deviceID, let credentials else { return }
        switch frame.kind {
        case .hello:
            let current = credentials.channelSequences[deviceID.rawValue] ?? credentials.lastSequence
            guard (frame.acknowledgedSequence ?? 0) < current else { return }
            devicesNeedingFullResend.insert(deviceID)
            if let store { schedulePublish(from: store) }
        case .attention:
            guard let device = devices.first(where: { $0.id == deviceID && $0.revokedAt == nil }),
                  let payload = try? RelayCryptography.open(
                      frame,
                      privateKey: credentials.keyPair.privateKey,
                      peerPublicKey: device.publicKey
                  ),
                  payload.kind == .sessionReviewed else { return }
            for sessionID in payload.sessionIDs ?? [] {
                store?.markSessionReviewed(sessionID)
            }
        default:
            return
        }
    }

    private func publishCurrentState(from store: MacSessionStore) async {
        guard isConnected, credentials != nil, let socket else { return }
        do {
            let activeDevices = devices.filter { $0.revokedAt == nil }
            guard !activeDevices.isEmpty else { return }
            if store.health == nil {
                guard !sentUnavailable else { return }
                let prepared = try RelayCryptography.prepare(
                    RemoteSessionPayload(kind: .unavailable, message: "Mac daemon unavailable")
                )
                try await sendFrames(
                    [(prepared, false)],
                    to: activeDevices,
                    perDeviceExtras: [:],
                    socket: socket
                )
                sentUnavailable = true
                lastSentDetails = nil
                lastError = nil
                return
            }

            let wasUnavailable = sentUnavailable
            let generatedAt = Date()
            let orderedDetails = try await store.snapshotDetails()
            let details = Dictionary(uniqueKeysWithValues: orderedDetails.map { ($0.summary.id, $0) })
            let previous = wasUnavailable ? nil : lastSentDetails
            let changed = RelayPublishPlan.changedSessions(previous: previous, current: details)
            let needsFull = !devicesNeedingFullResend.isEmpty
            let indexChanged = previous.map { Set($0.keys) != Set(details.keys) } ?? true
            guard !changed.isEmpty || indexChanged || needsFull || wasUnavailable else { return }

            // Session frames first, the index last: the index is the commit
            // marker a device prunes and completes against.
            var partsBySession: [SessionID: [(RelayPreparedPayload, Bool)]] = [:]
            let idsToPrepare = needsFull ? Array(details.keys) : changed
            for id in idsToPrepare {
                guard let detail = details[id] else { continue }
                partsBySession[id] = try RelaySessionPartitioner
                    .parts(for: detail, generatedAt: generatedAt)
                    .map { ($0.prepared, detail.summary.needsAttention) }
            }
            let anyAttention = orderedDetails.contains { $0.summary.needsAttention }
            let preparedIndex = try RelayCryptography.prepare(RemoteSessionPayload(
                kind: .index,
                generatedAt: generatedAt,
                sessionIDs: orderedDetails.map(\.summary.id)
            ))

            let changedFrames: [(RelayPreparedPayload, Bool)] = changed
                .compactMap { partsBySession[$0] }
                .flatMap { $0 } + [(preparedIndex, anyAttention)]
            let fullFrames: [(RelayPreparedPayload, Bool)] = orderedDetails
                .compactMap { partsBySession[$0.summary.id] }
                .flatMap { $0 } + [(preparedIndex, anyAttention)]

            var perDeviceExtras: [DeviceID: [(RelayPreparedPayload, Bool)]] = [:]
            for device in activeDevices where devicesNeedingFullResend.contains(device.id) {
                perDeviceExtras[device.id] = fullFrames
            }
            try await sendFrames(
                changedFrames,
                to: activeDevices.filter { !devicesNeedingFullResend.contains($0.id) },
                perDeviceExtras: perDeviceExtras,
                socket: socket
            )
            devicesNeedingFullResend.subtract(activeDevices.map(\.id))
            sentUnavailable = false
            lastSentDetails = details
            lastError = nil
        } catch {
            lastError = String(describing: error)
            notifyObservers()
        }
    }

    /// Seals and sends one batch per device, reserving and persisting the
    /// channel sequences BEFORE anything hits the wire: a crash mid-publish
    /// leaves a legal gap, never a fatal sequence reuse.
    private func sendFrames(
        _ frames: [(RelayPreparedPayload, Bool)],
        to devices: [RelayDeviceRecord],
        perDeviceExtras: [DeviceID: [(RelayPreparedPayload, Bool)]],
        socket: RelayWebSocketClient
    ) async throws {
        guard var credentials else { return }
        var batches: [(RelayDeviceRecord, [(RelayPreparedPayload, Bool)], UInt64)] = []
        for device in devices where !frames.isEmpty {
            batches.append((device, frames, reserve(&credentials, device: device, count: frames.count)))
        }
        for (deviceID, extras) in perDeviceExtras {
            guard let device = self.devices.first(where: { $0.id == deviceID }), !extras.isEmpty else { continue }
            batches.append((device, extras, reserve(&credentials, device: device, count: extras.count)))
        }
        guard !batches.isEmpty else { return }
        self.credentials = credentials
        try secureStore.save(credentials, account: credentialsAccount)
        for (device, batch, firstSequence) in batches {
            for (offset, item) in batch.enumerated() {
                let frame = try RelayCryptography.seal(
                    item.0,
                    hostID: credentials.hostID,
                    deviceID: device.id,
                    sequence: firstSequence + UInt64(offset),
                    kind: item.1 ? .attention : .data,
                    privateKey: credentials.keyPair.privateKey,
                    peerPublicKey: device.publicKey
                )
                try await socket.send(frame)
            }
        }
    }

    private func reserve(
        _ credentials: inout RelayHostCredentials,
        device: RelayDeviceRecord,
        count: Int
    ) -> UInt64 {
        let channelKey = device.id.rawValue
        let previous = credentials.channelSequences[channelKey] ?? credentials.lastSequence
        let first = previous + 1
        let last = previous + UInt64(count)
        credentials.channelSequences[channelKey] = last
        credentials.lastSequence = max(credentials.lastSequence, last)
        return first
    }

    /// Coalesces daemon changes into one publish batch: the sessions that
    /// changed since the last publish, each as one or more `.session` frames,
    /// closed by an `.index` frame. Each payload is prepared once and then
    /// encrypted per paired device channel.
    private func schedulePublish(from store: MacSessionStore) {
        publishPending = true
        guard publishTask == nil else { return }
        publishTask = Task { [weak self, weak store] in
            guard let self, let store else { return }
            while self.publishPending, !Task.isCancelled {
                self.publishPending = false
                // Full encrypted snapshots retain every Timeline item. A short
                // cadence keeps iPhone monitoring current while coalescing the
                // burst of hook/rollout events produced by one Agent action.
                try? await Task.sleep(for: .seconds(5))
                await self.publishCurrentState(from: store)
            }
            self.publishTask = nil
            if self.publishPending, !Task.isCancelled {
                self.schedulePublish(from: store)
            }
        }
    }

    private static func credential() -> String {
        RelayCryptography.makeKeyPair().privateKey
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum RelayPublishDecision {
    static func shouldSchedule(
        previousRevision: UInt64,
        currentRevision: UInt64,
        wasDaemonAvailable: Bool,
        isDaemonAvailable: Bool
    ) -> Bool {
        previousRevision != currentRevision || wasDaemonAvailable != isDaemonAvailable
    }
}

enum RelayPublishPlan {
    /// The sessions whose relay copy is stale: inserted or byte-different.
    /// Deletions never appear here — the trailing index prunes them.
    /// `previous == nil` means everything must go out again.
    static func changedSessions(
        previous: [SessionID: SessionDetail]?,
        current: [SessionID: SessionDetail]
    ) -> [SessionID] {
        guard let previous else { return Array(current.keys) }
        return current.compactMap { id, detail in
            previous[id] == detail ? nil : id
        }
    }
}
