import AgentStatusRemote
import AgentStatusTransport
import Foundation
import Testing

@Test func pairedKeysRoundTripEncryptedSessionPayload() throws {
    let host = RelayCryptography.makeKeyPair()
    let device = RelayCryptography.makeKeyPair()
    let hostID = HostID("host-test-000001")
    let deviceID = DeviceID("device-test-0001")
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let payload = RemoteSessionPayload(
        kind: .session,
        generatedAt: date,
        session: SessionDetail(
            summary: SessionSummary(
                id: SessionID("session-1"), agent: .codex, title: "Session 1",
                lifecycle: .running, phase: .thinking,
                startedAt: date, updatedAt: date, lastActivityAt: date
            ),
            timeline: [TimelineItem(
                id: TimelineItemID("item-1"), sessionID: SessionID("session-1"),
                occurredAt: date,
                payload: .message(MessageTimelinePayload(role: .user, text: "hello"))
            )]
        ),
        part: 0
    )

    let frame = try RelayCryptography.seal(
        RelayCryptography.prepare(payload),
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

@Test func preparedPayloadDeflatesRepetitiveTimelines() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let items = (0..<200).map { index in
        TimelineItem(
            id: TimelineItemID("item-\(index)"), sessionID: SessionID("big"),
            occurredAt: date,
            payload: .message(MessageTimelinePayload(
                role: .assistant,
                text: String(repeating: "swift build output line \(index) ", count: 40)
            ))
        )
    }
    let payload = RemoteSessionPayload(
        kind: .session,
        generatedAt: date,
        session: SessionDetail(
            summary: SessionSummary(
                id: SessionID("big"), agent: .claude, title: "Big",
                lifecycle: .running, phase: .thinking,
                startedAt: date, updatedAt: date, lastActivityAt: date
            ),
            timeline: items
        ),
        part: 0
    )
    let encodedCount = try TransportCoding.makeEncoder().encode(payload).count
    let prepared = try RelayCryptography.prepare(payload)
    #expect(prepared.byteCount < encodedCount / 2)

    let host = RelayCryptography.makeKeyPair()
    let device = RelayCryptography.makeKeyPair()
    let frame = try RelayCryptography.seal(
        prepared,
        hostID: HostID("host-test-000001"),
        deviceID: DeviceID("device-test-0001"),
        sequence: 1,
        privateKey: host.privateKey,
        peerPublicKey: device.publicKey
    )
    let opened = try RelayCryptography.open(
        frame,
        privateKey: device.privateKey,
        peerPublicKey: host.publicKey
    )
    #expect(opened == payload)
}

@Test func wrongDeviceCannotDecryptPayload() throws {
    let host = RelayCryptography.makeKeyPair()
    let device = RelayCryptography.makeKeyPair()
    let otherDevice = RelayCryptography.makeKeyPair()
    let frame = try RelayCryptography.seal(
        RemoteSessionPayload(kind: .index, sessionIDs: []),
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
