import Foundation
import Testing
@testable import AgentStatusTransport

private let session = SessionID("s1")
private let turn = TurnID("t1")
private let base = Date(timeIntervalSince1970: 1_700_000_000)

private func item(
    _ id: String,
    _ offset: TimeInterval,
    turnID: TurnID? = turn,
    _ payload: TimelinePayload
) -> TimelineItem {
    TimelineItem(
        id: TimelineItemID(id),
        sessionID: session,
        turnID: turnID,
        occurredAt: base.addingTimeInterval(offset),
        payload: payload
    )
}

@Test func toolCallAndResultStayAsTwoRowsPairedByToolUseID() {
    let rows = TimelineProjection.rows(from: [
        item("a", 0, .tool(ToolTimelinePayload(name: "Bash", summary: "npm test", status: .started, toolUseID: "tu1"))),
        item("b", 5, .tool(ToolTimelinePayload(name: "Bash", status: .succeeded, durationMilliseconds: 7_100, toolUseID: "tu1"))),
    ])
    #expect(rows.count == 2)
    #expect(rows[0].tag == .tool)
    #expect(rows[0].status == .started)
    #expect(rows[0].lane == .exec)
    #expect(rows[0].level == .l1)
    #expect(rows[1].tag == .result)
    #expect(rows[1].status == .succeeded)
    #expect(rows[1].level == .l2)
    #expect(rows[0].toolUseID == "tu1" && rows[1].toolUseID == "tu1")
    #expect(rows[1].text.contains("7.1s"))
}

@Test func failedToolResultEscalatesToFailedL3() {
    let rows = TimelineProjection.rows(from: [
        item("b", 5, .tool(ToolTimelinePayload(name: "Bash", status: .failed, toolUseID: "tu1"))),
    ])
    #expect(rows[0].tag == .failed)
    #expect(rows[0].level == .l3)
    #expect(rows[0].lane == .exec)
}

@Test func adjacentSessionContextMergesIntoContextGroup() {
    let rows = TimelineProjection.rows(from: [
        item("c1", 0, turnID: nil, .context(ContextTimelinePayload(scope: .session, kind: "instructions", summary: "CLAUDE.md"))),
        item("c2", 1, turnID: nil, .context(ContextTimelinePayload(scope: .session, kind: "model_configuration", summary: "gpt-5"))),
        item("c3", 2, turnID: nil, .context(ContextTimelinePayload(scope: .session, kind: "cwd", summary: "/tmp"))),
        item("hidden", 2, turnID: nil, .modelConfiguration(ModelConfigurationTimelinePayload(source: "x", model: "gpt-5", settings: .null))),
        item("u", 3, .message(MessageTimelinePayload(role: .user, text: "hi"))),
        item("c4", 4, .context(ContextTimelinePayload(scope: .turn, kind: "system_reminder", summary: "reminder"))),
    ])
    #expect(rows.count == 3)
    #expect(rows[0].tag == .contextGroup)
    #expect(rows[0].count == 3)
    #expect(rows[0].label == "CONTEXT ×3")
    #expect(!rows[0].spansLanes)
    #expect(rows[0].lane == .user)
    #expect(rows[0].items.count == 3)
    #expect(rows[1].tag == .user)
    #expect(rows[2].tag == .context)
    #expect(rows[2].lane == .user)
    #expect(rows[2].level == .l1)
}

@Test func subagentUpdatesInPlaceByAgentID() {
    let rows = TimelineProjection.rows(from: [
        item("s1", 0, .subagent(SubagentTimelinePayload(name: "Explore", agentSessionID: "ag1", status: .started))),
        item("m", 1, .message(MessageTimelinePayload(role: .assistant, text: "thinking"))),
        item("s2", 2, .subagent(SubagentTimelinePayload(name: "Explore", agentSessionID: "ag1", status: .completed))),
    ])
    #expect(rows.count == 2)
    #expect(rows[0].tag == .subagent)
    #expect(rows[0].status == .succeeded)
    #expect(rows[0].items.count == 2)
    #expect(rows[0].lane == .model)
}

@Test func turnEndAppendsL3RowAndMarksLastAssistantSucceeded() {
    let rows = TimelineProjection.rows(from: [
        item("u", 0, .message(MessageTimelinePayload(role: .user, text: "do it"))),
        item("a1", 1, .message(MessageTimelinePayload(role: .assistant, text: "working"))),
        item("a2", 2, .message(MessageTimelinePayload(role: .assistant, text: "done"))),
        item("e", 3, .turnEnd(TurnEndTimelinePayload(outcome: .completed))),
    ])
    #expect(rows.map(\.tag) == [.user, .assistant, .assistant, .turnEnd])
    #expect(rows[1].status == .info)
    #expect(rows[2].status == .succeeded)
    #expect(rows[3].level == .l3)
    #expect(rows[3].lane == .model)
}

@Test func sessionMarkersSpanLanesAndUsageIsHidden() {
    let rows = TimelineProjection.rows(from: [
        item("s", 0, turnID: nil, .sessionMarker(SessionMarkerTimelinePayload(kind: .sessionStarted, detail: "resume", model: "gpt-5"))),
        item("usage", 1, .usageMetrics(UsageMetricsTimelinePayload(total: TokenUsage(totalTokens: 10)))),
        item("c", 2, turnID: nil, .sessionMarker(SessionMarkerTimelinePayload(kind: .compactionEnded, detail: "auto"))),
        item("x", 3, turnID: nil, .sessionMarker(SessionMarkerTimelinePayload(kind: .sessionEnded, detail: "other"))),
    ])
    #expect(rows.map(\.tag) == [.session, .compact, .session])
    let allSpan = rows.allSatisfy { $0.spansLanes }
    #expect(allSpan)
    #expect(rows[0].text.contains("resume"))
}

@Test func legacyReasoningContextMapsToReasoningL1() {
    let rows = TimelineProjection.rows(from: [
        item("r", 0, .internalContext(InternalContextTimelinePayload(kind: "agent_reasoning", content: .object(["text": .string("hmm")])))),
        item("r2", 1, .reasoning(ReasoningTimelinePayload(text: "thinking hard"))),
    ])
    #expect(rows.map(\.tag) == [.reasoning, .reasoning])
    #expect(rows[0].text == "hmm")
    #expect(rows[0].level == .l1)
}

@Test func newPayloadsRoundTripThroughCoding() throws {
    let payloads: [TimelinePayload] = [
        .reasoning(ReasoningTimelinePayload(text: "t")),
        .context(ContextTimelinePayload(scope: .turn, kind: "attachment", summary: "a", content: .string("x"))),
        .sessionMarker(SessionMarkerTimelinePayload(kind: .compactionStarted, detail: "manual")),
        .turnEnd(TurnEndTimelinePayload(outcome: .aborted, message: "user")),
        .tool(ToolTimelinePayload(name: "Bash", status: .started, toolUseID: "id")),
    ]
    let encoder = TransportCoding.makeEncoder()
    let decoder = TransportCoding.makeDecoder()
    for payload in payloads {
        let data = try encoder.encode(payload)
        let decoded = try decoder.decode(TimelinePayload.self, from: data)
        #expect(decoded == payload)
    }

    let turnSummary = TurnSummary(id: turn, sessionID: session, index: 2, phase: .executing, prompt: "p", startedAt: base, toolCallCount: 3)
    let data = try encoder.encode(turnSummary)
    let decodedTurn = try decoder.decode(TurnSummary.self, from: data)
    #expect(decodedTurn == turnSummary)
    let merged = turnSummary.merging(TurnSummary(id: turn, sessionID: session, phase: .idle, startedAt: base.addingTimeInterval(1), endedAt: base.addingTimeInterval(9), outcome: .completed))
    #expect(merged.prompt == "p" && merged.toolCallCount == 3 && merged.outcome == .completed && merged.phase == .idle)

    // Older detail JSON without `turns` still decodes.
    let old = Data("""
    {"summary":{"id":"s","agent":"codex","title":"t","lifecycle":"running","phase":"idle","startedAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z","lastActivityAt":"2024-01-01T00:00:00Z","needsAttention":false,"needsReview":false,"hiddenInNotch":false},"timeline":[]}
    """.utf8)
    let detail = try decoder.decode(SessionDetail.self, from: old)
    #expect(detail.turns.isEmpty)
}

@Test func repeatedReasoningHeadersCollapseWithinATurn() {
    let rows = TimelineProjection.rows(from: [
        item("r1", 0, .reasoning(ReasoningTimelinePayload(text: "**Planning**"))),
        item("r2", 1, .reasoning(ReasoningTimelinePayload(text: "**Designing**"))),
        // Codex re-sends the turn's headers with the next reasoning item.
        item("r3", 2, .reasoning(ReasoningTimelinePayload(text: "**Planning**"))),
        item("r4", 3, .reasoning(ReasoningTimelinePayload(text: "**Designing**"))),
        item("r5", 4, .reasoning(ReasoningTimelinePayload(text: "**Testing**"))),
        // A new turn starts over.
        item("u", 5, turnID: TurnID("t2"), .message(MessageTimelinePayload(role: .user, text: "next"))),
        item("r6", 6, turnID: TurnID("t2"), .reasoning(ReasoningTimelinePayload(text: "**Planning**"))),
    ])
    #expect(rows.map(\.text) == ["**Planning**", "**Designing**", "**Testing**", "next", "**Planning**"])
    #expect(rows[0].items.map(\.id.rawValue) == ["r1", "r3"])
}

@Test func emptyReasoningShowsPlaceholderAndNeverCollapses() {
    let rows = TimelineProjection.rows(from: [
        // Claude may persist a thinking block with only a signature; each
        // such block is a thinking step of its own.
        item("r1", 0, .reasoning(ReasoningTimelinePayload(text: ""))),
        item("t1", 1, .tool(ToolTimelinePayload(name: "Bash", summary: "ls", status: .started, toolUseID: "tu1"))),
        item("r2", 2, .reasoning(ReasoningTimelinePayload(text: ""))),
        item("r3", 3, .reasoning(ReasoningTimelinePayload(text: ""))),
        item("r4", 4, .reasoning(ReasoningTimelinePayload(text: "**Planning**"))),
        item("r5", 5, .reasoning(ReasoningTimelinePayload(text: "**Planning**"))),
    ])
    #expect(rows.map(\.tag) == [.reasoning, .tool, .reasoning, .reasoning, .reasoning])
    #expect(rows.map(\.text) == ["Empty", "Bash · ls", "Empty", "Empty", "**Planning**"])
    #expect(rows.filter { $0.text == "Empty" }.allSatisfy { $0.items.count == 1 })
    #expect(rows[4].items.map(\.id.rawValue) == ["r4", "r5"])
}
