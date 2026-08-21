import AgentStatusCore
import AgentStatusDaemonRuntime
import AgentStatusRemote
import AgentStatusTransport
import Foundation
import Testing

/// Drives `RelayHostService` through an in-memory relay: a device end sends
/// sealed requests and reads the sealed answers, the hub publishes events.
private struct RelayHarness {
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

    init(healthProvider: @escaping RelayHostService.HealthProvider = { nil }, preregisterDevice: Bool = true) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        statePath = directory.appendingPathComponent("relay-host-state.json").path
        rest = InMemoryRelayHostREST(devices: preregisterDevice ? [
            PairedDevice(id: deviceID, name: "Test iPhone", publicKey: deviceKeys.publicKey, pairedAt: Date()),
        ] : [])
        let connections = connections
        service = RelayHostService(
            repository: repository,
            subscriptions: hub,
            relayURL: relayURL,
            credentialStore: credentialStore,
            sequenceStatePath: statePath,
            transportFactory: link,
            rest: rest,
            hostName: { "Test Mac" },
            healthProvider: healthProvider,
            onConnectionChange: { connected in connections.append(connected) },
            logger: { _ in },
            eventCoalesceInterval: .milliseconds(20),
            reconnectDelay: .milliseconds(50),
            deviceRefreshInterval: .seconds(60),
            healthInterval: .seconds(60)
        )
    }

    var hostCredentials: RelayHostCredentials {
        get throws { try #require(try credentialStore.load()) }
    }

    /// Starts the host and opens the device end.
    func connect() async throws -> any RelayFrameTransport {
        await service.start()
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
    let persisted = RelayHostSequenceStore(path: harness.statePath)
    #expect(persisted.current(for: harness.deviceID) == 2)
    await harness.service.stop()
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
    await harness.service.stop()
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
    await harness.service.stop()
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
    await harness.service.stop()
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
    await harness.service.stop()
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
    await harness.service.stop()
}

@Test func hostLooksUpAJustPairedDeviceBeforeDroppingItsFirstRequest() async throws {
    let harness = RelayHarness(preregisterDevice: false)
    await harness.service.start()
    let device = harness.link.makeDeviceTransport(harness.deviceID)
    try await device.connect(hostID: try harness.hostCredentials.hostID, role: .device(harness.deviceID), token: "token")
    _ = try await device.next() // presence

    // Paired after the host's last device refresh (the 10 s timer has not
    // fired): the first request must still be answered, not logged and dropped.
    await harness.rest.pair(PairedDevice(id: harness.deviceID, name: "New iPhone", publicKey: harness.deviceKeys.publicKey, pairedAt: Date()))
    try await harness.request(RemoteSessionPayload(kind: .syncIndex, requestID: RequestID("first")), via: device)
    let seen = try await harness.collect(from: device) { $0.kind == .sessionIndex }
    #expect(seen.last?.payload.requestID == RequestID("first"))
    await harness.service.stop()
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
    #expect(harness.connections.snapshot == [true, false, true])
    // A push after reconnect goes nowhere until the device re-indexes.
    let sent = await harness.link.hostSent.count
    harness.hub.publish(AgentIngressEvent(eventID: EventID("e"), sessionID: SessionID("x"), agent: .codex, occurredAt: Date(), phase: .thinking))
    try await Task.sleep(for: .milliseconds(100))
    #expect(await harness.link.hostSent.count == sent)
    await harness.service.stop()
}

@Test func hostCreatesPairingOffersAndRevokesDevices() async throws {
    let harness = RelayHarness()
    _ = try await harness.connect()
    let offer = try await harness.service.createPairingOffer()
    #expect(offer.hostID == (try harness.hostCredentials.hostID))
    #expect(offer.hostName == "Test Mac")
    #expect(offer.relayURL == harness.relayURL)
    #expect(await harness.rest.offers.count == 1)

    try await harness.service.revoke(deviceID: harness.deviceID)
    let status = await harness.service.status()
    #expect(status.devices.first?.revokedAt != nil)
    await harness.service.stop()
}
