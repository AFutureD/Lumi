import AgentStatusTransport
import Foundation
import GRDB
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

@Test func grdbRepositoryReadsCurrentTurnUserMessagesWithoutLoadingFullDetails() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-status-current-message-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteSessionRepository(
        path: directory.appendingPathComponent("sessions.sqlite3").path
    )
    let sessionID = SessionID("current-message")
    let firstTurn = TurnID("turn-1")
    let currentTurn = TurnID("turn-2")
    let date = Date(timeIntervalSince1970: 1_800)
    let items = [
        TimelineItem(
            id: TimelineItemID("older-user"),
            sessionID: sessionID,
            turnID: firstTurn,
            occurredAt: date,
            payload: .message(MessageTimelinePayload(role: .user, text: "Older request"))
        ),
        TimelineItem(
            id: TimelineItemID("current-user"),
            sessionID: sessionID,
            turnID: currentTurn,
            occurredAt: date.addingTimeInterval(1),
            payload: .message(MessageTimelinePayload(role: .user, text: "Current request"))
        ),
        TimelineItem(
            id: TimelineItemID("current-assistant"),
            sessionID: sessionID,
            turnID: currentTurn,
            occurredAt: date.addingTimeInterval(2),
            payload: .message(MessageTimelinePayload(role: .assistant, text: "Working"))
        ),
    ]

    for (index, item) in items.enumerated() {
        #expect(try await repository.apply(AgentIngressEvent(
            eventID: EventID("current-message-event-\(index)"),
            sessionID: sessionID,
            agent: .codex,
            occurredAt: item.occurredAt,
            timelineItem: item
        )))
    }

    let messages = try await repository.currentTurnUserMessages(
        sessionIDs: [sessionID, sessionID]
    )
    #expect(messages == [sessionID: "Current request"])
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

    #expect(try await repository.deleteSession(id: deletedID) == [deletedID])
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

@Test func inMemoryRepositoryDeletesTheLineageSubtreeWithTheParent() async throws {
    let repository = InMemorySessionRepository()
    try await seedLineageFixture(repository)

    #expect(try await !repository.deleteSession(id: SessionID("parent")).isEmpty)

    let remaining = try await repository.listSessions(limit: 100).map(\.id)
    #expect(remaining == [SessionID("unrelated")])
    // The subagent is tombstoned like the parent: a straggling event must
    // not resurrect it.
    #expect(try await !repository.apply(AgentIngressEvent(
        eventID: EventID("late-child-event"),
        sessionID: SessionID("child"),
        agent: .codexSubagent,
        occurredAt: Date(timeIntervalSince1970: 5_000),
        lifecycle: .running,
        phase: .executing
    )))
    #expect(try await repository.listSessions(limit: 100).map(\.id) == [SessionID("unrelated")])
}

@Test func grdbRepositoryDeletesTheLineageSubtreeWithTheParent() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-status-cascade-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteSessionRepository(path: directory.appendingPathComponent("sessions.sqlite3").path)
    try await seedLineageFixture(repository)

    #expect(try await !repository.deleteSession(id: SessionID("parent")).isEmpty)

    let remaining = try await repository.listSessions(limit: 100).map(\.id)
    #expect(remaining == [SessionID("unrelated")])
    #expect(try await !repository.apply(AgentIngressEvent(
        eventID: EventID("late-grandchild-event"),
        sessionID: SessionID("grandchild"),
        agent: .codexSubagent,
        occurredAt: Date(timeIntervalSince1970: 5_000),
        lifecycle: .running,
        phase: .executing
    )))
    #expect(try await repository.listSessions(limit: 100).map(\.id) == [SessionID("unrelated")])
}

/// Parent → child → grandchild lineage plus one unrelated session that a
/// cascade must never touch.
private func seedLineageFixture(_ repository: some SessionRepository) async throws {
    let date = Date(timeIntervalSince1970: 4_000)
    let members: [(SessionID, SessionLineage?)] = [
        (SessionID("parent"), nil),
        (SessionID("child"), SessionLineage(
            threadSource: "subagent",
            parentSessionID: SessionID("parent"),
            subagentDepth: 1
        )),
        (SessionID("grandchild"), SessionLineage(
            threadSource: "subagent",
            parentSessionID: SessionID("child"),
            subagentDepth: 2
        )),
        (SessionID("unrelated"), nil),
    ]
    for (index, (sessionID, lineage)) in members.enumerated() {
        #expect(try await repository.apply(AgentIngressEvent(
            eventID: EventID("seed-\(sessionID.rawValue)"),
            sessionID: sessionID,
            agent: lineage == nil ? .codex : .codexSubagent,
            occurredAt: date.addingTimeInterval(Double(index)),
            lifecycle: .running,
            phase: .thinking,
            lineage: lineage
        )))
    }
}

@Test func grdbRepositoryKeepsNotchArchiveUntilTheHumanReEngages() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-status-notch-archive-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteSessionRepository(path: directory.appendingPathComponent("sessions.sqlite3").path)
    let sessionID = SessionID("archived")
    let date = Date(timeIntervalSince1970: 3_000)

    #expect(try await repository.apply(AgentIngressEvent(
        eventID: EventID("create"),
        sessionID: sessionID,
        agent: .codex,
        occurredAt: date,
        lifecycle: .waitingForInput,
        phase: .idle
    )))
    try await repository.markSessionHiddenInNotch(sessionID)
    #expect(try await repository.listSessions(limit: 100).first?.hiddenInNotch == true)

    // Passive activity (a lifecycle/phase update without a prompt) keeps the
    // session archived; only human engagement brings it back to the Notch.
    #expect(try await repository.apply(AgentIngressEvent(
        eventID: EventID("passive"),
        sessionID: sessionID,
        agent: .codex,
        occurredAt: date.addingTimeInterval(10),
        lifecycle: .running,
        phase: .executing
    )))
    #expect(try await repository.listSessions(limit: 100).first?.hiddenInNotch == true)

    #expect(try await repository.apply(promptEvent(sessionID, id: "re-engage", at: 3_020)))
    #expect(try await repository.listSessions(limit: 100).first?.hiddenInNotch == false)
}

@Test func grdbRepositoryReplacesOneSessionAndPrunesToAnIndex() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-status-replace-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteSessionRepository(path: directory.appendingPathComponent("cache.sqlite3").path)
    let first = SessionDetail(summary: summary(id: "first", updatedAt: 1), timeline: [])
    let second = SessionDetail(
        summary: summary(id: "second", updatedAt: 2),
        turns: [TurnSummary(id: TurnID("t1"), sessionID: SessionID("second"), phase: .idle, startedAt: Date(timeIntervalSince1970: 2))],
        timeline: [TimelineItem(
            id: TimelineItemID("second-item"),
            sessionID: SessionID("second"),
            occurredAt: Date(timeIntervalSince1970: 2),
            payload: .message(MessageTimelinePayload(role: .user, text: "hi"))
        )]
    )

    try await repository.replaceSession(first)
    try await repository.replaceSession(second)
    #expect(try await repository.listSessions(limit: 100).map(\.id) == [second.summary.id, first.summary.id])

    // A replace is wholesale: stale turns and timeline are gone, not merged.
    let trimmed = SessionDetail(summary: summary(id: "second", updatedAt: 3), timeline: [])
    try await repository.replaceSession(trimmed)
    let detail = try await repository.sessionDetail(id: second.summary.id, cursor: nil, limit: 100)
    #expect(detail?.turns.isEmpty == true)
    #expect(detail?.timeline.isEmpty == true)

    // Pruning drops what the index no longer lists — and writes no tombstone,
    // so the pruned session can come back through a later replace.
    #expect(try await repository.pruneSessions(keeping: [second.summary.id]) == 1)
    #expect(try await repository.listSessions(limit: 100).map(\.id) == [second.summary.id])
    try await repository.replaceSession(first)
    #expect(try await repository.listSessions(limit: 100).count == 2)
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

// MARK: - Provisional sessions and helper discards

private func startEvent(_ sessionID: SessionID, id: String, at: TimeInterval, agent: AgentKind = .claude) -> AgentIngressEvent {
    AgentIngressEvent(
        eventID: EventID(id),
        sessionID: sessionID,
        agent: agent,
        occurredAt: Date(timeIntervalSince1970: at),
        lifecycle: .starting,
        phase: .idle,
        timelineItem: TimelineItem(
            id: TimelineItemIDs.sessionMarker(sessionID, .sessionStarted),
            sessionID: sessionID,
            occurredAt: Date(timeIntervalSince1970: at),
            payload: .sessionMarker(SessionMarkerTimelinePayload(kind: .sessionStarted, detail: "startup"))
        )
    )
}

private func promptEvent(_ sessionID: SessionID, id: String, at: TimeInterval) -> AgentIngressEvent {
    AgentIngressEvent(
        eventID: EventID(id),
        sessionID: sessionID,
        turnID: TurnID("turn-\(id)"),
        agent: .claude,
        occurredAt: Date(timeIntervalSince1970: at),
        lifecycle: .running,
        phase: .thinking,
        turn: TurnSummary(id: TurnID("turn-\(id)"), sessionID: sessionID, phase: .thinking, prompt: "hi", startedAt: Date(timeIntervalSince1970: at))
    )
}

private func discardEvent(_ sessionID: SessionID, id: String, at: TimeInterval) -> AgentIngressEvent {
    AgentIngressEvent(
        eventID: EventID(id),
        sessionID: sessionID,
        agent: .claude,
        occurredAt: Date(timeIntervalSince1970: at),
        disposition: .discard
    )
}

@Test func reducerMarksFirstTurnOnceAndKeepsItThroughRestart() {
    let sessionID = SessionID("provisional")
    let started = SessionReduction.summary(applying: startEvent(sessionID, id: "start", at: 100), to: nil)
    #expect(started.isProvisional)
    #expect(started.firstTurnAt == nil)

    let prompted = SessionReduction.summary(applying: promptEvent(sessionID, id: "p1", at: 110), to: started)
    #expect(!prompted.isProvisional)
    #expect(prompted.firstTurnAt == Date(timeIntervalSince1970: 110))

    let later = SessionReduction.summary(applying: promptEvent(sessionID, id: "p2", at: 200), to: prompted)
    #expect(later.firstTurnAt == Date(timeIntervalSince1970: 110))

    // `resume` / `compact` re-fire SessionStart: lifecycle regresses to
    // starting, but the session stays visible.
    let resumed = SessionReduction.summary(applying: startEvent(sessionID, id: "resume", at: 300), to: later)
    #expect(resumed.lifecycle == .starting)
    #expect(!resumed.isProvisional)
}

private func assertDiscardSemantics(_ repository: any SessionRepository) async throws {
    let ghost = SessionID("ghost")
    let real = SessionID("real")
    #expect(try await repository.apply(startEvent(ghost, id: "ghost-start", at: 100)))
    #expect(try await repository.apply(startEvent(real, id: "real-start", at: 100)))
    #expect(try await repository.apply(promptEvent(real, id: "real-p1", at: 101)))
    #expect(try await repository.listSessions(limit: 100).count == 2)

    // Discard: row gone, tombstoned, and reported as applied (so it is published).
    #expect(try await repository.apply(discardEvent(ghost, id: "ghost-discard", at: 102)))
    #expect(try await repository.listSessions(limit: 100).map(\.id) == [real])
    #expect(try await repository.sessionDetail(id: ghost, cursor: nil, limit: 10) == nil)
    // Idempotent on replay.
    #expect(try await !repository.apply(discardEvent(ghost, id: "ghost-discard", at: 102)))

    // Passive stragglers stay rejected; a replayed SessionStart (same event
    // id) must not un-ignore it either.
    #expect(try await !repository.apply(AgentIngressEvent(
        eventID: EventID("ghost-late"), sessionID: ghost, agent: .claude,
        occurredAt: Date(timeIntervalSince1970: 103), lifecycle: .completed, phase: .idle
    )))
    #expect(try await !repository.apply(startEvent(ghost, id: "ghost-start", at: 100)))
    #expect(try await !repository.apply(AgentIngressEvent(
        eventID: EventID("ghost-late-2"), sessionID: ghost, agent: .claude,
        occurredAt: Date(timeIntervalSince1970: 104), lifecycle: .completed, phase: .idle
    )))
    #expect(try await repository.listSessions(limit: 100).map(\.id) == [real])

    // A genuinely new start still resurrects (existing delete semantics).
    #expect(try await repository.apply(startEvent(ghost, id: "ghost-start-again", at: 200)))
    #expect(try await repository.listSessions(limit: 100).count == 2)
}

@Test func inMemoryRepositoryDiscardsAndTombstonesWithoutReplayResurrection() async throws {
    try await assertDiscardSemantics(InMemorySessionRepository())
}

@Test func grdbRepositoryDiscardsAndTombstonesWithoutReplayResurrection() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-status-discard-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteSessionRepository(path: directory.appendingPathComponent("sessions.sqlite3").path)
    try await assertDiscardSemantics(repository)
}

@Test func grdbSessionReplaceClearsOnlyItsOwnClientTombstone() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-status-replace-tombstone-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteSessionRepository(path: directory.appendingPathComponent("cache.sqlite3").path)
    let ghost = SessionID("ghost")
    let other = SessionID("other")
    #expect(try await repository.apply(startEvent(ghost, id: "start", at: 100)))
    #expect(try await repository.apply(discardEvent(ghost, id: "discard", at: 101)))
    #expect(try await repository.apply(startEvent(other, id: "other-start", at: 100)))
    #expect(try await repository.apply(discardEvent(other, id: "other-discard", at: 101)))

    // The daemon resurrected it while this client was offline; the replace
    // brings it back and later passive events must apply again.
    try await repository.replaceSession(SessionDetail(summary: summary(id: "ghost", updatedAt: 200), timeline: []))
    #expect(try await repository.apply(AgentIngressEvent(
        eventID: EventID("after-replace"), sessionID: ghost, agent: .claude,
        occurredAt: Date(timeIntervalSince1970: 201), lifecycle: .running, phase: .executing
    )))
    #expect(try await repository.sessionDetail(id: ghost, cursor: nil, limit: 10)?.summary.phase == .executing)

    // The other tombstone is untouched: its passive events stay swallowed.
    #expect(try await !repository.apply(AgentIngressEvent(
        eventID: EventID("other-after"), sessionID: other, agent: .claude,
        occurredAt: Date(timeIntervalSince1970: 201), lifecycle: .running, phase: .executing
    )))

    // A replayed pre-replace event is still deduped: the replace keeps
    // processed events so old increments cannot double-apply.
    #expect(try await !repository.apply(startEvent(ghost, id: "start", at: 100)))
}

@Test func grdbMigrationSweepsEmptyCompletedClaudeSessionsOnly() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-status-sweep-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("sessions.sqlite3").path
    let ghost = SessionID("ghost")
    let usedClaude = SessionID("used-claude")
    let codex = SessionID("codex")
    let endEvent = { (id: SessionID, event: String, at: TimeInterval, agent: AgentKind) in
        AgentIngressEvent(
            eventID: EventID(event), sessionID: id, agent: agent,
            occurredAt: Date(timeIntervalSince1970: at), lifecycle: .completed, phase: .idle,
            timelineItem: TimelineItem(
                id: TimelineItemIDs.sessionMarker(id, .sessionEnded), sessionID: id,
                occurredAt: Date(timeIntervalSince1970: at),
                payload: .sessionMarker(SessionMarkerTimelinePayload(kind: .sessionEnded, detail: "other"))
            )
        )
    }
    do {
        // Write the fixture through the repository (the sweep already ran on
        // the empty database), then make the database look pre-sweep below.
        let repository = try SQLiteSessionRepository(path: path)
        #expect(try await repository.apply(startEvent(ghost, id: "g-start", at: 100)))
        #expect(try await repository.apply(endEvent(ghost, "g-end", 102, .claude)))
        #expect(try await repository.apply(startEvent(usedClaude, id: "u-start", at: 100)))
        #expect(try await repository.apply(promptEvent(usedClaude, id: "u-p1", at: 101)))
        #expect(try await repository.apply(endEvent(usedClaude, "u-end", 105, .claude)))
        #expect(try await repository.apply(startEvent(codex, id: "c-start", at: 100, agent: .codex)))
        #expect(try await repository.apply(endEvent(codex, "c-end", 102, .codex)))
        #expect(try await repository.listSessions(limit: 100).count == 3)
    }
    // Simulate a database from before the sweep: drop the migration marker
    // and reopen, which re-runs it on the existing rows.
    try await DatabaseQueue(path: path).write { db in
        try db.execute(
            sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
            arguments: ["agent-status-v3-sweep-empty-claude-sessions"]
        )
    }
    let reopened = try SQLiteSessionRepository(path: path)
    let remaining = try await reopened.listSessions(limit: 100).map(\.id)
    #expect(Set(remaining) == [usedClaude, codex])
    #expect(try await !reopened.apply(endEvent(ghost, "g-late", 110, .claude)))   // tombstoned
}

@Test func reducerSetsNeedsReviewOnTurnEndAndOnlyTheHumanClearsIt() async throws {
    let repository = InMemorySessionRepository()
    let sessionID = SessionID("review")
    let running = AgentIngressEvent(
        eventID: EventID("r1"), sessionID: sessionID, agent: .codex,
        occurredAt: Date(timeIntervalSince1970: 100), lifecycle: .running, phase: .thinking
    )
    let turnEnd = AgentIngressEvent(
        eventID: EventID("r2"), sessionID: sessionID, agent: .codex,
        occurredAt: Date(timeIntervalSince1970: 200), lifecycle: .waitingForInput, phase: .idle,
        timelineItem: TimelineItem(
            id: TimelineItemID("turn_end:1"), sessionID: sessionID,
            occurredAt: Date(timeIntervalSince1970: 200),
            payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed))
        )
    )
    let laterContext = AgentIngressEvent(
        eventID: EventID("r3"), sessionID: sessionID, agent: .codex,
        occurredAt: Date(timeIntervalSince1970: 300),
        timelineItem: TimelineItem(
            id: TimelineItemID("ctx:1"), sessionID: sessionID,
            occurredAt: Date(timeIntervalSince1970: 300),
            payload: .usageMetrics(UsageMetricsTimelinePayload(total: TokenUsage(totalTokens: 10)))
        )
    )
    _ = try await repository.apply(running)
    var summary = try await repository.sessionDetail(id: sessionID, cursor: nil, limit: 1)?.summary
    #expect(summary?.needsReview == false)
    #expect(summary?.needsAttention == false)

    // A turn end flips it on, and the attention flag follows the green tier…
    _ = try await repository.apply(turnEnd)
    summary = try await repository.sessionDetail(id: sessionID, cursor: nil, limit: 1)?.summary
    #expect(summary?.needsReview == true)
    #expect(summary?.needsAttention == true)
    #expect(summary?.statusTone == .green)

    // …and it sticks through later events until the human opens the session.
    _ = try await repository.apply(laterContext)
    summary = try await repository.sessionDetail(id: sessionID, cursor: nil, limit: 1)?.summary
    #expect(summary?.needsReview == true)
    try await repository.markSessionReviewed(sessionID)
    summary = try await repository.sessionDetail(id: sessionID, cursor: nil, limit: 1)?.summary
    #expect(summary?.needsReview == false)
    #expect(summary?.needsAttention == false)
    #expect(summary?.statusTone == .gray)
}
