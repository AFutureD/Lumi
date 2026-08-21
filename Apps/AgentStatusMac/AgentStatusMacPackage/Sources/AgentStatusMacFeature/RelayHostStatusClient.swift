import AgentStatusIPCClient
import AgentStatusTransport
import Foundation

/// The Mac app's read-mostly view of the daemon's Relay host: connection
/// state, last error and the paired iPhones, plus the three actions the
/// Pairing screen needs (generate a code, refresh, revoke). Everything goes
/// over daemon IPC — the app holds no Relay credentials and no socket.
@MainActor
final class RelayHostStatusClient {
    private let store: MacSessionStore
    private let client: any MacDaemonClient
    private let socketPath: String
    private let visibleInterval: Duration
    private let hiddenInterval: Duration

    private(set) var isConnected = false
    private(set) var lastError: String?
    private(set) var devices: [PairedDevice] = []
    private var observers: [UUID: () -> Void] = [:]
    private var pollTask: Task<Void, Never>?
    private var pairingVisible = false
    private var lastSeenRelayConnected: Bool?
    private var stopped = false

    init(
        store: MacSessionStore,
        client: any MacDaemonClient = DaemonIPCClient(),
        socketPath: String = DaemonEndpoint.defaultSocketPath(),
        visibleInterval: Duration = .seconds(5),
        hiddenInterval: Duration = .seconds(30)
    ) {
        self.store = store
        self.client = client
        self.socketPath = socketPath
        self.visibleInterval = visibleInterval
        self.hiddenInterval = hiddenInterval
        store.observe { [weak self] in self?.storeChanged() }
        restartPolling()
    }

    /// Multiple views (Pairing, sidebar, toolbar) observe connection and device changes.
    @discardableResult
    func observe(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    /// The Pairing screen polls faster while it is on screen.
    func setPairingViewVisible(_ visible: Bool) {
        guard pairingVisible != visible else { return }
        pairingVisible = visible
        restartPolling()
        if visible { Task { await refreshDevices() } }
    }

    func refreshDevices() async {
        await perform(IPCRequest(operation: .relayRefreshDevices))
    }

    func createPairingOffer() async throws -> PairingOffer {
        let response = try await request(IPCRequest(operation: .relayCreatePairingOffer))
        apply(response)
        if let offer = response.pairingOffer { return offer }
        throw response.failure ?? IPCFailure(code: "relay_unavailable", message: "The daemon has no Relay connection.", retryable: true)
    }

    func revoke(deviceID: DeviceID) async {
        await perform(IPCRequest(operation: .relayRevokeDevice, deviceID: deviceID))
    }

    func stop() {
        stopped = true
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Private

    private func storeChanged() {
        let relayConnected = store.health?.relayConnected
        if relayConnected != lastSeenRelayConnected {
            lastSeenRelayConnected = relayConnected
            Task { await refreshStatus() }
        }
        if store.health == nil, isConnected {
            isConnected = false
            lastError = store.connectionError ?? "Agent Status daemon is not reachable."
            notifyObservers()
        }
    }

    private func restartPolling() {
        pollTask?.cancel()
        guard !stopped else { return }
        let interval = pairingVisible ? visibleInterval : hiddenInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func refreshStatus() async {
        await perform(IPCRequest(operation: .relayStatus))
    }

    private func perform(_ request: IPCRequest) async {
        do {
            apply(try await self.request(request))
        } catch {
            isConnected = false
            lastError = String(describing: error)
            notifyObservers()
        }
    }

    private func apply(_ response: IPCResponse) {
        if let relay = response.relay {
            isConnected = relay.connected
            lastError = relay.lastError
            devices = relay.devices
        } else if let failure = response.failure {
            // A failed action (revoke, pairing offer) does not mean the
            // Relay connection dropped; only the daemon saying so does.
            if failure.code == "relay_unavailable" { isConnected = false }
            lastError = failure.message
        }
        notifyObservers()
    }

    private func request(_ request: IPCRequest) async throws -> IPCResponse {
        let client = client
        let socketPath = socketPath
        return try await Task.detached {
            try client.request(request, socketPath: socketPath, timeoutSeconds: 15)
        }.value
    }

    private func notifyObservers() {
        observers.values.forEach { $0() }
    }
}
