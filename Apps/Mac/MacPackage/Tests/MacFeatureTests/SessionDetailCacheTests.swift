import Core
import Transport
import Foundation
import Testing
@testable import MacFeature

private let base = Date(timeIntervalSince1970: 1_000)

private func summary(_ id: String, phase: TurnPhase = .thinking, at offset: TimeInterval = 0) -> SessionSummary {
    let date = base.addingTimeInterval(offset)
    return SessionSummary(
        id: SessionID(id), agent: .codex, title: id, lifecycle: .running, phase: phase,
        startedAt: base, updatedAt: date, lastActivityAt: date
    )
}

private func item(_ session: String, _ id: String, at offset: TimeInterval) -> TimelineItem {
    TimelineItem(
        id: TimelineItemID(id), sessionID: SessionID(session), turnID: TurnID("t1"),
        occurredAt: base.addingTimeInterval(offset),
        payload: .message(MessageTimelinePayload(role: .assistant, text: id))
    )
}

private func detail(_ id: String, items: Int = 1) -> SessionDetail {
    SessionDetail(
        summary: summary(id),
        timeline: (0..<items).map { item(id, "\(id)-\($0)", at: Double($0)) }
    )
}

private func event(_ session: String, _ id: String, at offset: TimeInterval, discard: Bool = false) -> AgentIngressEvent {
    AgentIngressEvent(
        eventID: EventID(id), sessionID: SessionID(session), turnID: TurnID("t1"), agent: .codex,
        occurredAt: base.addingTimeInterval(offset), phase: .responding,
        timelineItem: discard ? nil : item(session, id, at: offset),
        disposition: discard ? .discard : nil
    )
}

@Test func detailCacheEvictsTheLeastRecentBeyondCapacityButNeverThePin() {
    var cache = SessionDetailCache(capacity: 2)
    cache.insert(detail("a"))
    cache.insert(detail("b"))
    #expect(cache.residentIDs.map(\.rawValue) == ["a", "b"])

    // A touch makes `a` the most recent; the next insert evicts `b`.
    #expect(cache.touch(SessionID("a")) != nil)
    cache.insert(detail("c"))
    #expect(cache.residentIDs.map(\.rawValue) == ["a", "c"])
    #expect(cache.statistics == .init(hits: 1, misses: 0, evictions: 1))

    // The pinned lead survives even as the least recent entry.
    cache.pin(SessionID("a"))
    cache.insert(detail("d"))
    #expect(cache.residentIDs.map(\.rawValue) == ["a", "d"])
    #expect(cache.peek(SessionID("c")) == nil)
    #expect(cache.touch(SessionID("c")) == nil)
    #expect(cache.statistics.misses == 1)

    // Peeking is not a use: recency is unchanged.
    _ = cache.peek(SessionID("a"))
    #expect(cache.residentIDs.map(\.rawValue) == ["a", "d"])
}

@Test func detailCacheReplacesAndPatchesOnlyResidentSessions() {
    var cache = SessionDetailCache(capacity: 4)
    cache.insert(detail("a"))

    let replacedResident = cache.replaceIfPresent(detail("a", items: 3))
    #expect(replacedResident)
    #expect(cache.peek(SessionID("a"))?.timeline.count == 3)
    let replacedAbsent = cache.replaceIfPresent(detail("b", items: 3))
    #expect(!replacedAbsent)
    #expect(cache.count == 1)

    let patchedResident = cache.patchSummary(SessionID("a")) { $0.withHiddenInNotch(true) }
    #expect(patchedResident)
    #expect(cache.peek(SessionID("a"))?.summary.hiddenInNotch == true)
    #expect(cache.peek(SessionID("a"))?.timeline.count == 3)
    let patchedAbsent = cache.patchSummary(SessionID("b")) { $0 }
    #expect(!patchedAbsent)
}

@Test func detailCacheFoldsEventsEvictsDiscardsAndAbsentSessionsAndTakesTheDatabaseSummary() {
    var cache = SessionDetailCache(capacity: 4)
    cache.insert(detail("a"))
    cache.insert(detail("b"))
    cache.insert(detail("gone"))
    cache.pin(SessionID("gone"))

    let freshA = summary("a", phase: .responding, at: 20)
    let changed = cache.fold(
        events: [
            event("a", "a-new", at: 10),
            // Not resident: nothing to fold, nothing pulled in.
            event("c", "c-new", at: 11),
            event("b", "b-discard", at: 12, discard: true),
            // After the discard, the session's events belong to a copy the
            // database must provide; they do not resurrect the evicted one.
            event("b", "b-after", at: 13),
        ],
        summaries: [SessionID("a"): freshA]
    )

    #expect(changed == [SessionID("a"), SessionID("b"), SessionID("gone")])
    #expect(cache.residentIDs.map(\.rawValue) == ["a"])
    let a = cache.peek(SessionID("a"))
    #expect(a?.timeline.map(\.id.rawValue) == ["a-0", "a-new"])
    #expect(a?.summary == freshA)
    #expect(a?.turns.first?.lastAssistantMessage == "a-new")
    // The pin does not keep a session the database no longer lists.
    #expect(cache.peek(SessionID("gone")) == nil)
    #expect(cache.statistics.evictions == 2)

    // No events, same summaries: nothing changes.
    #expect(cache.fold(events: [], summaries: [SessionID("a"): freshA]).isEmpty)
}
