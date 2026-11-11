import Core
import Remote
import Transport
import Foundation
import Testing
@testable import IOSFeature

/// A daemon stand-in on the host end of an in-memory relay: opens channel
/// sessions and answers the device's requests from its own repository the
/// way `RelayHostService` does — a request counts only inside the current
/// session and in rising order — and can push events / summaries / removals.
private actor FakeHost {
    enum Path: Equatable {
        case relay
        case direct(DirectConnectionID)
    }

    let link: RelayInMemoryLink
    /// The local network, when the test has one.
    let direct: InMemoryDirectLink?
    let repository = InMemorySessionRepository()
    let keys = RelayCryptography.makeKeyPair()
    let hostID: HostID
    let deviceID: DeviceID
    let devicePublicKey: Data
    private var transport: (any RelayFrameTransport)?
    private var sequence: UInt64 = 0
    private var loop: Task<Void, Never>?
    private var directLoop: Task<Void, Never>?
    /// The channel session the device opened last, its request cursor and
    /// the link it lives on.
    private var sessionKey: RelayChannelKey?
    private var sessionPath: Path = .relay
    private var lastRequestSequence: UInt64 = 0
    /// Kinds this host does not answer (a stalled Mac).
    private var stalled: Set<RemotePayloadKind> = []

    func setStalled(_ kinds: Set<RemotePayloadKind>) { stalled = kinds }
    var currentPath: Path { sessionPath }
    /// Every request that counted, openings (`sync_index`) included.
    private(set) var requests: [RemoteSessionPayload] = []
    /// Requests that opened in the session but not past its cursor: the
    /// daemon drops those, so a correct iPhone never sends one.
    private(set) var outOfOrderRequests = 0
    private(set) var reviewed: [SessionID] = []
    /// Requests the device gave up on (`cancel_request`).
    private(set) var cancelled: [RequestID] = []
    /// What `fetch_usage` answers with; `nil` = the daemon could not build it.
    var usageReport: UsageReport?
    var planUsage: (state: PlanUsageState, settings: DaemonSettings)?

    func setUsageReport(_ report: UsageReport?) { usageReport = report }
    func setPlanUsage(_ state: PlanUsageState, settings: DaemonSettings) { planUsage = (state, settings) }

    init(link: RelayInMemoryLink, direct: InMemoryDirectLink? = nil, hostID: HostID, deviceID: DeviceID, devicePublicKey: Data) {
        self.link = link
        self.direct = direct
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
                await self.handle(message, from: .relay)
            }
        }
        if let direct, directLoop == nil {
            try await direct.start(hostID: hostID)
            directLoop = Task { [weak self] in
                for await event in direct.events {
                    guard let self else { return }
                    switch event {
                    case let .frame(connection, frame):
                        await self.handle(.frame(frame), from: .direct(connection))
                    case let .closed(connection):
                        await self.directClosed(connection)
                    }
                }
            }
        }
    }

    private func directClosed(_ connection: DirectConnectionID) {
        if sessionPath == .direct(connection) { sessionKey = nil }
    }

    func stop() async {
        loop?.cancel()
        await transport?.disconnect()
        transport = nil
    }

    private var handshakeKey: RelayChannelKey {
        get throws {
            try RelayCryptography.handshakeKey(privateKey: keys.privateKey, peerPublicKey: devicePublicKey, hostID: hostID, deviceID: deviceID)
        }
    }

    private func handle(_ message: RelayIncomingMessage, from path: Path) async {
        guard case let .frame(frame) = message, frame.kind == .request else { return }
        if let sessionKey, sessionPath == path, let payload = try? RelayCryptography.open(frame, key: sessionKey) {
            guard frame.sequence > lastRequestSequence else {
                outOfOrderRequests += 1
                return
            }
            lastRequestSequence = frame.sequence
            requests.append(payload)
            await answer(payload)
            return
        }
        // Outside the session: only a `sync_index` sealed with the handshake
        // key, which opens the next one.
        guard let handshakeKey = try? handshakeKey,
              let opening = try? RelayCryptography.open(frame, key: handshakeKey),
              opening.kind == .syncIndex, let requestID = opening.requestID, let deviceEphemeralKey = opening.ephemeralKey else { return }
        requests.append(opening)
        do {
            let ephemeral = RelayEphemeralKey()
            sessionKey = try RelayCryptography.sessionKey(
                as: .host, ephemeral: ephemeral, peerEphemeralPublicKey: deviceEphemeralKey,
                privateKey: keys.privateKey, peerPublicKey: devicePublicKey, hostID: hostID, deviceID: deviceID
            )
            lastRequestSequence = frame.sequence
            sessionPath = path
            let opened = try RelayCryptography.prepare(RemoteSessionPayload(
                kind: .channelOpened, requestID: requestID, ephemeralKey: try ephemeral.publicKey
            ))
            try await send([opened], key: handshakeKey)
            let now = Date()
            let entries = try await repository.sessionIndex(limit: 10_000)
            try await send(RelayPayloadBatcher.indexParts(entries, requestID: requestID, generatedAt: now).map(\.prepared))
            let health = DaemonHealth(daemonVersion: "fake", executableHash: nil, process: nil, uptimeSeconds: 1, activeSessionCount: entries.count, retainedSessionCount: entries.count, socketPath: "/s", relayConnected: true)
            try await send([RelayCryptography.prepare(RemoteSessionPayload(kind: .health, generatedAt: now, health: health))])
        } catch {
            Issue.record("fake host failed to open a channel session: \(error)")
        }
    }

    private func answer(_ payload: RemoteSessionPayload) async {
        let now = Date()
        let limit = min(max(payload.limit ?? 80, 1), 500)
        guard !stalled.contains(payload.kind) else { return }
        do {
            switch payload.kind {
            case .fetchSession:
                for id in payload.sessionIDs ?? [] {
                    if let page = try await repository.timelinePage(id: id, before: nil, limit: limit) {
                        try await send(RelaySessionPartitioner.parts(
                            summary: page.summary, turns: page.turns, timeline: page.timeline, hasOlder: page.hasOlder,
                            kind: .sessionTail, order: .newestFirst, requestID: payload.requestID, generatedAt: now
                        ).map(\.prepared))
                    } else {
                        try await send([RelayCryptography.prepare(RemoteSessionPayload(kind: .sessionRemoved, generatedAt: now, requestID: payload.requestID, sessionIDs: [id]))])
                    }
                }
            case .fetchSessionBefore:
                guard let id = payload.sessionIDs?.first, let before = payload.before,
                      let page = try await repository.timelinePage(id: id, before: before, limit: limit) else { return }
                try await send(RelaySessionPartitioner.parts(
                    summary: page.summary, turns: page.turns, timeline: page.timeline, hasOlder: page.hasOlder,
                    kind: .sessionHistory, order: .newestFirst, requestID: payload.requestID, generatedAt: now
                ).map(\.prepared))
            case .fetchTimelineSince:
                guard let id = payload.sessionIDs?.first, let since = payload.since,
                      let page = try await repository.timelinePage(id: id, before: nil, limit: limit) else { return }
                if let oldest = page.timeline.first, oldest.occurredAt <= since || !page.hasOlder {
                    try await send(RelaySessionPartitioner.parts(
                        summary: page.summary, turns: page.turns, timeline: page.timeline.filter { $0.occurredAt >= since }, hasOlder: nil,
                        kind: .sessionTimeline, order: .oldestFirst, requestID: payload.requestID, generatedAt: now
                    ).map(\.prepared))
                } else {
                    try await send(RelaySessionPartitioner.parts(
                        summary: page.summary, turns: page.turns, timeline: page.timeline, hasOlder: page.hasOlder,
                        kind: .sessionTail, order: .newestFirst, requestID: payload.requestID, generatedAt: now
                    ).map(\.prepared))
                }
            case .fetchTimelineItems:
                guard let id = payload.sessionIDs?.first, let itemIDs = payload.itemIDs,
                      let detail = try await repository.timelineItems(id: id, itemIDs: itemIDs) else { return }
                try await send(RelaySessionPartitioner.parts(
                    summary: detail.summary, turns: [], timeline: detail.timeline, hasOlder: nil,
                    kind: .sessionItems, order: .oldestFirst, requestID: payload.requestID, generatedAt: now, trimming: false
                ).map(\.prepared))
            case .cancelRequest:
                if let target = payload.cancels { cancelled.append(target) }
            case .sessionReviewed:
                reviewed += payload.sessionIDs ?? []
            case .fetchUsage:
                try await send([RelayCryptography.prepare(RemoteSessionPayload(kind: .usageReport, generatedAt: now, requestID: payload.requestID, usage: usageReport))])
            case .fetchPlanUsage:
                try await send([RelayCryptography.prepare(RemoteSessionPayload(
                    kind: .planUsage, generatedAt: now, requestID: payload.requestID,
                    planUsage: planUsage?.state, settings: planUsage?.settings
                ))])
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

    /// A summary-only change the repository keeps too, so a later index agrees.
    func update(summary: SessionSummary) async throws {
        try await repository.updateSummary(summary)
        try await push(summaries: [summary])
    }

    /// A frame of the current session that never goes out: a summary change
    /// sealed `ahead` sequences past the last one sent, for a Relay to keep
    /// and deliver whenever it likes.
    func sealWithoutSending(summary: SessionSummary, ahead: UInt64) throws -> RelayRoutingFrame {
        let key = try #require(sessionKey)
        let prepared = try #require(RelayPayloadBatcher.summaryBatches([summary], generatedAt: Date()).first?.prepared)
        return try RelayCryptography.seal(prepared, hostID: hostID, deviceID: deviceID, sequence: sequence + ahead, kind: .data, key: key)
    }

    func pushRemoved(_ ids: [SessionID]) async throws {
        for id in ids { _ = try await repository.deleteSession(id: id) }
        try await send([RelayCryptography.prepare(RemoteSessionPayload(kind: .sessionRemoved, generatedAt: Date(), sessionIDs: ids))])
    }

    /// Seals with the open session's key unless another is given
    /// (`channel_opened` goes out under the handshake key).
    private func send(_ prepared: [RelayPreparedPayload], key: RelayChannelKey? = nil) async throws {
        guard let key = key ?? sessionKey else { return }
        for payload in prepared {
            sequence += 1
            let frame = try RelayCryptography.seal(
                payload, hostID: hostID, deviceID: deviceID, sequence: sequence, kind: .data,
                key: key
            )
            switch sessionPath {
            case .relay:
                guard let transport else { return }
                try await transport.send(frame)
            case let .direct(connection):
                try await direct?.send(frame, to: connection)
            }
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
    let direct: InMemoryDirectLink?
    let hostID = HostID("host-test-000001")
    let deviceID = DeviceID("device-test-0001")
    let deviceKeys = RelayCryptography.makeKeyPair()
    let cache = InMemorySessionRepository()
    let settings: LocalSettings
    let host: FakeHost
    let pairingAPI: ScriptedPairingAPI
    let controller: RelayDeviceController

    init(localNetwork: Bool = false) {
        settings = LocalSettings(defaults: UserDefaults(suiteName: "relay-tests-\(UUID().uuidString)")!)
        let direct = localNetwork ? InMemoryDirectLink() : nil
        self.direct = direct
        host = FakeHost(link: link, direct: direct, hostID: hostID, deviceID: deviceID, devicePublicKey: deviceKeys.publicKey)
        pairingAPI = ScriptedPairingAPI(hostID: hostID, hostKeys: host.keys)
        let cache = cache
        let dependencies = RelayDeviceDependencies(
            defaultRelayURL: URL(string: "https://relay.example.test")!,
            transportFactory: DeviceTransportFactory(link: link, deviceID: deviceID),
            directDiscovery: direct,
            directTransportFactory: direct,
            pairingAPI: pairingAPI,
            pairingPollInterval: .milliseconds(20),
            makeRepository: { _ in cache },
            removeRepository: { _ in },
            requestTimeouts: .init(index: .seconds(2), fetch: .seconds(2), usage: .seconds(1), tick: .milliseconds(100), retryDelay: .milliseconds(200)),
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
    // A's rows came from an earlier run without a sync mark, so they count
    // as nothing loaded: like B (unknown → summary only) its content waits
    // for a tap; C pruned. The index itself asked for no rows.
    #expect(harness.session("A")?.timeline.count == 3)
    #expect(harness.session("B")?.timeline.isEmpty == true)
    #expect(harness.settings.lastSync(for: harness.hostID) != nil)
    // Health is its own frame after the index, not part of the sync: wait
    // for it rather than assume it landed with the last index part.
    await harness.waitUntil { harness.state?.health != nil }
    #expect(harness.state?.health?.daemonVersion == "fake")
    var kinds = await harness.host.requests.map(\.kind)
    #expect(!kinds.contains(.fetchTimelineSince))
    #expect(!kinds.contains(.fetchSession))
    let index = try await harness.cache.sessionIndex(limit: 10)
    #expect(index.map(\.summary.id).sorted { $0.rawValue < $1.rawValue } == [SessionID("A"), SessionID("B")])
    #expect(index.first { $0.summary.id == SessionID("B") }?.timelineItemCount == 0)

    // Opening B takes its tail; while it is on its way the channel says so.
    harness.controller.openSession(hostID: harness.hostID, id: SessionID("B"))
    #expect(harness.controller.isFetchingSession(hostID: harness.hostID, id: SessionID("B")))
    await harness.waitUntil { harness.session("B")?.timeline.count == 2 }
    #expect(!harness.controller.isFetchingSession(hostID: harness.hostID, id: SessionID("B")))
    for _ in 0..<300 where try await harness.cache.sessionDetail(id: SessionID("B"), cursor: nil, limit: 10)?.timeline.count != 2 {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await harness.cache.sessionDetail(id: SessionID("B"), cursor: nil, limit: 10)?.timeline.count == 2)
    kinds = await harness.host.requests.map(\.kind)
    #expect(kinds.filter { $0 == .fetchSession }.count == 1)
    // B holds everything the Mac has: nothing older to page.
    #expect(!harness.controller.canLoadOlder(hostID: harness.hostID, id: SessionID("B")))

    // Opening A merges the Mac's tail over the old rows (5 now, by id).
    harness.controller.openSession(hostID: harness.hostID, id: SessionID("A"))
    await harness.waitUntil { harness.session("A")?.timeline.count == 5 }
    // Opening a held, current session again asks for nothing more.
    harness.controller.closeSession(hostID: harness.hostID, id: SessionID("A"))
    let asked = await harness.host.requests.count
    harness.controller.openSession(hostID: harness.hostID, id: SessionID("A"))
    try await Task.sleep(for: .milliseconds(50))
    #expect(await harness.host.requests.count == asked)
    await harness.host.stop()
}

@Test @MainActor func liveEventsApplyToHeldSessionsAndOnlyMoveSummariesOtherwise() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = Harness()
    try await harness.host.repository.replaceSession(detail("A", items: 1, at: base))
    // A is held from an earlier run — its rows and its sync mark survive a
    // relaunch; the host also has S, which the iPhone will know by summary only.
    let heldA = detail("A", items: 1, at: base)
    try await harness.cache.replaceSession(heldA)
    harness.settings.setSyncMarks([SessionID("A"): SessionSyncMark(
        timelineItemCount: 1, lastItemAt: heldA.timeline.last?.occurredAt, oldest: TimelineCursor(heldA.timeline[0]), hasOlder: false
    )], for: harness.hostID)
    try await harness.host.repository.replaceSession(detail("S", items: 1, at: base))
    try await harness.host.start()
    try await harness.controller.addChannel(harness.credentials)
    await harness.waitUntil { harness.state?.hasCompleteSync == true }
    #expect(harness.session("S")?.timeline.isEmpty == true)

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

    // An event for a summary-only session moves its summary and nothing else.
    let touchS = AgentIngressEvent(
        eventID: EventID("e-s"), sessionID: SessionID("S"), turnID: TurnID("S-turn"), agent: .codex,
        occurredAt: base.addingTimeInterval(20), phase: .idle,
        timelineItem: TimelineItem(
            id: TimelineItemID("S-item-9"), sessionID: SessionID("S"), turnID: TurnID("S-turn"),
            occurredAt: base.addingTimeInterval(20),
            payload: .message(MessageTimelinePayload(role: .assistant, text: "done"))
        )
    )
    try await harness.host.push(events: [touchS])
    await harness.waitUntil { harness.session("S")?.summary.phase == .idle }
    #expect(harness.session("S")?.timeline.isEmpty == true)
    for _ in 0..<300 where try await harness.cache.sessionDetail(id: SessionID("S"), cursor: nil, limit: 10)?.summary.phase != .idle {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await harness.cache.sessionDetail(id: SessionID("S"), cursor: nil, limit: 10)?.timeline.isEmpty == true)

    // An event for a session the cache never saw creates it as a summary —
    // no fetch; the timeline waits for a tap.
    try await harness.host.repository.replaceSession(detail("Z", items: 3, at: base.addingTimeInterval(200)))
    let unknown = AgentIngressEvent(
        eventID: EventID("e2"), sessionID: SessionID("Z"), agent: .codex,
        occurredAt: base.addingTimeInterval(204), phase: .thinking
    )
    try await harness.host.push(events: [unknown])
    await harness.waitUntil { harness.session("Z") != nil }
    #expect(harness.session("Z")?.timeline.isEmpty == true)
    #expect(harness.session("Z")?.summary.phase == .thinking)
    #expect(await harness.host.requests.contains { $0.kind == .fetchSession } == false)
    harness.controller.openSession(hostID: harness.hostID, id: SessionID("Z"))
    await harness.waitUntil { harness.session("Z")?.timeline.count == 3 }
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
    // The refill is summaries only; the content comes back on open.
    await harness.waitUntil { harness.session("A") != nil && harness.state?.hasCompleteSync == true }
    #expect(harness.session("A")?.timeline.isEmpty == true)
    harness.controller.openSession(hostID: harness.hostID, id: SessionID("A"))
    await harness.waitUntil { harness.session("A")?.timeline.count == 2 }
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

    private final class RevokedTransport: RelayFrameTransport, Sendable {
        func connect(hostID: HostID, role: RelayConnectionRole, token: String) async throws {}
        func send(_ frame: RelayRoutingFrame) async throws { throw RelayClientError.notConnected }
        func next() async throws -> RelayIncomingMessage { throw RelayClientError.unauthorized }
        func ping() async throws {}
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
        requestTimeouts: .init(index: .seconds(2), fetch: .seconds(2), usage: .seconds(1), tick: .milliseconds(100), retryDelay: .milliseconds(200)),
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
    // B was never opened, so the event only moved its summary — in memory
    // and in the cache — and that was enough to bring it back.
    #expect(harness.session("B")?.summary.phase == .executing)
    #expect(harness.session("B")?.timeline.isEmpty == true)
    for _ in 0..<300 where try await harness.cache.sessionDetail(id: SessionID("B"), cursor: nil, limit: 10)?.summary.phase != .executing {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await harness.cache.sessionDetail(id: SessionID("B"), cursor: nil, limit: 10)?.summary.phase == .executing)
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

@Test @MainActor func usageAndPlanUsageAnswersLandInMemoryOnly() async throws {
    let now = Date(timeIntervalSince1970: 1_788_616_800)
    let harness = Harness()
    let report = UsageReport(
        since: UsageDay(year: 2026, month: 8, day: 31), until: UsageDay(year: 2026, month: 9, day: 5), generatedAt: now,
        totals: UsageSlice(tokens: UsageTokens(input: 10), costUSD: 1.5, calls: 1, sessions: 1, turns: 1),
        byAgent: [], byProject: [], byModel: [],
        pricing: UsagePricingStatus(source: .builtin, modelCount: 1),
        scan: UsageScanStatus(scannedFiles: 1, pendingFiles: 0, isScanning: false)
    )
    let state = PlanUsageState(accounts: [PlanUsageAccount(id: .claude, provider: .claude, enabled: true, status: .ok, limits: [PlanUsageLimit(window: .session, usedPercent: 42)])], generatedAt: now)
    let settings = DaemonSettings(planUsage: PlanUsageSettings(enabledAccounts: [.claude], percentStyle: .remaining))
    await harness.host.setUsageReport(report)
    await harness.host.setPlanUsage(state, settings: settings)
    try await harness.host.start()
    try await harness.controller.addChannel(harness.credentials)
    await harness.waitUntil { harness.state?.hasCompleteSync == true }

    // Nothing asked yet: no snapshot, and the sync did not wait for one.
    #expect(harness.state?.usage == nil && harness.state?.planUsage == nil)

    harness.controller.requestUsage(.thisWeek)
    #expect(harness.state?.usage?.isLoading == true)
    await harness.waitUntil { harness.state?.usage?.report != nil }
    #expect(harness.state?.usage?.report == report)
    #expect(harness.state?.usage?.preset == .thisWeek)
    #expect(harness.state?.usage?.isLoading == false && harness.state?.usage?.error == nil)

    harness.controller.requestPlanUsage()
    await harness.waitUntil { harness.state?.planUsage?.state != nil }
    #expect(harness.state?.planUsage?.state == state)
    #expect(harness.state?.planUsage?.settings == settings)
    // The cache never sees any of it.
    #expect(try await harness.cache.sessionIndex(limit: 10).isEmpty)

    // The daemon could not build the report: the last one stays, with the error.
    await harness.host.setUsageReport(nil)
    harness.controller.requestUsage(.today)
    await harness.waitUntil { harness.state?.usage?.error != nil }
    #expect(harness.state?.usage?.report == report && harness.state?.usage?.preset == .thisWeek)
    #expect(harness.state?.usage?.error == "The Mac could not build the report.")
    #expect(await harness.host.requests.filter { $0.kind == .fetchUsage }.map(\.usageRange) == [.thisWeek, .today])
    await harness.host.stop()
}

// MARK: - The Relay as an adversary

// A frame counts once, in the channel session it was sealed for, and only
// moving forward — whatever the Relay repeats, keeps, or says about presence.
@Test @MainActor func framesTheRelayRepeatsOrKeepsFromAnEarlierSessionChangeNothing() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = Harness()
    try await harness.host.repository.replaceSession(detail("A", items: 1, at: base))
    try await harness.host.start()
    try await harness.controller.addChannel(harness.credentials)
    await harness.waitUntil { harness.state?.hasCompleteSync == true }

    try await harness.host.update(summary: detail("A", items: 1, at: base, phase: .idle).summary)
    await harness.waitUntil { harness.session("A")?.summary.phase == .idle }
    let idleFrame = try #require(await harness.link.hostSent.last)
    try await harness.host.update(summary: detail("A", items: 1, at: base, phase: .executing).summary)
    await harness.waitUntil { harness.session("A")?.summary.phase == .executing }

    // The same frame again, inside its own session: behind the cursor.
    await harness.link.deliver(idleFrame, to: harness.deviceID)
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.session("A")?.summary.phase == .executing)

    // A frame of this session the Relay keeps for later, sealed far ahead
    // of anything sent so far — so no cursor will ever be in its way.
    let kept = try await harness.host.sealWithoutSending(summary: detail("A", items: 1, at: base, phase: .idle).summary, ahead: 100_000)

    // The Relay claims the Mac went away and came back. The iPhone opens a
    // new session; what stands in the way of the old session's frames now
    // is its key.
    let openings = await harness.host.requests.count(where: { $0.kind == .syncIndex })
    await harness.link.sendPresence(online: false, to: harness.deviceID)
    await harness.link.sendPresence(online: true, to: harness.deviceID)
    for _ in 0..<300 where await harness.host.requests.count(where: { $0.kind == .syncIndex }) == openings {
        try? await Task.sleep(for: .milliseconds(10))
    }
    await harness.waitUntil { harness.state?.hasCompleteSync == true }
    #expect(harness.session("A")?.summary.phase == .executing)
    await harness.link.deliver(kept, to: harness.deviceID)
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.session("A")?.summary.phase == .executing)

    // The new session carries on.
    try await harness.host.update(summary: detail("A", items: 1, at: base, phase: .idle).summary)
    await harness.waitUntil { harness.session("A")?.summary.phase == .idle }
    #expect(harness.session("A")?.summary.phase == .idle)
    await harness.host.stop()
}

@Test @MainActor func aFrameThatDoesNotAuthenticateMovesNoCursor() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = Harness()
    try await harness.host.repository.replaceSession(detail("A", items: 1, at: base))
    try await harness.host.start()
    try await harness.controller.addChannel(harness.credentials)
    await harness.waitUntil { harness.state?.hasCompleteSync == true }

    // Far ahead of the session's sequences, sealed with nothing the iPhone knows.
    let genuine = try #require(await harness.link.hostSent.last)
    await harness.link.deliver(RelayRoutingFrame(
        hostID: harness.hostID, deviceID: harness.deviceID, sequence: genuine.sequence + 1_000_000, kind: .data,
        nonce: genuine.nonce, ciphertext: genuine.ciphertext
    ), to: harness.deviceID)
    try await Task.sleep(for: .milliseconds(100))

    // The daemon's next frame, on its real sequence, still lands — and is
    // not mistaken for the far side of a gap.
    let openings = await harness.host.requests.count(where: { $0.kind == .syncIndex })
    try await harness.host.update(summary: detail("A", items: 1, at: base, phase: .idle).summary)
    await harness.waitUntil { harness.session("A")?.summary.phase == .idle }
    #expect(harness.session("A")?.summary.phase == .idle)
    try await Task.sleep(for: .milliseconds(100))
    #expect(await harness.host.requests.count(where: { $0.kind == .syncIndex }) == openings)
    await harness.host.stop()
}

@Test @MainActor func requestsMadeWhileASessionOpensWaitForItAndArriveInOrder() async throws {
    let now = Date(timeIntervalSince1970: 1_788_616_800)
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = Harness()
    let report = UsageReport(
        since: UsageDay(year: 2026, month: 8, day: 31), until: UsageDay(year: 2026, month: 9, day: 5), generatedAt: now,
        totals: UsageSlice(tokens: UsageTokens(input: 10), costUSD: 1.5, calls: 1, sessions: 1, turns: 1),
        byAgent: [], byProject: [], byModel: [],
        pricing: UsagePricingStatus(source: .builtin, modelCount: 1),
        scan: UsageScanStatus(scannedFiles: 1, pendingFiles: 0, isScanning: false)
    )
    await harness.host.setUsageReport(report)
    let needsReview = detail("A", items: 2, at: base)
    try await harness.host.repository.replaceSession(SessionDetail(
        summary: needsReview.summary.withReviewState(needsAttention: true, needsReview: true),
        turns: needsReview.turns, timeline: needsReview.timeline
    ))
    try await harness.host.start()
    try await harness.controller.addChannel(harness.credentials)
    await harness.waitUntil { harness.state?.hasCompleteSync == true }

    // Back in the foreground: a new session starts opening, and the person
    // is already tapping — a Session, the Usage tab.
    let openings = await harness.host.requests.count(where: { $0.kind == .syncIndex })
    harness.controller.refreshAll()
    harness.controller.openSession(hostID: harness.hostID, id: SessionID("A"))
    harness.controller.markReviewed(hostID: harness.hostID, id: SessionID("A"))
    harness.controller.requestUsage(.thisWeek)

    await harness.waitUntil { harness.state?.usage?.report != nil && harness.session("A")?.timeline.count == 2 }
    #expect(harness.state?.usage?.report == report)
    #expect(harness.session("A")?.timeline.count == 2)
    for _ in 0..<300 where await harness.host.reviewed.isEmpty {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(await harness.host.reviewed == [SessionID("A")])
    // One new opening, and nothing arrived out of order or outside a session.
    #expect(await harness.host.requests.count(where: { $0.kind == .syncIndex }) == openings + 1)
    #expect(await harness.host.outOfOrderRequests == 0)
    await harness.host.stop()
}

@Test @MainActor func openingTakesTheTailAndLoadEarlierPagesOlderRows() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = Harness()
    try await harness.host.repository.replaceSession(detail("A", items: 200, at: base))
    try await harness.host.start()
    try await harness.controller.addChannel(harness.credentials)
    await harness.waitUntil { harness.state?.hasCompleteSync == true }
    #expect(harness.session("A")?.timeline.isEmpty == true)

    // Opening takes the newest page only, and says older rows exist.
    harness.controller.openSession(hostID: harness.hostID, id: SessionID("A"))
    await harness.waitUntil { harness.session("A")?.timeline.count == 80 }
    #expect(harness.session("A")?.timeline.first?.id == TimelineItemID("A-item-120"))
    #expect(harness.session("A")?.timeline.last?.id == TimelineItemID("A-item-199"))
    #expect(harness.controller.canLoadOlder(hostID: harness.hostID, id: SessionID("A")))
    #expect(harness.settings.syncMarks(for: harness.hostID)[SessionID("A")] == nil || true)

    // Each `Load earlier` adds one page above, until the Mac has no more.
    harness.controller.loadOlder(hostID: harness.hostID, id: SessionID("A"))
    await harness.waitUntil { harness.session("A")?.timeline.count == 160 }
    #expect(harness.session("A")?.timeline.first?.id == TimelineItemID("A-item-40"))
    #expect(harness.controller.canLoadOlder(hostID: harness.hostID, id: SessionID("A")))
    harness.controller.loadOlder(hostID: harness.hostID, id: SessionID("A"))
    await harness.waitUntil { harness.session("A")?.timeline.count == 200 }
    #expect(!harness.controller.canLoadOlder(hostID: harness.hostID, id: SessionID("A")))
    let kinds = await harness.host.requests.map(\.kind)
    #expect(kinds.filter { $0 == .fetchSession }.count == 1)
    #expect(kinds.filter { $0 == .fetchSessionBefore }.count == 2)
    // The whole page is in the cache too, in order.
    for _ in 0..<300 where try await harness.cache.sessionDetail(id: SessionID("A"), cursor: nil, limit: 500)?.timeline.count != 200 {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await harness.cache.sessionDetail(id: SessionID("A"), cursor: nil, limit: 500)?.timeline.count == 200)
    // The mark remembers the window across a relaunch.
    for _ in 0..<50 where harness.settings.syncMarks(for: harness.hostID)[SessionID("A")]?.hasOlder != false {
        try? await Task.sleep(for: .milliseconds(10))
    }
    let mark = try #require(harness.settings.syncMarks(for: harness.hostID)[SessionID("A")])
    #expect(mark.hasOlder == false)
    #expect(mark.oldest?.id == TimelineItemID("A-item-0"))
    await harness.host.stop()
}

@Test @MainActor func aTrimmedRowIsCompletedOnDemandAndNeverTrimmedAgain() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = Harness()
    let huge = JSONValue.string(String(repeating: "x", count: 200_000))
    let big = TimelineItem(
        id: TimelineItemID("A-big"), sessionID: SessionID("A"), turnID: TurnID("A-turn"), occurredAt: base.addingTimeInterval(5),
        payload: .tool(ToolTimelinePayload(name: "Bash", summary: "ls", content: huge, status: .succeeded, toolUseID: "t1"))
    )
    var full = detail("A", items: 3, at: base)
    full = SessionDetail(summary: full.summary, turns: full.turns, timeline: full.timeline + [big])
    try await harness.host.repository.replaceSession(full)
    try await harness.host.start()
    try await harness.controller.addChannel(harness.credentials)
    await harness.waitUntil { harness.state?.hasCompleteSync == true }

    harness.controller.openSession(hostID: harness.hostID, id: SessionID("A"))
    await harness.waitUntil { harness.session("A")?.timeline.count == 4 }
    let trimmed = try #require(harness.session("A")?.timeline.last)
    #expect(trimmed.isTruncated)
    if case let .tool(payload) = trimmed.payload { #expect(payload.content == nil && payload.summary == "ls") } else { Issue.record("payload kind changed") }

    // Asking for the whole row brings the content; the cache keeps it.
    harness.controller.fetchTimelineItems(hostID: harness.hostID, id: SessionID("A"), itemIDs: [TimelineItemID("A-big")])
    await harness.waitUntil { harness.session("A")?.timeline.last?.isTruncated == false }
    if case let .tool(payload) = harness.session("A")?.timeline.last?.payload { #expect(payload.content == huge) } else { Issue.record("payload kind changed") }

    // The same row arriving trimmed again (a live event) does not undo it.
    let again = AgentIngressEvent(
        eventID: EventID("e-big"), sessionID: SessionID("A"), turnID: TurnID("A-turn"), agent: .codex,
        occurredAt: base.addingTimeInterval(5), phase: .executing, timelineItem: big
    )
    try await harness.host.push(events: [again])
    await harness.waitUntil { harness.session("A")?.summary.phase == .executing }
    #expect(harness.session("A")?.timeline.last?.isTruncated == false)
    for _ in 0..<300 where try await harness.cache.sessionDetail(id: SessionID("A"), cursor: nil, limit: 10)?.timeline.last?.isTruncated != false {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await harness.cache.sessionDetail(id: SessionID("A"), cursor: nil, limit: 10)?.timeline.last?.isTruncated == false)
    await harness.host.stop()
}

@Test @MainActor func aStalledAnswerIsAskedOnceMoreThenGivenUpAlone() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = Harness()
    try await harness.host.repository.replaceSession(detail("A", items: 2, at: base))
    try await harness.host.repository.replaceSession(detail("B", items: 2, at: base))
    try await harness.host.start()
    try await harness.controller.addChannel(harness.credentials)
    await harness.waitUntil { harness.state?.hasCompleteSync == true }

    await harness.host.setStalled([.fetchSession])
    harness.controller.openSession(hostID: harness.hostID, id: SessionID("A"))
    #expect(harness.controller.isFetchingSession(hostID: harness.hostID, id: SessionID("A")))
    // Timeout (2 s in tests): asked once more under a new id…
    for _ in 0..<600 where await harness.host.requests.count(where: { $0.kind == .fetchSession }) < 2 {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(await harness.host.requests.count(where: { $0.kind == .fetchSession }) == 2)
    #expect(harness.controller.isFetchingSession(hostID: harness.hostID, id: SessionID("A")))
    // …then given up, and the Mac told so. Nothing else was reset: the
    // channel is still open and another session opens normally.
    for _ in 0..<600 where await harness.host.cancelled.isEmpty {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(await harness.host.cancelled.count == 1)
    #expect(!harness.controller.isFetchingSession(hostID: harness.hostID, id: SessionID("A")))
    #expect(harness.state?.lastError?.contains("did not answer") == true)
    #expect(await harness.host.requests.count(where: { $0.kind == .syncIndex }) == 1)
    await harness.host.setStalled([])
    harness.controller.openSession(hostID: harness.hostID, id: SessionID("B"))
    await harness.waitUntil { harness.session("B")?.timeline.count == 2 }
    await harness.host.stop()
}

@Test @MainActor func leavingTheDetailCancelsItsPageRequest() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = Harness()
    try await harness.host.repository.replaceSession(detail("A", items: 100, at: base))
    try await harness.host.start()
    try await harness.controller.addChannel(harness.credentials)
    await harness.waitUntil { harness.state?.hasCompleteSync == true }
    harness.controller.openSession(hostID: harness.hostID, id: SessionID("A"))
    await harness.waitUntil { harness.session("A")?.timeline.count == 80 }

    await harness.host.setStalled([.fetchSessionBefore])
    harness.controller.loadOlder(hostID: harness.hostID, id: SessionID("A"))
    #expect(harness.controller.isLoadingOlder(hostID: harness.hostID, id: SessionID("A")))
    harness.controller.closeSession(hostID: harness.hostID, id: SessionID("A"))
    #expect(!harness.controller.isLoadingOlder(hostID: harness.hostID, id: SessionID("A")))
    for _ in 0..<300 where await harness.host.cancelled.isEmpty {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(await harness.host.cancelled.count == 1)
    // What was loaded stays; the window is unchanged.
    #expect(harness.session("A")?.timeline.count == 80)
    #expect(harness.controller.canLoadOlder(hostID: harness.hostID, id: SessionID("A")))
    await harness.host.stop()
}

@Test @MainActor func aMacOnTheSameNetworkIsReachedDirectlyAndTheRelayTakesOverWhenItLeaves() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let harness = Harness(localNetwork: true)
    let direct = try #require(harness.direct)
    try await harness.host.repository.replaceSession(detail("A", items: 2, at: base))
    try await harness.host.start()
    try await harness.controller.addChannel(harness.credentials)
    harness.controller.start()

    // The Mac is on the network: the channel session moves onto the direct
    // link and the Relay carries nothing more for it.
    await harness.waitUntil { harness.state?.connectionPath == .direct && harness.state?.hasCompleteSync == true }
    #expect(harness.state?.connectionPath == .direct)
    #expect(await harness.host.currentPath != .relay)
    let relayFramesBefore = await harness.link.hostSent.count
    harness.controller.openSession(hostID: harness.hostID, id: SessionID("A"))
    await harness.waitUntil { harness.session("A")?.timeline.count == 2 }
    #expect(await harness.link.hostSent.count == relayFramesBefore)
    #expect(await direct.hostSent.count > 0)

    // Wi‑Fi gone: the direct connection drops, the Relay takes the channel
    // back with a fresh session, and the cache is intact.
    let openings = await harness.host.requests.count(where: { $0.kind == .syncIndex })
    await direct.setAdvertised(false)
    await direct.dropAllConnections()
    await harness.waitUntil { harness.state?.connectionPath == .relay && harness.state?.hasCompleteSync == true }
    #expect(await harness.host.requests.count(where: { $0.kind == .syncIndex }) == openings + 1)
    #expect(await harness.host.currentPath == .relay)
    #expect(harness.session("A")?.timeline.count == 2)

    // Back on the network: direct again.
    await direct.setAdvertised(true)
    await harness.waitUntil { harness.state?.connectionPath == .direct && harness.state?.hasCompleteSync == true }
    #expect(await harness.host.currentPath != .relay)
    await harness.host.stop()
}
