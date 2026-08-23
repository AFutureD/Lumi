import Transport
import Foundation
import Testing
@testable import Core

/// The mirror-side primitives added for index-first sync, asserted against
/// both repository implementations.
private let base = Date(timeIntervalSince1970: 1_000)

private func item(_ id: String, session: String, at offset: TimeInterval, text: String = "x") -> TimelineItem {
    TimelineItem(
        id: TimelineItemID(id), sessionID: SessionID(session),
        occurredAt: base.addingTimeInterval(offset),
        payload: .message(MessageTimelinePayload(role: .assistant, text: text))
    )
}

private func detail(_ session: String, phase: TurnPhase = .thinking, turns: [TurnSummary] = [], items: [TimelineItem]) -> SessionDetail {
    SessionDetail(
        summary: SessionSummary(
            id: SessionID(session), agent: .codex, title: session,
            lifecycle: .running, phase: phase,
            startedAt: base, updatedAt: base.addingTimeInterval(items.map(\.occurredAt.timeIntervalSince1970).max().map { $0 - base.timeIntervalSince1970 } ?? 0),
            lastActivityAt: base
        ),
        turns: turns,
        timeline: items
    )
}

private func temporaryRepository() throws -> (SQLiteSessionRepository, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let repository = try SQLiteSessionRepository(path: directory.appendingPathComponent("sessions.sqlite3").path)
    return (repository, directory)
}

private func assertSyncPrimitives(_ repository: any SessionRepository) async throws {
    try await repository.replaceSession(detail("a", items: [item("a1", session: "a", at: 1), item("a2", session: "a", at: 5)]))
    try await repository.replaceSession(detail("b", items: []))

    // sessionIndex: raw counts and high-water marks, latest activity first.
    let index = try await repository.sessionIndex(limit: 10)
    #expect(index.map(\.summary.id) == [SessionID("a"), SessionID("b")] || index.map(\.summary.id) == [SessionID("b"), SessionID("a")])
    let a = try #require(index.first { $0.summary.id == SessionID("a") })
    let b = try #require(index.first { $0.summary.id == SessionID("b") })
    #expect(a.timelineItemCount == 2)
    #expect(a.lastItemAt == base.addingTimeInterval(5))
    #expect(b.timelineItemCount == 0)
    #expect(b.lastItemAt == nil)

    // updateSummary: only a retained session, only the summary.
    let idle = detail("a", phase: .idle, items: []).summary
    try await repository.updateSummary(idle)
    try await repository.updateSummary(detail("ghost", items: []).summary)
    #expect(try await repository.sessionDetail(id: SessionID("a"), cursor: nil, limit: 10)?.summary.phase == .idle)
    #expect(try await repository.sessionDetail(id: SessionID("a"), cursor: nil, limit: 10)?.timeline.count == 2)
    #expect(try await repository.sessionDetail(id: SessionID("ghost"), cursor: nil, limit: 10) == nil)

    // mergeSession: adds and upserts rows, never deletes, clears a tombstone.
    _ = try await repository.deleteSession(id: SessionID("b"))
    try await repository.mergeSession(detail("b", items: [item("b1", session: "b", at: 2)]))
    #expect(try await repository.sessionDetail(id: SessionID("b"), cursor: nil, limit: 10)?.timeline.map(\.id) == [TimelineItemID("b1")])
    try await repository.mergeSession(detail(
        "a",
        turns: [TurnSummary(id: TurnID("t1"), sessionID: SessionID("a"), phase: .thinking, startedAt: base)],
        items: [item("a2", session: "a", at: 5, text: "replaced"), item("a3", session: "a", at: 9)]
    ))
    let merged = try #require(try await repository.sessionDetail(id: SessionID("a"), cursor: nil, limit: 10))
    #expect(merged.timeline.map(\.id) == [TimelineItemID("a1"), TimelineItemID("a2"), TimelineItemID("a3")])
    if case let .message(message)? = merged.timeline[1].payload as TimelinePayload? {
        #expect(message.text == "replaced")
    } else {
        Issue.record("expected a message payload")
    }
    #expect(merged.turns.map(\.id) == [TurnID("t1")])
    // An older copy of a row never regresses the newer one.
    try await repository.mergeSession(detail("a", items: [item("a3", session: "a", at: 8, text: "stale")]))
    let kept = try #require(try await repository.sessionDetail(id: SessionID("a"), cursor: nil, limit: 10))
    #expect(kept.timeline.last?.occurredAt == base.addingTimeInterval(9))

    // timelineSince: rows from `since` on, paged.
    let tail = try #require(try await repository.timelineSince(id: SessionID("a"), since: base.addingTimeInterval(5), cursor: nil, limit: 1))
    #expect(tail.timeline.map(\.id) == [TimelineItemID("a2")])
    #expect(tail.turns.map(\.id) == [TurnID("t1")])
    let next = try #require(tail.nextCursor)
    let rest = try #require(try await repository.timelineSince(id: SessionID("a"), since: base.addingTimeInterval(5), cursor: next, limit: 1))
    #expect(rest.timeline.map(\.id) == [TimelineItemID("a3")])
    #expect(rest.nextCursor == nil)
    #expect(try await repository.timelineSince(id: SessionID("ghost"), since: base, cursor: nil, limit: 10) == nil)

    // deleteSession reports what actually existed.
    #expect(try await repository.deleteSession(id: SessionID("ghost")).isEmpty)
    #expect(try await repository.deleteSession(id: SessionID("a")) == [SessionID("a")])
}

@Test func inMemoryRepositorySyncPrimitives() async throws {
    try await assertSyncPrimitives(InMemorySessionRepository())
}

@Test func grdbRepositorySyncPrimitives() async throws {
    let (repository, directory) = try temporaryRepository()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await assertSyncPrimitives(repository)
}
