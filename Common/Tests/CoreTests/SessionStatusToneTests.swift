import Persistence
import Transport
import Foundation
import Testing
@testable import Core

@Test func sessionStatusToneFollowsTheSharedCrossPlatformPalette() {
    #expect(summary(lifecycle: .starting, phase: .idle).statusTone == .blue)
    #expect(summary(lifecycle: .running, phase: .thinking).statusTone == .blue)
    // A finished turn parks in `waitingForInput · idle`: reviewed reads as
    // the Completed tier, unreviewed keeps the green "open me next" tier.
    #expect(summary(lifecycle: .waitingForInput, phase: .idle).statusTone == .gray)
    #expect(summary(lifecycle: .waitingForInput, phase: .idle, needsReview: true).statusTone == .green)
    #expect(summary(lifecycle: .waitingForInput, phase: .idle).displayLifecycle == .completed)
    // A human decision blocking the turn is orange, viewed or not.
    #expect(summary(lifecycle: .waitingForInput, phase: .waitingForApproval).statusTone == .orange)
    #expect(summary(lifecycle: .waitingForInput, phase: .waitingForApproval, needsReview: true).statusTone == .orange)
    #expect(summary(lifecycle: .waitingForInput, phase: .waitingForApproval).displayLifecycle == .waitingForInput)
    #expect(summary(lifecycle: .completed, phase: .idle).statusTone == .gray)
    #expect(summary(lifecycle: .completed, phase: .idle, needsReview: true).statusTone == .green)
    #expect(summary(lifecycle: .failed, phase: .idle).statusTone == .red)
    #expect(summary(lifecycle: .failed, phase: .idle, needsReview: true).statusTone == .red)
    #expect(summary(lifecycle: .interrupted, phase: .idle).statusTone == .red)
}

@Test func reviewingClearsTheFlagAndTheDerivedAttentionBit() {
    let unreviewed = summary(lifecycle: .waitingForInput, phase: .idle, needsReview: true, needsAttention: true)
    let reviewed = unreviewed.reviewed
    #expect(reviewed.needsReview == false)
    #expect(reviewed.needsAttention == false)
    #expect(reviewed.statusTone == .gray)

    // An approval prompt keeps demanding attention after a review.
    let blocked = summary(lifecycle: .waitingForInput, phase: .waitingForApproval, needsReview: true, needsAttention: true)
    #expect(blocked.reviewed.needsAttention == true)
    #expect(blocked.reviewed.statusTone == .orange)
}

// A turn end asks for review when it is news, and whether it is news is a
// question about the record: the hook and the transcript report the same
// end on one row, and a repeat must not undo a review done in between.
@Test func onlyATurnEndThatIsNewsAsksForReview() async throws {
    let session = SessionID("review-record")
    let turn = TurnID("t1")
    func event(_ id: String, at seconds: TimeInterval, lifecycle: SessionLifecycle, phase: TurnPhase = .idle, endsTurn: Bool = false) -> AgentIngressEvent {
        let at = Date(timeIntervalSince1970: seconds)
        return AgentIngressEvent(
            eventID: EventID(id), sessionID: session, turnID: turn, agent: .claude, occurredAt: at,
            lifecycle: lifecycle, phase: phase,
            timelineItem: endsTurn ? TimelineItem(
                id: TimelineItemIDs.turnEnd(session, turnID: turn), sessionID: session, turnID: turn, occurredAt: at,
                payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed))
            ) : nil
        )
    }
    func ended(_ id: String, at seconds: TimeInterval) -> AgentIngressEvent {
        event(id, at: seconds, lifecycle: .waitingForInput, endsTurn: true)
    }
    func flag(_ repository: InMemorySessionRepository) async throws -> Bool? {
        try await repository.sessionSummary(id: session)?.needsReview
    }

    // The hook closes the turn, the human looks, and then the turn's
    // terminal record — stamped before the hook — is read from the file.
    var repository = InMemorySessionRepository()
    _ = try await repository.apply(event("prompt", at: 100, lifecycle: .running, phase: .thinking))
    _ = try await repository.apply(ended("hook", at: 200))
    #expect(try await flag(repository) == true)
    try await repository.markSessionReviewed(session)
    _ = try await repository.apply(ended("transcript", at: 190))
    #expect(try await flag(repository) == false)

    // The other order: the record is read first, the human looks, and the
    // hook's report of the same end arrives later — with a later stamp.
    repository = InMemorySessionRepository()
    _ = try await repository.apply(event("prompt", at: 100, lifecycle: .running, phase: .thinking))
    _ = try await repository.apply(ended("transcript", at: 190))
    try await repository.markSessionReviewed(session)
    _ = try await repository.apply(ended("hook", at: 200))
    #expect(try await flag(repository) == false)

    // The turn goes on after its end and ends again: the same row, news.
    _ = try await repository.apply(event("continued", at: 300, lifecycle: .running, phase: .thinking))
    _ = try await repository.apply(ended("again", at: 310))
    #expect(try await flag(repository) == true)

    // An end heard for the first time is news however late it comes: the
    // session ended at 200, and the turn's own end (190) is only read now.
    repository = InMemorySessionRepository()
    _ = try await repository.apply(event("prompt", at: 100, lifecycle: .running, phase: .thinking))
    _ = try await repository.apply(event("session-end", at: 200, lifecycle: .completed))
    #expect(try await flag(repository) == false)
    _ = try await repository.apply(ended("late-first-report", at: 190))
    #expect(try await flag(repository) == true)
    #expect(try await repository.sessionSummary(id: session)?.lifecycle == .completed)
}

// The same rule in the store the daemon and the Mac cache run on.
@Test func theSQLiteStoreAsksItsOwnRowsWhetherATurnEndIsNews() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumi-review-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteSessionRepository(path: directory.appendingPathComponent("sessions.sqlite3").path)
    let session = SessionID("review-sqlite")
    let turn = TurnID("t1")
    func ended(_ id: String, at seconds: TimeInterval) -> AgentIngressEvent {
        let at = Date(timeIntervalSince1970: seconds)
        return AgentIngressEvent(
            eventID: EventID(id), sessionID: session, turnID: turn, agent: .claude, occurredAt: at,
            lifecycle: .waitingForInput, phase: .idle,
            timelineItem: TimelineItem(
                id: TimelineItemIDs.turnEnd(session, turnID: turn), sessionID: session, turnID: turn, occurredAt: at,
                payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed))
            )
        )
    }
    func flag() async throws -> Bool? {
        try await repository.sessionSummary(id: session)?.needsReview
    }
    _ = try await repository.apply(AgentIngressEvent(
        eventID: EventID("prompt"), sessionID: session, turnID: turn, agent: .claude,
        occurredAt: Date(timeIntervalSince1970: 100), lifecycle: .running, phase: .thinking
    ))
    #expect(try await repository.apply(ended("hook", at: 200)))
    #expect(try await flag() == true)
    try await repository.markSessionReviewed(session)
    // Applied — its id is new — and still no news.
    #expect(try await repository.apply(ended("transcript", at: 190)))
    #expect(try await flag() == false)
    #expect(try await repository.apply(ended("hook-again-later", at: 210)))
    #expect(try await flag() == false)
    // The turn goes on and ends again.
    _ = try await repository.apply(AgentIngressEvent(
        eventID: EventID("continued"), sessionID: session, turnID: turn, agent: .claude,
        occurredAt: Date(timeIntervalSince1970: 300), lifecycle: .running, phase: .thinking
    ))
    #expect(try await repository.apply(ended("again", at: 310)))
    #expect(try await flag() == true)
}

// A caller that reduces without the session's rows cannot ask the record,
// and falls back to the clock.
@Test func withoutTheRowsATurnEndTheClockHasPassedIsTakenForARepeat() {
    let session = SessionID("review-clock")
    func turnEnd(_ id: String, at seconds: TimeInterval) -> AgentIngressEvent {
        let at = Date(timeIntervalSince1970: seconds)
        return AgentIngressEvent(
            eventID: EventID(id), sessionID: session, agent: .claude, occurredAt: at,
            lifecycle: .waitingForInput, phase: .idle,
            timelineItem: TimelineItem(
                id: TimelineItemID("turn_end:review-clock:t1"), sessionID: session, occurredAt: at,
                payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed))
            )
        )
    }
    let closed = SessionReduction.summary(applying: turnEnd("hook", at: 200), to: nil)
    #expect(closed.needsReview)
    let reviewed = closed.reviewed
    #expect(!SessionReduction.summary(applying: turnEnd("transcript", at: 190), to: reviewed).needsReview)
    #expect(SessionReduction.summary(applying: turnEnd("next", at: 300), to: reviewed).needsReview)
    // The loaded-detail fold knows the rows it holds.
    let detail = SessionDetailReduction.applying(turnEnd("hook", at: 200), to: SessionDetail(summary: reviewed, turns: [], timeline: [turnEnd("hook", at: 200).timelineItem!]))
    #expect(!detail.summary.needsReview)
}

private func summary(
    lifecycle: SessionLifecycle,
    phase: TurnPhase,
    needsReview: Bool = false,
    needsAttention: Bool = false
) -> SessionSummary {
    let date = Date(timeIntervalSince1970: 0)
    return SessionSummary(
        id: SessionID("tone"),
        agent: .codex,
        title: "Tone",
        lifecycle: lifecycle,
        phase: phase,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date,
        needsAttention: needsAttention,
        needsReview: needsReview
    )
}
