import Adapters
import Core
import DaemonRuntime
import IPCClient
import Transport
import Foundation
import Testing

private func hookFrame(_ fields: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: fields)
}

@Test func serviceIngestsHookFramesAndListsSessions() async throws {
    let repository = InMemorySessionRepository()
    let service = DaemonService(repository: repository, socketPath: "/tmp/lumi.sock", executableHash: "test-hash")
    let backfill = TranscriptBackfillQueue(repository: repository)
    await service.attachHookIngest(HookIngestService(
        repository: repository,
        backfill: backfill,
        codexAdapter: CodexAdapter(threads: FixedThreadIdentities(identities: [:]))
    ))

    let accepted = await service.handle(TransportEnvelope(payload: IPCRequest(
        operation: .ingestHook,
        createdAt: Date(),
        agent: .codex,
        env: [:],
        data: hookFrame(["session_id": "session", "turn_id": "t1", "cwd": "/tmp", "hook_event_name": "UserPromptSubmit", "prompt": "hi"])
    )))
    #expect(accepted.payload.status == .accepted)

    let listed = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .listSessions)))
    #expect(listed.payload.sessions?.map(\.id) == [SessionID("session")])

    // A frame the daemon cannot decode is rejected, not dropped silently.
    let rejected = await service.handle(TransportEnvelope(payload: IPCRequest(
        operation: .ingestHook,
        createdAt: Date(),
        agent: .codex,
        env: [:],
        data: hookFrame(["hook_event_name": "UserPromptSubmit"])
    )))
    #expect(rejected.payload.failure?.code == "malformed_hook")

    let cleared = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .clearHistory)))
    #expect(cleared.payload.status == .ok)
    let empty = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .listSessions)))
    #expect(empty.payload.sessions?.isEmpty == true)
}

@Test func serviceDeletesOneSessionAndRejectsItsLateEvents() async throws {
    let repository = InMemorySessionRepository()
    let service = DaemonService(repository: repository, socketPath: "/tmp/lumi.sock", executableHash: "test-hash")
    let sessionID = SessionID("session-to-delete")
    _ = try await repository.apply(AgentIngressEvent(
        eventID: EventID("first-event"),
        sessionID: sessionID,
        agent: .codex,
        occurredAt: Date(timeIntervalSince1970: 100),
        lifecycle: .running,
        phase: .thinking
    ))

    let deleted = await service.handle(TransportEnvelope(
        payload: IPCRequest(operation: .deleteSession, sessionID: sessionID)
    ))
    #expect(deleted.payload.status == .ok)

    let late = try await repository.apply(AgentIngressEvent(
        eventID: EventID("late-event"),
        sessionID: sessionID,
        agent: .codex,
        occurredAt: Date(timeIntervalSince1970: 200),
        lifecycle: .running,
        phase: .executing
    ))
    #expect(late == false)
    let listed = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .listSessions)))
    #expect(listed.payload.sessions?.isEmpty == true)
}

@Test func serviceBroadcastsHookDiscardsAndHidesProvisionalSessionsFromHealth() async throws {
    let repository = InMemorySessionRepository()
    let hub = DaemonSubscriptionHub()
    let capture = EventCapture()
    let subscriptionID = hub.subscribe { message in
        if case let .event(event) = message { capture.append(event) }
    }
    defer { hub.unsubscribe(subscriptionID) }
    let service = DaemonService(repository: repository, socketPath: "/tmp/lumi.sock", executableHash: "test-hash", subscriptions: hub)
    let backfill = TranscriptBackfillQueue(repository: repository)
    await service.attachHookIngest(HookIngestService(
        repository: repository,
        backfill: backfill,
        onEvent: { hub.publish($0) }
    ))
    let ghost = SessionID("ghost")
    // A Claude probe: SessionStart with no transcript on disk, no turn ever.
    let base: [String: Any] = ["session_id": ghost.rawValue, "cwd": "/tmp/none", "transcript_path": "/tmp/none/missing.jsonl"]
    _ = await service.handle(TransportEnvelope(payload: IPCRequest(
        operation: .ingestHook,
        createdAt: Date(timeIntervalSince1970: 100),
        agent: .claude,
        env: [:],
        data: hookFrame(base.merging(["hook_event_name": "SessionStart", "source": "startup"]) { $1 })
    )))

    // Provisional: retained, but not "active".
    let detail = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .getSession, sessionID: ghost, limit: 1)))
    #expect(detail.payload.session?.summary.isProvisional == true)
    let health = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .health)))
    #expect(health.payload.health?.activeSessionCount == 0)
    #expect(health.payload.health?.retainedSessionCount == 1)

    let response = await service.handle(TransportEnvelope(payload: IPCRequest(
        operation: .ingestHook,
        createdAt: Date(timeIntervalSince1970: 102),
        agent: .claude,
        env: [:],
        data: hookFrame(base.merging(["hook_event_name": "SessionEnd", "reason": "other"]) { $1 })
    )))
    #expect(response.payload.status == .accepted)
    #expect(response.payload.acceptedCount == 1)
    #expect(capture.events.last?.disposition == .discard)

    let listed = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .listSessions)))
    #expect(listed.payload.sessions?.isEmpty == true)
    let gone = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .getSession, sessionID: ghost, limit: 1)))
    #expect(gone.payload.failure?.code == "session_not_found")
}

@Test func subscriptionHubMultiplexesEventsWithoutSessionChannels() {
    let hub = DaemonSubscriptionHub()
    let capture = EventCapture()
    let subscriptionID = hub.subscribe { message in
        if case let .event(event) = message { capture.append(event) }
    }
    defer { hub.unsubscribe(subscriptionID) }

    for index in 1...3 {
        hub.publish(AgentIngressEvent(
            eventID: EventID("event-\(index)"),
            sessionID: SessionID("session-\(index)"),
            agent: .codex,
            occurredAt: Date(timeIntervalSince1970: Double(index))
        ))
    }

    #expect(capture.events.map(\.sessionID) == [
        SessionID("session-1"),
        SessionID("session-2"),
        SessionID("session-3"),
    ])
}

@Test func unixSocketIsOwnerOnlyAndServesHealth() async throws {
    let socketPath = "/tmp/as-\(UUID().uuidString.prefix(8)).sock"
    defer { try? FileManager.default.removeItem(atPath: socketPath) }
    let repository = InMemorySessionRepository()
    let service = DaemonService(repository: repository, socketPath: socketPath, executableHash: "test-hash")
    let server = DaemonServer(socketPath: socketPath, service: service)
    try server.start()
    defer { server.shutdown() }

    let permissions = try FileManager.default.attributesOfItem(atPath: socketPath)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)

    let response = try DaemonIPCClient().request(
        IPCRequest(operation: .health),
        socketPath: socketPath
    )
    #expect(response.status == .ok)
    #expect(response.health?.daemonVersion == DaemonService.version)
    #expect(response.health?.executableHash == "test-hash")
}

@Test func listPlusPagedGetSessionReassemblesEverySession() async throws {
    let repository = InMemorySessionRepository()
    let service = DaemonService(repository: repository, socketPath: "/tmp/lumi.sock", executableHash: "test-hash")
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    // Two sessions, one of them wider than a single page.
    for (session, itemCount) in [("session-1", 5), ("session-2", 12)] {
        let sessionID = SessionID(session)
        for index in 0..<itemCount {
            _ = try await repository.apply(AgentIngressEvent(
                eventID: EventID("\(session)-event-\(index)"),
                sessionID: sessionID,
                agent: .codex,
                occurredAt: date.addingTimeInterval(Double(index)),
                lifecycle: .running,
                phase: .executing,
                timelineItem: TimelineItem(
                    id: TimelineItemID("\(session)-item-\(index)"),
                    sessionID: sessionID,
                    occurredAt: date.addingTimeInterval(Double(index)),
                    payload: .message(MessageTimelinePayload(role: .assistant, text: "Update \(index)"))
                )
            ))
        }
    }

    // The reconcile shape: a summary index, then per-session paged fetches.
    let list = await service.handle(TransportEnvelope(
        payload: IPCRequest(operation: .listSessions, limit: 10_000)
    ))
    #expect(list.payload.sessions?.count == 2)

    for summary in list.payload.sessions ?? [] {
        var cursor: PaginationCursor?
        var timeline: [TimelineItem] = []
        var pages = 0
        repeat {
            let response = await service.handle(TransportEnvelope(
                payload: IPCRequest(operation: .getSession, sessionID: summary.id, cursor: cursor, limit: 5)
            ))
            guard let page = response.payload.session else { break }
            timeline.append(contentsOf: page.timeline)
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil
        let expected = try await repository.sessionDetail(id: summary.id, cursor: nil, limit: 500)
        #expect(timeline == expected?.timeline)
        #expect(pages == (summary.id.rawValue == "session-2" ? 3 : 1))
    }

    // The removed whole-snapshot operation no longer decodes at all.
    #expect(throws: DecodingError.self) {
        try TransportCoding.makeDecoder().decode(
            TransportEnvelope<IPCRequest>.self,
            from: Data(#"{"version":"1.2","requestID":"r","sentAt":"2026-01-01T00:00:00Z","payload":{"operation":"snapshot_sessions"}}"#.utf8)
        )
    }
}

@Test func oversizedResponseBecomesACleanFailureFrame() async throws {
    let socketPath = "/tmp/as-large-\(UUID().uuidString.prefix(8)).sock"
    defer { try? FileManager.default.removeItem(atPath: socketPath) }
    let repository = InMemorySessionRepository()
    let service = DaemonService(repository: repository, socketPath: socketPath, executableHash: "test-hash")
    let server = DaemonServer(socketPath: socketPath, service: service)
    try server.start()
    defer { server.shutdown() }

    let sessionID = SessionID("huge")
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    // Ten 1 MiB items: one 500-limit page overflows the 8 MiB frame,
    // a 5-item page fits.
    for index in 0..<10 {
        _ = try await repository.apply(AgentIngressEvent(
            eventID: EventID("huge-event-\(index)"),
            sessionID: sessionID,
            agent: .codex,
            occurredAt: date.addingTimeInterval(Double(index)),
            lifecycle: .running,
            phase: .executing,
            timelineItem: TimelineItem(
                id: TimelineItemID("huge-item-\(index)"),
                sessionID: sessionID,
                occurredAt: date.addingTimeInterval(Double(index)),
                payload: .message(MessageTimelinePayload(
                    role: .assistant,
                    text: String(repeating: "x", count: 1_048_576)
                ))
            )
        ))
    }

    let oversized = try DaemonIPCClient().request(
        IPCRequest(operation: .getSession, sessionID: sessionID, limit: 500),
        socketPath: socketPath,
        timeout: .seconds(15)
    )
    #expect(oversized.failure?.code == "response_too_large")

    let paged = try DaemonIPCClient().request(
        IPCRequest(operation: .getSession, sessionID: sessionID, limit: 5),
        socketPath: socketPath,
        timeout: .seconds(15)
    )
    #expect(paged.session?.timeline.count == 5)
    #expect(paged.session?.nextCursor != nil)
}

@Test func unavailableUnixSocketReturnsAnErrorWithoutLeakingPromises() {
    let socketPath = "/tmp/as-missing-\(UUID().uuidString).sock"
    var didThrow = false

    do {
        _ = try DaemonIPCClient().request(
            IPCRequest(operation: .health),
            socketPath: socketPath
        )
    } catch {
        didThrow = true
    }

    #expect(didThrow)
}

@Test func rolloutWatcherResumesFromPersistedOffset() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumi-rollout-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rollout = directory.appendingPathComponent("rollout.jsonl")
    let initial = """
    {"timestamp":"2026-08-16T10:00:00Z","type":"session_meta","payload":{"id":"session-1","cwd":"/tmp/project"}}
    {"timestamp":"2026-08-16T10:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"Sanitized prompt"}}

    """
    try Data(initial.utf8).write(to: rollout)

    let repository = InMemorySessionRepository()
    let watcher = CodexRolloutWatcher(rootDirectory: directory, repository: repository)
    await watcher.scanOnce()
    let firstDetail = try await repository.sessionDetail(id: SessionID("session-1"), cursor: nil, limit: 100)
    #expect(firstDetail?.timeline.count == 2)   // session-started marker + user prompt

    let handle = try FileHandle(forWritingTo: rollout)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("""
    {"timestamp":"2026-08-16T10:00:02Z","type":"event_msg","payload":{"type":"agent_message","message":"Sanitized response"}}

    """.utf8))
    try handle.close()

    await watcher.scanOnce()
    let secondDetail = try await repository.sessionDetail(id: SessionID("session-1"), cursor: nil, limit: 100)
    #expect(secondDetail?.timeline.count == 3)
}

@Test func rolloutWatcherSkipsForkedParentHistoryUntilSubagentTrigger() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumi-subagent-rollout-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rollout = directory.appendingPathComponent("rollout.jsonl")
    let childID = SessionID("child-session")
    let parentID = SessionID("parent-session")
    let inheritedPrefix = #"""
    {"timestamp":"2026-08-18T04:19:27Z","type":"session_meta","payload":{"id":"child-session","cwd":"/tmp/project","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session","depth":1,"agent_path":"/root/docs_review","agent_nickname":"Hypatia","agent_role":null}}}}}
    {"timestamp":"2026-08-18T04:19:27Z","type":"session_meta","payload":{"id":"parent-session","cwd":"/tmp/project","source":"vscode"}}
    {"timestamp":"2026-08-18T04:19:27Z","type":"event_msg","payload":{"type":"task_started","turn_id":"parent-turn"}}
    {"timestamp":"2026-08-18T04:19:27Z","type":"event_msg","payload":{"type":"user_message","message":"Inherited parent request"}}
    {"timestamp":"2026-08-18T04:19:27Z","type":"event_msg","payload":{"type":"agent_message","message":"Inherited parent response"}}
    {"timestamp":"2026-08-18T04:19:28Z","type":"event_msg","payload":{"type":"task_started","turn_id":"child-turn"}}

    """#
    try Data((inheritedPrefix + "\n").utf8).write(to: rollout)

    let repository = InMemorySessionRepository()
    let identity = CodexThreadIdentity(
        sessionID: childID,
        threadSource: "subagent",
        agentNickname: "Hypatia",
        agentPath: "/root/docs_review",
        parentSessionID: parentID,
        subagentDepth: 1,
        subagentKind: "thread_spawn"
    )
    let identities = MutableThreadIdentityProvider(identities: [childID: identity])
    let watcher = CodexRolloutWatcher(
        rootDirectory: directory,
        repository: repository,
        threadIdentities: identities
    )

    await watcher.scanOnce()
    #expect(try await repository.listSessions(limit: 10).isEmpty)
    #expect(try await repository.rolloutCursor(path: rollout.path) == nil)

    let handle = try FileHandle(forWritingTo: rollout)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((#"""
    {"timestamp":"2026-08-18T04:19:30Z","type":"inter_agent_communication_metadata","payload":{"trigger_turn":true}}
    {"timestamp":"2026-08-18T04:19:31Z","type":"event_msg","payload":{"type":"agent_message","message":"Child review started"}}

    """# + "\n").utf8))
    try handle.close()

    let restartedWatcher = CodexRolloutWatcher(
        rootDirectory: directory,
        repository: repository,
        threadIdentities: identities
    )
    await restartedWatcher.scanOnce()

    let incrementalHandle = try FileHandle(forWritingTo: rollout)
    try incrementalHandle.seekToEnd()
    try incrementalHandle.write(contentsOf: Data((#"""
    {"timestamp":"2026-08-18T04:19:32Z","type":"event_msg","payload":{"type":"agent_message","message":"Child review continued"}}

    """# + "\n").utf8))
    try incrementalHandle.close()

    let secondRestartedWatcher = CodexRolloutWatcher(
        rootDirectory: directory,
        repository: repository,
        threadIdentities: identities
    )
    await secondRestartedWatcher.scanOnce()

    let summaries = try await repository.listSessions(limit: 10)
    let detail = try #require(try await repository.sessionDetail(id: childID, cursor: nil, limit: 100))
    #expect(summaries.map(\.id) == [childID])
    #expect(summaries.first?.title == "Hypatia · docs_review")
    #expect(detail.timeline.compactMap { item -> String? in
        guard case let .message(message) = item.payload else { return nil }
        return message.text
    } == ["Child review started", "Child review continued"])
    #expect(try await repository.sessionDetail(id: parentID, cursor: nil, limit: 100) == nil)
}

@Test func rolloutWatcherSynchronizesCodexTitlesAndSubagentIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumi-title-sync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = InMemorySessionRepository()
    let sessionID = SessionID("titled-session")
    let date = Date(timeIntervalSince1970: 100)
    #expect(try await repository.apply(AgentIngressEvent(
        eventID: EventID("create"),
        sessionID: sessionID,
        agent: .codex,
        occurredAt: date,
        lifecycle: .waitingForInput,
        phase: .idle
    )))
    let capture = EventCapture()
    let originalIdentity = CodexThreadIdentity(
        sessionID: sessionID,
        threadSource: "subagent",
        agentNickname: "Hypatia",
        agentPath: "/root/docs_review",
        parentSessionID: SessionID("parent-session"),
        subagentDepth: 1,
        subagentKind: "thread_spawn"
    )
    let provider = MutableThreadIdentityProvider(identities: [sessionID: originalIdentity])
    let watcher = CodexRolloutWatcher(
        rootDirectory: directory,
        repository: repository,
        threadIdentities: provider,
        onEvent: capture.append
    )

    await watcher.scanOnce()
    provider.set(CodexThreadIdentity(
        sessionID: sessionID,
        title: "Renamed Subagent",
        threadSource: "subagent",
        agentNickname: "Hypatia",
        agentPath: "/root/docs_review",
        parentSessionID: SessionID("parent-session"),
        subagentDepth: 1,
        subagentKind: "thread_spawn"
    ))
    await watcher.scanOnce()
    provider.set(originalIdentity)
    await watcher.scanOnce()

    let roundTripped = try #require(try await repository.listSessions(limit: 10).first)
    #expect(roundTripped.title == "Hypatia · docs_review")
    #expect(roundTripped.agent == .codexSubagent)
    #expect(roundTripped.lineage?.parentSessionID == SessionID("parent-session"))
    // Identity churn moves the record clock (sync must see it) but never the
    // state clock that drives activity ordering.
    #expect(roundTripped.updatedAt >= date)
    #expect(roundTripped.lastActivityAt == date)
    #expect(capture.events.map(\.title) == [
        "Hypatia · docs_review",
        "Renamed Subagent",
        "Hypatia · docs_review",
    ])
}

// The identity sync must mirror the reducer's guards before emitting: a
// lineage-less `.codex` identity against a stored `.codexSubagent` summary
// is a diff the reducer refuses (demotesSubagent), so emitting it would
// mint a fresh accepted-but-ineffective event every poll, forever.
@Test func identitySyncStaysQuietWhenTheReducerWouldRefuseTheDiff() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumi-identity-quiet-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = InMemorySessionRepository()
    let sessionID = SessionID("subagent-session")
    _ = try await repository.apply(AgentIngressEvent(
        eventID: EventID("seed"),
        sessionID: sessionID,
        agent: .codexSubagent,
        occurredAt: Date(timeIntervalSince1970: 100),
        title: "Hypatia · docs_review",
        lifecycle: .completed,
        phase: .idle,
        lineage: SessionLineage(threadSource: "subagent", parentSessionID: SessionID("parent"))
    ))

    // The state DB stopped reporting the subagent source: identity resolves
    // to a bare `.codex` with no lineage and an inherited (nil) title.
    let capture = EventCapture()
    let watcher = CodexRolloutWatcher(
        rootDirectory: directory,
        repository: repository,
        threadIdentities: MutableThreadIdentityProvider(identities: [
            sessionID: CodexThreadIdentity(sessionID: sessionID),
        ]),
        onEvent: capture.append
    )
    await watcher.scanOnce()
    await watcher.scanOnce()
    #expect(capture.events.isEmpty)
    let summary = try #require(try await repository.sessionDetail(id: sessionID, cursor: nil, limit: 1)?.summary)
    #expect(summary.agent == .codexSubagent)
    #expect(summary.title == "Hypatia · docs_review")
}

// The owning AaaS is the authority on the title: a Paseo-owned session —
// alive or long ended — keeps its Paseo title even though the identity sync
// keeps seeing a different native thread name. Agent/lineage still sync.
@Test func titleSyncLeavesWrapperOwnedSessionsAloneButStillSyncsIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumi-aaas-sync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = InMemorySessionRepository()
    let sessionID = SessionID("paseo-owned")
    _ = try await repository.apply(AgentIngressEvent(
        eventID: EventID("seed"),
        sessionID: sessionID,
        agent: .codex,
        occurredAt: Date(timeIntervalSince1970: 100),
        title: "[CUA] Paseo 里的标题",
        lifecycle: .interrupted,
        phase: .idle,
        aaas: SessionAaaS(kind: .paseo, agentID: "p-1")
    ))

    let identity = CodexThreadIdentity(
        sessionID: sessionID,
        title: "Native thread title",
        threadSource: "subagent",
        agentNickname: "Hypatia",
        agentPath: "/root/docs_review",
        parentSessionID: SessionID("parent-session"),
        subagentDepth: 1,
        subagentKind: "thread_spawn"
    )
    let watcher = CodexRolloutWatcher(
        rootDirectory: directory,
        repository: repository,
        threadIdentities: MutableThreadIdentityProvider(identities: [sessionID: identity])
    )
    await watcher.scanOnce()
    await watcher.scanOnce()

    let summary = try #require(try await repository.sessionDetail(id: sessionID, cursor: nil, limit: 1)?.summary)
    #expect(summary.title == "[CUA] Paseo 里的标题")
    #expect(summary.agent == .codexSubagent)
    #expect(summary.lineage?.parentSessionID == SessionID("parent-session"))
    #expect(summary.aaas?.kind == .paseo)
}

@Test func firstRunBaselineIgnoresExistingSessionsAndRecordsNewFiles() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumi-baseline-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let existing = directory.appendingPathComponent("existing.jsonl")
    try Data("""
    {"timestamp":"2026-08-16T10:00:00Z","type":"session_meta","payload":{"id":"existing-session","cwd":"/tmp/old"}}
    {"timestamp":"2026-08-16T10:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"Old prompt"}}

    """.utf8).write(to: existing)

    let repository = InMemorySessionRepository()
    let watcher = CodexRolloutWatcher(rootDirectory: directory, repository: repository)
    try await watcher.prepareInitialBaseline()
    await watcher.scanOnce()
    #expect(try await repository.listSessions(limit: 100).isEmpty)

    let fresh = directory.appendingPathComponent("fresh.jsonl")
    try Data("""
    {"timestamp":"2026-08-16T10:01:00Z","type":"session_meta","payload":{"id":"fresh-session","cwd":"/tmp/new"}}
    {"timestamp":"2026-08-16T10:01:01Z","type":"event_msg","payload":{"type":"user_message","message":"New prompt"}}

    """.utf8).write(to: fresh)
    await watcher.scanOnce()

    #expect(try await repository.listSessions(limit: 100).map(\.id) == [SessionID("fresh-session")])
}

// Upgrade path: a store that ingested sessions before any baseline existed
// (hook-driven reads predate the always-on watcher) must not have its live
// sessions ignored or their cursors clobbered by the first-run baseline.
@Test func firstRunBaselineLeavesAlreadyTrackedSessionsAlone() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumi-upgrade-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // A tracked session with a cursor short of the file: the stranded-tail
    // shape (`turn_aborted` written after the last hook).
    let tracked = directory.appendingPathComponent("tracked.jsonl")
    let head = """
    {"timestamp":"2026-08-29T04:46:20Z","type":"session_meta","payload":{"id":"tracked-session","cwd":"/tmp/project"}}
    {"timestamp":"2026-08-29T04:46:21Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}

    """
    let tail = """
    {"timestamp":"2026-08-29T04:49:16Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-1","reason":"interrupted"}}

    """
    try Data((head + tail).utf8).write(to: tracked)

    // A known session whose cursor was never claimed (hook-only ingestion).
    let known = directory.appendingPathComponent("known.jsonl")
    try Data("""
    {"timestamp":"2026-08-29T04:00:00Z","type":"session_meta","payload":{"id":"known-session","cwd":"/tmp/project"}}

    """.utf8).write(to: known)

    // Pre-Lumi history: session the store has never seen.
    let foreign = directory.appendingPathComponent("foreign.jsonl")
    try Data("""
    {"timestamp":"2026-08-01T00:00:00Z","type":"session_meta","payload":{"id":"foreign-session","cwd":"/tmp/old"}}

    """.utf8).write(to: foreign)

    let repository = InMemorySessionRepository()
    for id in ["tracked-session", "known-session"] {
        _ = try await repository.apply(AgentIngressEvent(
            eventID: EventID("seed-\(id)"), sessionID: SessionID(id), agent: .codex,
            occurredAt: Date(timeIntervalSince1970: 100), lifecycle: .running, phase: .thinking
        ))
    }
    try await repository.saveRolloutCursor(RolloutCursor(
        path: tracked.path,
        byteOffset: UInt64(head.utf8.count),
        fileSize: UInt64(head.utf8.count),
        sessionID: SessionID("tracked-session")
    ))

    let watcher = CodexRolloutWatcher(rootDirectory: directory, repository: repository)
    try await watcher.prepareInitialBaseline()

    // Tracked cursor untouched; known session takes over from EOF with its
    // own id; only the foreign session is ignored.
    #expect(try await repository.rolloutCursor(path: tracked.path)?.byteOffset == UInt64(head.utf8.count))
    #expect(try await repository.rolloutCursor(path: known.path)?.sessionID == SessionID("known-session"))
    #expect(try await !repository.isSessionIgnored(SessionID("tracked-session")))
    #expect(try await !repository.isSessionIgnored(SessionID("known-session")))
    #expect(try await repository.isSessionIgnored(SessionID("foreign-session")))

    // The first scan then heals the stranded tail.
    await watcher.scanOnce()
    let healed = try await repository.sessionDetail(id: SessionID("tracked-session"), cursor: nil, limit: 100)
    #expect(healed?.summary.lifecycle == .interrupted)
    #expect(try await repository.sessionDetail(id: SessionID("foreign-session"), cursor: nil, limit: 1) == nil)
}

// The motivating bug: an interrupt writes `turn_aborted` to the rollout
// seconds after the last hook, and no hook ever fires again. The always-on
// watcher must close the turn from the tail alone.
@Test func rolloutWatcherClosesATurnAbortedAfterTheLastHook() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumi-abort-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rollout = directory.appendingPathComponent("rollout.jsonl")
    try Data("""
    {"timestamp":"2026-08-29T04:46:20Z","type":"session_meta","payload":{"id":"aborted-session","cwd":"/tmp/project"}}
    {"timestamp":"2026-08-29T04:46:21Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
    {"timestamp":"2026-08-29T04:46:22Z","type":"event_msg","payload":{"type":"user_message","message":"open a page"}}

    """.utf8).write(to: rollout)

    let repository = InMemorySessionRepository()
    let watcher = CodexRolloutWatcher(rootDirectory: directory, repository: repository)
    await watcher.scanOnce()
    let sid = SessionID("aborted-session")
    let running = try await repository.sessionDetail(id: sid, cursor: nil, limit: 100)
    #expect(running?.summary.lifecycle == .running)

    // The interrupt: written to the rollout with no hook to deliver it.
    let handle = try FileHandle(forWritingTo: rollout)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("""
    {"timestamp":"2026-08-29T04:49:16Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-1","reason":"interrupted"}}

    """.utf8))
    try handle.close()

    await watcher.scanOnce()
    let interrupted = try await repository.sessionDetail(id: sid, cursor: nil, limit: 100)
    #expect(interrupted?.summary.lifecycle == .interrupted)
    #expect(interrupted?.summary.phase == .idle)
    #expect(interrupted?.turns.first?.outcome == .aborted)
}

// Regression for the retired per-line watcher: reading each line with a fresh
// state lost the current turn and the tool-name pairing. Through the shared
// catch-up, tool calls and results pair up and every row lands on the turn.
@Test func rolloutWatcherKeepsTurnAttributionAndToolPairingAcrossLines() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumi-pairing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rollout = directory.appendingPathComponent("rollout.jsonl")
    try Data("""
    {"timestamp":"2026-08-29T04:00:00Z","type":"session_meta","payload":{"id":"paired-session","cwd":"/tmp/project"}}
    {"timestamp":"2026-08-29T04:00:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
    {"timestamp":"2026-08-29T04:00:02Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call_1","name":"exec","input":"ls"}}
    {"timestamp":"2026-08-29T04:00:03Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_1","output":"{\\"output\\":\\"ok\\",\\"metadata\\":{\\"exit_code\\":0}}"}}
    {"timestamp":"2026-08-29T04:00:04Z","type":"event_msg","payload":{"type":"agent_message","message":"Done."}}

    """.utf8).write(to: rollout)

    let repository = InMemorySessionRepository()
    let watcher = CodexRolloutWatcher(rootDirectory: directory, repository: repository)
    await watcher.scanOnce()

    let sid = SessionID("paired-session")
    let detail = try #require(try await repository.sessionDetail(id: sid, cursor: nil, limit: 100))
    let toolRows = detail.timeline.compactMap { item -> ToolTimelinePayload? in
        guard case let .tool(tool) = item.payload else { return nil }
        return tool
    }
    #expect(toolRows.count == 2)
    #expect(toolRows.allSatisfy { $0.toolUseID == "call_1" })
    // The result row resolves its name from the call seen lines earlier.
    #expect(toolRows.last?.name == "exec")
    // Everything after the turn opener is attributed to turn-1.
    let attributed = detail.timeline.filter { $0.turnID == TurnID("turn-1") }
    #expect(attributed.count >= 3)
    #expect(detail.turns.first?.toolCallCount == 1)
}

private final class EventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentIngressEvent] = []

    var events: [AgentIngressEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ event: AgentIngressEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

private final class MutableThreadIdentityProvider: CodexThreadIdentityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [SessionID: CodexThreadIdentity]

    init(identities: [SessionID: CodexThreadIdentity]) {
        self.identities = identities
    }

    func identity(for sessionID: SessionID) -> CodexThreadIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return identities[sessionID]
    }

    func set(_ identity: CodexThreadIdentity) {
        lock.lock()
        identities[identity.sessionID] = identity
        lock.unlock()
    }
}

@Test func serviceReingestsASessionFromItsTranscript() async throws {
    let session = "ffffffff-1111-2222-3333-444444444444"
    let sid = SessionID(session)
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let projectDir = home.appendingPathComponent(".claude/projects/-tmp-proj", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let path = projectDir.appendingPathComponent("\(session).jsonl").path
    let records: [[String: Any]] = [
        ["type": "user", "uuid": "u1", "sessionId": session, "promptId": "p1", "timestamp": "2026-08-19T06:42:07.000Z", "cwd": "/tmp/proj", "origin": ["kind": "human"],
         "message": ["role": "user", "content": "hi"]],
        ["type": "assistant", "uuid": "a1", "sessionId": session, "timestamp": "2026-08-19T06:42:10.000Z",
         "message": ["role": "assistant", "model": "claude-opus-4-7", "stop_reason": "end_turn", "content": [["type": "text", "text": "Hello."]]]],
    ]
    try (records.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n") + "\n")
        .write(toFile: path, atomically: true, encoding: .utf8)

    let repository = InMemorySessionRepository()
    let service = DaemonService(
        repository: repository,
        socketPath: "/tmp/lumi.sock",
        executableHash: "test-hash",
        reingester: SessionReingester(repository: repository, homeDirectory: home)
    )
    // The daemon only knows a stuck summary; the transcript is found by cwd.
    _ = try await repository.apply(AgentIngressEvent(
        eventID: EventID("stuck"), sessionID: sid, turnID: TurnID("p1"), agent: .claude,
        occurredAt: Date(), workspace: "/tmp/proj", lifecycle: .running, phase: .thinking
    ))

    let rebuilt = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .reingestSession, sessionID: sid)))
    #expect(rebuilt.payload.status == .ok)
    #expect(rebuilt.payload.session?.summary.lifecycle == .waitingForInput)
    #expect(rebuilt.payload.session?.turns.first?.prompt == "hi")
    #expect(rebuilt.payload.session?.turns.first?.outcome == .completed)

    let missing = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .reingestSession, sessionID: SessionID("nope"))))
    #expect(missing.payload.failure?.code == "session_not_found")

    _ = try await repository.apply(AgentIngressEvent(
        eventID: EventID("orphan"), sessionID: SessionID("orphan"), agent: .claude, occurredAt: Date(), lifecycle: .running
    ))
    let orphan = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .reingestSession, sessionID: SessionID("orphan"))))
    #expect(orphan.payload.failure?.code == "rich_source_unavailable")
}

// A user interrupt fires no hook: only the transcript records it. The watcher
// must pick up the increment for active Claude sessions (cursor resume), and
// must leave parked sessions alone.
@Test func claudeWatcherIngestsInterruptAndTitleWrittenAfterTheLastHook() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumi-claude-watcher-\(UUID().uuidString)", isDirectory: true)
    let projectDir = home.appendingPathComponent(".claude/projects/-tmp-project", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let sid = SessionID("aaaa1111-0000-0000-0000-000000000001")
    let transcript = projectDir.appendingPathComponent("\(sid.rawValue).jsonl")
    try Data("""
    {"type":"user","sessionId":"\(sid.rawValue)","promptId":"p1","timestamp":"2026-08-20T09:44:42Z","origin":{"kind":"human"},"message":{"role":"user","content":"Do the thing"}}

    """.utf8).write(to: transcript)

    let repository = InMemorySessionRepository()
    _ = try await repository.apply(AgentIngressEvent(
        eventID: EventID("seed"), sessionID: sid, agent: .claude,
        occurredAt: Date(timeIntervalSince1970: 1_787_219_000), workspace: "/tmp/project",
        lifecycle: .running, phase: .thinking
    ))

    let watcher = ClaudeTranscriptWatcher(repository: repository, homeDirectory: home)
    await watcher.scanOnce()
    let running = try await repository.sessionDetail(id: sid, cursor: nil, limit: 100)
    #expect(running?.summary.lifecycle == .running)
    #expect(running?.timeline.contains { if case .message = $0.payload { true } else { false } } == true)

    // Stop pressed: title + interrupt marker land with no hook ever firing.
    let handle = try FileHandle(forWritingTo: transcript)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("""
    {"type":"custom-title","customTitle":"Renamed session","sessionId":"\(sid.rawValue)"}
    {"type":"user","sessionId":"\(sid.rawValue)","timestamp":"2026-08-20T09:44:44Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}

    """.utf8))
    try handle.close()

    await watcher.scanOnce()
    let interrupted = try await repository.sessionDetail(id: sid, cursor: nil, limit: 100)
    #expect(interrupted?.summary.lifecycle == .interrupted)
    #expect(interrupted?.summary.title == "Renamed session")
    #expect(interrupted?.timeline.contains { item in
        if case let .turnEnd(end) = item.payload { end.outcome == .aborted } else { false }
    } == true)

    // A parked finished session is not polled, even with a marker in its file.
    let parked = SessionID("aaaa1111-0000-0000-0000-000000000002")
    try Data("""
    {"type":"user","sessionId":"\(parked.rawValue)","timestamp":"2026-08-20T09:50:00Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}

    """.utf8).write(to: projectDir.appendingPathComponent("\(parked.rawValue).jsonl"))
    _ = try await repository.apply(AgentIngressEvent(
        eventID: EventID("seed-parked"), sessionID: parked, agent: .claude,
        occurredAt: Date(timeIntervalSince1970: 1_787_219_000), workspace: "/tmp/project",
        lifecycle: .waitingForInput, phase: .idle
    ))
    await watcher.scanOnce()
    let untouched = try await repository.sessionDetail(id: parked, cursor: nil, limit: 100)
    #expect(untouched?.summary.lifecycle == .waitingForInput)
}

@Test func backfillQueueRebuildsAColdSessionAndYieldsToNewerHookState() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumi-backfill-\(UUID().uuidString)", isDirectory: true)
    let projectDir = home.appendingPathComponent(".claude/projects/-tmp-project", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let sid = SessionID("bbbb2222-0000-0000-0000-000000000001")
    let transcript = projectDir.appendingPathComponent("\(sid.rawValue).jsonl")
    try Data("""
    {"type":"user","sessionId":"\(sid.rawValue)","promptId":"p1","timestamp":"2026-08-20T09:00:00Z","cwd":"/tmp/project","origin":{"kind":"human"},"message":{"role":"user","content":"Do the thing"}}
    {"type":"assistant","sessionId":"\(sid.rawValue)","timestamp":"2026-08-20T09:00:05Z","message":{"role":"assistant","model":"claude-opus-4-7","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}

    """.utf8).write(to: transcript)

    // The cold session was first seen through a hook: newer wall-clock state
    // already sits in the store before the history lands.
    let repository = InMemorySessionRepository()
    _ = try await repository.apply(AgentIngressEvent(
        eventID: EventID("hook-stop"), sessionID: sid, agent: .claude,
        occurredAt: Date(timeIntervalSince1970: 1_787_300_000), workspace: "/tmp/project",
        lifecycle: .waitingForInput, phase: .idle
    ))

    let queue = TranscriptBackfillQueue(repository: repository)
    await queue.enqueue(sessionID: sid, path: transcript.path)
    await queue.flush()

    let detail = try await repository.sessionDetail(id: sid, cursor: nil, limit: 100)
    // History is in: timeline rows, the turn, and an advanced cursor.
    #expect(detail?.timeline.contains { if case .message = $0.payload { true } else { false } } == true)
    #expect(detail?.turns.first?.id == TurnID("p1"))
    #expect(detail?.turns.first?.outcome == .completed)
    let cursor = try await repository.rolloutCursor(path: transcript.path)
    #expect((cursor?.byteOffset ?? 0) > 0)
    // The hook's newer state assertion still wins over the replayed history.
    #expect(detail?.summary.lifecycle == .waitingForInput)
    #expect(detail?.summary.lastActivityAt == Date(timeIntervalSince1970: 1_787_300_000))

    // Re-enqueueing is idempotent: everything dedupes, nothing regresses.
    let applied = detail?.timeline.count
    await queue.enqueue(sessionID: sid, path: transcript.path)
    await queue.flush()
    let again = try await repository.sessionDetail(id: sid, cursor: nil, limit: 100)
    #expect(again?.timeline.count == applied)
}

@Test func backfillQueueHealsASessionCreatedByAMetadataOnlyEvent() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumi-backfill-\(UUID().uuidString)", isDirectory: true)
    let projectDir = home.appendingPathComponent(".claude/projects/-tmp-project", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let sid = SessionID("bbbb2222-0000-0000-0000-000000000002")
    let transcript = projectDir.appendingPathComponent("\(sid.rawValue).jsonl")
    try Data("""
    {"type":"user","sessionId":"\(sid.rawValue)","promptId":"p1","timestamp":"2026-08-20T09:00:00Z","cwd":"/tmp/project","origin":{"kind":"human"},"message":{"role":"user","content":"Do the thing"}}
    {"type":"assistant","sessionId":"\(sid.rawValue)","timestamp":"2026-08-20T09:00:05Z","message":{"role":"assistant","model":"claude-opus-4-7","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}

    """.utf8).write(to: transcript)

    // The stuck-Running shape: a metadata-only hook (no lifecycle) created
    // the session with a fresh wall-clock timestamp.
    let repository = InMemorySessionRepository()
    _ = try await repository.apply(AgentIngressEvent(
        eventID: EventID("hook-config"), sessionID: sid, agent: .claude,
        occurredAt: Date(timeIntervalSince1970: 1_787_300_000), workspace: "/tmp/project"
    ))

    let queue = TranscriptBackfillQueue(repository: repository)
    await queue.enqueue(sessionID: sid, path: transcript.path)
    await queue.flush()

    // The replayed history's final state lands despite its older timestamps.
    let detail = try await repository.sessionDetail(id: sid, cursor: nil, limit: 100)
    #expect(detail?.summary.lifecycle == .waitingForInput)
    #expect(detail?.summary.phase == .idle)
    #expect(detail?.summary.workspace == "/tmp/project")
}

// MARK: - DaemonEventSubscriber over the real socket

private final class StreamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentIngressEvent] = []
    private var healthCount = 0
    private var disconnectCount = 0

    func append(_ event: AgentIngressEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }
    func recordHealth() {
        lock.lock(); healthCount += 1; lock.unlock()
    }
    func recordDisconnect() {
        lock.lock(); disconnectCount += 1; lock.unlock()
    }
    var snapshot: (events: [AgentIngressEvent], health: Int, disconnects: Int) {
        lock.lock(); defer { lock.unlock() }
        return (events, healthCount, disconnectCount)
    }
}

private func waitUntil(
    _ comment: Comment,
    timeout: Duration = .seconds(5),
    _ condition: @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        try #require(ContinuousClock.now < deadline, comment)
        try await Task.sleep(for: .milliseconds(20))
    }
}

@Test func eventSubscriberStreamsFramesInOrderAndSeesTheServerDisconnect() async throws {
    let socketPath = "/tmp/as-\(UUID().uuidString.prefix(8)).sock"
    defer { try? FileManager.default.removeItem(atPath: socketPath) }
    let repository = InMemorySessionRepository()
    let hub = DaemonSubscriptionHub()
    let service = DaemonService(
        repository: repository, socketPath: socketPath, executableHash: "test-hash", subscriptions: hub
    )
    let server = DaemonServer(socketPath: socketPath, service: service)
    try server.start()

    let capture = StreamCapture()
    let subscriber = DaemonEventSubscriber()
    try subscriber.start(
        socketPath: socketPath,
        onEvent: { capture.append($0) },
        onSummary: { _ in },
        onHealth: { _ in capture.recordHealth() },
        onDisconnect: { capture.recordDisconnect() }
    )
    // The subscribe ack carries a health frame.
    try await waitUntil("subscribe ack health") { capture.snapshot.health >= 1 }

    for index in 1...2 {
        hub.publish(AgentIngressEvent(
            eventID: EventID("stream-\(index)"),
            sessionID: SessionID("stream-session"),
            agent: .codex,
            occurredAt: Date(timeIntervalSince1970: Double(index))
        ))
    }
    try await waitUntil("both events") { capture.snapshot.events.count == 2 }
    #expect(capture.snapshot.events.map(\.eventID) == [EventID("stream-1"), EventID("stream-2")])

    server.shutdown()
    try await waitUntil("server disconnect") { capture.snapshot.disconnects == 1 }
    #expect(subscriber.isRunning == false)
    #expect(capture.snapshot.disconnects == 1)
}

@Test func eventSubscriberStopsCleanlyAndCanStartAgain() async throws {
    let socketPath = "/tmp/as-\(UUID().uuidString.prefix(8)).sock"
    defer { try? FileManager.default.removeItem(atPath: socketPath) }
    let repository = InMemorySessionRepository()
    let service = DaemonService(repository: repository, socketPath: socketPath, executableHash: "test-hash")
    let server = DaemonServer(socketPath: socketPath, service: service)
    try server.start()
    defer { server.shutdown() }

    let capture = StreamCapture()
    let subscriber = DaemonEventSubscriber()
    let start = { @Sendable in
        try subscriber.start(
            socketPath: socketPath,
            onEvent: { _ in },
            onSummary: { _ in },
            onHealth: { _ in capture.recordHealth() },
            onDisconnect: { capture.recordDisconnect() }
        )
    }
    try start()
    try await waitUntil("first health") { capture.snapshot.health >= 1 }
    subscriber.stop()
    try await waitUntil("stop disconnect") { capture.snapshot.disconnects == 1 }
    #expect(subscriber.isRunning == false)

    // The read loop's exit must not clobber a restarted connection.
    try start()
    try await waitUntil("second health") { capture.snapshot.health >= 2 }
    #expect(subscriber.isRunning == true)
    subscriber.stop()
    try await waitUntil("second disconnect") { capture.snapshot.disconnects == 2 }
}

// MARK: - POSIX DaemonServer semantics over the real socket

private func makeSocketServer(
    outboundByteBudget: Int = 64 << 20,
    hub: DaemonSubscriptionHub = DaemonSubscriptionHub()
) throws -> (server: DaemonServer, service: DaemonService, hub: DaemonSubscriptionHub, socketPath: String) {
    let socketPath = "/tmp/as-\(UUID().uuidString.prefix(8)).sock"
    let service = DaemonService(
        repository: InMemorySessionRepository(),
        socketPath: socketPath,
        executableHash: "test-hash",
        subscriptions: hub
    )
    let server = DaemonServer(socketPath: socketPath, service: service, outboundByteBudget: outboundByteBudget)
    try server.start()
    return (server, service, hub, socketPath)
}

private func rawUnixConnect(_ socketPath: String) -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    precondition(descriptor >= 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let path = socketPath.utf8CString
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        path.withUnsafeBytes { destination.copyBytes(from: $0) }
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    precondition(result == 0)
    return descriptor
}

@Test func oneConnectionRunsRequestsConcurrentlyAndAnswersEveryRequestID() async throws {
    let (server, _, _, socketPath) = try makeSocketServer()
    defer { server.shutdown() }

    let connection = try FrameConnection.connect(socketPath: socketPath, deadline: ContinuousClock.now + .seconds(5))
    defer { connection.close() }
    let requestIDs = (1...5).map { RequestID(rawValue: "req-\($0)") }
    for requestID in requestIDs {
        let body = try TransportCoding.makeEncoder().encode(
            TransportEnvelope(requestID: requestID, payload: IPCRequest(operation: .health))
        )
        try connection.writeFrame(body, deadline: ContinuousClock.now + .seconds(5))
    }
    var answered: Set<String> = []
    for _ in requestIDs {
        let frame = try connection.readFrame(deadline: ContinuousClock.now + .seconds(5))
        let envelope = try TransportCoding.makeDecoder().decode(TransportEnvelope<IPCResponse>.self, from: frame)
        #expect(envelope.payload.status == .ok)
        answered.insert(envelope.requestID.rawValue)
    }
    #expect(answered == Set(requestIDs.map(\.rawValue)))
}

@Test func aMalformedFrameGetsAnErrorFrameAndTheConnectionStaysUsable() async throws {
    let (server, _, _, socketPath) = try makeSocketServer()
    defer { server.shutdown() }

    let connection = try FrameConnection.connect(socketPath: socketPath, deadline: ContinuousClock.now + .seconds(5))
    defer { connection.close() }
    try connection.writeFrame(Data("not-json".utf8), deadline: ContinuousClock.now + .seconds(5))
    let errorFrame = try connection.readFrame(deadline: ContinuousClock.now + .seconds(5))
    let errorEnvelope = try TransportCoding.makeDecoder().decode(TransportEnvelope<IPCResponse>.self, from: errorFrame)
    #expect(errorEnvelope.payload.failure?.code == "malformed_request")

    let body = try TransportCoding.makeEncoder().encode(
        TransportEnvelope(payload: IPCRequest(operation: .health))
    )
    try connection.writeFrame(body, deadline: ContinuousClock.now + .seconds(5))
    let frame = try connection.readFrame(deadline: ContinuousClock.now + .seconds(5))
    let envelope = try TransportCoding.makeDecoder().decode(TransportEnvelope<IPCResponse>.self, from: frame)
    #expect(envelope.payload.status == .ok)
}

@Test func anOversizedInboundHeaderDropsOnlyThatConnection() async throws {
    let (server, _, _, socketPath) = try makeSocketServer()
    defer { server.shutdown() }

    let descriptor = rawUnixConnect(socketPath)
    defer { close(descriptor) }
    var header = UInt32(LengthPrefixedFrameCodec.maximumFrameLength + 1).bigEndian
    let written = withUnsafeBytes(of: &header) { write(descriptor, $0.baseAddress, 4) }
    #expect(written == 4)
    var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    #expect(poll(&entry, 1, 5000) == 1)
    var probe: UInt8 = 0
    #expect(read(descriptor, &probe, 1) == 0)

    let response = try DaemonIPCClient().request(IPCRequest(operation: .health), socketPath: socketPath)
    #expect(response.status == .ok)
}

@Test func aSubscriberThatStopsReadingIsDroppedWithoutStallingTheOthers() async throws {
    let hub = DaemonSubscriptionHub()
    let (server, _, _, socketPath) = try makeSocketServer(outboundByteBudget: 4096, hub: hub)
    defer { server.shutdown() }

    let capture = StreamCapture()
    let healthy = DaemonEventSubscriber()
    try healthy.start(
        socketPath: socketPath,
        onEvent: { capture.append($0) },
        onSummary: { _ in },
        onHealth: { _ in capture.recordHealth() },
        onDisconnect: { capture.recordDisconnect() }
    )
    try await waitUntil("healthy subscriber ack") { capture.snapshot.health >= 1 }

    let stalled = try FrameConnection.connect(socketPath: socketPath, deadline: ContinuousClock.now + .seconds(5))
    defer { stalled.close() }
    let subscribe = try TransportCoding.makeEncoder().encode(
        TransportEnvelope(payload: IPCRequest(operation: .subscribe))
    )
    try stalled.writeFrame(subscribe, deadline: ContinuousClock.now + .seconds(5))
    _ = try stalled.readFrame(deadline: ContinuousClock.now + .seconds(5))

    // The stalled client stops reading, so its kernel buffer fills, its
    // writer blocks, and the padded frames overflow its 4KiB budget. The
    // publishes are paced so the healthy subscriber's queue keeps draining.
    let padding = String(repeating: "x", count: 2048)
    for index in 1...30 {
        hub.publish(AgentIngressEvent(
            eventID: EventID("burst-\(index)"),
            sessionID: SessionID("burst"),
            agent: .codex,
            occurredAt: Date(timeIntervalSince1970: Double(index)),
            timelineItem: TimelineItem(
                id: TimelineItemID("burst-item-\(index)"),
                sessionID: SessionID("burst"),
                occurredAt: Date(timeIntervalSince1970: Double(index)),
                payload: .message(MessageTimelinePayload(role: .assistant, text: padding))
            )
        ))
        try await Task.sleep(for: .milliseconds(10))
    }
    try await waitUntil("healthy subscriber got the burst") { capture.snapshot.events.count == 30 }

    // The server dropped the stalled connection: drain whatever the kernel
    // buffered, then hit the close.
    #expect(throws: DaemonIPCClientError.self) {
        while true {
            _ = try stalled.readFrame(deadline: ContinuousClock.now + .seconds(5))
        }
    }
    #expect(capture.snapshot.disconnects == 0)
}

@Test func shutdownUnblocksWaitAndRemovesTheSocketFile() async throws {
    let (server, _, _, socketPath) = try makeSocketServer()
    let capture = StreamCapture()
    let subscriber = DaemonEventSubscriber()
    try subscriber.start(
        socketPath: socketPath,
        onEvent: { _ in },
        onSummary: { _ in },
        onHealth: { _ in capture.recordHealth() },
        onDisconnect: { capture.recordDisconnect() }
    )
    try await waitUntil("subscriber ack") { capture.snapshot.health >= 1 }

    let waitReturned = StreamCapture()
    let waiter = Thread {
        try? server.wait()
        waitReturned.recordDisconnect()
    }
    waiter.start()
    server.shutdown()
    try await waitUntil("wait() returned") { waitReturned.snapshot.disconnects == 1 }
    #expect(!FileManager.default.fileExists(atPath: socketPath))
    try await waitUntil("subscriber saw the shutdown") { capture.snapshot.disconnects == 1 }
}

@Test func startThrowsWhenTheSocketPathHoldsARegularFile() throws {
    let socketPath = "/tmp/as-\(UUID().uuidString.prefix(8)).sock"
    defer { try? FileManager.default.removeItem(atPath: socketPath) }
    FileManager.default.createFile(atPath: socketPath, contents: Data("x".utf8))
    let service = DaemonService(
        repository: InMemorySessionRepository(),
        socketPath: socketPath,
        executableHash: "test-hash"
    )
    let server = DaemonServer(socketPath: socketPath, service: service)
    #expect(throws: DaemonServerError.self) { try server.start() }
}
