import AgentStatusCodex
import AgentStatusCore
import AgentStatusDaemonRuntime
import AgentStatusIPCClient
import AgentStatusTransport
import Foundation
import Testing

@Test func serviceIngestsAndListsSessions() async throws {
    let repository = InMemorySessionRepository()
    let service = DaemonService(repository: repository, socketPath: "/tmp/agent-status.sock")
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
    let service = DaemonService(repository: repository, socketPath: "/tmp/agent-status.sock")
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

@Test func subscriptionHubMultiplexesEventsWithoutSessionChannels() {
    let hub = DaemonSubscriptionHub()
    let capture = EventCapture()
    let subscriptionID = hub.subscribe { event in capture.append(event) }
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
    let service = DaemonService(repository: repository, socketPath: socketPath)
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
}

@Test func snapshotReturnsAllSessionsOverOneIPCRequest() async throws {
    let repository = InMemorySessionRepository()
    let service = DaemonService(repository: repository, socketPath: "/tmp/agent-status.sock")
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    for index in 1...3 {
        let sessionID = SessionID("session-\(index)")
        let event = AgentIngressEvent(
            eventID: EventID("event-\(index)"),
            sessionID: sessionID,
            agent: .codex,
            occurredAt: date.addingTimeInterval(Double(index)),
            lifecycle: .running,
            phase: .executing,
            timelineItem: TimelineItem(
                id: TimelineItemID("item-\(index)"),
                sessionID: sessionID,
                occurredAt: date.addingTimeInterval(Double(index)),
                payload: .message(MessageTimelinePayload(role: .assistant, text: "Update \(index)"))
            )
        )
        _ = try await repository.apply(event)
    }

    let snapshot = await service.handle(TransportEnvelope(
        payload: IPCRequest(operation: .snapshotSessions, limit: 250)
    ))

    #expect(snapshot.payload.status == .ok)
    #expect(snapshot.payload.sessionDetails?.count == 3)
    #expect(snapshot.payload.sessionDetails?.allSatisfy { $0.timeline.count == 1 } == true)
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
    #expect(firstDetail?.timeline.count == 1)

    let handle = try FileHandle(forWritingTo: rollout)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("""
    {"timestamp":"2026-08-16T10:00:02Z","type":"event_msg","payload":{"type":"agent_message","message":"Sanitized response"}}

    """.utf8))
    try handle.close()

    await watcher.scanOnce()
    let secondDetail = try await repository.sessionDetail(id: SessionID("session-1"), cursor: nil, limit: 100)
    #expect(secondDetail?.timeline.count == 2)
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
