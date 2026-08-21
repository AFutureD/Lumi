import AgentStatusCodex
import AgentStatusCore
import AgentStatusDaemonRuntime
import AgentStatusIPCClient
import AgentStatusTransport
import Foundation
import Testing

@Test func serviceIngestsAndListsSessions() async throws {
    let repository = InMemorySessionRepository()
    let service = DaemonService(repository: repository, socketPath: "/tmp/agent-status.sock", executableHash: "test-hash")
    let event = AgentIngressEvent(
        eventID: EventID("event"),
        sessionID: SessionID("session"),
        agent: .codex,
        occurredAt: Date(),
        lifecycle: .running,
        phase: .thinking
    )
    let accepted = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .ingest, event: event)))
    #expect(accepted.payload.status == .accepted)

    let listed = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .listSessions)))
    #expect(listed.payload.sessions?.map(\.id) == [SessionID("session")])

    let cleared = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .clearHistory)))
    #expect(cleared.payload.status == .ok)
    let empty = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .listSessions)))
    #expect(empty.payload.sessions?.isEmpty == true)
}

@Test func serviceDeletesOneSessionAndRejectsItsLateEvents() async throws {
    let repository = InMemorySessionRepository()
    let service = DaemonService(repository: repository, socketPath: "/tmp/agent-status.sock", executableHash: "test-hash")
    let sessionID = SessionID("session-to-delete")
    let event = AgentIngressEvent(
        eventID: EventID("first-event"),
        sessionID: sessionID,
        agent: .codex,
        occurredAt: Date(timeIntervalSince1970: 100),
        lifecycle: .running,
        phase: .thinking
    )
    _ = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .ingest, event: event)))

    let deleted = await service.handle(TransportEnvelope(
        payload: IPCRequest(operation: .deleteSession, sessionID: sessionID)
    ))
    #expect(deleted.payload.status == .ok)

    let late = AgentIngressEvent(
        eventID: EventID("late-event"),
        sessionID: sessionID,
        agent: .codex,
        occurredAt: Date(timeIntervalSince1970: 200),
        lifecycle: .running,
        phase: .executing
    )
    let ignored = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .ingest, event: late)))
    #expect(ignored.payload.status == .ok)
    let listed = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .listSessions)))
    #expect(listed.payload.sessions?.isEmpty == true)
}

@Test func serviceBroadcastsHelperDiscardsAndHidesProvisionalSessionsFromHealth() async throws {
    let repository = InMemorySessionRepository()
    let hub = DaemonSubscriptionHub()
    let capture = EventCapture()
    let subscriptionID = hub.subscribe { message in
        if case let .event(event) = message { capture.append(event) }
    }
    defer { hub.unsubscribe(subscriptionID) }
    let service = DaemonService(repository: repository, socketPath: "/tmp/agent-status.sock", executableHash: "test-hash", subscriptions: hub)
    let ghost = SessionID("ghost")
    let start = AgentIngressEvent(
        eventID: EventID("ghost-start"), sessionID: ghost, agent: .claude,
        occurredAt: Date(timeIntervalSince1970: 100), lifecycle: .starting, phase: .idle
    )
    _ = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .ingestBatch, events: [start])))

    // Provisional: retained and served to the helper, but not "active".
    let detail = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .getSession, sessionID: ghost, limit: 1)))
    #expect(detail.payload.session?.summary.isProvisional == true)
    let health = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .health)))
    #expect(health.payload.health?.activeSessionCount == 0)
    #expect(health.payload.health?.retainedSessionCount == 1)

    let discard = AgentIngressEvent(
        eventID: EventID("ghost-discard"), sessionID: ghost, agent: .claude,
        occurredAt: Date(timeIntervalSince1970: 102), disposition: .discard
    )
    let response = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .ingestBatch, events: [discard])))
    #expect(response.payload.status == .accepted)
    #expect(response.payload.acceptedCount == 1)
    #expect(capture.events.map(\.eventID) == [EventID("ghost-start"), EventID("ghost-discard")])

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
    let service = DaemonService(repository: repository, socketPath: "/tmp/agent-status.sock", executableHash: "test-hash")
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
        .appendingPathComponent("agent-status-rollout-\(UUID().uuidString)", isDirectory: true)
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
        .appendingPathComponent("agent-status-subagent-rollout-\(UUID().uuidString)", isDirectory: true)
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
        .appendingPathComponent("agent-status-title-sync-\(UUID().uuidString)", isDirectory: true)
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
    #expect(roundTripped.updatedAt == date)
    #expect(roundTripped.lastActivityAt == date)
    #expect(capture.events.map(\.title) == [
        "Hypatia · docs_review",
        "Renamed Subagent",
        "Hypatia · docs_review",
    ])
}

@Test func firstRunBaselineIgnoresExistingSessionsAndRecordsNewFiles() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-status-baseline-\(UUID().uuidString)", isDirectory: true)
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
        ["type": "user", "uuid": "u1", "sessionId": session, "promptId": "p1", "timestamp": "2026-08-19T06:42:07.000Z", "cwd": "/tmp/proj",
         "message": ["role": "user", "content": "hi"]],
        ["type": "assistant", "uuid": "a1", "sessionId": session, "timestamp": "2026-08-19T06:42:10.000Z",
         "message": ["role": "assistant", "model": "claude-opus-4-7", "stop_reason": "end_turn", "content": [["type": "text", "text": "Hello."]]]],
    ]
    try (records.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n") + "\n")
        .write(toFile: path, atomically: true, encoding: .utf8)

    let repository = InMemorySessionRepository()
    let service = DaemonService(
        repository: repository,
        socketPath: "/tmp/agent-status.sock",
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
        .appendingPathComponent("agent-status-claude-watcher-\(UUID().uuidString)", isDirectory: true)
    let projectDir = home.appendingPathComponent(".claude/projects/-tmp-project", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let sid = SessionID("aaaa1111-0000-0000-0000-000000000001")
    let transcript = projectDir.appendingPathComponent("\(sid.rawValue).jsonl")
    try Data("""
    {"type":"user","sessionId":"\(sid.rawValue)","promptId":"p1","timestamp":"2026-08-20T09:44:42Z","message":{"role":"user","content":"Do the thing"}}

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
