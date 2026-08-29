import Core
import DaemonRuntime
import Remote
import Transport
import Foundation
import Testing

/// Drives `RelayHostService` through an in-memory relay: a device end sends
/// sealed requests and reads the sealed answers, the hub publishes events.
/// The host runs as a held task; `stop()` is cancellation, like the daemon's
/// ServiceGroup shutdown.
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
    let credentialStore = InMemoryRelayHostCredentialStore()
    let statePath: String
    let service: RelayHostService
    let deviceID = DeviceID("device-test-0001")
    let deviceKeys = RelayCryptography.makeKeyPair()
    let relayURL = URL(string: "https://relay.example.test")!
    let connections = ConnectionLog()

    init(
        healthProvider: @escaping RelayHostService.HealthProvider = { nil },
        preregisterDevice: Bool = true,
        pinDeviceKey: Bool = true,
        pairingCodeLifetime: Duration = .seconds(5 * 60),
        pairingDecisionTimeout: Duration = .seconds(60)
    ) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        statePath = directory.appendingPathComponent("relay-host-state.json").path
        rest = InMemoryRelayHostREST(devices: preregisterDevice ? [
            PairedDevice(id: deviceID, name: "Test iPhone", publicKey: deviceKeys.publicKey, pairedAt: Date()),
        ] : [])
        if preregisterDevice, pinDeviceKey {
            // A device this daemon verified in an earlier life: its key is pinned.
            var state = RelayHostStateStore(path: statePath)
            try? state.setVerifiedKey(deviceKeys.publicKey, for: deviceID)
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

    func request(_ payload: RemoteSessionPayload, via device: any RelayFrameTransport, sequence: UInt64 = 1) async throws {
        let frame = try RelayCryptography.seal(
            payload,
            hostID: try hostCredentials.hostID,
            deviceID: deviceID,
            sequence: sequence,
            kind: .request,
            privateKey: deviceKeys.privateKey,
            peerPublicKey: try hostCredentials.keyPair.publicKey
        )
        try await device.send(frame)
    }

    /// Reads sealed `data` frames until `predicate` accepts one; returns every payload seen.
    func collect(
        from device: any RelayFrameTransport,
        until predicate: (RemoteSessionPayload) -> Bool
    ) async throws -> [(frame: RelayRoutingFrame, payload: RemoteSessionPayload)] {
        var seen: [(RelayRoutingFrame, RemoteSessionPayload)] = []
        for _ in 0..<200 {
            let message = try await withTimeout(seconds: 5) { try await device.next() }
            guard case let .frame(frame) = message else { continue }
            let payload = try RelayCryptography.open(
                frame,
                privateKey: deviceKeys.privateKey,
                peerPublicKey: try hostCredentials.keyPair.publicKey
            )
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
        timeline: (0..<items).map { index in
            TimelineItem(
                id: TimelineItemID("\(id)-item-\(index)"), sessionID: sessionID,
                occurredAt: base.addingTimeInterval(Double(index)),
                payload: .message(MessageTimelinePayload(role: .assistant, text: "line \(index)"))
            )
        }
    )
}

@Test func hostRegistersOnceAndAnswersSyncIndexWithHealth() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let health = DaemonHealth(daemonVersion: "t", executableHash: "h", uptimeSeconds: 1, activeSessionCount: 1, retainedSessionCount: 2, socketPath: "/s", relayConnected: true)
    let harness = RelayHarness(healthProvider: { health })
    try await harness.repository.replaceSession(sampleDetail("a", items: 3, at: base))
    try await harness.repository.replaceSession(sampleDetail("b", items: 0, at: base.addingTimeInterval(-100)))
    let device = try await harness.connect()

    #expect(harness.connections.snapshot == [true])
    let credentials = try harness.hostCredentials
    #expect(await harness.rest.registered[credentials.hostID] == credentials.hostSecret)
    #expect(await harness.service.status().connected)

    try await harness.request(RemoteSessionPayload(kind: .syncIndex, requestID: RequestID("r1")), via: device)
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
    // Sequences are per device, start at 1, and are persisted before send.
    #expect(seen.map(\.frame.sequence) == [1, 2])
    let persisted = RelayHostStateStore(path: harness.statePath)
    #expect(persisted.current(for: harness.deviceID) == 2)
    await harness.stop()
}

@Test func hostServesFullSessionsTimelineTailsAndRemovals() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = RelayHarness()
    try await harness.repository.replaceSession(sampleDetail("a", items: 5, at: base))
    let device = try await harness.connect()

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
    ), via: device, sequence: 2)
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

    try await harness.request(RemoteSessionPayload(kind: .syncIndex), via: device)
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

@Test func hostHealsASequenceCursorTheRelayReportsAsBehind() async throws {
    let harness = RelayHarness()
    let device = try await harness.connect()
    try await harness.request(RemoteSessionPayload(kind: .syncIndex), via: device)
    let first = try await harness.collect(from: device) { $0.kind == .sessionIndex }
    #expect(first.last?.frame.sequence == 1)

    await harness.link.sendErrorToHost(RelayErrorMessage(code: "non_monotonic_sequence", sequence: 1, lastSequence: 40, deviceID: harness.deviceID))
    try await Task.sleep(for: .milliseconds(50))
    // The device is no longer "active" until it re-indexes…
    let event = AgentIngressEvent(eventID: EventID("e"), sessionID: SessionID("x"), agent: .codex, occurredAt: Date(), phase: .thinking)
    harness.hub.publish(event)
    try await Task.sleep(for: .milliseconds(100))
    #expect(await harness.link.hostSent.count == 1)
    // …and the next answer continues past the relay's cursor.
    try await harness.request(RemoteSessionPayload(kind: .syncIndex), via: device, sequence: 2)
    let second = try await harness.collect(from: device) { $0.kind == .sessionIndex }
    #expect(second.last?.frame.sequence == 41)
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
    let device = try await harness.connect()
    try await harness.request(RemoteSessionPayload(kind: .syncIndex), via: device)
    _ = try await harness.collect(from: device) { $0.kind == .sessionIndex }

    try await harness.request(RemoteSessionPayload(kind: .sessionReviewed, sessionIDs: [SessionID("a")]), via: device, sequence: 2)
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

@Test func hostNudgesADeviceAfterTheRelayRejectsItsSequence() async throws {
    let health = DaemonHealth(daemonVersion: "t", executableHash: "h", uptimeSeconds: 1, activeSessionCount: 0, retainedSessionCount: 0, socketPath: "/s", relayConnected: true)
    let harness = RelayHarness(healthProvider: { health })
    let device = try await harness.connect()
    try await harness.request(RemoteSessionPayload(kind: .syncIndex), via: device)
    _ = try await harness.collect(from: device) { $0.kind == .health }

    // The Relay tells only the host; the device would never notice on its
    // own. The host heals its cursor and sends one frame past the hole so the
    // device sees a gap and re-indexes.
    await harness.link.sendErrorToHost(RelayErrorMessage(code: "non_monotonic_sequence", sequence: 2, lastSequence: 40, deviceID: harness.deviceID))
    let nudge = try await harness.collect(from: device) { $0.kind == .health }
    #expect(nudge.last?.frame.sequence == 41)
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
    try await harness.request(RemoteSessionPayload(kind: .syncIndex, requestID: RequestID("first")), via: device)
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
    // Relay swapped) stays unverified: its request goes unanswered.
    await harness.rest.pair(harness.pairedDevice)
    await harness.service.refreshDevices()
    #expect(await harness.service.status().devices.map(\.keyVerified) == [false])
    try await harness.request(RemoteSessionPayload(kind: .syncIndex, requestID: RequestID("untrusted")), via: device)
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
    let device = try await harness.connect()
    try await harness.request(RemoteSessionPayload(kind: .syncIndex), via: device)
    _ = try await harness.collect(from: device) { $0.kind == .sessionIndex }

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
    // A push after reconnect goes nowhere until the device re-indexes.
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
    // Remove deletes the record and forgets the pinned key.
    try await harness.service.remove(deviceID: harness.deviceID)
    #expect(await harness.service.status().devices.isEmpty)
    #expect(RelayHostStateStore(path: harness.statePath).verifiedKey(for: harness.deviceID) == nil)
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
