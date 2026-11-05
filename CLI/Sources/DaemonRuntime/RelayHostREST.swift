import Remote
import Transport
import Foundation

/// The Relay's host-side REST surface as `RelayHostService` uses it. Tests
/// substitute an in-memory directory of pairing sessions and paired devices.
public protocol RelayHostREST: Sendable {
    func registerHost(hostID: HostID, hostSecret: String) async throws
    func createPairingSession(
        hostID: HostID,
        commit: Data,
        hostPublicKey: Data,
        hostName: String?,
        expiresAt: Date,
        hostSecret: String
    ) async throws -> RelayPairingSessionCreated
    func revealPairing(hostID: HostID, sessionID: String, hostNonce: Data, hostSecret: String) async throws
    func decidePairing(hostID: HostID, sessionID: String, approved: Bool, hostSecret: String) async throws
    func cancelPairing(hostID: HostID, sessionID: String, hostSecret: String) async throws
    func devices(hostID: HostID, hostSecret: String) async throws -> [PairedDevice]
    func revoke(hostID: HostID, deviceID: DeviceID, hostSecret: String) async throws
    func removeDevice(hostID: HostID, deviceID: DeviceID, hostSecret: String) async throws
    func sendPushNotification(
        hostID: HostID,
        notification: RelayPushNotification,
        hostSecret: String
    ) async throws -> [RelayPushResult]
}

public struct LiveRelayHostREST: RelayHostREST {
    private let client: RelayRESTClient

    public init(baseURL: URL) {
        client = RelayRESTClient(baseURL: baseURL)
    }

    public func registerHost(hostID: HostID, hostSecret: String) async throws {
        try await client.registerHost(hostID: hostID, hostSecret: hostSecret)
    }

    public func createPairingSession(
        hostID: HostID,
        commit: Data,
        hostPublicKey: Data,
        hostName: String?,
        expiresAt: Date,
        hostSecret: String
    ) async throws -> RelayPairingSessionCreated {
        try await client.createPairingSession(
            hostID: hostID, commit: commit, hostPublicKey: hostPublicKey,
            hostName: hostName, expiresAt: expiresAt, hostSecret: hostSecret
        )
    }

    public func revealPairing(hostID: HostID, sessionID: String, hostNonce: Data, hostSecret: String) async throws {
        try await client.revealPairing(hostID: hostID, sessionID: sessionID, hostNonce: hostNonce, hostSecret: hostSecret)
    }

    public func decidePairing(hostID: HostID, sessionID: String, approved: Bool, hostSecret: String) async throws {
        try await client.decidePairing(hostID: hostID, sessionID: sessionID, approved: approved, hostSecret: hostSecret)
    }

    public func cancelPairing(hostID: HostID, sessionID: String, hostSecret: String) async throws {
        try await client.cancelPairing(hostID: hostID, sessionID: sessionID, bearerToken: hostSecret)
    }

    public func devices(hostID: HostID, hostSecret: String) async throws -> [PairedDevice] {
        try await client.devices(hostID: hostID, hostSecret: hostSecret).map {
            PairedDevice(id: $0.id, name: $0.name, publicKey: $0.publicKey, pairedAt: $0.pairedAt, revokedAt: $0.revokedAt)
        }
    }

    public func revoke(hostID: HostID, deviceID: DeviceID, hostSecret: String) async throws {
        try await client.revoke(hostID: hostID, deviceID: deviceID, hostSecret: hostSecret)
    }

    public func removeDevice(hostID: HostID, deviceID: DeviceID, hostSecret: String) async throws {
        try await client.removeDevice(hostID: hostID, deviceID: deviceID, hostSecret: hostSecret)
    }

    public func sendPushNotification(
        hostID: HostID,
        notification: RelayPushNotification,
        hostSecret: String
    ) async throws -> [RelayPushResult] {
        try await client.sendPushNotification(hostID: hostID, notification: notification, hostSecret: hostSecret)
    }
}

/// Tests: a directory of pairing sessions and paired devices the service can
/// drive and list. `submit` plays the iPhone (what the Relay would do before
/// pushing `pairing_device` to the host); an approved decision lists it.
/// `refuseReveals` / `refuseRevocations` play a Relay that takes a request
/// and answers it with an error; `holdDecisions` one that sits on a decision
/// until the test lets it answer.
public actor InMemoryRelayHostREST: RelayHostREST {
    public struct Session: Hashable, Sendable {
        public let sessionID: String
        public let code: String
        public let commit: Data
        public let hostPublicKey: Data
        public let hostName: String?
        public let expiresAt: Date
        public var state: PairingSessionState
        public var hostNonce: Data?
        public var device: PairedDevice?
    }

    public private(set) var registered: [HostID: String] = [:]
    public private(set) var sessions: [String: Session] = [:]
    /// Creation order, oldest first.
    public private(set) var sessionOrder: [String] = []
    public private(set) var pairedDevices: [PairedDevice]

    public init(devices: [PairedDevice] = []) {
        pairedDevices = devices
    }

    /// Lists a device as if an earlier pairing approved it.
    public func pair(_ device: PairedDevice) {
        pairedDevices.removeAll { $0.id == device.id }
        pairedDevices.append(device)
    }

    /// The iPhone submitted itself to `sessionID` (the Relay would now push
    /// `pairing_device` to the host socket — tests do that through the link).
    public func submit(sessionID: String, device: PairedDevice) {
        sessions[sessionID]?.state = .submitted
        sessions[sessionID]?.device = device
    }

    public var latestSession: Session? {
        sessionOrder.last.flatMap { sessions[$0] }
    }

    /// Every `cancelPairing` the daemon sent, in order — a session the Relay
    /// already ended (expired, decided) must not get one.
    public private(set) var cancelRequests: [String] = []

    private var refusesReveals = false
    private var refusesRevocations = false
    /// Sessions whose nonce reached the Relay, answered or refused.
    public private(set) var disclosedNonces: [String: Data] = [:]
    /// Every `revoke` the daemon sent, in order, answered or refused.
    public private(set) var revokeRequests: [DeviceID] = []

    /// The Relay reads each reveal's nonce and then answers with an error.
    public func refuseReveals(_ refuse: Bool) {
        refusesReveals = refuse
    }

    /// The Relay answers every revoke with an error and keeps the device listed as it was.
    public func refuseRevocations(_ refuse: Bool) {
        refusesRevocations = refuse
    }

    private var holdsDecisions = false
    private var heldDecision: CheckedContinuation<Bool, Never>?

    /// The Relay takes each decision and does not answer until `releaseDecision`.
    public func holdDecisions(_ hold: Bool) {
        holdsDecisions = hold
    }

    /// A decision is waiting for `releaseDecision`.
    public var isHoldingDecision: Bool { heldDecision != nil }

    /// Lets the held decision go on, or answers it with an error.
    public func releaseDecision(refusing: Bool) {
        heldDecision?.resume(returning: refusing)
        heldDecision = nil
    }

    public func registerHost(hostID: HostID, hostSecret: String) async throws {
        registered[hostID] = hostSecret
    }

    public func createPairingSession(
        hostID: HostID,
        commit: Data,
        hostPublicKey: Data,
        hostName: String?,
        expiresAt: Date,
        hostSecret: String
    ) async throws -> RelayPairingSessionCreated {
        // One live session per host: the new one supersedes.
        for id in sessionOrder where sessions[id]?.state.isTerminal == false {
            sessions[id]?.state = .cancelled
        }
        let sessionID = "session-\(UUID().uuidString.lowercased())"
        let code = String((0..<PairingCode.length).map { _ in PairingCode.alphabet.randomElement()! })
        sessions[sessionID] = Session(
            sessionID: sessionID, code: code, commit: commit, hostPublicKey: hostPublicKey,
            hostName: hostName, expiresAt: expiresAt, state: .offered
        )
        sessionOrder.append(sessionID)
        return RelayPairingSessionCreated(sessionID: sessionID, code: code, expiresAt: expiresAt)
    }

    public func revealPairing(hostID: HostID, sessionID: String, hostNonce: Data, hostSecret: String) async throws {
        disclosedNonces[sessionID] = hostNonce
        if refusesReveals { throw RelayClientError.server(status: 503, message: "reveal refused") }
        guard var session = sessions[sessionID], session.state == .submitted else {
            throw RelayClientError.relay(status: 409, code: "invalid_state")
        }
        session.state = .revealed
        session.hostNonce = hostNonce
        sessions[sessionID] = session
    }

    public func decidePairing(hostID: HostID, sessionID: String, approved: Bool, hostSecret: String) async throws {
        if holdsDecisions {
            let refused = await withCheckedContinuation { heldDecision = $0 }
            if refused { throw RelayClientError.server(status: 503, message: "decision refused") }
        }
        guard var session = sessions[sessionID] else { throw RelayClientError.relay(status: 404, code: "not_found") }
        if approved {
            guard session.state == .revealed, let device = session.device else {
                throw RelayClientError.relay(status: 409, code: "invalid_state")
            }
            session.state = .approved
            pair(device)
        } else {
            guard session.state == .submitted || session.state == .revealed else {
                throw RelayClientError.relay(status: 409, code: "invalid_state")
            }
            session.state = .rejected
        }
        sessions[sessionID] = session
    }

    public func cancelPairing(hostID: HostID, sessionID: String, hostSecret: String) async throws {
        cancelRequests.append(sessionID)
        guard var session = sessions[sessionID] else { return }
        if !session.state.isTerminal { session.state = .cancelled }
        sessions[sessionID] = session
    }

    public func devices(hostID: HostID, hostSecret: String) async throws -> [PairedDevice] {
        pairedDevices
    }

    public func revoke(hostID: HostID, deviceID: DeviceID, hostSecret: String) async throws {
        revokeRequests.append(deviceID)
        if refusesRevocations { throw RelayClientError.server(status: 503, message: "revoke refused") }
        pairedDevices = pairedDevices.map { device in
            guard device.id == deviceID else { return device }
            return PairedDevice(id: device.id, name: device.name, publicKey: device.publicKey, pairedAt: device.pairedAt, revokedAt: Date())
        }
    }

    public func removeDevice(hostID: HostID, deviceID: DeviceID, hostSecret: String) async throws {
        pairedDevices.removeAll { $0.id == deviceID }
    }

    /// Notifications the service asked the Relay to forward, in send order.
    public private(set) var sentNotifications: [RelayPushNotification] = []

    public func sendPushNotification(
        hostID: HostID,
        notification: RelayPushNotification,
        hostSecret: String
    ) async throws -> [RelayPushResult] {
        sentNotifications.append(notification)
        // Mirrors the Relay: explicit targets are answered one by one
        // (unknown or revoked rows report `revoked`); no targets means every
        // non-revoked device.
        if let targets = notification.deviceIDs {
            return targets.map { id in
                guard let device = pairedDevices.first(where: { $0.id == id }), device.revokedAt == nil else {
                    return RelayPushResult(deviceID: id, status: .revoked)
                }
                return RelayPushResult(deviceID: device.id, status: .sent)
            }
        }
        return pairedDevices.filter { $0.revokedAt == nil }.map {
            RelayPushResult(deviceID: $0.id, status: .sent)
        }
    }
}
