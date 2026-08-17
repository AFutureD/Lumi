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
    private var lastSentDetails: [SessionDetail]?
    private var sentUnavailable = false
    private var lastObservedStoreRevision: UInt64 = 0
    private var lastObservedDaemonAvailable = false

    private(set) var devices: [RelayDeviceRecord] = []
    private(set) var isConnected = false
    private(set) var lastError: String?
    var onChange: (() -> Void)?

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
        onChange?()
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
        onChange?()
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
        do {
            let previousActiveIDs = Set(devices.filter { $0.revokedAt == nil }.map(\.id))
            let refreshed = try await RelayRESTClient(baseURL: credentials.relayURL).devices(
                hostID: credentials.hostID,
                hostSecret: credentials.hostSecret
            )
            devices = refreshed
            let activeIDs = Set(refreshed.filter { $0.revokedAt == nil }.map(\.id))
            if activeIDs != previousActiveIDs {
                lastSentDetails = nil
                sentUnavailable = false
                if let store { schedulePublish(from: store) }
            }
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        onChange?()
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
            onChange?()
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
                    while !Task.isCancelled { _ = try await socket.next() }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.isConnected = false
                    self?.lastError = String(describing: error)
                    self?.onChange?()
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
        onChange?()
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

    private func publishCurrentState(from store: MacSessionStore) async {
        guard isConnected, credentials != nil, let socket else { return }
        do {
            let activeDevices = devices.filter { $0.revokedAt == nil }
            guard !activeDevices.isEmpty else { return }
            let details: [SessionDetail]
            let payload: RemoteSessionPayload
            if store.health == nil {
                guard !sentUnavailable else { return }
                details = []
                payload = RemoteSessionPayload(kind: .unavailable, message: "Mac daemon unavailable")
                sentUnavailable = true
            } else {
                let wasUnavailable = sentUnavailable
                details = try await store.snapshotDetails()
                guard RelayPublishDecision.shouldSendSnapshot(
                    wasUnavailable: wasUnavailable,
                    previous: lastSentDetails,
                    current: details
                ) else { return }
                payload = RemoteSessionPayload(kind: .snapshot, sessions: details)
                sentUnavailable = false
            }
            guard var credentials else { return }
            for device in activeDevices {
                let channelKey = device.id.rawValue
                let previousSequence = credentials.channelSequences[channelKey] ?? credentials.lastSequence
                let sequence = previousSequence + 1
                credentials.channelSequences[channelKey] = sequence
                credentials.lastSequence = max(credentials.lastSequence, sequence)
                let frame = try RelayCryptography.seal(
                    payload,
                    hostID: credentials.hostID,
                    deviceID: device.id,
                    sequence: sequence,
                    kind: details.contains(where: { $0.summary.needsAttention }) ? .attention : .data,
                    privateKey: credentials.keyPair.privateKey,
                    peerPublicKey: device.publicKey
                )
                try await socket.send(frame)
            }
            self.credentials = credentials
            try secureStore.save(credentials, account: credentialsAccount)
            lastSentDetails = details
            lastError = nil
        } catch {
            lastError = String(describing: error)
            onChange?()
        }
    }

    /// Coalesces daemon changes into one full snapshot operation. The snapshot
    /// contains every session and is then encrypted once per paired device channel.
    private func schedulePublish(from store: MacSessionStore) {
        publishPending = true
        guard publishTask == nil else { return }
        publishTask = Task { [weak self, weak store] in
            guard let self, let store else { return }
            while self.publishPending, !Task.isCancelled {
                self.publishPending = false
                try? await Task.sleep(for: .milliseconds(100))
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

    static func shouldSendSnapshot(
        wasUnavailable: Bool,
        previous: [SessionDetail]?,
        current: [SessionDetail]
    ) -> Bool {
        wasUnavailable || previous != current
    }
}
