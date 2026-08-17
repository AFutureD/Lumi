import AgentStatusRemote
import AgentStatusTransport
import Foundation
import Testing

@Test func pairedKeysRoundTripEncryptedSnapshot() throws {
    let host = RelayCryptography.makeKeyPair()
    let device = RelayCryptography.makeKeyPair()
    let hostID = HostID("host-test-000001")
    let deviceID = DeviceID("device-test-0001")
    let payload = RemoteSessionPayload(
        kind: .snapshot,
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        message: "ready"
    )

    let frame = try RelayCryptography.seal(
        payload,
        hostID: hostID,
        deviceID: deviceID,
        sequence: 7,
        privateKey: host.privateKey,
        peerPublicKey: device.publicKey
    )
    let opened = try RelayCryptography.open(
        frame,
        privateKey: device.privateKey,
        peerPublicKey: host.publicKey
    )

    #expect(opened == payload)
    #expect(frame.sequence == 7)
    #expect(frame.ciphertext != nil)
}

@Test func wrongDeviceCannotDecryptPayload() throws {
    let host = RelayCryptography.makeKeyPair()
    let device = RelayCryptography.makeKeyPair()
    let otherDevice = RelayCryptography.makeKeyPair()
    let frame = try RelayCryptography.seal(
        RemoteSessionPayload(kind: .snapshot),
        hostID: HostID("host-test-000001"),
        deviceID: DeviceID("device-test-0001"),
        sequence: 1,
        privateKey: host.privateKey,
        peerPublicKey: device.publicKey
    )

    #expect(throws: (any Error).self) {
        try RelayCryptography.open(
            frame,
            privateKey: otherDevice.privateKey,
            peerPublicKey: host.publicKey
        )
    }
}

@Test func credentialCollectionKeepsMacChannelsAndSequencesIndependent() throws {
    let first = channelCredentials(host: "host-first-0001", sequence: 7)
    let second = channelCredentials(host: "host-second-0002", sequence: 2)
    var collection = RelayDeviceCredentialCollection()
    collection.upsert(first)
    collection.upsert(second)

    #expect(collection.channels.map(\.hostID) == [first.hostID, second.hostID])
    #expect(collection.channels.map(\.lastAcknowledgedSequence) == [7, 2])
    let restored = try JSONDecoder().decode(
        RelayDeviceCredentialCollection.self,
        from: JSONEncoder().encode(collection)
    )
    #expect(restored == collection)

    collection.remove(hostID: first.hostID)
    #expect(collection.channels == [second])
}

private func channelCredentials(host: String, sequence: UInt64) -> RelayDeviceCredentials {
    RelayDeviceCredentials(
        relayURL: URL(string: "https://relay.example.com")!,
        hostID: HostID(host),
        hostName: host,
        deviceID: DeviceID("device-\(host)"),
        deviceToken: "token-\(host)",
        keyPair: RelayCryptography.makeKeyPair(),
        hostPublicKey: RelayCryptography.makeKeyPair().publicKey,
        lastAcknowledgedSequence: sequence
    )
}
