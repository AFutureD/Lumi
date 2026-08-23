import Transport
import AppKit
import Foundation
import Testing
@testable import MacFeature

/// A scripted daemon: answers `relay_*` operations from a queue of responses
/// and records what it was asked.
private final class ScriptedRelayDaemon: MacDaemonClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [IPCResponse]
    private let handler: ((IPCRequest, Int) -> IPCResponse?)?
    private(set) var requests: [IPCRequest] = []

    /// `responses` are dequeued in order (the last one repeats); a `handler`
    /// answers by operation instead — it gets how many times that operation
    /// was asked before — and falls back to the queue when it returns nil.
    init(responses: [IPCResponse], handler: ((IPCRequest, Int) -> IPCResponse?)? = nil) {
        self.responses = responses
        self.handler = handler
    }

    func request(_ request: IPCRequest, socketPath: String, timeoutSeconds: Int64) throws -> IPCResponse {
        lock.lock()
        defer { lock.unlock() }
        let earlier = requests.count { $0.operation == request.operation }
        requests.append(request)
        if let answer = handler?(request, earlier) { return answer }
        if responses.count > 1 { return responses.removeFirst() }
        return responses.first ?? IPCResponse(status: .error, failure: IPCFailure(code: "down", message: "daemon down", retryable: true))
    }

    var operations: [IPCOperation] {
        lock.lock()
        defer { lock.unlock() }
        return requests.map(\.operation)
    }
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@Test @MainActor func relayStatusClientMirrorsTheDaemonAndRefreshesOnDemand() async throws {
    let device = PairedDevice(id: DeviceID("device-1"), name: "iPhone", publicKey: Data([1]), pairedAt: Date(timeIntervalSince1970: 1))
    let connected = RelayHostStatus(connected: true, hostID: HostID("host-1"), devices: [device])
    let daemon = ScriptedRelayDaemon(responses: [IPCResponse(status: .ok, relay: connected)])
    let store = MacSessionStore(socketPath: "/tmp/none.sock", cachePath: NSTemporaryDirectory() + "/\(UUID().uuidString).sqlite3", client: daemon)
    let client = RelayHostStatusClient(store: store, client: daemon, socketPath: "/tmp/none.sock", visibleInterval: .seconds(60), hiddenInterval: .seconds(60))
    defer { client.stop() }

    await waitUntil { client.isConnected }
    #expect(client.devices == [device])
    #expect(client.lastError == nil)
    #expect(daemon.operations.first == .relayStatus)

    var notified = 0
    client.observe { notified += 1 }
    await client.refreshDevices()
    #expect(daemon.operations.last == .relayRefreshDevices)
    #expect(notified == 1)

    await client.revoke(deviceID: device.id)
    #expect(daemon.requests.last?.operation == .relayRevokeDevice)
    #expect(daemon.requests.last?.deviceID == device.id)

    await client.remove(deviceID: device.id)
    #expect(daemon.requests.last?.operation == .relayRemoveDevice)
    #expect(daemon.requests.last?.deviceID == device.id)
}

@Test @MainActor func relayStatusClientDrivesPairingSessionsAndSurfacesFailures() async throws {
    let relayURL = URL(string: "https://relay.example.test")!
    let started = RelayPairingSession(sessionID: "s1", code: "7KF3QP", relayURL: relayURL, expiresAt: Date(timeIntervalSince1970: 100))
    let pending = RelayPairingSession(
        sessionID: "s1", code: "7KF3QP", relayURL: relayURL, expiresAt: Date(timeIntervalSince1970: 100),
        pending: RelayPairingPending(deviceID: DeviceID("device-1"), deviceName: "iPhone", sas: "482913", receivedAt: Date(timeIntervalSince1970: 50))
    )
    let approved = RelayPairingSession(
        sessionID: "s1", code: "7KF3QP", relayURL: relayURL, expiresAt: Date(timeIntervalSince1970: 100),
        outcome: RelayPairingOutcome(kind: .approved, deviceName: "iPhone", at: Date(timeIntervalSince1970: 60))
    )
    let connected = RelayHostStatus(connected: true)
    let daemon = ScriptedRelayDaemon(responses: [IPCResponse(status: .ok, relay: connected)]) { request, earlier in
        switch request.operation {
        case .relayPairingStart:
            return earlier == 0
                ? IPCResponse(status: .ok, relay: connected, pairing: started)
                : IPCResponse(status: .error, failure: IPCFailure(code: "relay_unavailable", message: "The daemon runs without a Relay connection.", retryable: false))
        case .relayPairingState:
            return IPCResponse(status: .ok, relay: connected, pairing: pending)
        case .relayPairingDecide:
            return earlier == 0
                ? IPCResponse(status: .ok, relay: connected, pairing: approved)
                : IPCResponse(status: .error, failure: IPCFailure(code: "no_pending_device", message: "No iPhone is waiting on the pairing session.", retryable: false))
        default:
            return nil
        }
    }
    let store = MacSessionStore(socketPath: "/tmp/none.sock", cachePath: NSTemporaryDirectory() + "/\(UUID().uuidString).sqlite3", client: daemon)
    let client = RelayHostStatusClient(store: store, client: daemon, socketPath: "/tmp/none.sock", visibleInterval: .seconds(60), hiddenInterval: .seconds(60))
    defer { client.stop() }
    await waitUntil { client.isConnected }

    #expect(try await client.startPairing() == started)
    #expect(daemon.operations.last == .relayPairingStart)
    #expect(client.pairing == started)

    // The page polls `relay_pairing_state` while visible; the pending iPhone shows up.
    client.setPairingViewVisible(true)
    await waitUntil { client.pairing?.pending != nil }
    #expect(daemon.operations.contains(.relayPairingState))
    #expect(client.pairing?.pending?.sas == "482913")

    #expect(try await client.decidePairing(approved: true) == approved)
    #expect(daemon.requests.last?.operation == .relayPairingDecide)
    #expect(daemon.requests.last?.approved == true)

    // A decision with nobody waiting fails without dropping the connection.
    await #expect(throws: (any Error).self) { try await client.decidePairing(approved: false) }
    #expect(client.isConnected)
    #expect(client.lastError == "No iPhone is waiting on the pairing session.")
    // The daemon saying it has no Relay does drop it.
    await #expect(throws: (any Error).self) { try await client.startPairing() }
    #expect(!client.isConnected)
    #expect(client.lastError == "The daemon runs without a Relay connection.")
}

/// Regression: `configureUI` once activated a constraint against the pending
/// card before it had a superview; AppKit swallowed the thrown exception and
/// the whole page came up blank. Building the view must produce the scroll
/// hierarchy with both columns.
@Test @MainActor func pairingScreenBuildsItsContentHierarchy() async throws {
    let daemon = ScriptedRelayDaemon(responses: [IPCResponse(status: .ok, relay: RelayHostStatus(connected: true))])
    let store = MacSessionStore(socketPath: "/tmp/none.sock", cachePath: NSTemporaryDirectory() + "/\(UUID().uuidString).sqlite3", client: daemon)
    let client = RelayHostStatusClient(store: store, client: daemon, socketPath: "/tmp/none.sock", visibleInterval: .seconds(60), hiddenInterval: .seconds(60))
    defer { client.stop() }

    let controller = PairingViewController(relayHost: client)
    let view = controller.view // loadView → configureUI
    let scroll = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
    let document = try #require(scroll.documentView)
    let stacks = document.subviews.compactMap { $0 as? NSStackView }
    #expect(!stacks.isEmpty)
    // Both columns made it in: the code card column and the devices column.
    #expect(stacks.first?.arrangedSubviews.count == 2)
}
