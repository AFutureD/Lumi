import AgentStatusTransport
import Foundation
import Testing
@testable import AgentStatusCore

private let base = Date(timeIntervalSince1970: 1_000)

private func item(_ id: String, at offset: TimeInterval, text: String = "x") -> TimelineItem {
    TimelineItem(
        id: TimelineItemID(id), sessionID: SessionID("s"), turnID: TurnID("t1"),
        occurredAt: base.addingTimeInterval(offset),
        payload: .message(MessageTimelinePayload(role: .assistant, text: text))
    )
}

@Test func detailReductionAppliesAnEventLikeTheRepository() {
    let detail = SessionDetail(
        summary: SessionSummary(
            id: SessionID("s"), agent: .codex, title: "s", lifecycle: .running, phase: .thinking,
            startedAt: base, updatedAt: base, lastActivityAt: base
        ),
        turns: [],
        timeline: [item("a", at: 1)]
    )
    let event = AgentIngressEvent(
        eventID: EventID("e1"), sessionID: SessionID("s"), turnID: TurnID("t1"), agent: .codex,
        occurredAt: base.addingTimeInterval(5), phase: .executing,
        timelineItem: item("b", at: 5)
    )
    let applied = SessionDetailReduction.applying(event, to: detail)
    #expect(applied.summary.phase == .executing)
    #expect(applied.summary.updatedAt == base.addingTimeInterval(5))
    #expect(applied.turns.map(\.id) == [TurnID("t1")])
    #expect(applied.turns.first?.phase == .executing)
    #expect(applied.timeline.map(\.id) == [TimelineItemID("a"), TimelineItemID("b")])

    // An older copy of a row never regresses the newer one.
    let stale = AgentIngressEvent(
        eventID: EventID("e2"), sessionID: SessionID("s"), agent: .codex,
        occurredAt: base.addingTimeInterval(2),
        timelineItem: item("b", at: 2, text: "stale")
    )
    let kept = SessionDetailReduction.applying(stale, to: applied)
    #expect(kept.timeline.last?.occurredAt == base.addingTimeInterval(5))
}

@Test func detailReductionMergesAPartialCopy() {
    let detail = SessionDetail(
        summary: SessionSummary(
            id: SessionID("s"), agent: .codex, title: "s", lifecycle: .running, phase: .thinking,
            startedAt: base, updatedAt: base, lastActivityAt: base
        ),
        turns: [TurnSummary(id: TurnID("t1"), sessionID: SessionID("s"), phase: .thinking, startedAt: base)],
        timeline: [item("a", at: 1), item("b", at: 5)]
    )
    let partial = SessionDetail(
        summary: SessionSummary(
            id: SessionID("s"), agent: .codex, title: "s", lifecycle: .completed, phase: .idle,
            startedAt: base, updatedAt: base.addingTimeInterval(9), lastActivityAt: base.addingTimeInterval(9)
        ),
        turns: [
            TurnSummary(id: TurnID("t1"), sessionID: SessionID("s"), phase: .idle, startedAt: base),
            TurnSummary(id: TurnID("t2"), sessionID: SessionID("s"), phase: .idle, startedAt: base.addingTimeInterval(6)),
        ],
        timeline: [item("b", at: 5, text: "replaced"), item("c", at: 9)]
    )
    let merged = SessionDetailReduction.merging(partial, into: detail)
    #expect(merged.summary.lifecycle == .completed)
    #expect(merged.turns.map(\.id) == [TurnID("t1"), TurnID("t2")])
    #expect(merged.turns.first?.phase == .idle)
    #expect(merged.timeline.map(\.id) == [TimelineItemID("a"), TimelineItemID("b"), TimelineItemID("c")])
    if case let .message(message)? = merged.timeline[1].payload as TimelinePayload? {
        #expect(message.text == "replaced")
    }
}
