import Remote
import Transport
import Foundation
import Testing

private let date = Date(timeIntervalSince1970: 100)

private func summary(_ id: String) -> SessionSummary {
    SessionSummary(
        id: SessionID(id), agent: .codex, title: id,
        lifecycle: .running, phase: .thinking,
        startedAt: date, updatedAt: date, lastActivityAt: date
    )
}

/// Random text defeats compression, so a few of these force a split.
private func noisyText(bytes: Int) -> String {
    Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
}

@Test func indexPartsNumberThemselvesAndStayInsideTheBudget() throws {
    let entries = (0..<600).map { index in
        SessionIndexEntry(
            summary: SessionSummary(
                id: SessionID("s-\(index)"), agent: .codex, title: noisyText(bytes: 2_000),
                lifecycle: .running, phase: .thinking,
                startedAt: date, updatedAt: date, lastActivityAt: date
            ),
            timelineItemCount: index,
            lastItemAt: date
        )
    }
    let parts = try RelayPayloadBatcher.indexParts(entries, requestID: RequestID("req-1"), generatedAt: date)
    #expect(parts.count > 1)
    #expect(parts.enumerated().allSatisfy { $0.offset == $0.element.payload.part })
    #expect(parts.allSatisfy { $0.payload.partCount == parts.count })
    #expect(parts.allSatisfy { $0.payload.requestID == RequestID("req-1") })
    #expect(parts.allSatisfy { $0.prepared.byteCount <= RelayPayloadBatcher.maxCompressedBytes })
    #expect(parts.flatMap { $0.payload.index ?? [] } == entries)
    #expect(RelayFrameReduction.assembleIndex(parts: parts.map(\.payload).shuffled()) == entries)
    #expect(RelayFrameReduction.assembleIndex(parts: Array(parts.map(\.payload).dropLast())) == nil)

    let empty = try RelayPayloadBatcher.indexParts([], requestID: nil, generatedAt: date)
    #expect(empty.count == 1)
    #expect(empty[0].payload.partCount == 1)
    #expect(empty[0].payload.index?.isEmpty == true)
}

@Test func eventBatchesFillGreedilyAndTrimOversizedRows() throws {
    func event(_ id: String, text: String) -> AgentIngressEvent {
        AgentIngressEvent(
            eventID: EventID(id), sessionID: SessionID("s"), agent: .codex, occurredAt: date,
            phase: .executing,
            timelineItem: TimelineItem(
                id: TimelineItemID(id), sessionID: SessionID("s"), occurredAt: date,
                payload: .message(MessageTimelinePayload(role: .assistant, text: text))
            ),
            aaas: SessionAaaS(kind: .paseo, agentID: "p-1")
        )
    }
    // Forty rows of 40 KB: each fits the row budget, the batch does not.
    let events = (0..<40).map { event("e-\($0)", text: noisyText(bytes: 30_000)) }
    let batches = try RelayPayloadBatcher.eventBatches(events, generatedAt: date)
    #expect(batches.count > 1)
    #expect(batches.allSatisfy { $0.prepared.byteCount <= RelayPayloadBatcher.maxCompressedBytes })
    #expect(batches.flatMap { $0.payload.events ?? [] } == events)
    // Greedy fill: every batch but the last is nearly full.
    let encoded = try batches.dropLast().map { try TransportCoding.makeEncoder().encode($0.payload).count }
    #expect(encoded.allSatisfy { $0 > RelayPayloadBatcher.maxEncodedBytes * 9 / 10 })

    // A row past the content budget travels trimmed and marked, with every
    // other field — the AaaS ownership included, or the iPhone mirror's
    // title gate never arms — untouched.
    let huge = event("huge", text: noisyText(bytes: 900_000))
    let small = event("small", text: "hi")
    let trimmed = try RelayPayloadBatcher.eventBatches([small, huge], generatedAt: date)
    let delivered = trimmed.flatMap { $0.payload.events ?? [] }
    #expect(delivered.map(\.eventID) == [small.eventID, huge.eventID])
    #expect(delivered[0].timelineItem?.isTruncated == false)
    let item = try #require(delivered[1].timelineItem)
    #expect(item.isTruncated)
    #expect(TimelineContentBudget.encodedSize(item) <= TimelineContentBudget.maxItemBytes)
    if case let .message(message) = item.payload { #expect(message.text.hasSuffix("…")) } else { Issue.record("payload kind changed") }
    #expect(delivered[1].phase == .executing)
    #expect(delivered[1].aaas == SessionAaaS(kind: .paseo, agentID: "p-1"))
}

@Test func contentBudgetTrimsEveryLargeKindAndLeavesSmallRowsAlone() throws {
    func item(_ payload: TimelinePayload) -> TimelineItem {
        TimelineItem(id: TimelineItemID("i"), sessionID: SessionID("s"), occurredAt: date, payload: payload)
    }
    let small = item(.message(MessageTimelinePayload(role: .user, text: "hi")))
    #expect(TimelineContentBudget.trimmed(small) == small)
    #expect(TimelineContentBudget.trimmed(small).truncated == nil)

    let bigContent = JSONValue.string(noisyText(bytes: 200_000))
    let tool = TimelineContentBudget.trimmed(item(.tool(ToolTimelinePayload(name: "Bash", summary: "ls", content: bigContent, status: .succeeded, toolUseID: "t1"))))
    #expect(tool.isTruncated)
    if case let .tool(payload) = tool.payload {
        #expect(payload.content == nil)
        #expect(payload.summary == "ls")
        #expect(payload.toolUseID == "t1")
    } else { Issue.record("payload kind changed") }
    let context = TimelineContentBudget.trimmed(item(.context(ContextTimelinePayload(kind: "file", summary: "CLAUDE.md", content: bigContent))))
    if case let .context(payload) = context.payload { #expect(payload.content == nil) } else { Issue.record("payload kind changed") }
    let reasoning = TimelineContentBudget.trimmed(item(.reasoning(ReasoningTimelinePayload(text: noisyText(bytes: 200_000)))))
    #expect(TimelineContentBudget.encodedSize(reasoning) <= TimelineContentBudget.maxItemBytes)
    // A trimmed copy only ever gets smaller; the flag is the one addition.
    let encoded = try TransportCoding.makeEncoder().encode(tool)
    #expect(String(decoding: encoded, as: UTF8.self).contains("\"truncated\":true"))
}

@Test func sessionPartitionerPacksPagesNewestFirstWithTurnsOnPartZero() throws {
    let turns = [TurnSummary(id: TurnID("t"), sessionID: SessionID("small"), phase: .thinking, startedAt: date)]
    let one = [TimelineItem(
        id: TimelineItemID("one"), sessionID: SessionID("small"), occurredAt: date,
        payload: .message(MessageTimelinePayload(role: .user, text: "hi"))
    )]
    let singleParts = try RelaySessionPartitioner.parts(
        summary: summary("small"), turns: turns, timeline: one, hasOlder: false,
        kind: .sessionTail, order: .newestFirst, requestID: RequestID("r"), generatedAt: date
    )
    #expect(singleParts.count == 1)
    #expect(singleParts[0].payload.kind == .sessionTail)
    #expect(singleParts[0].payload.requestID == RequestID("r"))
    #expect(singleParts[0].payload.session?.nextCursor == nil)
    #expect(singleParts[0].payload.part == 0)
    #expect(singleParts[0].payload.hasOlder == false)
    #expect(singleParts[0].payload.oldest == TimelineCursor(one[0]))

    let bigTimeline = (0..<64).map { index in
        TimelineItem(
            id: TimelineItemID("big-\(index)"), sessionID: SessionID("big"), occurredAt: date.addingTimeInterval(Double(index)),
            payload: .message(MessageTimelinePayload(role: .assistant, text: noisyText(bytes: 40_000)))
        )
    }
    let parts = try RelaySessionPartitioner.parts(
        summary: summary("big"), turns: turns, timeline: bigTimeline, hasOlder: true,
        kind: .sessionTail, order: .newestFirst, requestID: nil, generatedAt: date
    )
    #expect(parts.count > 1)
    #expect(parts.allSatisfy { $0.payload.kind == .sessionTail })
    #expect(parts.dropLast().allSatisfy { $0.payload.session?.nextCursor != nil })
    #expect(parts.last?.payload.session?.nextCursor == nil)
    #expect(parts.allSatisfy { $0.prepared.byteCount <= RelayPayloadBatcher.maxCompressedBytes })
    #expect(parts.first?.payload.session?.turns.isEmpty == false)
    #expect(parts.dropFirst().allSatisfy { $0.payload.session?.turns.isEmpty == true })
    // Newest rows first: part 0 holds the end of the timeline.
    #expect(parts.first?.payload.session?.timeline.first?.id == TimelineItemID("big-63"))
    // Only the last part says where the page starts and whether more exists.
    #expect(parts.dropLast().allSatisfy { $0.payload.oldest == nil && $0.payload.hasOlder == nil })
    #expect(parts.last?.payload.oldest == TimelineCursor(bigTimeline[0]))
    #expect(parts.last?.payload.hasOlder == true)
    let assembled = RelayFrameReduction.assemble(parts: parts.map(\.payload).shuffled())
    #expect(assembled?.timeline == bigTimeline)
    #expect(assembled?.turns.count == 1)

    // A since-tail lands oldest first and carries no paging facts.
    let since = try RelaySessionPartitioner.parts(
        summary: summary("big"), turns: turns, timeline: bigTimeline, hasOlder: nil,
        kind: .sessionTimeline, order: .oldestFirst, requestID: nil, generatedAt: date
    )
    #expect(since.first?.payload.session?.timeline.first?.id == TimelineItemID("big-0"))
    #expect(since.last?.payload.hasOlder == nil)
    #expect(since.last?.payload.oldest == TimelineCursor(bigTimeline[0]))
}
