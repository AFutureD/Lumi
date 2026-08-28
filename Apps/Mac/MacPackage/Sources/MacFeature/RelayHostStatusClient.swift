import IPCClient
import Diagnostics
import Logging
import Transport
import Foundation

private let log = Logger(label: "relay")
private let pairingLog = Logger(label: "pairing")

/// The Mac app's read-mostly view of the daemon's Relay host: connection
/// state, last error, the paired iPhones and the live pairing session, plus
/// the actions the Pairing screen needs (start a code, Match / Don't match,
/// cancel, refresh, revoke). Everything goes over daemon IPC — the app holds
/// no Relay credentials and no socket.
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
    /// The daemon's pairing session (code, pending iPhone, outcome, or an
    /// expired code the daemon keeps until the page asks for another);
    /// `nil` when none. Refreshed every second while the Pairing page is up.
    private(set) var pairing: RelayPairingSession?
    private var observers: [UUID: () -> Void] = [:]
    private var pollTask: Task<Void, Never>?
    private var pairingVisible = false
    private var lastSeenRelayConnected: Bool?
    private var stopped = false

    init(
        store: MacSessionStore,
        client: any MacDaemonClient = DaemonIPCClient(),
        socketPath: String = DaemonEndpoint.defaultSocketPath(),
        visibleInterval: Duration = .seconds(1),
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

    /// A fresh code (any earlier one is cancelled at the Relay).
    func startPairing() async throws -> RelayPairingSession {
        let response = try await request(IPCRequest(operation: .relayPairingStart))
        apply(response, pairingAuthoritative: true)
        if let pairing = response.pairing {
            pairingLog.info("pairing_page_started", metadata: .fields(["expires_at": pairing.expiresAt]))
            return pairing
        }
        let failure = response.failure ?? IPCFailure(code: "relay_unavailable", message: "The daemon has no Relay connection.", retryable: true)
        pairingLog.warning("pairing_page_start_failed", metadata: .fields(["code": failure.code, "message": failure.message]))
        throw failure
    }

    /// Match (`true`) / Don't match (`false`) for the iPhone on the live session.
    func decidePairing(approved: Bool) async throws -> RelayPairingSession {
        let response = try await request(IPCRequest(operation: .relayPairingDecide, approved: approved))
        apply(response, pairingAuthoritative: true)
        if let pairing = response.pairing {
            pairingLog.info("pairing_page_decided", metadata: .fields(["approved": approved, "outcome": pairing.outcome?.kind.rawValue]))
            return pairing
        }
        let failure = response.failure ?? IPCFailure(code: "no_pending_device", message: "No iPhone is waiting on the pairing session.", retryable: false)
        pairingLog.warning("pairing_page_decision_failed", metadata: .fields(["approved": approved, "code": failure.code]))
        throw failure
    }

    /// Leaving the page: the code stops being claimable.
    func cancelPairing() async {
        await perform(IPCRequest(operation: .relayPairingCancel))
        pairing = nil
        notifyObservers()
    }

    func revoke(deviceID: DeviceID) async {
        await perform(IPCRequest(operation: .relayRevokeDevice, deviceID: deviceID))
    }

    /// Deletes a revoked iPhone's record (it can pair again with a new code).
    func remove(deviceID: DeviceID) async {
        await perform(IPCRequest(operation: .relayRemoveDevice, deviceID: deviceID))
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
            lastError = store.connectionError ?? "Lumen is not running."
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

    /// Off the Pairing page: connection + devices. On it: the same plus the
    /// live pairing session, every second.
    private func refreshStatus() async {
        await perform(IPCRequest(operation: pairingVisible ? .relayPairingState : .relayStatus))
    }

    private func perform(_ request: IPCRequest) async {
        do {
            apply(try await self.request(request), pairingAuthoritative: request.operation == .relayPairingState)
        } catch {
            if isConnected {
                log.warning("relay_status_unavailable", metadata: .fields(["op": request.operation.rawValue, "error": error]))
            }
            isConnected = false
            lastError = String(describing: error)
            notifyObservers()
        }
    }

    /// `pairingAuthoritative`: the operation speaks for the live pairing
    /// session (start / state / decide), so a missing `pairing` means "none";
    /// status, refresh and revoke say nothing about it.
    private func apply(_ response: IPCResponse, pairingAuthoritative: Bool) {
        if let relay = response.relay {
            if relay.connected != isConnected {
                log.info(relay.connected ? "relay_reported_connected" : "relay_reported_disconnected", metadata: .fields([
                    "devices": relay.devices.count,
                    "last_error": relay.lastError,
                ]))
            }
            isConnected = relay.connected
            lastError = relay.lastError
            devices = relay.devices
            if pairingAuthoritative { pairing = response.pairing }
        } else if let failure = response.failure {
            // A failed action (revoke, decision) does not mean the Relay
            // connection dropped; only the daemon saying so does.
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
