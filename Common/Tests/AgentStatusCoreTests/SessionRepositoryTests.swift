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

@Test func reducerAppliesAnAuthoritativeTitleWithoutAdvancingActivity() {
    let date = Date(timeIntervalSince1970: 100)
    let current = SessionSummary(
        id: SessionID("titled-session"),
        agent: .codex,
        title: "Codex Session",
        lifecycle: .waitingForInput,
        phase: .idle,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date
    )
    let titleUpdate = AgentIngressEvent(
        eventID: EventID("thread-title"),
        sessionID: current.id,
        agent: .codex,
        occurredAt: date.addingTimeInterval(100),
        title: "[macOS] Session list and detail"
    )

    let updated = SessionReduction.summary(applying: titleUpdate, to: current)

    #expect(updated.title == "[macOS] Session list and detail")
    #expect(updated.lifecycle == current.lifecycle)
    #expect(updated.phase == current.phase)
    #expect(updated.updatedAt == current.updatedAt)
    #expect(updated.lastActivityAt == current.lastActivityAt)
}

@Test func reducerPreservesKnownSubagentIdentityWhenCodexStateIsUnavailable() {
    let date = Date(timeIntervalSince1970: 100)
    let lineage = SessionLineage(
        threadSource: "subagent",
        parentSessionID: SessionID("parent"),
        subagentDepth: 1,
        agentNickname: "Hypatia",
        agentPath: "/root/docs_review",
        subagentKind: "thread_spawn"
    )
    let current = SessionSummary(
        id: SessionID("subagent"),
        agent: .codexSubagent,
        title: "Hypatia · docs_review",
        lifecycle: .running,
        phase: .thinking,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date,
        lineage: lineage
    )
    let eventWithoutStateMetadata = AgentIngressEvent(
        eventID: EventID("visible-update"),
        sessionID: current.id,
        agent: .codex,
        occurredAt: date.addingTimeInterval(1),
        lifecycle: .running,
        phase: .responding,
        timelineItem: TimelineItem(
            id: TimelineItemID("assistant"),
            sessionID: current.id,
            occurredAt: date.addingTimeInterval(1),
            payload: .message(MessageTimelinePayload(role: .assistant, text: "Done"))
        )
    )

    let updated = SessionReduction.summary(applying: eventWithoutStateMetadata, to: current)

    #expect(updated.agent == .codexSubagent)
    #expect(updated.title == current.title)
    #expect(updated.lineage == lineage)
    #expect(updated.phase == .responding)
}

@Test func retainedDiagnosticsDoNotReorderVisibleSessionActivity() async throws {
    let sessionID = SessionID("session")
    let visibleDate = Date(timeIntervalSince1970: 200)
    let diagnosticDate = Date(timeIntervalSince1970: 300)
    let current = SessionSummary(
        id: sessionID,
        agent: .codex,
        title: "Current",
        lifecycle: .waitingForInput,
        phase: .idle,
        startedAt: visibleDate,
        updatedAt: visibleDate,
        lastActivityAt: visibleDate
    )
    let diagnostic = AgentIngressEvent(
        eventID: EventID("diagnostic"),
        sessionID: sessionID,
        agent: .codex,
        occurredAt: diagnosticDate,
        timelineItem: TimelineItem(
            id: TimelineItemID("diagnostic"),
            sessionID: sessionID,
            occurredAt: diagnosticDate,
            payload: .usageMetrics(UsageMetricsTimelinePayload(
                total: TokenUsage(totalTokens: 100)
            ))
        )
    )

    let result = SessionReduction.summary(applying: diagnostic, to: current)
    #expect(result.lifecycle == .waitingForInput)
    #expect(result.updatedAt == visibleDate)
    #expect(result.lastActivityAt == visibleDate)
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

@Test func grdbRepositoryPersistsRetainedSessionDiagnostics() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-status-diagnostics-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteSessionRepository(path: directory.appendingPathComponent("sessions.sqlite3").path)
    let sessionID = SessionID("diagnostics-session")
    let date = Date(timeIntervalSince1970: 1_500)
    let payloads: [TimelinePayload] = [
        .modelConfiguration(ModelConfigurationTimelinePayload(
            source: "turn_context",
            model: "gpt-5.6",
            reasoningEffort: "high",
            settings: .object(["model": .string("gpt-5.6")])
        )),
        .internalContext(InternalContextTimelinePayload(
            kind: "reasoning",
            content: .object(["text": .string("Retained fixture")])
        )),
        .usageMetrics(UsageMetricsTimelinePayload(
            total: TokenUsage(inputTokens: 100, outputTokens: 50, totalTokens: 150),
            modelContextWindow: 258_000
        )),
    ]

    for (index, payload) in payloads.enumerated() {
        let item = TimelineItem(
            id: TimelineItemID("diagnostic-\(index)"),
            sessionID: sessionID,
            occurredAt: date.addingTimeInterval(Double(index)),
            payload: payload
        )
        #expect(try await repository.apply(AgentIngressEvent(
            eventID: EventID("diagnostic-event-\(index)"),
            sessionID: sessionID,
            agent: .codex,
            occurredAt: item.occurredAt,
            timelineItem: item
        )))
    }

    let replacementUsage = TimelinePayload.usageMetrics(UsageMetricsTimelinePayload(
        total: TokenUsage(inputTokens: 200, outputTokens: 75, totalTokens: 275),
        modelContextWindow: 258_000
    ))
    let replacementItem = TimelineItem(
        id: TimelineItemID("diagnostic-2"),
        sessionID: sessionID,
        occurredAt: date.addingTimeInterval(10),
        payload: replacementUsage
    )
    #expect(try await repository.apply(AgentIngressEvent(
        eventID: EventID("diagnostic-event-replacement"),
        sessionID: sessionID,
        agent: .codex,
        occurredAt: replacementItem.occurredAt,
        timelineItem: replacementItem
    )))

    let staleUsage = TimelinePayload.usageMetrics(UsageMetricsTimelinePayload(
        total: TokenUsage(totalTokens: 1)
    ))
    let staleItem = TimelineItem(
        id: replacementItem.id,
        sessionID: sessionID,
        occurredAt: date.addingTimeInterval(5),
        payload: staleUsage
    )
    #expect(try await repository.apply(AgentIngressEvent(
        eventID: EventID("diagnostic-event-stale"),
        sessionID: sessionID,
        agent: .codex,
        occurredAt: staleItem.occurredAt,
        timelineItem: staleItem
    )))

    let detail = try await repository.sessionDetail(id: sessionID, cursor: nil, limit: 100)
    #expect(detail?.timeline.count == 3)
    #expect(detail?.timeline.last?.payload == replacementUsage)
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
