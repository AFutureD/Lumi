import Transport
import Foundation
import Testing
@testable import Core

private let session = SessionID("s")

private func item(
    _ id: String,
    turn: String?,
    at seconds: TimeInterval,
    _ payload: TimelinePayload
) -> TimelineItem {
    TimelineItem(
        id: TimelineItemID(id),
        sessionID: session,
        turnID: turn.map(TurnID.init),
        occurredAt: Date(timeIntervalSince1970: seconds),
        payload: payload
    )
}

@Test func projectionFoldsACompletedTurn() {
    let turns = TurnProjection.turns(from: [
        item("p", turn: "t1", at: 10, .message(MessageTimelinePayload(role: .user, text: "do it"))),
        item("tool1", turn: "t1", at: 11, .tool(ToolTimelinePayload(name: "Bash", status: .started, toolUseID: "u1"))),
        item("tool1r", turn: "t1", at: 12, .tool(ToolTimelinePayload(name: "Bash", status: .succeeded, toolUseID: "u1"))),
        item("sub", turn: "t1", at: 13, .subagent(SubagentTimelinePayload(name: "worker", status: .started))),
        item("reply", turn: "t1", at: 14, .message(MessageTimelinePayload(role: .assistant, text: "working"))),
        item("end", turn: "t1", at: 15, .turnEnd(TurnEndTimelinePayload(outcome: .completed, message: "Done."))),
    ], sessionID: session)

    #expect(turns.count == 1)
    let turn = turns[0]
    #expect(turn.id == TurnID("t1"))
    #expect(turn.prompt == "do it")
    #expect(turn.startedAt == Date(timeIntervalSince1970: 10))
    #expect(turn.endedAt == Date(timeIntervalSince1970: 15))
    #expect(turn.outcome == .completed)
    #expect(turn.toolCallCount == 1)
    #expect(turn.subagentCount == 1)
    // The turn end's message overrides the last assistant text.
    #expect(turn.lastAssistantMessage == "Done.")
    #expect(!turn.isOpen)
    // Fixed by contract: not derivable, read by nothing.
    #expect(turn.index == nil)
    #expect(turn.phase == .idle)
}

@Test func projectionKeepsAnUnfinishedTurnOpenAndClosesOnFatalError() {
    let open = TurnProjection.turns(from: [
        item("p", turn: "t1", at: 10, .message(MessageTimelinePayload(role: .user, text: "hi"))),
        item("r", turn: "t1", at: 11, .message(MessageTimelinePayload(role: .assistant, text: "thinking"))),
    ], sessionID: session)
    #expect(open[0].isOpen)
    #expect(open[0].lastAssistantMessage == "thinking")

    let recoverable = TurnProjection.turns(from: [
        item("p", turn: "t1", at: 10, .message(MessageTimelinePayload(role: .user, text: "hi"))),
        item("e", turn: "t1", at: 11, .error(ErrorTimelinePayload(title: "hiccup", message: "retry", recoverable: true))),
    ], sessionID: session)
    #expect(recoverable[0].isOpen)

    let fatal = TurnProjection.turns(from: [
        item("p", turn: "t1", at: 10, .message(MessageTimelinePayload(role: .user, text: "hi"))),
        item("e", turn: "t1", at: 11, .error(ErrorTimelinePayload(title: "boom", message: "context limit", recoverable: false))),
    ], sessionID: session)
    #expect(fatal[0].outcome == .failed)
    #expect(fatal[0].endedAt == Date(timeIntervalSince1970: 11))
}

@Test func projectionOrdersTurnsIgnoresTurnlessItemsAndSurvivesUnsortedInput() {
    let turns = TurnProjection.turns(from: [
        // Deliberately out of order; a turn-less marker mixed in.
        item("p2", turn: "t2", at: 20, .message(MessageTimelinePayload(role: .user, text: "second"))),
        item("marker", turn: nil, at: 5, .sessionMarker(SessionMarkerTimelinePayload(kind: .sessionStarted))),
        item("end1", turn: "t1", at: 12, .turnEnd(TurnEndTimelinePayload(outcome: .aborted))),
        item("p1", turn: "t1", at: 10, .message(MessageTimelinePayload(role: .user, text: "first"))),
    ], sessionID: session)

    #expect(turns.map(\.id) == [TurnID("t1"), TurnID("t2")])
    #expect(turns[0].prompt == "first")
    #expect(turns[0].outcome == .aborted)
    #expect(turns[1].isOpen)
}

@Test func projectionFirstUserMessageWinsThePrompt() {
    let turns = TurnProjection.turns(from: [
        item("p1", turn: "t1", at: 10, .message(MessageTimelinePayload(role: .user, text: "real prompt"))),
        item("p2", turn: "t1", at: 11, .message(MessageTimelinePayload(role: .user, text: "follow-up"))),
    ], sessionID: session)
    #expect(turns[0].prompt == "real prompt")
}

@Test func currentTurnIDIsTheNewestTurnScopedItem() {
    #expect(TurnProjection.currentTurnID(in: []) == nil)
    #expect(TurnProjection.currentTurnID(in: [
        item("marker", turn: nil, at: 5, .sessionMarker(SessionMarkerTimelinePayload(kind: .sessionStarted))),
    ]) == nil)

    let timeline = [
        item("p1", turn: "t1", at: 10, .message(MessageTimelinePayload(role: .user, text: "one"))),
        item("end1", turn: "t1", at: 12, .turnEnd(TurnEndTimelinePayload(outcome: .completed))),
        item("p2", turn: "t2", at: 20, .message(MessageTimelinePayload(role: .user, text: "two"))),
        item("marker", turn: nil, at: 25, .sessionMarker(SessionMarkerTimelinePayload(kind: .sessionEnded))),
    ]
    #expect(TurnProjection.currentTurnID(in: timeline) == TurnID("t2"))
}
