import AgentStatusCore
import AgentStatusRemote
import AgentStatusTransport
import Foundation
import Testing
@testable import AgentStatusIOSFeature

/// A daemon stand-in on the host end of an in-memory relay: answers the
/// device's requests from its own repository the way `RelayHostService` does,
/// and can push events / summaries / removals.
private actor FakeHost {
    let link: RelayInMemoryLink
    let repository = InMemorySessionRepository()
    let keys = RelayCryptography.makeKeyPair()
    let hostID: HostID
    let deviceID: DeviceID
    let devicePublicKey: Data
    private var transport: (any RelayFrameTransport)?
    private var sequence: UInt64 = 0
    private var loop: Task<Void, Never>?
    private(set) var requests: [RemoteSessionPayload] = []
    private(set) var reviewed: [SessionID] = []

    init(link: RelayInMemoryLink, hostID: HostID, deviceID: DeviceID, devicePublicKey: Data) {
        self.link = link
        self.hostID = hostID
        self.deviceID = deviceID
        self.devicePublicKey = devicePublicKey
    }

    func start() async throws {
        let transport = link.makeHostTransport()
        try await transport.connect(hostID: hostID, role: .host, token: "secret")
        self.transport = transport
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let message = try? await transport.next() else { return }
                await self.handle(message)
            }
        }
    }

    func stop() async {
        loop?.cancel()
        await transport?.disconnect()
        transport = nil
    }

    private func handle(_ message: RelayIncomingMessage) async {
        guard case let .frame(frame) = message, frame.kind == .request else { return }
        guard let payload = try? RelayCryptography.open(frame, privateKey: keys.privateKey, peerPublicKey: devicePublicKey) else { return }
        requests.append(payload)
        let now = Date()
        do {
            switch payload.kind {
            case .syncIndex:
                let entries = try await repository.sessionIndex(limit: 10_000)
                try await send(RelayPayloadBatcher.indexParts(entries, requestID: payload.requestID, generatedAt: now).map(\.prepared))
                let health = DaemonHealth(daemonVersion: "fake", executableHash: nil, uptimeSeconds: 1, activeSessionCount: entries.count, retainedSessionCount: entries.count, socketPath: "/s", relayConnected: true)
                try await send([RelayCryptography.prepare(RemoteSessionPayload(kind: .health, generatedAt: now, health: health))])
            case .fetchSession:
                for id in payload.sessionIDs ?? [] {
                    if let detail = try await repository.sessionDetail(id: id, cursor: nil, limit: 500) {
                        let full = SessionDetail(summary: detail.summary, turns: detail.turns, timeline: detail.timeline)
                        try await send(RelaySessionPartitioner.parts(for: full, kind: .sessionFull, requestID: payload.requestID, generatedAt: now).map(\.prepared))
                    } else {
                        try await send([RelayCryptography.prepare(RemoteSessionPayload(kind: .sessionRemoved, generatedAt: now, requestID: payload.requestID, sessionIDs: [id]))])
                    }
                }
            case .fetchTimelineSince:
                guard let id = payload.sessionIDs?.first, let since = payload.since else { return }
                if let detail = try await repository.timelineSince(id: id, since: since, cursor: nil, limit: 500) {
                    try await send(RelaySessionPartitioner.parts(for: detail, kind: .sessionTimeline, requestID: payload.requestID, generatedAt: now).map(\.prepared))
                }
            case .sessionReviewed:
                reviewed += payload.sessionIDs ?? []
            default:
                break
            }
        } catch {
            Issue.record("fake host failed: \(error)")
        }
    }

    func push(events: [AgentIngressEvent]) async throws {
        for event in events { _ = try await repository.apply(event) }
        try await send(RelayPayloadBatcher.eventBatches(events, generatedAt: Date()).map(\.prepared))
    }

    func push(summaries: [SessionSummary]) async throws {
        try await send(RelayPayloadBatcher.summaryBatches(summaries, generatedAt: Date()).map(\.prepared))
    }

    func pushRemoved(_ ids: [SessionID]) async throws {
        for id in ids { _ = try await repository.deleteSession(id: id) }
        try await send([RelayCryptography.prepare(RemoteSessionPayload(kind: .sessionRemoved, generatedAt: Date(), sessionIDs: ids))])
    }

    private func send(_ prepared: [RelayPreparedPayload]) async throws {
        guard let transport else { return }
        for payload in prepared {
            sequence += 1
            let frame = try RelayCryptography.seal(
                payload, hostID: hostID, deviceID: deviceID, sequence: sequence, kind: .data,
                privateKey: keys.privateKey, peerPublicKey: devicePublicKey
            )
            try await transport.send(frame)
        }
    }
}

private struct DeviceTransportFactory: RelayFrameTransportFactory {
    let link: RelayInMemoryLink
    let deviceID: DeviceID

    func makeTransport(baseURL: URL) -> any RelayFrameTransport {
        link.makeDeviceTransport(deviceID)
    }
}

@MainActor
private struct Harness {
    let link = RelayInMemoryLink()
    let hostID = HostID("host-test-000001")
    let deviceID = DeviceID("device-test-0001")
    let deviceKeys = RelayCryptography.makeKeyPair()
    let cache = InMemorySessionRepository()
    let settings: LocalSettings
    let host: FakeHost
    let pairingAPI: ScriptedPairingAPI
    let controller: RelayDeviceController

    init() {
        settings = LocalSettings(defaults: UserDefaults(suiteName: "relay-tests-\(UUID().uuidString)")!)
        host = FakeHost(link: link, hostID: hostID, deviceID: deviceID, devicePublicKey: deviceKeys.publicKey)
        pairingAPI = ScriptedPairingAPI(hostID: hostID, hostKeys: host.keys)
        let cache = cache
        let dependencies = RelayDeviceDependencies(
            defaultRelayURL: URL(string: "https://relay.example.test")!,
            transportFactory: DeviceTransportFactory(link: link, deviceID: deviceID),
            pairingAPI: pairingAPI,
            pairingPollInterval: .milliseconds(20),
            makeRepository: { _ in cache },
            removeRepository: { _ in },
            requestTimeouts: .init(index: .seconds(2), fetch: .seconds(2), tick: .milliseconds(100), retryDelay: .milliseconds(200)),
            persistsCredentials: false
        )
        controller = RelayDeviceController(settings: settings, dependencies: dependencies, loadStoredCredentials: false)
    }

    var credentials: RelayDeviceCredentials {
        RelayDeviceCredentials(
            relayURL: URL(string: "https://relay.example.test")!,
            hostID: hostID, hostName: "Test Mac", deviceID: deviceID, deviceToken: "token",
            keyPair: deviceKeys, hostPublicKey: host.keys.publicKey
        )
    }

    var state: MacChannelState? { controller.channelStates.first }

    func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func session(_ id: String) -> SessionDetail? {
        state?.sessions.first { $0.summary.id == SessionID(id) }
    }
}

private func detail(_ id: String, items: Int, at base: Date, firstItem: Int = 0, phase: TurnPhase = .thinking) -> SessionDetail {
    let sessionID = SessionID(id)
    return SessionDetail(
        summary: SessionSummary(
            id: sessionID, agent: .codex, title: id, lifecycle: .running, phase: phase,
            startedAt: base, updatedAt: base.addingTimeInterval(Double(firstItem + items)), lastActivityAt: base.addingTimeInterval(Double(firstItem + items))
        ),
        turns: [TurnSummary(id: TurnID("\(id)-turn"), sessionID: sessionID, phase: phase, startedAt: base)],
        timeline: (firstItem..<(firstItem + items)).map { index in
            TimelineItem(
                id: TimelineItemID("\(id)-item-\(index)"), sessionID: sessionID, turnID: TurnID("\(id)-turn"),
                occurredAt: base.addingTimeInterval(Double(index)),
                payload: .message(MessageTimelinePayload(role: .assistant, text: "line \(index)"))
            )
        }
    )
}

@Test @MainActor func coldStartShowsTheCacheThenReconcilesAgainstTheIndex() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = Harness()
    // Cache: A with 3 rows (host has 5), C the host no longer has.
    try await harness.cache.replaceSession(detail("A", items: 3, at: base))
    try await harness.cache.replaceSession(detail("C", items: 1, at: base.addingTimeInterval(-500)))
    // Host: A with 5 rows, B unknown to the cache.
    try await harness.host.repository.replaceSession(detail("A", items: 5, at: base))
    try await harness.host.repository.replaceSession(detail("B", items: 2, at: base.addingTimeInterval(100)))

    try await harness.controller.addChannel(harness.credentials)
    // The cache shows before any host is reachable.
    await harness.waitUntil { harness.state?.sessions.count == 2 }
    #expect(harness.state?.sessions.map(\.summary.id) == [SessionID("A"), SessionID("C")])
    #expect(harness.state?.isOnline == false)

    try await harness.host.start()
    await harness.waitUntil { harness.state?.hasCompleteSync == true }
    #expect(harness.state?.sessions.map(\.summary.id) == [SessionID("B"), SessionID("A")])
    #expect(harness.session("A")?.timeline.count == 5)
    #expect(harness.session("B")?.timeline.count == 2)
    #expect(harness.settings.lastSync(for: harness.hostID) != nil)
    #expect(harness.state?.health?.daemonVersion == "fake")
    // A grew → patched from the tail; B was unknown → taken whole; C pruned.
    let kinds = await harness.host.requests.map(\.kind)
    #expect(kinds.contains(.fetchTimelineSince))
    #expect(kinds.contains(.fetchSession))
    #expect(try await harness.cache.sessionIndex(limit: 10).map(\.summary.id).sorted { $0.rawValue < $1.rawValue } == [SessionID("A"), SessionID("B")])
    await harness.host.stop()
}

@Test @MainActor func liveEventsApplyAndUnknownSessionsAreFetched() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = Harness()
    try await harness.host.repository.replaceSession(detail("A", items: 1, at: base))
    try await harness.host.start()
    try await harness.controller.addChannel(harness.credentials)
    await harness.waitUntil { harness.state?.hasCompleteSync == true }

    let grow = AgentIngressEvent(
        eventID: EventID("e1"), sessionID: SessionID("A"), turnID: TurnID("A-turn"), agent: .codex,
        occurredAt: base.addingTimeInterval(10), phase: .executing,
        timelineItem: TimelineItem(
            id: TimelineItemID("A-item-9"), sessionID: SessionID("A"), turnID: TurnID("A-turn"),
            occurredAt: base.addingTimeInterval(10),
            payload: .tool(ToolTimelinePayload(name: "swift build", status: .started))
        )
    )
    try await harness.host.push(events: [grow])
    await harness.waitUntil { harness.session("A")?.timeline.count == 2 }
    #expect(harness.session("A")?.summary.phase == .executing)
    #expect(try await harness.cache.sessionDetail(id: SessionID("A"), cursor: nil, limit: 10)?.timeline.count == 2)

    // An event for a session the cache never saw makes the device take it whole.
    try await harness.host.repository.replaceSession(detail("Z", items: 3, at: base.addingTimeInterval(200)))
    let unknown = AgentIngressEvent(
        eventID: EventID("e2"), sessionID: SessionID("Z"), agent: .codex,
        occurredAt: base.addingTimeInterval(204), phase: .thinking
    )
    try await harness.host.push(events: [unknown])
    await harness.waitUntil { harness.session("Z") != nil }
    #expect(harness.session("Z")?.timeline.count == 3)
    #expect(harness.state?.sessions.first?.summary.id == SessionID("Z"))
    await harness.host.stop()
}

@Test @MainActor func summaryInfoRemovalsAndReviewsFlowBothWays() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = Harness()
    try await harness.host.repository.replaceSession(detail("A", items: 1, at: base))
    try await harness.host.repository.replaceSession(detail("B", items: 1, at: base.addingTimeInterval(50)))
    try await harness.host.start()
    try await harness.controller.addChannel(harness.credentials)
    await harness.waitUntil { harness.state?.hasCompleteSync == true }

    // session_info: summary-only change lands without refetching — in memory
    // at once, in the cache as soon as the queued write lands.
    let idle = detail("A", items: 1, at: base, phase: .idle).summary
    try await harness.host.push(summaries: [idle])
    await harness.waitUntil { harness.session("A")?.summary.phase == .idle }
    for _ in 0..<300 where try await harness.cache.sessionDetail(id: SessionID("A"), cursor: nil, limit: 10)?.summary.phase != .idle {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await harness.cache.sessionDetail(id: SessionID("A"), cursor: nil, limit: 10)?.summary.phase == .idle)

    // session_removed: gone from memory at once, from the cache as soon as
    // the queued write lands.
    try await harness.host.pushRemoved([SessionID("B")])
    await harness.waitUntil { harness.session("B") == nil }
    for _ in 0..<300 where try await harness.cache.sessionDetail(id: SessionID("B"), cursor: nil, limit: 10) != nil {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await harness.cache.sessionDetail(id: SessionID("B"), cursor: nil, limit: 10) == nil)

    // Reviewing on the iPhone tells the daemon.
    let needsReview = try await harness.host.repository.sessionDetail(id: SessionID("A"), cursor: nil, limit: 1)!.summary
        .withReviewState(needsAttention: true, needsReview: true)
    try await harness.host.push(summaries: [needsReview])
    await harness.waitUntil { harness.session("A")?.summary.needsReview == true }
    harness.controller.markReviewed(hostID: harness.hostID, id: SessionID("A"))
    #expect(harness.session("A")?.summary.needsReview == false)
    for _ in 0..<300 where await harness.host.reviewed.isEmpty {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(await harness.host.reviewed == [SessionID("A")])
    await harness.host.stop()
}

@Test @MainActor func clearReceivedDataEmptiesTheCacheAndRefills() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = Harness()
    try await harness.host.repository.replaceSession(detail("A", items: 2, at: base))
    try await harness.host.start()
    try await harness.controller.addChannel(harness.credentials)
    await harness.waitUntil { harness.state?.hasCompleteSync == true }

    harness.controller.clearReceivedData()
    #expect(harness.state?.sessions.isEmpty == true)
    await harness.waitUntil { harness.session("A") != nil && harness.state?.hasCompleteSync == true }
    #expect(harness.session("A")?.timeline.count == 2)
    await harness.host.stop()
}

/// A Relay that refuses the device's credentials on every connect.
private final class RevokingTransportFactory: RelayFrameTransportFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    var connectAttempts: Int { lock.lock(); defer { lock.unlock() }; return attempts }

    func makeTransport(baseURL: URL) -> any RelayFrameTransport {
        lock.lock(); attempts += 1; lock.unlock()
        return RevokedTransport()
    }

    private struct RevokedTransport: RelayFrameTransport {
        func connect(hostID: HostID, role: RelayConnectionRole, token: String) async throws {}
        func send(_ frame: RelayRoutingFrame) async throws { throw RelayClientError.notConnected }
        func next() async throws -> RelayIncomingMessage { throw RelayClientError.unauthorized }
        func disconnect() async {}
    }
}

@Test @MainActor func revokedCredentialsStopReconnectingAndFlagTheMac() async throws {
    let settings = LocalSettings(defaults: UserDefaults(suiteName: "relay-tests-\(UUID().uuidString)")!)
    let factory = RevokingTransportFactory()
    let cache = InMemorySessionRepository()
    let dependencies = RelayDeviceDependencies(
        defaultRelayURL: URL(string: "https://relay.example.test")!,
        transportFactory: factory,
        makeRepository: { _ in cache },
        removeRepository: { _ in },
        requestTimeouts: .init(index: .seconds(2), fetch: .seconds(2), tick: .milliseconds(100), retryDelay: .milliseconds(200)),
        persistsCredentials: false
    )
    let controller = RelayDeviceController(settings: settings, dependencies: dependencies, loadStoredCredentials: false)
    let keys = RelayCryptography.makeKeyPair()
    try await controller.addChannel(RelayDeviceCredentials(
        relayURL: dependencies.defaultRelayURL, hostID: HostID("host-revoked"), hostName: "Old Mac",
        deviceID: DeviceID("device-revoked"), deviceToken: "stale", keyPair: keys, hostPublicKey: keys.publicKey
    ))
    for _ in 0..<300 where controller.channelStates.first?.accessRevoked != true {
        try? await Task.sleep(for: .milliseconds(10))
    }
    let state = try #require(controller.channelStates.first)
    #expect(state.accessRevoked)
    #expect(!state.isConnected)
    #expect(state.lastError?.contains("revoked") == true)
    // No 2 s retry loop: one attempt, then the Macs screen asks to pair again.
    try await Task.sleep(for: .milliseconds(2_500))
    #expect(factory.connectAttempts == 1)
    #expect(MacsViewController.meta(for: state, now: Date()).hasPrefix("Revoked"))
}

@Test @MainActor func aRepeatedOnlinePresenceMakesTheDeviceIndexAgain() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = Harness()
    try await harness.host.repository.replaceSession(detail("A", items: 1, at: base))
    try await harness.host.start()
    try await harness.controller.addChannel(harness.credentials)
    await harness.waitUntil { harness.state?.hasCompleteSync == true }
    let before = await harness.host.requests.count(where: { $0.kind == .syncIndex })

    // The daemon reconnected behind the Relay: devices get `online` again
    // without an `offline` first, and the daemon forgot who had synced.
    try await harness.host.start()
    for _ in 0..<300 where await harness.host.requests.count(where: { $0.kind == .syncIndex }) == before {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(await harness.host.requests.count(where: { $0.kind == .syncIndex }) == before + 1)
    await harness.waitUntil { harness.state?.hasCompleteSync == true }
    #expect(harness.state?.hasCompleteSync == true)
    await harness.host.stop()
}

@Test @MainActor func aHiddenSessionReturnsOnlyWhenTheDaemonSendsANewerCopy() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = Harness()
    try await harness.host.repository.replaceSession(detail("A", items: 1, at: base))
    try await harness.host.repository.replaceSession(detail("B", items: 1, at: base))
    try await harness.host.start()
    try await harness.controller.addChannel(harness.credentials)
    await harness.waitUntil { harness.state?.hasCompleteSync == true }

    harness.controller.dismissSession(hostID: harness.hostID, id: SessionID("A"))
    harness.controller.dismissSession(hostID: harness.hostID, id: SessionID("B"))
    #expect(harness.session("A") == nil)
    #expect(harness.session("B") == nil)

    // The same summary again (a reconcile with nothing new): stays hidden…
    try await harness.host.push(summaries: [detail("A", items: 1, at: base).summary])
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.session("A") == nil)

    // …a newer summary shows it, and the cache carried the change meanwhile.
    try await harness.host.push(summaries: [detail("A", items: 1, at: base.addingTimeInterval(60), phase: .idle).summary])
    await harness.waitUntil { harness.session("A") != nil }
    #expect(harness.session("A")?.summary.phase == .idle)
    #expect(try await harness.cache.sessionDetail(id: SessionID("A"), cursor: nil, limit: 10)?.summary.phase == .idle)

    // An event (any activity) is a newer copy too, and it was written to the
    // cache while hidden, so nothing is lost.
    let grow = AgentIngressEvent(
        eventID: EventID("e1"), sessionID: SessionID("B"), turnID: TurnID("B-turn"), agent: .codex,
        occurredAt: base.addingTimeInterval(10), phase: .executing,
        timelineItem: TimelineItem(
            id: TimelineItemID("B-item-9"), sessionID: SessionID("B"), turnID: TurnID("B-turn"),
            occurredAt: base.addingTimeInterval(10),
            payload: .tool(ToolTimelinePayload(name: "swift build", status: .started))
        )
    )
    try await harness.host.push(events: [grow])
    await harness.waitUntil { harness.session("B") != nil }
    #expect(harness.session("B")?.timeline.count == 2)
    #expect(try await harness.cache.sessionDetail(id: SessionID("B"), cursor: nil, limit: 10)?.timeline.count == 2)
    await harness.host.stop()
}

@Test @MainActor func pairingTheSameMacAgainKeepsTheDeviceID() async throws {
    let harness = Harness()
    #expect(harness.controller.deviceID(forPairingWith: harness.hostID) != harness.deviceID)
    try await harness.controller.addChannel(harness.credentials)
    #expect(harness.controller.deviceID(forPairingWith: harness.hostID) == harness.deviceID)
    #expect(harness.controller.deviceID(forPairingWith: HostID("host-other")) != harness.deviceID)
}


/// A Relay stand-in for the pairing calls: one session, scripted by the test
/// (which nonce / key it reveals, whether the Mac approves).
private actor ScriptedPairingAPI: RelayPairingAPI {
    let hostID: HostID
    let hostKeys: RelayKeyPair
    let nonce = RelayCryptography.makePairingNonce()
    let sessionID = "session-0001"
    var code = "7KF3QP"
    /// What `status` reveals as the host key (a MITM would swap it).
    var revealedHostKey: Data
    var decision: PairingSessionState = .approved
    var hostOffline = false
    private(set) var submitted: (deviceID: DeviceID, deviceName: String, devicePublicKey: Data)?
    private(set) var cancelled = false
    private(set) var polls = 0

    init(hostID: HostID, hostKeys: RelayKeyPair) {
        self.hostID = hostID
        self.hostKeys = hostKeys
        revealedHostKey = hostKeys.publicKey
    }

    func set(revealedHostKey: Data) { self.revealedHostKey = revealedHostKey }
    func set(decision: PairingSessionState) { self.decision = decision }
    func set(hostOffline: Bool) { self.hostOffline = hostOffline }

    func claim(relayURL: URL, code: String) async throws -> RelayPairingClaim {
        guard code == self.code else { throw RelayClientError.relay(status: 404, code: "invalid_or_expired_code") }
        return RelayPairingClaim(
            sessionID: sessionID, hostID: hostID, hostName: "Test Mac",
            commit: RelayCryptography.pairingCommitment(hostPublicKey: hostKeys.publicKey, hostNonce: nonce)
        )
    }

    func submit(relayURL: URL, hostID: HostID, sessionID: String, deviceID: DeviceID, deviceName: String, devicePublicKey: Data) async throws {
        if hostOffline { throw RelayClientError.relay(status: 409, code: "host_offline") }
        submitted = (deviceID, deviceName, devicePublicKey)
    }

    func status(relayURL: URL, hostID: HostID, sessionID: String) async throws -> RelayPairingSessionStatus {
        polls += 1
        guard submitted != nil else { return RelayPairingSessionStatus(state: .claimed, hostName: "Test Mac") }
        // Submitted → revealed on the first poll → the decision on the second.
        if polls <= 1 {
            return RelayPairingSessionStatus(state: .revealed, hostName: "Test Mac", hostPublicKey: revealedHostKey, hostNonce: nonce)
        }
        return RelayPairingSessionStatus(
            state: decision, hostName: "Test Mac", hostPublicKey: revealedHostKey, hostNonce: nonce,
            deviceToken: decision == .approved ? "device-token-0001" : nil,
            pairedAt: decision == .approved ? Date(timeIntervalSince1970: 1_700_000_000) : nil
        )
    }

    func cancel(relayURL: URL, hostID: HostID, sessionID: String) async throws {
        cancelled = true
    }
}

@Test @MainActor func pairingAttemptVerifiesTheCommitmentShowsTheSASAndInstallsTheChannel() async throws {
    let harness = Harness()
    try await harness.host.start()
    let attempt = harness.controller.makePairingAttempt(relayURL: URL(string: "https://relay.example.test")!, code: "7KF3QP")
    var seen: [PairingProgress] = []
    attempt.onChange = { if let progress = attempt.progress, seen.last != progress { seen.append(progress) } }
    attempt.start()
    await harness.waitUntil { attempt.progress.map { if case .paired = $0 { true } else { false } } ?? false || attempt.failure != nil }
    #expect(attempt.failure == nil)

    // Claim → waiting → SAS → paired, in that order.
    #expect(seen.first == .claiming)
    #expect(seen.contains(.waitingForMac(hostName: "Test Mac", relayHost: "relay.example.test")))
    let submitted = try #require(await harness.pairingAPI.submitted)
    let expectedSAS = RelayCryptography.pairingSAS(
        hostID: harness.hostID, deviceID: submitted.deviceID,
        hostPublicKey: harness.host.keys.publicKey, devicePublicKey: submitted.devicePublicKey, hostNonce: await harness.pairingAPI.nonce
    )
    #expect(seen.contains(.comparing(sas: expectedSAS, hostName: "Test Mac", relayHost: "relay.example.test")))
    #expect(seen.last == .paired(hostID: harness.hostID, hostName: "Test Mac", relayHost: "relay.example.test"))
    #expect(submitted.deviceName == harness.settings.deviceName)

    // The channel is installed with the Relay the code came from and the
    // Mac's key; it connects and indexes like any other.
    let state = try #require(harness.state)
    #expect(state.hostID == harness.hostID)
    #expect(state.relayURL == URL(string: "https://relay.example.test")!)
    #expect(state.displayName == "Test Mac")
    #expect(harness.controller.deviceID(forPairingWith: harness.hostID) == submitted.deviceID)
    #expect(MacsViewController.meta(for: state, now: Date()).hasSuffix("relay.example.test"))
}

@Test @MainActor func pairingAttemptRefusesASwappedHostKeyAndReportsTheMacsDecision() async throws {
    let harness = Harness()
    try await harness.host.start()

    // The Relay reveals a key that does not open the commitment: stop, tell
    // the Relay, keep nothing.
    let impostor = RelayCryptography.makeKeyPair()
    await harness.pairingAPI.set(revealedHostKey: impostor.publicKey)
    let mitm = harness.controller.makePairingAttempt(relayURL: URL(string: "https://relay.example.test")!, code: "7KF3QP")
    mitm.start()
    await harness.waitUntil { mitm.failure != nil }
    #expect(mitm.failure == .commitMismatch)
    #expect(harness.controller.channelStates.isEmpty)
    await harness.waitUntil { false }  // let the fire-and-forget cancel land
    #expect(await harness.pairingAPI.cancelled)

    // Wrong code: refused at claim, nothing submitted.
    let wrong = harness.controller.makePairingAttempt(relayURL: URL(string: "https://relay.example.test")!, code: "AAAAAA")
    wrong.start()
    await harness.waitUntil { wrong.failure != nil }
    #expect(wrong.failure == .badCode)

    // Mac offline at submit: resumable — `start()` again submits without a new claim.
    await harness.pairingAPI.set(revealedHostKey: harness.host.keys.publicKey)
    await harness.pairingAPI.set(hostOffline: true)
    await harness.pairingAPI.set(decision: .rejected)
    let offline = harness.controller.makePairingAttempt(relayURL: URL(string: "https://relay.example.test")!, code: "7KF3QP")
    offline.start()
    await harness.waitUntil { offline.failure != nil }
    #expect(offline.failure == .hostOffline)
    await harness.pairingAPI.set(hostOffline: false)
    offline.start()
    await harness.waitUntil { offline.failure != nil && offline.failure != .hostOffline }
    // …and the Mac pressed Don't match.
    #expect(offline.failure == .rejected)
    #expect(harness.controller.channelStates.isEmpty)
}
