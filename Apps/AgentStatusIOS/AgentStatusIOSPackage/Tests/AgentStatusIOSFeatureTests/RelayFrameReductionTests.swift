import AgentStatusTransport
import Foundation
import Testing
@testable import AgentStatusIOSFeature

private func detail(_ id: String, items: Int, activityAt: TimeInterval, firstItem: Int = 0) -> SessionDetail {
    let sessionID = SessionID(id)
    let date = Date(timeIntervalSince1970: activityAt)
    return SessionDetail(
        summary: SessionSummary(
            id: sessionID, agent: .claude, title: id.capitalized,
            lifecycle: .running, phase: .thinking,
            startedAt: date, updatedAt: date, lastActivityAt: date
        ),
        turns: [TurnSummary(id: TurnID("\(id)-turn"), sessionID: sessionID, phase: .thinking, startedAt: date)],
        timeline: (firstItem..<(firstItem + items)).map { index in
            TimelineItem(
                id: TimelineItemID("\(id)-item-\(index)"), sessionID: sessionID,
                occurredAt: date.addingTimeInterval(Double(index)),
                payload: .message(MessageTimelinePayload(role: .assistant, text: "Update \(index)"))
            )
        }
    )
}

@Test func partsAssembleInOrderWithPartZeroIdentity() {
    let base = detail("split", items: 2, activityAt: 100)
    let tail = detail("split", items: 2, activityAt: 100, firstItem: 2)
    let partZero = RemoteSessionPayload(
        kind: .session,
        session: SessionDetail(
            summary: base.summary, turns: base.turns, timeline: base.timeline,
            nextCursor: PaginationCursor(value: "1")
        ),
        part: 0
    )
    let partOne = RemoteSessionPayload(
        kind: .session,
        session: SessionDetail(summary: base.summary, turns: [], timeline: tail.timeline),
        part: 1
    )

    // Parts assemble regardless of buffer order; turns come from part 0.
    let assembled = RelayFrameReduction.assemble(parts: [partOne, partZero])
    #expect(assembled?.timeline.map(\.id) == (base.timeline + tail.timeline).map(\.id))
    #expect(assembled?.turns.count == 1)
    #expect(RelayFrameReduction.assemble(parts: []) == nil)
}

@Test func upsertKeepsLatestActivityOrderAndPruneFollowsTheIndex() {
    let older = detail("older", items: 1, activityAt: 10)
    let newer = detail("newer", items: 1, activityAt: 20)
    var sessions = RelayFrameReduction.upsert(older, into: [])
    sessions = RelayFrameReduction.upsert(newer, into: sessions)
    #expect(sessions.map(\.summary.id) == [newer.summary.id, older.summary.id])

    // A replace moves the session, never duplicates it.
    let refreshed = detail("older", items: 2, activityAt: 30)
    sessions = RelayFrameReduction.upsert(refreshed, into: sessions)
    #expect(sessions.map(\.summary.id) == [refreshed.summary.id, newer.summary.id])
    #expect(sessions.count == 2)

    let pruned = RelayFrameReduction.prune(sessions, keeping: [newer.summary.id])
    #expect(pruned.map(\.summary.id) == [newer.summary.id])
}

@Test func missingIDsGateTheCompletenessOfASync() {
    let received = detail("received", items: 1, activityAt: 10)
    let missing = SessionID("missing")
    #expect(RelayFrameReduction.missingIDs(
        index: [received.summary.id, missing],
        sessions: [received]
    ) == [missing])
    #expect(RelayFrameReduction.missingIDs(
        index: [received.summary.id],
        sessions: [received]
    ).isEmpty)
}
