import Core
import DaemonRuntime
import Remote
import Transport
import Foundation
import Testing

/// Drives `RelayHostService` through an in-memory relay: a device end opens
/// channel sessions, sends sealed requests and reads the sealed answers, the
/// hub publishes events. The host runs as a held task; `stop()` is
/// cancellation, like the daemon's ServiceGroup shutdown.
private final class RelayHarness {
    private var runTask: Task<Void, Never>?

    /// Starts `run()` and waits for the connection to come up, matching the
    /// old start()-returns-connected contract the tests were written against.
    func start() async {
        guard runTask == nil else { return }
        let service = service
        runTask = Task { try? await service.run() }
        let deadline = ContinuousClock.now + .seconds(5)
        while await !service.status().connected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func stop() async {
        runTask?.cancel()
        await runTask?.value
        runTask = nil
    }

    let repository = InMemorySessionRepository()
    let hub = DaemonSubscriptionHub()
    let link = RelayInMemoryLink()
    let rest: InMemoryRelayHostREST
    let credentialStore: InMemoryRelayHostCredentialStore
    let statePath: String
    let service: RelayHostService
    let deviceID = DeviceID("device-test-0001")
    let deviceKeys: RelayKeyPair
    let relayURL = URL(string: "https://relay.example.test")!
    let connections = ConnectionLog()
    /// The harness device's end of the channel: the key of the session it
    /// opened last, and its request sequence on this connection.
    private(set) var sessionKey: RelayChannelKey?
    private var requestSequence: UInt64 = 0

    init(
        healthProvider: @escaping RelayHostService.HealthProvider = { nil },
        usageProvider: @escaping RelayHostService.UsageProvider = { _ in throw DaemonServiceError.unavailable("usage") },
        planUsageProvider: @escaping RelayHostService.PlanUsageProvider = { throw DaemonServiceError.unavailable("plan_usage") },
        preregisterDevice: Bool = true,
        pinDeviceKey: Bool = true,
        pairingCodeLifetime: Duration = .seconds(5 * 60),
        pairingDecisionTimeout: Duration = .seconds(60),
        restarting previous: RelayHarness? = nil
    ) {
        if let previous {
            // The daemon came back: same Relay, same Keychain, same state file.
            statePath = previous.statePath
            rest = previous.rest
            credentialStore = previous.credentialStore
            deviceKeys = previous.deviceKeys
        } else {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            statePath = directory.appendingPathComponent("relay-host-state.json").path
            credentialStore = InMemoryRelayHostCredentialStore()
            let keys = RelayCryptography.makeKeyPair()
            deviceKeys = keys
            rest = InMemoryRelayHostREST(devices: preregisterDevice ? [
                PairedDevice(id: deviceID, name: "Test iPhone", publicKey: keys.publicKey, pairedAt: Date()),
            ] : [])
            if preregisterDevice, pinDeviceKey {
                // A device this daemon verified in an earlier life: its key is pinned.
                var state = RelayHostStateStore(path: statePath)
                try? state.setVerifiedKey(keys.publicKey, for: deviceID)
            }
        }
        let connections = connections
        service = RelayHostService(
            repository: repository,
            subscriptions: hub,
            relayURL: relayURL,
            credentialStore: credentialStore,
            statePath: statePath,
            transportFactory: link,
            rest: rest,
            hostName: { "Test Mac" },
            healthProvider: healthProvider,
            usageProvider: usageProvider,
            planUsageProvider: planUsageProvider,
            onConnectionChange: { connected in connections.append(connected) },
            eventCoalesceInterval: .milliseconds(20),
            reconnectDelay: .milliseconds(50),
            deviceRefreshInterval: .seconds(60),
            healthInterval: .seconds(60),
            pairingCodeLifetime: pairingCodeLifetime,
            pairingDecisionTimeout: pairingDecisionTimeout
        )
    }

    var hostCredentials: RelayHostCredentials {
        get throws { try #require(try credentialStore.load()) }
    }

    /// The harness device as the Relay lists it once a pairing approved it.
    var pairedDevice: PairedDevice {
        PairedDevice(id: deviceID, name: "Test iPhone", publicKey: deviceKeys.publicKey, pairedAt: Date())
    }

    /// Plays the iPhone against the live pairing session: submits the device
    /// to the Relay stand-in and has the Relay push `pairing_device` to the
    /// host. Returns once the daemon shows an SAS (or gives up).
    func submitDevice() async throws {
        let sessionID = try #require(await rest.latestSession?.sessionID)
        await rest.submit(sessionID: sessionID, device: pairedDevice)
        await link.sendPairingDeviceToHost(RelayPairingDeviceNotice(
            sessionID: sessionID, deviceID: deviceID, deviceName: "Test iPhone", devicePublicKey: deviceKeys.publicKey
        ))
        for _ in 0..<300 where await service.pairingSession()?.pending == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Starts the host and opens the device end.
    func connect() async throws -> any RelayFrameTransport {
        await start()
        let device = link.makeDeviceTransport(deviceID)
        try await device.connect(hostID: try hostCredentials.hostID, role: .device(deviceID), token: "token")
        // The first message on a device socket is the presence flag.
        guard case .presence(online: true) = try await device.next() else {
            Issue.record("expected the host to be online")
            throw RelayClientError.notConnected
        }
        return device
    }

    var handshakeKey: RelayChannelKey {
        get throws {
            try RelayCryptography.handshakeKey(
                privateKey: deviceKeys.privateKey,
                peerPublicKey: try hostCredentials.keyPair.publicKey,
                hostID: try hostCredentials.hostID,
                deviceID: deviceID
            )
        }
    }

    /// Sends a `sync_index` opening — sealed with the handshake key, on the
    /// next request sequence — and returns the one-time key it carried.
    @discardableResult
    func sendOpening(via device: any RelayFrameTransport, requestID: RequestID = RequestID()) async throws -> RelayEphemeralKey {
        let ephemeral = RelayEphemeralKey()
        requestSequence += 1
        try await device.send(try RelayCryptography.seal(
            RemoteSessionPayload(kind: .syncIndex, requestID: requestID, ephemeralKey: try ephemeral.publicKey),
            hostID: try hostCredentials.hostID,
            deviceID: deviceID,
            sequence: requestSequence,
            kind: .request,
            key: try handshakeKey
        ))
        return ephemeral
    }

    /// Opens a channel session the way the iPhone does: `sync_index` out,
    /// `channel_opened` in. The index follows on the device end.
    func sync(via device: any RelayFrameTransport, requestID: RequestID = RequestID()) async throws {
        let ephemeral = try await sendOpening(via: device, requestID: requestID)
        try await finishOpening(ephemeral, requestID: requestID, via: device)
    }

    /// Reads up to the `channel_opened` that answers `requestID` and derives
    /// the session key from it.
    func finishOpening(_ ephemeral: RelayEphemeralKey, requestID: RequestID, via device: any RelayFrameTransport) async throws {
        let handshakeKey = try handshakeKey
        for _ in 0..<200 {
            let message = try await withTimeout(seconds: 5) { try await device.next() }
            guard case let .frame(frame) = message,
                  let payload = try? RelayCryptography.open(frame, key: handshakeKey),
                  payload.kind == .channelOpened, payload.requestID == requestID,
                  let hostEphemeralKey = payload.ephemeralKey else { continue }
            sessionKey = try RelayCryptography.sessionKey(
                as: .device,
                ephemeral: ephemeral,
                peerEphemeralPublicKey: hostEphemeralKey,
                privateKey: deviceKeys.privateKey,
                peerPublicKey: try hostCredentials.keyPair.publicKey,
                hostID: try hostCredentials.hostID,
                deviceID: deviceID
            )
            return
        }
        Issue.record("the channel session never opened")
    }

    /// Starts the host, opens the device end and a channel session, and
    /// reads past the index that comes with it.
    func connectAndSync() async throws -> any RelayFrameTransport {
        let device = try await connect()
        try await sync(via: device)
        _ = try await collect(from: device) { $0.kind == .sessionIndex }
        return device
    }

    /// Seals a request inside the open channel session, on the next request
    /// sequence unless one is given.
    func seal(_ payload: RemoteSessionPayload, sequence: UInt64? = nil) throws -> RelayRoutingFrame {
        if sequence == nil { requestSequence += 1 }
        return try RelayCryptography.seal(
            payload,
            hostID: try hostCredentials.hostID,
            deviceID: deviceID,
            sequence: sequence ?? requestSequence,
            kind: .request,
            key: try #require(sessionKey)
        )
    }

    func request(_ payload: RemoteSessionPayload, via device: any RelayFrameTransport) async throws {
        try await device.send(try seal(payload))
    }

    /// Reads sealed `data` frames until `predicate` accepts one; returns
    /// every payload seen. Frames open with the session key; a
    /// `channel_opened` (the daemon opening the session again) with the
    /// handshake key.
    func collect(
        from device: any RelayFrameTransport,
        until predicate: (RemoteSessionPayload) -> Bool
    ) async throws -> [(frame: RelayRoutingFrame, payload: RemoteSessionPayload)] {
        var seen: [(RelayRoutingFrame, RemoteSessionPayload)] = []
        let sessionKey = try #require(sessionKey)
        let handshakeKey = try handshakeKey
        for _ in 0..<200 {
            let message = try await withTimeout(seconds: 5) { try await device.next() }
            guard case let .frame(frame) = message else { continue }
            guard let payload = (try? RelayCryptography.open(frame, key: sessionKey))
                ?? (try? RelayCryptography.open(frame, key: handshakeKey)) else {
                Issue.record("frame \(frame.sequence) opens with neither key")
                continue
            }
            seen.append((frame, payload))
            if predicate(payload) { return seen }
        }
        Issue.record("ran out of frames")
        return seen
    }
}

private final class StreamedSummaries: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SessionSummary] = []
    func append(_ value: SessionSummary) { lock.lock(); values.append(value); lock.unlock() }
    var snapshot: [SessionSummary] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class ConnectionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func append(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
    var snapshot: [Bool] { lock.lock(); defer { lock.unlock() }; return values }
}

private func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw RelayClientError.notConnected
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private func sampleDetail(_ id: String, items: Int, at base: Date) -> SessionDetail {
    let sessionID = SessionID(id)
    return SessionDetail(
        summary: SessionSummary(
            id: sessionID, agent: .codex, title: id,
            lifecycle: .running, phase: .thinking,
            startedAt: base, updatedAt: base.addingTimeInterval(Double(items)), lastActivityAt: base.addingTimeInterval(Double(items))
        ),
        turns: [TurnSummary(id: TurnID("\(id)-turn"), sessionID: sessionID, phase: .thinking, startedAt: base)],
        // Turn-scoped rows: turns are projected from the timeline now, so the
        // fixture's turn surfaces through its items, not the array above.
        timeline: (0..<items).map { index in
            TimelineItem(
                id: TimelineItemID("\(id)-item-\(index)"), sessionID: sessionID,
                turnID: TurnID("\(id)-turn"),
                occurredAt: base.addingTimeInterval(Double(index)),
                payload: .message(MessageTimelinePayload(role: .assistant, text: "line \(index)"))
            )
        }
    )
}

@Test func hostRegistersOnceAndAnswersSyncIndexWithHealth() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let health = DaemonHealth(daemonVersion: "t", executableHash: "h", process: nil, uptimeSeconds: 1, activeSessionCount: 1, retainedSessionCount: 2, socketPath: "/s", relayConnected: true)
    let harness = RelayHarness(healthProvider: { health })
    try await harness.repository.replaceSession(sampleDetail("a", items: 3, at: base))
    try await harness.repository.replaceSession(sampleDetail("b", items: 0, at: base.addingTimeInterval(-100)))
    let device = try await harness.connect()

    #expect(harness.connections.snapshot == [true])
    let credentials = try harness.hostCredentials
    #expect(await harness.rest.registered[credentials.hostID] == credentials.hostSecret)
    #expect(await harness.service.status().connected)

    try await harness.sync(via: device, requestID: RequestID("r1"))
    let seen = try await harness.collect(from: device) { $0.kind == .health }
    let indexParts = seen.map(\.payload).filter { $0.kind == .sessionIndex }
    #expect(indexParts.count == 1)
    #expect(indexParts[0].requestID == RequestID("r1"))
    #expect(indexParts[0].partCount == 1)
    let entries = try #require(RelayFrameReduction.assembleIndex(parts: indexParts))
    #expect(entries.map(\.summary.id) == [SessionID("a"), SessionID("b")])
    #expect(entries[0].timelineItemCount == 3)
    #expect(entries[0].lastItemAt == base.addingTimeInterval(2))
    #expect(entries[1].timelineItemCount == 0)
    #expect(seen.last?.payload.health == health)
    // Sequences are per device, start at 1 (`channel_opened`), and are
    // persisted before send.
    #expect(seen.map(\.frame.sequence) == [2, 3])
    let persisted = RelayHostStateStore(path: harness.statePath)
    #expect(persisted.current(for: harness.deviceID) == 3)
    await harness.stop()
}

@Test func hostServesFullSessionsTimelineTailsAndRemovals() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = RelayHarness()
    try await harness.repository.replaceSession(sampleDetail("a", items: 5, at: base))
    let device = try await harness.connectAndSync()

    try await harness.request(RemoteSessionPayload(kind: .fetchSession, requestID: RequestID("f"), sessionIDs: [SessionID("a"), SessionID("ghost")]), via: device)
    let seen = try await harness.collect(from: device) { $0.kind == .sessionRemoved }
    let full = seen.map(\.payload).filter { $0.kind == .sessionFull }
    #expect(full.count == 1)
    #expect(full[0].requestID == RequestID("f"))
    let assembled = try #require(RelayFrameReduction.assemble(parts: full))
    #expect(assembled.timeline.count == 5)
    #expect(assembled.turns.count == 1)
    #expect(seen.last?.payload.sessionIDs == [SessionID("ghost")])
    #expect(seen.last?.payload.requestID == RequestID("f"))

    try await harness.request(RemoteSessionPayload(
        kind: .fetchTimelineSince, requestID: RequestID("t"),
        sessionIDs: [SessionID("a")], since: base.addingTimeInterval(3)
    ), via: device)
    let tail = try await harness.collect(from: device) { $0.kind == .sessionTimeline }
    let detail = try #require(RelayFrameReduction.assemble(parts: tail.map(\.payload)))
    #expect(detail.timeline.map(\.id) == [TimelineItemID("a-item-3"), TimelineItemID("a-item-4")])
    #expect(detail.turns.count == 1)
    await harness.stop()
}

@Test func hostPushesEventsInfoAndRemovalsOnlyToSyncedDevices() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = RelayHarness()
    try await harness.repository.replaceSession(sampleDetail("a", items: 1, at: base))
    let device = try await harness.connect()

    // Not synced yet: nothing is pushed.
    let early = AgentIngressEvent(eventID: EventID("e0"), sessionID: SessionID("a"), agent: .codex, occurredAt: base, phase: .executing)
    _ = try await harness.repository.apply(early)
    harness.hub.publish(early)
    try await Task.sleep(for: .milliseconds(100))
    #expect(await harness.link.hostSent.isEmpty)

    try await harness.sync(via: device)
    _ = try await harness.collect(from: device) { $0.kind == .sessionIndex }

    let first = AgentIngressEvent(eventID: EventID("e1"), sessionID: SessionID("a"), agent: .codex, occurredAt: base.addingTimeInterval(10), phase: .thinking)
    let second = AgentIngressEvent(eventID: EventID("e2"), sessionID: SessionID("a"), agent: .codex, occurredAt: base.addingTimeInterval(11), phase: .executing)
    harness.hub.publish(first)
    harness.hub.publish(second)
    let messages = try await harness.collect(from: device) { $0.kind == .sessionMessage }
    // Coalesced into one batch, in order.
    #expect(messages.last?.payload.events?.map(\.eventID) == [EventID("e1"), EventID("e2")])

    try await harness.repository.markSessionReviewed(SessionID("a"))
    await harness.service.summariesChanged([SessionID("a")])
    let info = try await harness.collect(from: device) { $0.kind == .sessionInfo }
    #expect(info.last?.payload.summaries?.map(\.id) == [SessionID("a")])

    await harness.service.sessionsRemoved([SessionID("a")])
    let removed = try await harness.collect(from: device) { $0.kind == .sessionRemoved }
    #expect(removed.last?.payload.sessionIDs == [SessionID("a")])
    #expect(removed.last?.payload.requestID == nil)
    await harness.stop()
}

@Test func hostOpensTheChannelSessionAgainPastASequenceTheRelayRejected() async throws {
    let harness = RelayHarness()
    let device = try await harness.connect()
    try await harness.sync(via: device, requestID: RequestID("r1"))
    let first = try await harness.collect(from: device) { $0.kind == .sessionIndex }
    #expect(first.last?.frame.sequence == 2)

    // The Relay tells only the host, and the rejected frame may have been
    // `channel_opened` itself. The host heals its cursor and opens the same
    // session again past the hole: an iPhone still waiting gets its key and
    // index, one that had them sees the sequence gap and indexes again.
    await harness.link.sendErrorToHost(RelayErrorMessage(code: "non_monotonic_sequence", sequence: 2, lastSequence: 40, deviceID: harness.deviceID))
    let again = try await harness.collect(from: device) { $0.kind == .sessionIndex }
    #expect(again.map(\.payload.kind) == [.channelOpened, .sessionIndex])
    #expect(again.map(\.payload.requestID) == [RequestID("r1"), RequestID("r1")])
    #expect(again.map(\.frame.sequence) == [41, 42])
    #expect(RelayHostStateStore(path: harness.statePath).current(for: harness.deviceID) == 42)
    await harness.stop()
}

@Test func anIPhoneReviewReachesTheMacThroughTheLocalStream() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = RelayHarness()
    let needsReview = sampleDetail("a", items: 1, at: base)
    try await harness.repository.replaceSession(SessionDetail(
        summary: needsReview.summary.withReviewState(needsAttention: true, needsReview: true),
        turns: needsReview.turns, timeline: needsReview.timeline
    ))
    let streamed = StreamedSummaries()
    let subscription = harness.hub.subscribe { message in
        if case let .summary(summary) = message { streamed.append(summary) }
    }
    defer { harness.hub.unsubscribe(subscription) }
    let device = try await harness.connectAndSync()

    try await harness.request(RemoteSessionPayload(kind: .sessionReviewed, sessionIDs: [SessionID("a")]), via: device)
    // Other iPhones get `session_info`; the Mac window and the Notch get the
    // same summary on the daemon's local stream.
    let info = try await harness.collect(from: device) { $0.kind == .sessionInfo }
    #expect(info.last?.payload.summaries?.first?.needsReview == false)
    for _ in 0..<300 where streamed.snapshot.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(streamed.snapshot.map(\.id) == [SessionID("a")])
    #expect(streamed.snapshot.first?.needsReview == false)
    await harness.stop()
}

@Test func hostPairsAnIPhoneThroughCodeSASAndMatch() async throws {
    let harness = RelayHarness(preregisterDevice: false)
    await harness.start()
    let device = harness.link.makeDeviceTransport(harness.deviceID)
    try await device.connect(hostID: try harness.hostCredentials.hostID, role: .device(harness.deviceID), token: "token")
    _ = try await device.next() // presence

    // A code on the Mac: six Base32 characters, a commitment at the Relay,
    // no nonce anywhere yet.
    let started = try await harness.service.startPairing()
    #expect(started.code.count == PairingCode.length)
    #expect(started.code.allSatisfy { PairingCode.alphabet.contains($0) })
    #expect(started.relayURL == harness.relayURL)
    #expect(started.pending == nil)
    let session = try #require(await harness.rest.latestSession)
    #expect(session.state == .offered)
    #expect(session.hostNonce == nil)
    #expect(session.hostName == "Test Mac")
    #expect(await harness.service.pairingSession() == started)

    // The iPhone submits itself: the daemon shows the SAS and only then
    // reveals the nonce — which must open the commitment it published.
    try await harness.submitDevice()
    let pending = try #require(await harness.service.pairingSession()?.pending)
    #expect(pending.deviceID == harness.deviceID)
    #expect(pending.deviceName == "Test iPhone")
    let revealed = try #require(await harness.rest.latestSession)
    #expect(revealed.state == .revealed)
    let nonce = try #require(revealed.hostNonce)
    let hostKey = try harness.hostCredentials.keyPair.publicKey
    #expect(RelayCryptography.verifyPairingCommitment(revealed.commit, hostPublicKey: hostKey, hostNonce: nonce))
    #expect(pending.sas == RelayCryptography.pairingSAS(
        hostID: try harness.hostCredentials.hostID, deviceID: harness.deviceID,
        hostPublicKey: hostKey, devicePublicKey: harness.deviceKeys.publicKey, hostNonce: nonce
    ))
    #expect(pending.sas.count == 6)
    // Nothing is trusted before Match: the device is not listed / verified.
    #expect(await harness.service.status().devices.isEmpty)

    // Match: the Relay lists the device, the daemon pins its key and talks to it.
    let decided = try await harness.service.decidePairing(approved: true)
    #expect(decided.pending == nil)
    #expect(decided.outcome?.kind == .approved)
    #expect(decided.outcome?.deviceName == "Test iPhone")
    #expect(await harness.rest.latestSession?.state == .approved)
    #expect(await harness.service.status().devices.map(\.keyVerified) == [true])
    #expect(RelayHostStateStore(path: harness.statePath).verifiedKey(for: harness.deviceID) == harness.deviceKeys.publicKey)
    try await harness.sync(via: device, requestID: RequestID("first"))
    let seen = try await harness.collect(from: device) { $0.kind == .sessionIndex }
    #expect(seen.last?.payload.requestID == RequestID("first"))
    await harness.stop()
}

@Test func hostDeclinesAnUnansweredPairingAndIgnoresUnpinnedKeys() async throws {
    let harness = RelayHarness(preregisterDevice: false, pairingDecisionTimeout: .milliseconds(150))
    await harness.start()
    let device = harness.link.makeDeviceTransport(harness.deviceID)
    try await device.connect(hostID: try harness.hostCredentials.hostID, role: .device(harness.deviceID), token: "token")
    _ = try await device.next() // presence

    // Nobody presses Match: the daemon declines for the Mac.
    _ = try await harness.service.startPairing()
    try await harness.submitDevice()
    for _ in 0..<300 where await harness.service.pairingSession()?.outcome == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await harness.service.pairingSession()?.outcome?.kind == .rejected)
    #expect(await harness.rest.latestSession?.state == .rejected)
    await #expect(throws: RelayPairingError.self) { try await harness.service.decidePairing(approved: true) }

    // A device the Relay lists that this Mac never approved (or whose key the
    // Relay swapped) stays unverified: it cannot open a channel session.
    await harness.rest.pair(harness.pairedDevice)
    await harness.service.refreshDevices()
    #expect(await harness.service.status().devices.map(\.keyVerified) == [false])
    try await harness.sendOpening(via: device, requestID: RequestID("untrusted"))
    try await Task.sleep(for: .milliseconds(200))
    #expect(await harness.link.hostSent.isEmpty)

    // Don't match after a proper submit: rejected, nothing pinned.
    _ = try await harness.service.startPairing()
    try await harness.submitDevice()
    let declined = try await harness.service.decidePairing(approved: false)
    #expect(declined.outcome?.kind == .rejected)
    #expect(RelayHostStateStore(path: harness.statePath).verifiedKey(for: harness.deviceID) == nil)
    await harness.stop()
}

@Test func hostKeepsOneLivePairingSessionAndFollowsCancellations() async throws {
    let harness = RelayHarness()
    _ = try await harness.connect()

    let first = try await harness.service.startPairing()
    let second = try await harness.service.startPairing()
    #expect(first.sessionID != second.sessionID)
    // Starting again cancels the earlier code at the Relay.
    #expect(await harness.rest.sessions[first.sessionID]?.state == .cancelled)
    #expect(await harness.rest.sessions[second.sessionID]?.state == .offered)

    // The iPhone cancels mid-way: no pending card, no outcome — the session
    // is gone and the Mac app starts a fresh code.
    try await harness.submitDevice()
    await harness.link.sendPairingClosedToHost(sessionID: second.sessionID)
    for _ in 0..<300 where await harness.service.pairingSession() != nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await harness.service.pairingSession() == nil)

    // Leaving the page cancels whatever is live; a new start works from scratch.
    let third = try await harness.service.startPairing()
    await harness.service.cancelPairing()
    #expect(await harness.service.pairingSession() == nil)
    #expect(await harness.rest.sessions[third.sessionID]?.state == .cancelled)
    await harness.stop()
}

@Test func hostKeepsAnExpiredCodeOnScreenInsteadOfReplacingIt() async throws {
    let harness = RelayHarness(preregisterDevice: false, pairingCodeLifetime: .milliseconds(150))
    _ = try await harness.connect()

    // The timer runs out: the session stays, marked expired, and nothing is
    // asked of the Relay — a new code only comes from a person.
    let first = try await harness.service.startPairing()
    #expect(first.expiredAt == nil)
    for _ in 0..<300 where await harness.service.pairingSession()?.expiredAt == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    let expired = try #require(await harness.service.pairingSession())
    #expect(expired.sessionID == first.sessionID)
    #expect(expired.code == first.code)
    #expect(expired.expiredAt != nil)
    #expect(expired.pending == nil)
    #expect(expired.outcome == nil)
    try await Task.sleep(for: .milliseconds(200))
    #expect(await harness.service.pairingSession() == expired)
    #expect(await harness.rest.sessions.count == 1)

    // New code from the Mac: the expired one is dropped without a cancel
    // round-trip (it is already terminal at the Relay).
    let second = try await harness.service.startPairing()
    #expect(second.sessionID != first.sessionID)
    #expect(second.expiredAt == nil)
    #expect(await harness.rest.cancelRequests.isEmpty)
    #expect(await harness.service.pairingSession() == second)

    // The Relay's own expiry (its clock ahead of ours) lands in the same
    // state; an iPhone that was waiting is gone with the code.
    try await harness.submitDevice()
    #expect(await harness.service.pairingSession()?.pending != nil)
    await harness.link.sendPairingClosedToHost(sessionID: second.sessionID, reason: "expired")
    for _ in 0..<300 where await harness.service.pairingSession()?.expiredAt == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    let closed = try #require(await harness.service.pairingSession())
    #expect(closed.sessionID == second.sessionID)
    #expect(closed.expiredAt != nil)
    #expect(closed.pending == nil)
    await #expect(throws: RelayPairingError.self) { try await harness.service.decidePairing(approved: true) }

    // Leaving the page forgets it — again without telling the Relay about
    // a session it closed itself.
    await harness.service.cancelPairing()
    #expect(await harness.service.pairingSession() == nil)
    #expect(await harness.rest.cancelRequests.isEmpty)
    await harness.stop()
}

@Test func hostReconnectsAfterTheRelayDropsItAndForgetsActiveDevices() async throws {
    let harness = RelayHarness()
    let device = try await harness.connectAndSync()

    await harness.link.dropHost()
    guard case .presence(online: false) = try await withTimeout(seconds: 5, { try await device.next() }) else {
        Issue.record("expected the host to go offline")
        return
    }
    guard case .presence(online: true) = try await withTimeout(seconds: 5, { try await device.next() }) else {
        Issue.record("expected the host to reconnect")
        return
    }
    // The presence flag reaches the device as soon as the socket is up; the
    // daemon's own observer runs right after, so give it a moment.
    for _ in 0..<300 where harness.connections.snapshot != [true, false, true] {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(harness.connections.snapshot == [true, false, true])
    // The reconnect ended every channel session: a push goes nowhere until
    // the device opens one again.
    let sent = await harness.link.hostSent.count
    harness.hub.publish(AgentIngressEvent(eventID: EventID("e"), sessionID: SessionID("x"), agent: .codex, occurredAt: Date(), phase: .thinking))
    try await Task.sleep(for: .milliseconds(100))
    #expect(await harness.link.hostSent.count == sent)
    await harness.stop()
}

@Test func hostRevokesAndRemovesDevices() async throws {
    let harness = RelayHarness()
    _ = try await harness.connect()
    #expect(await harness.service.status().devices.first?.keyVerified == true)
    try await harness.service.revoke(deviceID: harness.deviceID)
    let status = await harness.service.status()
    #expect(status.devices.first?.revokedAt != nil)
    #expect(status.devices.first?.keyVerified == false)
    // Remove deletes the record and forgets the pinned key and the revocation.
    try await harness.service.remove(deviceID: harness.deviceID)
    #expect(await harness.service.status().devices.isEmpty)
    #expect(RelayHostStateStore(path: harness.statePath).verifiedKey(for: harness.deviceID) == nil)
    #expect(RelayHostStateStore(path: harness.statePath).revokedAt(for: harness.deviceID) == nil)
    await harness.stop()
}

@Test func hostAlertsAPairedButDisconnectedIPhoneOverAPNs() async throws {
    let harness = RelayHarness()
    let base = Date()
    try await harness.repository.replaceSession(sampleDetail("a", items: 1, at: base))
    // Start the host only: the device is paired (listed by the relay) but
    // never opens a socket — exactly the case push notifications exist for.
    await harness.start()

    let event = AgentIngressEvent(
        eventID: EventID("turn-end"), sessionID: SessionID("a"), agent: .codex, occurredAt: Date(),
        timelineItem: TimelineItem(
            id: TimelineItemID("a-end"), sessionID: SessionID("a"), occurredAt: Date(),
            payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed, message: "Shipped."))
        )
    )
    _ = try await harness.repository.apply(event)
    harness.hub.publish(event)
    for _ in 0..<300 where await harness.rest.sentNotifications.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    let sent = await harness.rest.sentNotifications
    #expect(sent.count == 1)
    #expect(sent.first?.title == "a")
    #expect(sent.first?.subtitle == "Completed")
    #expect(sent.first?.sessionID == SessionID("a"))
    // The alert names its targets: only the key-verified device.
    #expect(sent.first?.deviceIDs == [harness.deviceID])
    await harness.stop()
}

@Test func hostNeverAlertsAnUnverifiedDevice() async throws {
    // The Relay lists the device, but this daemon never pinned its key (the
    // Mac never pressed Match, or the Relay swapped the key): no frames, and
    // no push either — the alert title is the session title in plaintext.
    let harness = RelayHarness(pinDeviceKey: false)
    let base = Date()
    try await harness.repository.replaceSession(sampleDetail("a", items: 1, at: base))
    await harness.start()
    // Wait for the device list: without it the push gate would skip for the
    // wrong reason (no devices at all) and prove nothing.
    for _ in 0..<300 where await harness.service.status().devices.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await harness.service.status().devices.first?.keyVerified == false)

    let event = AgentIngressEvent(
        eventID: EventID("turn-end"), sessionID: SessionID("a"), agent: .codex, occurredAt: Date(),
        timelineItem: TimelineItem(
            id: TimelineItemID("a-end"), sessionID: SessionID("a"), occurredAt: Date(),
            payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed, message: "Shipped."))
        )
    )
    _ = try await harness.repository.apply(event)
    harness.hub.publish(event)
    try await Task.sleep(for: .milliseconds(150))
    #expect(await harness.rest.sentNotifications.isEmpty)
    await harness.stop()
}

@Test func hostNeverAlertsForReplayedOldEvents() async throws {
    let harness = RelayHarness()
    let base = Date().addingTimeInterval(-3_600)
    try await harness.repository.replaceSession(sampleDetail("a", items: 1, at: base))
    await harness.start()

    // A backfill replays a turn end from an hour ago: no alert.
    let event = AgentIngressEvent(
        eventID: EventID("old-end"), sessionID: SessionID("a"), agent: .codex, occurredAt: base,
        timelineItem: TimelineItem(
            id: TimelineItemID("a-old-end"), sessionID: SessionID("a"), occurredAt: base,
            payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed, message: "Long done."))
        )
    )
    _ = try await harness.repository.apply(event)
    harness.hub.publish(event)
    try await Task.sleep(for: .milliseconds(150))
    #expect(await harness.rest.sentNotifications.isEmpty)
    await harness.stop()
}

// Filter-hidden sessions are withheld from every device path: the index (so
// synced iPhones prune their copies), fetches and timeline tails (answered
// like a removed session), and the event / summary fan-out. A subagent child
// of a hidden parent is withheld transitively even though its own flag is
// false.
@Test func hostWithholdsFilterHiddenSessionsFromDevices() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = RelayHarness()
    try await harness.repository.replaceSession(sampleDetail("a", items: 1, at: base))
    var ghost = sampleDetail("ghost", items: 1, at: base)
    ghost = SessionDetail(
        summary: ghost.summary.withHiddenByFilter(true),
        turns: ghost.turns,
        timeline: ghost.timeline
    )
    try await harness.repository.replaceSession(ghost)
    let child = sampleDetail("ghost-child", items: 1, at: base)
    try await harness.repository.replaceSession(SessionDetail(
        summary: SessionSummary(
            id: child.summary.id, agent: .codexSubagent, title: "child",
            lifecycle: .running, phase: .thinking,
            startedAt: base, updatedAt: base, lastActivityAt: base,
            lineage: SessionLineage(parentSessionID: SessionID("ghost"))
        ),
        turns: child.turns,
        timeline: child.timeline
    ))
    let device = try await harness.connect()

    // Index: only the visible session.
    try await harness.sync(via: device, requestID: RequestID("r1"))
    let indexSeen = try await harness.collect(from: device) { $0.kind == .sessionIndex }
    let entries = try #require(RelayFrameReduction.assembleIndex(parts: indexSeen.map(\.payload).filter { $0.kind == .sessionIndex }))
    #expect(entries.map(\.summary.id) == [SessionID("a")])

    // Fetch: hidden ids answer like removed ones; the child transitively.
    try await harness.request(RemoteSessionPayload(
        kind: .fetchSession, requestID: RequestID("f"),
        sessionIDs: [SessionID("a"), SessionID("ghost"), SessionID("ghost-child")]
    ), via: device)
    let fetched = try await harness.collect(from: device) { $0.kind == .sessionRemoved && $0.sessionIDs == [SessionID("ghost-child")] }
    #expect(fetched.map(\.payload).filter { $0.kind == .sessionFull }.count == 1)
    let removedIDs = fetched.map(\.payload).filter { $0.kind == .sessionRemoved }.compactMap(\.sessionIDs)
    #expect(removedIDs == [[SessionID("ghost")], [SessionID("ghost-child")]])

    // Timeline tail of a hidden session: removed as well.
    try await harness.request(RemoteSessionPayload(
        kind: .fetchTimelineSince, requestID: RequestID("t"),
        sessionIDs: [SessionID("ghost")], since: base
    ), via: device)
    let tail = try await harness.collect(from: device) { $0.kind == .sessionRemoved }
    #expect(tail.last?.payload.sessionIDs == [SessionID("ghost")])

    // Event fan-out: the hidden session's later updates never leave the host.
    let ghostEvent = AgentIngressEvent(eventID: EventID("ge"), sessionID: SessionID("ghost"), agent: .codex, occurredAt: base.addingTimeInterval(10), phase: .executing)
    let visibleEvent = AgentIngressEvent(eventID: EventID("ve"), sessionID: SessionID("a"), agent: .codex, occurredAt: base.addingTimeInterval(11), phase: .executing)
    harness.hub.publish(ghostEvent)
    harness.hub.publish(visibleEvent)
    let messages = try await harness.collect(from: device) { $0.kind == .sessionMessage }
    #expect(messages.last?.payload.events?.map(\.eventID) == [EventID("ve")])

    // Summary fan-out: same gate.
    await harness.service.summariesChanged([SessionID("ghost"), SessionID("a")])
    let info = try await harness.collect(from: device) { $0.kind == .sessionInfo }
    #expect(info.last?.payload.summaries?.map(\.id) == [SessionID("a")])
    await harness.stop()
}

@Test func hostAnswersUsageAndPlanUsageRequestsFromAnIPhone() async throws {
    let now = Date(timeIntervalSince1970: 1_788_616_800)
    let report = UsageReport(
        since: UsageDay(year: 2026, month: 8, day: 31), until: UsageDay(year: 2026, month: 9, day: 5), generatedAt: now,
        totals: UsageSlice(tokens: UsageTokens(input: 10), costUSD: 1.5, calls: 1, sessions: 1, turns: 1),
        byAgent: [], byProject: [], byModel: [], byDay: [], byWeek: [], byMonth: [],
        trendUnit: .day, trend: [], comparison: nil,
        pricing: UsagePricingStatus(source: .builtin, fetchedAt: nil, modelCount: 1),
        scan: UsageScanStatus(scannedFiles: 1, pendingFiles: 0, lastScanAt: now, isScanning: false)
    )
    let state = PlanUsageState(accounts: [PlanUsageAccount(id: .claude, provider: .claude, enabled: true, status: .ok, limits: [PlanUsageLimit(window: .session, usedPercent: 42)])], generatedAt: now)
    let settings = DaemonSettings(planUsage: PlanUsageSettings(enabledAccounts: [.claude], percentStyle: .remaining))
    let presets = PresetLog()
    let harness = RelayHarness(
        usageProvider: { preset in
            presets.append(preset)
            if preset == .thisMonth { throw DaemonServiceError.unavailable("usage") }
            return report
        },
        planUsageProvider: { (state, settings) }
    )
    let device = try await harness.connectAndSync()

    try await harness.request(RemoteSessionPayload(kind: .fetchUsage, requestID: RequestID("u1"), usageRange: .thisWeek), via: device)
    var seen = try await harness.collect(from: device) { $0.kind == .usageReport }
    #expect(seen.last?.payload.requestID == RequestID("u1"))
    #expect(seen.last?.payload.usage == report)
    #expect(presets.snapshot == [.thisWeek])

    // The daemon could not build the report: the answer still comes, empty.
    try await harness.request(RemoteSessionPayload(kind: .fetchUsage, requestID: RequestID("u2"), usageRange: .thisMonth), via: device)
    seen = try await harness.collect(from: device) { $0.kind == .usageReport }
    #expect(seen.last?.payload.requestID == RequestID("u2") && seen.last?.payload.usage == nil)

    // A request without a preset is dropped, the next one still answered.
    try await harness.request(RemoteSessionPayload(kind: .fetchUsage, requestID: RequestID("u3")), via: device)
    try await harness.request(RemoteSessionPayload(kind: .fetchPlanUsage, requestID: RequestID("p1")), via: device)
    seen = try await harness.collect(from: device) { $0.kind == .planUsage }
    #expect(!seen.contains { $0.payload.requestID == RequestID("u3") })
    #expect(seen.last?.payload.planUsage == state && seen.last?.payload.settings == settings)
    await harness.stop()
}

private final class PresetLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UsageRangePreset] = []
    func append(_ value: UsageRangePreset) { lock.lock(); values.append(value); lock.unlock() }
    var snapshot: [UsageRangePreset] { lock.lock(); defer { lock.unlock() }; return values }
}

@Test func hostInterleavesSmallAnswersWithBulkSessionSends() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let now = Date(timeIntervalSince1970: 1_788_616_800)
    let report = UsageReport(
        since: UsageDay(year: 2026, month: 9, day: 7), until: UsageDay(year: 2026, month: 9, day: 8), generatedAt: now,
        totals: UsageSlice(tokens: UsageTokens(input: 1), costUSD: 0.1, calls: 1, sessions: 1, turns: 1),
        byAgent: [], byProject: [], byModel: [],
        pricing: UsagePricingStatus(source: .builtin, modelCount: 1),
        scan: UsageScanStatus(scannedFiles: 1, pendingFiles: 0, isScanning: false)
    )
    let harness = RelayHarness(usageProvider: { _ in report })
    for id in ["a", "b", "c", "d"] {
        try await harness.repository.replaceSession(sampleDetail(id, items: 40, at: base))
    }
    let device = try await harness.connectAndSync()

    // Four whole sessions queued, then a Usage ask right behind them: the
    // answer must not wait for the last session.
    try await harness.request(RemoteSessionPayload(kind: .fetchSession, requestID: RequestID("f"), sessionIDs: ["a", "b", "c", "d"].map(SessionID.init)), via: device)
    try await harness.request(RemoteSessionPayload(kind: .fetchUsage, requestID: RequestID("u"), usageRange: .today), via: device)
    let seen = try await harness.collect(from: device) { payload in
        payload.kind == .sessionFull && payload.session?.summary.id == SessionID("d")
    }
    let kinds = seen.map(\.payload.kind)
    let usageAt = try #require(kinds.firstIndex(of: .usageReport))
    let lastSessionAt = try #require(kinds.lastIndex(of: .sessionFull))
    #expect(usageAt < lastSessionAt)
    #expect(kinds.filter { $0 == .sessionFull }.count == 4)
    await harness.stop()
}

// MARK: - The Relay as an adversary

// The nonce counts as disclosed the moment the reveal is attempted: a Relay
// that takes it and answers with an error must not get the session back in
// the state where it still takes a device.
@Test func aFailedRevealEndsThePairingSessionForGood() async throws {
    let harness = RelayHarness(preregisterDevice: false)
    await harness.start()
    await harness.rest.refuseReveals(true)

    let started = try await harness.service.startPairing()
    await harness.rest.submit(sessionID: started.sessionID, device: harness.pairedDevice)
    await harness.link.sendPairingDeviceToHost(RelayPairingDeviceNotice(
        sessionID: started.sessionID, deviceID: harness.deviceID, deviceName: "Test iPhone", devicePublicKey: harness.deviceKeys.publicKey
    ))
    for _ in 0..<300 where await harness.service.pairingSession() != nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    // The Relay read the nonce; the session is gone, cancelled at the Relay,
    // and never showed an SAS.
    #expect(await harness.rest.disclosedNonces[started.sessionID] != nil)
    #expect(await harness.service.pairingSession() == nil)
    #expect(await harness.rest.cancelRequests == [started.sessionID])

    // Another identity for the same session — now that the nonce is known —
    // finds nothing to bind to.
    let other = RelayCryptography.makeKeyPair()
    await harness.link.sendPairingDeviceToHost(RelayPairingDeviceNotice(
        sessionID: started.sessionID, deviceID: DeviceID("device-other-0002"), deviceName: "Other iPhone", devicePublicKey: other.publicKey
    ))
    try await Task.sleep(for: .milliseconds(100))
    #expect(await harness.service.pairingSession() == nil)
    await #expect(throws: RelayPairingError.self) { try await harness.service.decidePairing(approved: true) }
    let persisted = RelayHostStateStore(path: harness.statePath)
    #expect(persisted.verifiedKey(for: harness.deviceID) == nil)
    #expect(persisted.verifiedKey(for: DeviceID("device-other-0002")) == nil)

    // The next code is a new session with a new nonce.
    await harness.rest.refuseReveals(false)
    let next = try await harness.service.startPairing()
    #expect(next.sessionID != started.sessionID)
    try await harness.submitDevice()
    let nonce = try #require(await harness.rest.disclosedNonces[next.sessionID])
    #expect(nonce != (await harness.rest.disclosedNonces[started.sessionID]))
    await harness.stop()
}

@Test func aPairingSessionTakesOneDeviceOnly() async throws {
    let harness = RelayHarness(preregisterDevice: false)
    await harness.start()
    let started = try await harness.service.startPairing()
    try await harness.submitDevice()
    let pending = try #require(await harness.service.pairingSession()?.pending)

    // A second `pairing_device` for the session whose nonce is out changes
    // nothing: same iPhone, same digits, and Match pins the first key.
    let other = RelayCryptography.makeKeyPair()
    await harness.link.sendPairingDeviceToHost(RelayPairingDeviceNotice(
        sessionID: started.sessionID, deviceID: DeviceID("device-other-0002"), deviceName: "Other iPhone", devicePublicKey: other.publicKey
    ))
    try await Task.sleep(for: .milliseconds(100))
    #expect(await harness.service.pairingSession()?.pending == pending)
    _ = try await harness.service.decidePairing(approved: true)
    let persisted = RelayHostStateStore(path: harness.statePath)
    #expect(persisted.verifiedKey(for: harness.deviceID) == harness.deviceKeys.publicKey)
    #expect(persisted.verifiedKey(for: DeviceID("device-other-0002")) == nil)
    await harness.stop()
}

// Revocation is this Mac's own record: it holds whatever the Relay lists
// afterwards, and across a daemon restart.
@Test func aRevocationHoldsAgainstTheRelayAndAcrossARestart() async throws {
    let harness = RelayHarness()
    let base = Date()
    try await harness.repository.replaceSession(sampleDetail("a", items: 1, at: base))
    let device = try await harness.connectAndSync()

    try await harness.service.revoke(deviceID: harness.deviceID)
    #expect(await harness.rest.revokeRequests == [harness.deviceID])
    var persisted = RelayHostStateStore(path: harness.statePath)
    #expect(persisted.verifiedKey(for: harness.deviceID) == nil)
    #expect(persisted.revokedAt(for: harness.deviceID) != nil)

    // The Relay lists the device as active again, with the key it always had.
    await harness.rest.pair(harness.pairedDevice)
    await harness.service.refreshDevices()
    let listed = try #require(await harness.service.status().devices.first)
    #expect(listed.revokedAt != nil)
    #expect(!listed.keyVerified)
    // …and is told to revoke it again.
    #expect(await harness.rest.revokeRequests == [harness.deviceID, harness.deviceID])
    #expect(await harness.rest.pairedDevices.first?.revokedAt != nil)

    // The revoked iPhone cannot open a session, hears no push, gets no alert.
    await harness.rest.pair(harness.pairedDevice)
    let sent = await harness.link.hostSent.count
    try await harness.sendOpening(via: device)
    try await harness.request(RemoteSessionPayload(kind: .fetchSession, requestID: RequestID("f"), sessionIDs: [SessionID("a")]), via: device)
    let event = AgentIngressEvent(
        eventID: EventID("turn-end"), sessionID: SessionID("a"), agent: .codex, occurredAt: Date(),
        timelineItem: TimelineItem(
            id: TimelineItemID("a-end"), sessionID: SessionID("a"), occurredAt: Date(),
            payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed, message: "Shipped."))
        )
    )
    _ = try await harness.repository.apply(event)
    harness.hub.publish(event)
    try await Task.sleep(for: .milliseconds(200))
    #expect(await harness.link.hostSent.count == sent)
    #expect(await harness.rest.sentNotifications.isEmpty)
    await harness.stop()

    // The daemon restarts while the Relay still lists the device as active.
    await harness.rest.pair(harness.pairedDevice)
    let restarted = RelayHarness(restarting: harness)
    let again = try await restarted.connect()
    let relisted = try #require(await restarted.service.status().devices.first)
    #expect(relisted.revokedAt != nil)
    #expect(!relisted.keyVerified)
    try await restarted.sendOpening(via: again)
    try await Task.sleep(for: .milliseconds(200))
    #expect(await restarted.link.hostSent.isEmpty)
    persisted = RelayHostStateStore(path: restarted.statePath)
    #expect(persisted.verifiedKey(for: restarted.deviceID) == nil)
    await restarted.stop()
}

@Test func aRevocationTheRelayRefusesStillHoldsOnThisMac() async throws {
    let harness = RelayHarness()
    _ = try await harness.connectAndSync()
    await harness.rest.refuseRevocations(true)

    // The Relay answers the revoke with an error: the Mac's own revocation
    // stands, the row says Revoked, and the failure is on the status.
    try await harness.service.revoke(deviceID: harness.deviceID)
    var status = await harness.service.status()
    #expect(status.devices.first?.revokedAt != nil)
    #expect(status.devices.first?.keyVerified == false)
    #expect(status.lastError?.contains("revocation") == true)
    #expect(await harness.rest.pairedDevices.first?.revokedAt == nil)
    #expect(RelayHostStateStore(path: harness.statePath).verifiedKey(for: harness.deviceID) == nil)

    // Once the Relay takes it, the next refresh delivers it.
    await harness.rest.refuseRevocations(false)
    await harness.service.refreshDevices()
    status = await harness.service.status()
    #expect(status.lastError == nil)
    #expect(await harness.rest.pairedDevices.first?.revokedAt != nil)
    await harness.stop()
}

@Test func aRevocationTheRelayReportsBecomesThisMacsOwn() async throws {
    let harness = RelayHarness()
    _ = try await harness.connectAndSync()

    // A device revoked before this Mac recorded revocations: the Relay says
    // so, for the very key the Mac pinned. The Mac adopts it…
    try await harness.rest.revoke(hostID: try harness.hostCredentials.hostID, deviceID: harness.deviceID, hostSecret: "")
    await harness.service.refreshDevices()
    let persisted = RelayHostStateStore(path: harness.statePath)
    #expect(persisted.verifiedKey(for: harness.deviceID) == nil)
    #expect(persisted.revokedAt(for: harness.deviceID) != nil)

    // …so the Relay taking it back later changes nothing.
    await harness.rest.pair(harness.pairedDevice)
    await harness.service.refreshDevices()
    #expect(await harness.service.status().devices.first?.revokedAt != nil)
    await harness.stop()
}

@Test func onlyPairingAgainLiftsARevocation() async throws {
    let harness = RelayHarness()
    let device = try await harness.connectAndSync()
    try await harness.service.revoke(deviceID: harness.deviceID)
    #expect(RelayHostStateStore(path: harness.statePath).revokedAt(for: harness.deviceID) != nil)

    // Mac shows a code, the same iPhone submits itself, the Mac presses Match.
    _ = try await harness.service.startPairing()
    try await harness.submitDevice()
    _ = try await harness.service.decidePairing(approved: true)
    let persisted = RelayHostStateStore(path: harness.statePath)
    #expect(persisted.verifiedKey(for: harness.deviceID) == harness.deviceKeys.publicKey)
    #expect(persisted.revokedAt(for: harness.deviceID) == nil)
    let listed = try #require(await harness.service.status().devices.first)
    #expect(listed.revokedAt == nil)
    #expect(listed.keyVerified)
    // The refresh after Match did not send the old revocation again.
    #expect(await harness.rest.revokeRequests == [harness.deviceID])

    try await harness.sync(via: device, requestID: RequestID("back"))
    let seen = try await harness.collect(from: device) { $0.kind == .sessionIndex }
    #expect(seen.last?.payload.requestID == RequestID("back"))
    await harness.stop()
}

@Test func aMatchTheRelayRefusesLeavesTrustAsItWas() async throws {
    let harness = RelayHarness()
    _ = try await harness.connectAndSync()
    try await harness.service.revoke(deviceID: harness.deviceID)
    let revokedAt = try #require(RelayHostStateStore(path: harness.statePath).revokedAt(for: harness.deviceID))

    _ = try await harness.service.startPairing()
    try await harness.submitDevice()
    // The Relay drops the session before the decision arrives.
    let sessionID = try #require(await harness.rest.latestSession?.sessionID)
    try await harness.rest.cancelPairing(hostID: try harness.hostCredentials.hostID, sessionID: sessionID, hostSecret: "")
    await #expect(throws: RelayClientError.self) { try await harness.service.decidePairing(approved: true) }

    let persisted = RelayHostStateStore(path: harness.statePath)
    #expect(persisted.verifiedKey(for: harness.deviceID) == nil)
    #expect(persisted.revokedAt(for: harness.deviceID) == revokedAt)
    await harness.stop()
}

// A request counts once, in the session it was sealed for, and only moving
// forward: the Relay repeating or reordering frames changes nothing.
@Test func repeatedAndOutOfOrderRequestsAreDropped() async throws {
    let presets = PresetLog()
    let harness = RelayHarness(usageProvider: { preset in
        presets.append(preset)
        throw DaemonServiceError.unavailable("usage")
    })
    let device = try await harness.connectAndSync()

    let first = try harness.seal(RemoteSessionPayload(kind: .fetchUsage, requestID: RequestID("u1"), usageRange: .today))
    let second = try harness.seal(RemoteSessionPayload(kind: .fetchUsage, requestID: RequestID("u2"), usageRange: .thisWeek))
    // The later one arrives first: the earlier one is then behind the cursor.
    try await device.send(second)
    _ = try await harness.collect(from: device) { $0.kind == .usageReport && $0.requestID == RequestID("u2") }
    try await device.send(first)
    // The same frame again.
    try await device.send(second)
    try await Task.sleep(for: .milliseconds(200))
    #expect(presets.snapshot == [.thisWeek])

    // The session goes on from there.
    try await harness.request(RemoteSessionPayload(kind: .fetchUsage, requestID: RequestID("u3"), usageRange: .thisMonth), via: device)
    _ = try await harness.collect(from: device) { $0.kind == .usageReport && $0.requestID == RequestID("u3") }
    #expect(presets.snapshot == [.thisWeek, .thisMonth])
    await harness.stop()
}

@Test func aRequestOpensOnlyInTheChannelSessionItWasSealedFor() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = RelayHarness()
    let needsReview = sampleDetail("a", items: 1, at: base)
    try await harness.repository.replaceSession(SessionDetail(
        summary: needsReview.summary.withReviewState(needsAttention: true, needsReview: true),
        turns: needsReview.turns, timeline: needsReview.timeline
    ))
    let device = try await harness.connectAndSync()

    // Kept from the first session, never delivered: a review of `a`.
    let kept = try harness.seal(RemoteSessionPayload(kind: .sessionReviewed, sessionIDs: [SessionID("a")]), sequence: 1_000)
    // The same request sealed with the handshake key instead of a session's.
    let outside = try RelayCryptography.seal(
        RemoteSessionPayload(kind: .sessionReviewed, sessionIDs: [SessionID("a")]),
        hostID: try harness.hostCredentials.hostID, deviceID: harness.deviceID, sequence: 2_000, kind: .request,
        key: try harness.handshakeKey
    )

    // The iPhone opens its next session; both frames arrive in it.
    try await harness.sync(via: device)
    _ = try await harness.collect(from: device) { $0.kind == .sessionIndex }
    try await device.send(kept)
    try await device.send(outside)
    try await Task.sleep(for: .milliseconds(200))
    #expect(try await harness.repository.sessionSummary(id: SessionID("a"))?.needsReview == true)

    // The session itself still works.
    try await harness.request(RemoteSessionPayload(kind: .sessionReviewed, sessionIDs: [SessionID("a")]), via: device)
    for _ in 0..<300 where try await harness.repository.sessionSummary(id: SessionID("a"))?.needsReview == true {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await harness.repository.sessionSummary(id: SessionID("a"))?.needsReview == false)
    await harness.stop()
}

@Test func aRevocationMadeWhileTheRelayAnswersAMatchStands() async throws {
    let harness = RelayHarness()
    _ = try await harness.connectAndSync()

    // The trusted iPhone pairs again with a new key; the Mac presses Match
    // and the Relay sits on the decision.
    let started = try await harness.service.startPairing()
    let newKeys = RelayCryptography.makeKeyPair()
    await harness.rest.submit(sessionID: started.sessionID, device: PairedDevice(
        id: harness.deviceID, name: "Test iPhone", publicKey: newKeys.publicKey, pairedAt: Date()
    ))
    await harness.link.sendPairingDeviceToHost(RelayPairingDeviceNotice(
        sessionID: started.sessionID, deviceID: harness.deviceID, deviceName: "Test iPhone", devicePublicKey: newKeys.publicKey
    ))
    for _ in 0..<300 where await harness.service.pairingSession()?.pending == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    await harness.rest.holdDecisions(true)
    let service = harness.service
    let decision = Task { try await service.decidePairing(approved: true) }
    for _ in 0..<300 where await !harness.rest.isHoldingDecision {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(RelayHostStateStore(path: harness.statePath).verifiedKey(for: harness.deviceID) == newKeys.publicKey)

    // Meanwhile the Mac revokes the iPhone — and then the Relay refuses the
    // decision. Undoing the Match must not undo the revocation.
    try await harness.service.revoke(deviceID: harness.deviceID)
    await harness.rest.releaseDecision(refusing: true)
    await #expect(throws: RelayClientError.self) { _ = try await decision.value }
    let persisted = RelayHostStateStore(path: harness.statePath)
    #expect(persisted.verifiedKey(for: harness.deviceID) == nil)
    #expect(persisted.revokedAt(for: harness.deviceID) != nil)
    await harness.stop()
}

// What happens after the index was read still reaches an iPhone whose
// session is only just opening: the push waits behind the index.
@Test func pushesMadeWhileASessionOpensFollowItsIndex() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = RelayHarness(usageProvider: { _ in
        try await Task.sleep(for: .milliseconds(300))
        throw DaemonServiceError.unavailable("usage")
    })
    try await harness.repository.replaceSession(sampleDetail("a", items: 1, at: base))
    let device = try await harness.connectAndSync()

    // The send loop is busy with a slow answer when the iPhone opens its
    // next session; an event lands before that session's index goes out.
    try await harness.request(RemoteSessionPayload(kind: .fetchUsage, requestID: RequestID("slow"), usageRange: .today), via: device)
    try await Task.sleep(for: .milliseconds(50))
    let ephemeral = try await harness.sendOpening(via: device, requestID: RequestID("again"))
    try await Task.sleep(for: .milliseconds(50))
    let event = AgentIngressEvent(eventID: EventID("e1"), sessionID: SessionID("a"), agent: .codex, occurredAt: base.addingTimeInterval(10), phase: .executing)
    harness.hub.publish(event)

    try await harness.finishOpening(ephemeral, requestID: RequestID("again"), via: device)
    let seen = try await harness.collect(from: device) { $0.kind == .sessionMessage }
    #expect(seen.map(\.payload.kind) == [.sessionIndex, .sessionMessage])
    #expect(seen.last?.payload.events?.map(\.eventID) == [EventID("e1")])
    await harness.stop()
}

@Test func theOpeningOfTheCurrentSessionSeenAgainChangesNothing() async throws {
    let presets = PresetLog()
    let harness = RelayHarness(usageProvider: { preset in
        presets.append(preset)
        throw DaemonServiceError.unavailable("usage")
    })
    let device = try await harness.connectAndSync()
    let opening = try #require(await harness.link.deviceSent.last)
    let sent = await harness.link.hostSent.count

    // The Relay delivers the same `sync_index` once more.
    try await device.send(opening)
    try await Task.sleep(for: .milliseconds(150))
    #expect(await harness.link.hostSent.count == sent)

    // The session it opened is still the one in use.
    try await harness.request(RemoteSessionPayload(kind: .fetchUsage, requestID: RequestID("u"), usageRange: .today), via: device)
    _ = try await harness.collect(from: device) { $0.kind == .usageReport }
    #expect(presets.snapshot == [.today])
    await harness.stop()
}

// A cursor the Relay could not hold must not be followed: doing so would
// use up the channel's sequences, and the next reservation would overflow.
@Test func aSequenceTheRelayCouldNotHoldIsRefused() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = RelayHarness()
    try await harness.repository.replaceSession(sampleDetail("a", items: 1, at: base))
    let device = try await harness.connectAndSync()
    let cursor = RelayHostStateStore(path: harness.statePath).current(for: harness.deviceID)

    await harness.link.sendErrorToHost(RelayErrorMessage(code: "non_monotonic_sequence", sequence: 2, lastSequence: .max, deviceID: harness.deviceID))
    try await Task.sleep(for: .milliseconds(100))
    #expect(RelayHostStateStore(path: harness.statePath).current(for: harness.deviceID) == cursor)

    // The channel carries on from its own cursor.
    let event = AgentIngressEvent(eventID: EventID("e1"), sessionID: SessionID("a"), agent: .codex, occurredAt: base.addingTimeInterval(10), phase: .executing)
    harness.hub.publish(event)
    let seen = try await harness.collect(from: device) { $0.kind == .sessionMessage }
    #expect(seen.last?.frame.sequence == cursor + 1)
    await harness.stop()
}

@Test func sequencesStayWithinWhatTheRelayCanCount() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("relay-host-state.json").path
    let device = DeviceID("device-test-0001")
    var store = RelayHostStateStore(path: path)

    #expect(throws: RelayHostStateError.self) { try store.advance(device, past: .max) }
    #expect(store.current(for: device) == 0)

    // The last sequences of the range are handed out, then no more.
    try store.advance(device, past: RelayHostStateStore.highestSequence - 1)
    #expect(throws: RelayHostStateError.self) { _ = try store.reserve(for: device, count: 2) }
    #expect(try store.reserve(for: device, count: 1) == RelayHostStateStore.highestSequence)
    #expect(throws: RelayHostStateError.self) { _ = try store.reserve(for: device, count: 1) }
    #expect(RelayHostStateStore(path: path).current(for: device) == RelayHostStateStore.highestSequence)
}

@Test func revocationsAndPinsSurviveAsOneRecord() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("relay-host-state.json").path
    let device = DeviceID("device-test-0001")
    let key = Data(repeating: 7, count: 32)
    let revokedAt = Date(timeIntervalSince1970: 1_700_000_000)

    var store = RelayHostStateStore(path: path)
    try store.setVerifiedKey(key, for: device)
    #expect(store.verifiedDeviceIDs == [device])
    try store.revoke(device, at: revokedAt)
    // Revoking again keeps the first date; the pin is gone either way.
    try store.revoke(device, at: revokedAt.addingTimeInterval(60))
    var reread = RelayHostStateStore(path: path)
    #expect(reread.verifiedKey(for: device) == nil)
    #expect(reread.verifiedDeviceIDs.isEmpty)
    #expect(reread.revokedAt(for: device) == revokedAt)

    // A Match pins again and lifts the mark; Remove forgets both.
    try reread.setVerifiedKey(key, for: device)
    #expect(RelayHostStateStore(path: path).revokedAt(for: device) == nil)
    #expect(RelayHostStateStore(path: path).verifiedKey(for: device) == key)
    try reread.revoke(device, at: revokedAt)
    try reread.forget(device)
    #expect(RelayHostStateStore(path: path).revokedAt(for: device) == nil)
    #expect(RelayHostStateStore(path: path).verifiedKey(for: device) == nil)

    // A state file from before revocations were recorded keeps its pins and sequences.
    let legacy = #"{"channelSequences":{"device-test-0001":12},"verifiedDeviceKeys":{"device-test-0001":"BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc="}}"#
    try Data(legacy.utf8).write(to: URL(fileURLWithPath: path))
    let upgraded = RelayHostStateStore(path: path)
    #expect(upgraded.current(for: device) == 12)
    #expect(upgraded.verifiedKey(for: device) == key)
    #expect(upgraded.revokedAt(for: device) == nil)
}
