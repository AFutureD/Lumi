import AgentStatusRemote
import AgentStatusTransport
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

@Test func eventBatchesSplitAndStripOnlyTheOversizedItem() throws {
    func event(_ id: String, text: String) -> AgentIngressEvent {
        AgentIngressEvent(
            eventID: EventID(id), sessionID: SessionID("s"), agent: .codex, occurredAt: date,
            phase: .executing,
            timelineItem: TimelineItem(
                id: TimelineItemID(id), sessionID: SessionID("s"), occurredAt: date,
                payload: .message(MessageTimelinePayload(role: .assistant, text: text))
            )
        )
    }
    let events = (0..<20).map { event("e-\($0)", text: noisyText(bytes: 100_000)) }
    let batches = try RelayPayloadBatcher.eventBatches(events, generatedAt: date)
    #expect(batches.count > 1)
    #expect(batches.allSatisfy { $0.prepared.byteCount <= RelayPayloadBatcher.maxCompressedBytes })
    #expect(batches.flatMap { $0.payload.events ?? [] } == events)

    let huge = event("huge", text: noisyText(bytes: 900_000))
    let small = event("small", text: "hi")
    let stripped = try RelayPayloadBatcher.eventBatches([small, huge], generatedAt: date)
    let delivered = stripped.flatMap { $0.payload.events ?? [] }
    #expect(delivered.map(\.eventID) == [small.eventID, huge.eventID])
    #expect(delivered[1].timelineItem == nil)
    #expect(delivered[1].phase == .executing)
}

@Test func sessionPartitionerSplitsOversizedSessionsWithTurnsOnPartZero() throws {
    let small = SessionDetail(
        summary: summary("small"),
        turns: [TurnSummary(id: TurnID("t"), sessionID: SessionID("small"), phase: .thinking, startedAt: date)],
        timeline: [TimelineItem(
            id: TimelineItemID("one"), sessionID: SessionID("small"), occurredAt: date,
            payload: .message(MessageTimelinePayload(role: .user, text: "hi"))
        )]
    )
    let singleParts = try RelaySessionPartitioner.parts(for: small, requestID: RequestID("r"), generatedAt: date)
    #expect(singleParts.count == 1)
    #expect(singleParts[0].payload.kind == .sessionFull)
    #expect(singleParts[0].payload.requestID == RequestID("r"))
    #expect(singleParts[0].payload.session?.nextCursor == nil)
    #expect(singleParts[0].payload.part == 0)

    let bigTimeline = (0..<64).map { index in
        TimelineItem(
            id: TimelineItemID("big-\(index)"), sessionID: SessionID("big"), occurredAt: date,
            payload: .message(MessageTimelinePayload(role: .assistant, text: noisyText(bytes: 65_536)))
        )
    }
    let big = SessionDetail(
        summary: summary("big"),
        turns: [TurnSummary(id: TurnID("t"), sessionID: SessionID("big"), phase: .thinking, startedAt: date)],
        timeline: bigTimeline
    )
    let parts = try RelaySessionPartitioner.parts(for: big, kind: .sessionTimeline, requestID: nil, generatedAt: date)
    #expect(parts.count > 1)
    #expect(parts.allSatisfy { $0.payload.kind == .sessionTimeline })
    #expect(parts.dropLast().allSatisfy { $0.payload.session?.nextCursor != nil })
    #expect(parts.last?.payload.session?.nextCursor == nil)
    #expect(parts.allSatisfy { $0.prepared.byteCount <= RelaySessionPartitioner.maxCompressedBytes })
    #expect(parts.first?.payload.session?.turns.isEmpty == false)
    #expect(parts.dropFirst().allSatisfy { $0.payload.session?.turns.isEmpty == true })
    let assembled = RelayFrameReduction.assemble(parts: parts.map(\.payload).shuffled())
    #expect(assembled?.timeline == bigTimeline)
    #expect(assembled?.turns.count == 1)
}
