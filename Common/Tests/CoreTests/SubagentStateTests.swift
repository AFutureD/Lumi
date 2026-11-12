import Transport
import Foundation
import GRDB
import Testing
@testable import Core
@testable import Persistence

// A session's status counts its subagents: parked at its prompt with one
// still at work, it is Running. A subagent itself is never "not looked at".

private let base = Date(timeIntervalSince1970: 1_000)

private func summary(
    _ id: String,
    parent: String? = nil,
    agent: AgentKind? = nil,
    lifecycle: SessionLifecycle = .running,
    phase: TurnPhase = .thinking,
    needsReview: Bool = false,
    at seconds: TimeInterval = 0
) -> SessionSummary {
    let date = base.addingTimeInterval(seconds)
    return SessionSummary(
        id: SessionID(id),
        agent: agent ?? (parent == nil ? .claude : .claudeSubagent),
        title: id,
        lifecycle: lifecycle,
        phase: phase,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date,
        needsReview: needsReview,
        lineage: parent.map { SessionLineage(parentSessionID: SessionID($0), subagentDepth: 1) }
    )
}

// MARK: Resolver

@Test func aParkedSessionWithWorkingSubagentsReadsRunning() {
    let parked = summary("p", lifecycle: .waitingForInput, phase: .idle, needsReview: true)
    #expect(parked.statusTone == .green)
    #expect(parked.statusText == "Completed · Idle")

    let lifted = parked.withWorkingSubagents(true)
    #expect(lifted.statusTone == .blue)
    #expect(lifted.displayLifecycle == .running)
    // Its own phase is idle and the subagents' phases are theirs: `Running`.
    #expect(lifted.statusText == "Running")
    // The review flag waits underneath and shows once the subagents stop.
    #expect(lifted.needsReview)
    #expect(lifted.withWorkingSubagents(false).statusTone == .green)
}

@Test func openingASessionItsSubagentsKeepRunningIsNotReviewingIt() {
    let parked = summary("p", lifecycle: .waitingForInput, phase: .idle, needsReview: true)
    #expect(parked.isReviewedByOpening)
    #expect(!parked.withWorkingSubagents(true).isReviewedByOpening)
    // Everything else gives the flag up as before, whatever its tier: a
    // failed turn looked at, a session at work carrying an earlier flag.
    #expect(summary("f", lifecycle: .failed, phase: .idle, needsReview: true).withWorkingSubagents(true).isReviewedByOpening)
    #expect(summary("r", lifecycle: .running, phase: .thinking, needsReview: true).withWorkingSubagents(true).isReviewedByOpening)
    #expect(summary("e", lifecycle: .completed, phase: .idle, needsReview: true).withWorkingSubagents(true).isReviewedByOpening)
    #expect(!summary("n", lifecycle: .waitingForInput, phase: .idle).isReviewedByOpening)
}

@Test func workingSubagentsLiftOnlyAParkedSession() {
    // Ended: the process is gone and took its subagents with it.
    let ended = summary("e", lifecycle: .completed, phase: .idle, needsReview: true).withWorkingSubagents(true)
    #expect(ended.statusTone == .green)
    #expect(ended.statusText == "Completed · Idle")
    // Approval, failure and interruption keep their own tiers.
    #expect(summary("a", lifecycle: .waitingForInput, phase: .waitingForApproval)
        .withWorkingSubagents(true).statusTone == .orange)
    #expect(summary("f", lifecycle: .failed, phase: .idle).withWorkingSubagents(true).statusTone == .red)
    #expect(summary("i", lifecycle: .interrupted, phase: .idle).withWorkingSubagents(true).statusTone == .red)
    // A session at work reads the same either way, phase included.
    let running = summary("r", lifecycle: .running, phase: .responding).withWorkingSubagents(true)
    #expect(running.statusTone == .blue)
    #expect(running.statusText == "Running · Responding")

    // "Kept running by its subagents" is the parked case and nothing else:
    // the mark alone does not say so.
    #expect(summary("p", lifecycle: .waitingForInput, phase: .idle).withWorkingSubagents(true).isKeptRunningBySubagents)
    #expect(!summary("p", lifecycle: .waitingForInput, phase: .idle).isKeptRunningBySubagents)
    #expect(!running.isKeptRunningBySubagents)
    #expect(!ended.isKeptRunningBySubagents)
    #expect(!summary("f", lifecycle: .failed, phase: .idle).withWorkingSubagents(true).isKeptRunningBySubagents)
    #expect(!summary("a", lifecycle: .waitingForInput, phase: .waitingForApproval).withWorkingSubagents(true).isKeptRunningBySubagents)
}

@Test func theMarkSurvivesEveryCopyButIsNeverEncoded() throws {
    let marked = summary("p", lifecycle: .waitingForInput, phase: .idle, needsReview: true).withWorkingSubagents(true)
    #expect(marked.reviewed.hasWorkingSubagents)
    #expect(marked.withHiddenInNotch(true).hasWorkingSubagents)
    #expect(marked.withHiddenByFilter(true).hasWorkingSubagents)
    #expect(marked.withFilterEvaluated(true).hasWorkingSubagents)
    #expect(marked != marked.withWorkingSubagents(false))

    // Derived, so never stored or sent: a decoded summary is unmarked.
    let data = try TransportCoding.makeEncoder().encode(marked)
    #expect(!String(decoding: data, as: UTF8.self).contains("hasWorkingSubagents"))
    let decoded = try TransportCoding.makeDecoder().decode(SessionSummary.self, from: data)
    #expect(!decoded.hasWorkingSubagents)
    #expect(decoded == marked.withWorkingSubagents(false))
}

// MARK: Derivation

@Test func aSubagentAtWorkMarksEveryAncestor() {
    let sessions = [
        summary("root", lifecycle: .waitingForInput, phase: .idle),
        summary("child", parent: "root", lifecycle: .completed, phase: .idle),
        summary("grandchild", parent: "child", lifecycle: .running, phase: .executing),
        summary("other", lifecycle: .waitingForInput, phase: .idle),
        summary("done", parent: "other", lifecycle: .completed, phase: .idle),
    ]
    let working = SessionHierarchy.sessionsWithWorkingSubagents(sessions)
    #expect(working == [SessionID("root"), SessionID("child")])

    let marked = Dictionary(uniqueKeysWithValues: SessionHierarchy.markingWorkingSubagents(sessions).map { ($0.id.rawValue, $0) })
    #expect(marked["root"]?.statusTone == .blue)
    // An ended subagent stays ended even with its own subagent at work.
    #expect(marked["child"]?.statusTone == .gray)
    #expect(marked["other"]?.statusTone == .gray)
    #expect(marked["grandchild"]?.hasWorkingSubagents == false)
}

@Test func whatCountsAsASubagentAtWork() {
    func working(_ lifecycle: SessionLifecycle, _ phase: TurnPhase) -> Bool {
        !SessionHierarchy.sessionsWithWorkingSubagents([
            summary("root", lifecycle: .waitingForInput, phase: .idle),
            summary("child", parent: "root", lifecycle: lifecycle, phase: phase),
        ]).isEmpty
    }
    #expect(working(.running, .thinking))
    #expect(working(.compacting, .compacting))
    // Held up on a human decision is still not finished.
    #expect(working(.waitingForInput, .waitingForApproval))
    // Parked, ended, failed, cut off — and one that only ever started.
    #expect(!working(.waitingForInput, .idle))
    #expect(!working(.completed, .idle))
    #expect(!working(.failed, .idle))
    #expect(!working(.interrupted, .idle))
    #expect(!working(.starting, .idle))
}

@Test func theMarkIsClearedWhenTheSubagentsStop() {
    let stale = summary("root", lifecycle: .waitingForInput, phase: .idle).withWorkingSubagents(true)
    let marked = SessionHierarchy.markingWorkingSubagents([
        stale,
        summary("child", parent: "root", lifecycle: .completed, phase: .idle),
    ])
    #expect(marked.first?.hasWorkingSubagents == false)
}

@Test func aLoopingLineageIsWalkedOnce() {
    let working = SessionHierarchy.sessionsWithWorkingSubagents([
        summary("a", parent: "b", lifecycle: .running, phase: .thinking),
        summary("b", parent: "a", lifecycle: .running, phase: .thinking),
    ])
    #expect(working == [SessionID("a"), SessionID("b")])
}

@Test func wholeSessionsTakeTheSameMark() {
    let details = SessionHierarchy.markingWorkingSubagents([
        SessionDetail(summary: summary("root", lifecycle: .waitingForInput, phase: .idle), timeline: []),
        SessionDetail(summary: summary("child", parent: "root"), timeline: []),
    ])
    #expect(details.map(\.summary.hasWorkingSubagents) == [true, false])
}

// MARK: A subagent is never "not looked at yet"

private func turnEnd(_ id: String, session: String, agent: AgentKind, lineage: SessionLineage? = nil, at seconds: TimeInterval) -> AgentIngressEvent {
    let date = base.addingTimeInterval(seconds)
    return AgentIngressEvent(
        eventID: EventID(id), sessionID: SessionID(session), agent: agent, occurredAt: date,
        lifecycle: agent.isSubagent ? .completed : .waitingForInput, phase: .idle,
        timelineItem: TimelineItem(
            id: TimelineItemID("turn_end:\(id)"), sessionID: SessionID(session), occurredAt: date,
            payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed))
        ),
        lineage: lineage
    )
}

@Test func aSubagentsTurnEndNeverAsksForReview() async throws {
    let repository = InMemorySessionRepository()
    let lineage = SessionLineage(threadSource: "subagent", parentSessionID: SessionID("main"), subagentDepth: 1)
    _ = try await repository.apply(turnEnd("m1", session: "main", agent: .claude, at: 10))
    _ = try await repository.apply(turnEnd("c1", session: "main:agent:a1", agent: .claudeSubagent, lineage: lineage, at: 20))

    let main = try #require(try await repository.sessionSummary(id: SessionID("main")))
    #expect(main.needsReview)
    #expect(main.statusTone == .green)

    let child = try #require(try await repository.sessionSummary(id: SessionID("main:agent:a1")))
    #expect(!child.needsReview)
    #expect(!child.needsAttention)
    #expect(child.statusTone == .gray)
}

@Test func aFailedSubagentStillAsksForAttention() async throws {
    let repository = InMemorySessionRepository()
    let id = SessionID("main:agent:a1")
    let date = base.addingTimeInterval(30)
    _ = try await repository.apply(AgentIngressEvent(
        eventID: EventID("c-abort"), sessionID: id, agent: .claudeSubagent, occurredAt: date,
        lifecycle: .interrupted, phase: .idle,
        timelineItem: TimelineItem(
            id: TimelineItemID("turn_end:abort"), sessionID: id, occurredAt: date,
            payload: .turnEnd(TurnEndTimelinePayload(outcome: .aborted))
        ),
        lineage: SessionLineage(parentSessionID: SessionID("main"))
    ))
    let child = try #require(try await repository.sessionSummary(id: id))
    #expect(!child.needsReview)
    #expect(child.needsAttention)
    #expect(child.statusTone == .red)
}

@Test func aLateLineageTakesTheReviewFlagAway() async throws {
    // A Codex child thread can end a turn while still read as plain `codex`;
    // the lineage that names its parent arrives afterwards.
    let repository = InMemorySessionRepository()
    let id = SessionID("thread")
    _ = try await repository.apply(turnEnd("t1", session: "thread", agent: .codex, at: 10))
    #expect(try await repository.sessionSummary(id: id)?.needsReview == true)

    _ = try await repository.apply(AgentIngressEvent(
        eventID: EventID("t2"), sessionID: id, agent: .codexSubagent, occurredAt: base.addingTimeInterval(20),
        title: "Child", lineage: SessionLineage(threadSource: "subagent", parentSessionID: SessionID("main"))
    ))
    let child = try #require(try await repository.sessionSummary(id: id))
    #expect(child.agent == .codexSubagent)
    #expect(!child.needsReview)
    #expect(!child.needsAttention)
}

// MARK: Stored subagents drop the flag (lumi-v15)

@Test func storedSubagentsDropTheReviewFlag() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let path = directory.appendingPathComponent("sessions.sqlite3").path
    defer { try? FileManager.default.removeItem(at: directory) }

    // Rows as builds before v15 could hold them.
    func flagged(_ summary: SessionSummary) -> SessionSummary {
        summary.withReviewState(needsAttention: true, needsReview: true)
    }
    let stored: [SessionSummary] = [
        flagged(summary("main", lifecycle: .waitingForInput, phase: .idle, at: 100)),
        flagged(summary("main:agent:done", parent: "main", lifecycle: .completed, phase: .idle, at: 50)),
        flagged(summary("main:agent:cut", parent: "main", lifecycle: .interrupted, phase: .idle, at: 60)),
        flagged(summary("main:agent:ask", parent: "main", lifecycle: .waitingForInput, phase: .waitingForApproval, at: 65)),
        flagged(summary("codex-child", parent: "main", agent: .codexSubagent, lifecycle: .waitingForInput, phase: .idle, at: 70)),
        // Never flagged: untouched, clocks included.
        summary("main:agent:busy", parent: "main", lifecycle: .running, phase: .executing, at: 110),
    ]
    do {
        let repository = try SQLiteSessionRepository(path: path)
        for summary in stored {
            try await repository.replaceSession(SessionDetail(summary: summary, timeline: []))
        }
    }
    let queue = try DatabaseQueue(path: path)
    try await queue.write { db in
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'lumi-v15-subagents-never-need-review'")
    }
    try queue.close()

    let reopened = try SQLiteSessionRepository(path: path)
    let byID = Dictionary(uniqueKeysWithValues: try await reopened.listSessions(limit: 100).map { ($0.id.rawValue, $0) })

    // The main session keeps its flag.
    #expect(byID["main"] == stored[0])
    // Subagents lose it; attention follows what is left of the ladder.
    #expect(byID["main:agent:done"] == stored[1].withReviewState(needsAttention: false, needsReview: false))
    #expect(byID["codex-child"] == stored[4].withReviewState(needsAttention: false, needsReview: false))
    #expect(byID["main:agent:cut"] == stored[2].withReviewState(needsAttention: true, needsReview: false))
    #expect(byID["main:agent:ask"] == stored[3].withReviewState(needsAttention: true, needsReview: false))
    #expect(byID["main:agent:busy"] == stored[5])
}
