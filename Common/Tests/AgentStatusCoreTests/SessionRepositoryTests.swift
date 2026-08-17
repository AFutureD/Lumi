import AgentStatusTransport
import Foundation
import Testing
@testable import AgentStatusCore

@Test func reducerIsIdempotentAndRejectsOlderStateRegression() async throws {
    let repository = InMemorySessionRepository()
    let sessionID = SessionID("session")
    let newer = AgentIngressEvent(
        eventID: EventID("newer"),
        sessionID: sessionID,
        agent: .codex,
        occurredAt: Date(timeIntervalSince1970: 200),
        title: "Current title",
        lifecycle: .waitingForInput,
        phase: .idle
    )
    let older = AgentIngressEvent(
        eventID: EventID("older"),
        sessionID: sessionID,
        agent: .codex,
        occurredAt: Date(timeIntervalSince1970: 100),
        title: "Old title",
        lifecycle: .running,
        phase: .executing
    )

    #expect(try await repository.apply(newer))
    #expect(try await !repository.apply(newer))
    #expect(try await repository.apply(older))

    let session = try await repository.sessionDetail(id: sessionID, cursor: nil, limit: 100)
    #expect(session?.summary.title == "Current title")
    #expect(session?.summary.lifecycle == .waitingForInput)
    #expect(session?.summary.startedAt == older.occurredAt)
}

@Test func grdbRepositoryPersistsTimelineUntilManualDeletion() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-status-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("sessions.sqlite3").path
    let repository = try SQLiteSessionRepository(path: path)
    let sessionID = SessionID("sqlite-session")
    let occurredAt = Date(timeIntervalSince1970: 1_000)
    let timeline = TimelineItem(
        id: TimelineItemID("message-1"),
        sessionID: sessionID,
        occurredAt: occurredAt,
        payload: .message(MessageTimelinePayload(role: .user, text: "Sanitized fixture"))
    )
    let event = AgentIngressEvent(
        eventID: EventID("event-1"),
        sessionID: sessionID,
        agent: .codex,
        occurredAt: occurredAt,
        lifecycle: .running,
        phase: .thinking,
        timelineItem: timeline
    )

    #expect(try await repository.apply(event))
    #expect(try await !repository.apply(event))
    #expect(try await repository.sessionDetail(id: sessionID, cursor: nil, limit: 100)?.timeline == [timeline])
    #expect(try await repository.deleteAllSessions() == 1)
    #expect(try await repository.listSessions(limit: 100).isEmpty)
    #expect(try await !repository.apply(AgentIngressEvent(
        eventID: EventID("event-after-clear"),
        sessionID: sessionID,
        agent: .codex,
        occurredAt: occurredAt.addingTimeInterval(1),
        lifecycle: .running,
        phase: .executing
    )))
}

@Test func grdbRepositoryDeletesOneSessionAndKeepsItDeleted() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-status-delete-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteSessionRepository(path: directory.appendingPathComponent("sessions.sqlite3").path)
    let deletedID = SessionID("deleted")
    let keptID = SessionID("kept")
    let date = Date(timeIntervalSince1970: 2_000)

    for sessionID in [deletedID, keptID] {
        #expect(try await repository.apply(AgentIngressEvent(
            eventID: EventID("create-\(sessionID.rawValue)"),
            sessionID: sessionID,
            agent: .codex,
            occurredAt: date,
            lifecycle: .running,
            phase: .thinking
        )))
    }

    #expect(try await repository.deleteSession(id: deletedID))
    #expect(try await repository.listSessions(limit: 100).map(\.id) == [keptID])
    #expect(try await !repository.apply(AgentIngressEvent(
        eventID: EventID("late-deleted-event"),
        sessionID: deletedID,
        agent: .codex,
        occurredAt: date.addingTimeInterval(10),
        lifecycle: .running,
        phase: .executing
    )))
    #expect(try await repository.listSessions(limit: 100).map(\.id) == [keptID])
}

@Test func grdbRepositoryAtomicallyReplacesClientSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-status-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteSessionRepository(path: directory.appendingPathComponent("cache.sqlite3").path)
    let first = SessionDetail(summary: summary(id: "first", updatedAt: 1), timeline: [])
    let second = SessionDetail(summary: summary(id: "second", updatedAt: 2), timeline: [])

    try await repository.replaceSnapshot([first, second])
    #expect(try await repository.listSessions(limit: 100).map(\.id) == [second.summary.id, first.summary.id])

    try await repository.replaceSnapshot([second])
    #expect(try await repository.listSessions(limit: 100).map(\.id) == [second.summary.id])
}

private func summary(id: String, updatedAt: TimeInterval) -> SessionSummary {
    let date = Date(timeIntervalSince1970: updatedAt)
    return SessionSummary(
        id: SessionID(id),
        agent: .codex,
        title: id,
        lifecycle: .running,
        phase: .thinking,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date
    )
}
