import AgentStatusTransport
import Foundation
import Testing
@testable import AgentStatusMacFeature

/// A scripted daemon: answers `relay_*` operations from a queue of responses
/// and records what it was asked.
private final class ScriptedRelayDaemon: MacDaemonClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [IPCResponse]
    private(set) var requests: [IPCRequest] = []

    init(responses: [IPCResponse]) {
        self.responses = responses
    }

    func request(_ request: IPCRequest, socketPath: String, timeoutSeconds: Int64) throws -> IPCResponse {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
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
}

@Test @MainActor func relayStatusClientSurfacesPairingOffersAndFailures() async throws {
    let offer = PairingOffer(
        relayURL: URL(string: "https://relay.example.test")!,
        hostID: HostID("host-1"),
        challenge: "challenge-000000000000000000000000",
        hostPublicKey: Data([2]),
        expiresAt: Date(timeIntervalSince1970: 100)
    )
    let daemon = ScriptedRelayDaemon(responses: [
        IPCResponse(status: .ok, relay: RelayHostStatus(connected: true)),
        IPCResponse(status: .ok, relay: RelayHostStatus(connected: true), pairingOffer: offer),
        IPCResponse(status: .error, failure: IPCFailure(code: "relay_unavailable", message: "The daemon runs without a Relay connection.", retryable: false)),
    ])
    let store = MacSessionStore(socketPath: "/tmp/none.sock", cachePath: NSTemporaryDirectory() + "/\(UUID().uuidString).sqlite3", client: daemon)
    let client = RelayHostStatusClient(store: store, client: daemon, socketPath: "/tmp/none.sock", visibleInterval: .seconds(60), hiddenInterval: .seconds(60))
    defer { client.stop() }
    await waitUntil { client.isConnected }

    #expect(try await client.createPairingOffer() == offer)
    await #expect(throws: (any Error).self) { try await client.createPairingOffer() }
    #expect(!client.isConnected)
    #expect(client.lastError == "The daemon runs without a Relay connection.")
}
