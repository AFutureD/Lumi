import Remote
import Transport
import Foundation
import Testing

/// The two ends of one paired Mac ↔ iPhone channel, each holding only its
/// own private keys.
private struct PairedChannel {
    let host = RelayCryptography.makeKeyPair()
    let device = RelayCryptography.makeKeyPair()
    let hostID = HostID("host-test-000001")
    let deviceID = DeviceID("device-test-0001")

    var hostHandshakeKey: RelayChannelKey {
        get throws {
            try RelayCryptography.handshakeKey(privateKey: host.privateKey, peerPublicKey: device.publicKey, hostID: hostID, deviceID: deviceID)
        }
    }

    var deviceHandshakeKey: RelayChannelKey {
        get throws {
            try RelayCryptography.handshakeKey(privateKey: device.privateKey, peerPublicKey: host.publicKey, hostID: hostID, deviceID: deviceID)
        }
    }

    /// One channel session: each end derives the key from its own one-time
    /// key and the other's public half.
    func openSession() throws -> (host: RelayChannelKey, device: RelayChannelKey) {
        let hostEphemeral = RelayEphemeralKey()
        let deviceEphemeral = RelayEphemeralKey()
        return (
            try RelayCryptography.sessionKey(
                as: .host, ephemeral: hostEphemeral, peerEphemeralPublicKey: try deviceEphemeral.publicKey,
                privateKey: host.privateKey, peerPublicKey: device.publicKey, hostID: hostID, deviceID: deviceID
            ),
            try RelayCryptography.sessionKey(
                as: .device, ephemeral: deviceEphemeral, peerEphemeralPublicKey: try hostEphemeral.publicKey,
                privateKey: device.privateKey, peerPublicKey: host.publicKey, hostID: hostID, deviceID: deviceID
            )
        )
    }
}

@Test func aChannelSessionRoundTripsAnEncryptedSessionPayload() throws {
    let channel = PairedChannel()
    let session = try channel.openSession()
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
        hostID: channel.hostID,
        deviceID: channel.deviceID,
        sequence: 7,
        key: session.host
    )
    let opened = try RelayCryptography.open(frame, key: session.device)

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

    let channel = PairedChannel()
    let session = try channel.openSession()
    let frame = try RelayCryptography.seal(prepared, hostID: channel.hostID, deviceID: channel.deviceID, sequence: 1, key: session.host)
    #expect(try RelayCryptography.open(frame, key: session.device) == payload)
}

@Test func theHandshakeKeyBelongsToOnePairing() throws {
    let channel = PairedChannel()
    let opening = RemoteSessionPayload(
        kind: .syncIndex,
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        requestID: RequestID("open-1"),
        ephemeralKey: try RelayEphemeralKey().publicKey
    )
    let frame = try RelayCryptography.seal(
        opening, hostID: channel.hostID, deviceID: channel.deviceID, sequence: 1, kind: .request,
        key: channel.deviceHandshakeKey
    )
    // Both ends derive it from their own private key and the other's public key.
    #expect(try RelayCryptography.open(frame, key: channel.hostHandshakeKey) == opening)

    // Another iPhone paired with the same Mac — or the same keys under
    // another channel's IDs — arrives at a different key.
    let otherDevice = RelayCryptography.makeKeyPair()
    let othersKey = try RelayCryptography.handshakeKey(
        privateKey: channel.host.privateKey, peerPublicKey: otherDevice.publicKey,
        hostID: channel.hostID, deviceID: channel.deviceID
    )
    #expect(throws: (any Error).self) { try RelayCryptography.open(frame, key: othersKey) }
    let otherChannelsKey = try RelayCryptography.handshakeKey(
        privateKey: channel.host.privateKey, peerPublicKey: channel.device.publicKey,
        hostID: channel.hostID, deviceID: DeviceID("device-test-0002")
    )
    let relabelled = RelayRoutingFrame(
        hostID: channel.hostID, deviceID: DeviceID("device-test-0002"), sequence: 1, kind: .request,
        nonce: frame.nonce, ciphertext: frame.ciphertext
    )
    #expect(throws: (any Error).self) { try RelayCryptography.open(relabelled, key: otherChannelsKey) }
}

@Test func requestPayloadsRoundTripThroughASealedRequestFrame() throws {
    let channel = PairedChannel()
    let session = try channel.openSession()
    let request = RemoteSessionPayload(
        kind: .fetchTimelineSince,
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        requestID: RequestID("req-9"),
        sessionIDs: [SessionID("session-1")],
        since: Date(timeIntervalSince1970: 1_699_999_000)
    )
    let frame = try RelayCryptography.seal(
        request,
        hostID: channel.hostID,
        deviceID: channel.deviceID,
        sequence: 3,
        kind: .request,
        key: session.device
    )
    #expect(frame.kind == .request)
    #expect(try RelayCryptography.open(frame, key: session.host) == request)
}

@Test func routingHeaderIsAuthenticated() throws {
    let channel = PairedChannel()
    let session = try channel.openSession()
    let frame = try RelayCryptography.seal(
        RemoteSessionPayload(kind: .health, generatedAt: Date(timeIntervalSince1970: 1_700_000_000)),
        hostID: channel.hostID, deviceID: channel.deviceID, sequence: 5,
        key: session.host
    )
    #expect(throws: Never.self) {
        try RelayCryptography.open(frame, key: session.device)
    }
    // A relay that re-stamps the sequence (replay under a fresh number) or
    // flips the direction cannot keep the tag valid.
    let resequenced = RelayRoutingFrame(
        hostID: channel.hostID, deviceID: channel.deviceID, sequence: 6, kind: frame.kind,
        nonce: frame.nonce, ciphertext: frame.ciphertext
    )
    #expect(throws: (any Error).self) {
        try RelayCryptography.open(resequenced, key: session.device)
    }
    let redirected = RelayRoutingFrame(
        hostID: channel.hostID, deviceID: channel.deviceID, sequence: 5, kind: .request,
        nonce: frame.nonce, ciphertext: frame.ciphertext
    )
    #expect(throws: (any Error).self) {
        try RelayCryptography.open(redirected, key: session.host)
    }
}

@Test func everyChannelSessionHasItsOwnKey() throws {
    let channel = PairedChannel()
    let first = try channel.openSession()
    let second = try channel.openSession()
    let payload = RemoteSessionPayload(kind: .health, generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let frame = try RelayCryptography.seal(payload, hostID: channel.hostID, deviceID: channel.deviceID, sequence: 1, key: first.host)
    #expect(try RelayCryptography.open(frame, key: first.device) == payload)

    // A frame kept from one session does not open in the next, and the
    // long-term keys alone — all the handshake key is made of — open none:
    // once a session's one-time keys are gone, so is the way into it.
    #expect(throws: (any Error).self) { try RelayCryptography.open(frame, key: second.device) }
    #expect(throws: (any Error).self) { try RelayCryptography.open(frame, key: channel.deviceHandshakeKey) }

    // Both long-term keys are part of the session key: an end holding the
    // right one-time keys but someone else's long-term key derives another.
    let stranger = RelayCryptography.makeKeyPair()
    let hostEphemeral = RelayEphemeralKey()
    let deviceEphemeral = RelayEphemeralKey()
    let hostKey = try RelayCryptography.sessionKey(
        as: .host, ephemeral: hostEphemeral, peerEphemeralPublicKey: try deviceEphemeral.publicKey,
        privateKey: channel.host.privateKey, peerPublicKey: channel.device.publicKey,
        hostID: channel.hostID, deviceID: channel.deviceID
    )
    let strangersKey = try RelayCryptography.sessionKey(
        as: .device, ephemeral: deviceEphemeral, peerEphemeralPublicKey: try hostEphemeral.publicKey,
        privateKey: stranger.privateKey, peerPublicKey: channel.host.publicKey,
        hostID: channel.hostID, deviceID: channel.deviceID
    )
    let sealed = try RelayCryptography.seal(payload, hostID: channel.hostID, deviceID: channel.deviceID, sequence: 2, key: hostKey)
    #expect(throws: (any Error).self) { try RelayCryptography.open(sealed, key: strangersKey) }
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
