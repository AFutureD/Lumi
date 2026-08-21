import AgentStatusRemote
import AgentStatusTransport
import Foundation

/// The Relay's host-side REST surface as `RelayHostService` uses it. Tests
/// substitute an in-memory directory of paired devices.
public protocol RelayHostREST: Sendable {
    func registerHost(hostID: HostID, hostSecret: String) async throws
    func createPairingOffer(_ offer: PairingOffer, hostSecret: String) async throws
    func devices(hostID: HostID, hostSecret: String) async throws -> [PairedDevice]
    func revoke(hostID: HostID, deviceID: DeviceID, hostSecret: String) async throws
}

public struct LiveRelayHostREST: RelayHostREST {
    private let client: RelayRESTClient

    public init(baseURL: URL) {
        client = RelayRESTClient(baseURL: baseURL)
    }

    public func registerHost(hostID: HostID, hostSecret: String) async throws {
        try await client.registerHost(hostID: hostID, hostSecret: hostSecret)
    }

    public func createPairingOffer(_ offer: PairingOffer, hostSecret: String) async throws {
        try await client.createPairingOffer(offer, hostSecret: hostSecret)
    }

    public func devices(hostID: HostID, hostSecret: String) async throws -> [PairedDevice] {
        try await client.devices(hostID: hostID, hostSecret: hostSecret).map {
            PairedDevice(id: $0.id, name: $0.name, publicKey: $0.publicKey, pairedAt: $0.pairedAt, revokedAt: $0.revokedAt)
        }
    }

    public func revoke(hostID: HostID, deviceID: DeviceID, hostSecret: String) async throws {
        try await client.revoke(hostID: hostID, deviceID: deviceID, hostSecret: hostSecret)
    }
}

/// Tests: a directory of paired devices the service can list and revoke.
public actor InMemoryRelayHostREST: RelayHostREST {
    public private(set) var registered: [HostID: String] = [:]
    public private(set) var offers: [PairingOffer] = []
    public private(set) var pairedDevices: [PairedDevice]

    public init(devices: [PairedDevice] = []) {
        pairedDevices = devices
    }

    public func pair(_ device: PairedDevice) {
        pairedDevices.removeAll { $0.id == device.id }
        pairedDevices.append(device)
    }

    public func registerHost(hostID: HostID, hostSecret: String) async throws {
        registered[hostID] = hostSecret
    }

    public func createPairingOffer(_ offer: PairingOffer, hostSecret: String) async throws {
        offers.append(offer)
    }

    public func devices(hostID: HostID, hostSecret: String) async throws -> [PairedDevice] {
        pairedDevices
    }

    public func revoke(hostID: HostID, deviceID: DeviceID, hostSecret: String) async throws {
        pairedDevices = pairedDevices.map { device in
            guard device.id == deviceID else { return device }
            return PairedDevice(id: device.id, name: device.name, publicKey: device.publicKey, pairedAt: device.pairedAt, revokedAt: Date())
        }
    }
}
