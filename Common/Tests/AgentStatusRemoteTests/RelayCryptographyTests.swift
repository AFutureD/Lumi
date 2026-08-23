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
        kind: .sessionFull,
        generatedAt: date,
        requestID: RequestID("req-1"),
        part: 0,
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
        )
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
        kind: .sessionFull,
        generatedAt: date,
        requestID: RequestID("req-1"),
        part: 0,
        session: SessionDetail(
            summary: SessionSummary(
                id: SessionID("big"), agent: .claude, title: "Big",
                lifecycle: .running, phase: .thinking,
                startedAt: date, updatedAt: date, lastActivityAt: date
            ),
            timeline: items
        )
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
        RemoteSessionPayload(kind: .syncIndex),
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

@Test func requestPayloadsRoundTripThroughASealedRequestFrame() throws {
    let host = RelayCryptography.makeKeyPair()
    let device = RelayCryptography.makeKeyPair()
    let request = RemoteSessionPayload(
        kind: .fetchTimelineSince,
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        requestID: RequestID("req-9"),
        sessionIDs: [SessionID("session-1")],
        since: Date(timeIntervalSince1970: 1_699_999_000)
    )
    let frame = try RelayCryptography.seal(
        request,
        hostID: HostID("host-test-000001"),
        deviceID: DeviceID("device-test-0001"),
        sequence: 3,
        kind: .request,
        privateKey: device.privateKey,
        peerPublicKey: host.publicKey
    )
    #expect(frame.kind == .request)
    let opened = try RelayCryptography.open(frame, privateKey: host.privateKey, peerPublicKey: device.publicKey)
    #expect(opened == request)
}

@Test func routingHeaderIsAuthenticated() throws {
    let host = RelayCryptography.makeKeyPair()
    let device = RelayCryptography.makeKeyPair()
    let hostID = HostID("host-test-000001")
    let deviceID = DeviceID("device-test-0001")
    let frame = try RelayCryptography.seal(
        RemoteSessionPayload(kind: .health, generatedAt: Date(timeIntervalSince1970: 1_700_000_000)),
        hostID: hostID, deviceID: deviceID, sequence: 5,
        privateKey: host.privateKey, peerPublicKey: device.publicKey
    )
    #expect(throws: Never.self) {
        try RelayCryptography.open(frame, privateKey: device.privateKey, peerPublicKey: host.publicKey)
    }
    // A relay that re-stamps the sequence (replay under a fresh number) or
    // flips the direction cannot keep the tag valid.
    let resequenced = RelayRoutingFrame(
        hostID: hostID, deviceID: deviceID, sequence: 6, kind: frame.kind,
        nonce: frame.nonce, ciphertext: frame.ciphertext
    )
    #expect(throws: (any Error).self) {
        try RelayCryptography.open(resequenced, privateKey: device.privateKey, peerPublicKey: host.publicKey)
    }
    let redirected = RelayRoutingFrame(
        hostID: hostID, deviceID: deviceID, sequence: 5, kind: .request,
        nonce: frame.nonce, ciphertext: frame.ciphertext
    )
    #expect(throws: (any Error).self) {
        try RelayCryptography.open(redirected, privateKey: device.privateKey, peerPublicKey: host.publicKey)
    }
}

@Test func pairingCommitmentAndSASMatchTheGoldenVectors() {
    // Fixed inputs; expected values computed independently with python3:
    //   sha256(b"Lumi Relay/pair-commit/v1" + hostPub + nonce)  -> base64
    //   sha256(b"Lumi Relay/pair-sas/v1" + hostID + deviceID + hostPub + devicePub + nonce)[:4] big-endian % 1_000_000
    let hostID = HostID("host-test-000001")
    let deviceID = DeviceID("device-test-0001")
    let hostPublicKey = Data((1...32).map { UInt8($0) })
    let devicePublicKey = Data((101...132).map { UInt8($0) })
    let nonce = Data(repeating: 0xAB, count: 32)

    let commit = RelayCryptography.pairingCommitment(hostPublicKey: hostPublicKey, hostNonce: nonce)
    #expect(commit.base64EncodedString() == "bTZyIx77RxZA+32JxLVcmvG2hKWnQhBfiRi88C+Bluo=")
    #expect(RelayCryptography.verifyPairingCommitment(commit, hostPublicKey: hostPublicKey, hostNonce: nonce))
    // A different key or nonce does not open the commitment; neither does a truncated one.
    #expect(!RelayCryptography.verifyPairingCommitment(commit, hostPublicKey: devicePublicKey, hostNonce: nonce))
    #expect(!RelayCryptography.verifyPairingCommitment(commit, hostPublicKey: hostPublicKey, hostNonce: Data(repeating: 0xAC, count: 32)))
    #expect(!RelayCryptography.verifyPairingCommitment(commit.dropLast(), hostPublicKey: hostPublicKey, hostNonce: nonce))

    let sas = RelayCryptography.pairingSAS(
        hostID: hostID, deviceID: deviceID,
        hostPublicKey: hostPublicKey, devicePublicKey: devicePublicKey, hostNonce: nonce
    )
    #expect(sas == "060476")
    #expect(PairingCode.displaySAS(sas) == "060 476")
    // Every input is bound: swapping the device key changes the digits.
    let swapped = RelayCryptography.pairingSAS(
        hostID: hostID, deviceID: deviceID,
        hostPublicKey: hostPublicKey, devicePublicKey: hostPublicKey, hostNonce: nonce
    )
    #expect(swapped != sas)
    #expect(swapped.count == 6)
    #expect(RelayCryptography.makePairingNonce().count == 32)
    #expect(RelayCryptography.makePairingNonce() != RelayCryptography.makePairingNonce())
}

@Test func credentialCollectionKeepsMacChannelsIndependent() throws {
    let first = channelCredentials(host: "host-first-0001")
    let second = channelCredentials(host: "host-second-0002")
    var collection = RelayDeviceCredentialCollection()
    collection.upsert(first)
    collection.upsert(second)

    #expect(collection.channels.map(\.hostID) == [first.hostID, second.hostID])
    let restored = try JSONDecoder().decode(
        RelayDeviceCredentialCollection.self,
        from: JSONEncoder().encode(collection)
    )
    #expect(restored == collection)

    collection.remove(hostID: first.hostID)
    #expect(collection.channels == [second])
}

private func channelCredentials(host: String) -> RelayDeviceCredentials {
    RelayDeviceCredentials(
        relayURL: URL(string: "https://relay.example.com")!,
        hostID: HostID(host),
        hostName: host,
        deviceID: DeviceID("device-\(host)"),
        deviceToken: "token-\(host)",
        keyPair: RelayCryptography.makeKeyPair(),
        hostPublicKey: RelayCryptography.makeKeyPair().publicKey
    )
}

@Test func relaySocketCredentialRejectionIsRecognised() {
    #expect(RelayWebSocketClient.isCredentialRejection(httpStatus: 401, closeCode: 1000))
    #expect(RelayWebSocketClient.isCredentialRejection(httpStatus: 403, closeCode: 1000))
    #expect(RelayWebSocketClient.isCredentialRejection(httpStatus: 101, closeCode: RelayWebSocketClient.deviceRevokedCloseCode))
    #expect(!RelayWebSocketClient.isCredentialRejection(httpStatus: 101, closeCode: 1001))
    #expect(!RelayWebSocketClient.isCredentialRejection(httpStatus: nil, closeCode: 1006))
}
