import Transport
import Foundation
import Testing
@testable import Core

private let base = Date(timeIntervalSince1970: 1_000)

private func summary(_ id: String, phase: TurnPhase = .thinking, needsReview: Bool = false) -> SessionSummary {
    SessionSummary(
        id: SessionID(id), agent: .codex, title: id,
        lifecycle: .running, phase: phase,
        startedAt: base, updatedAt: base, lastActivityAt: base,
        needsReview: needsReview
    )
}

private func entry(_ id: String, count: Int, lastAt: TimeInterval?, phase: TurnPhase = .thinking) -> SessionIndexEntry {
    SessionIndexEntry(
        summary: summary(id, phase: phase),
        timelineItemCount: count,
        lastItemAt: lastAt.map { base.addingTimeInterval($0) }
    )
}

@Test func reconcilePlanPrunesFetchesPatchesAndUpdatesInfo() {
    let plan = SyncReconcilePlan.make(
        local: [
            entry("same", count: 3, lastAt: 30),
            entry("info", count: 3, lastAt: 30, phase: .thinking),
            entry("grew", count: 3, lastAt: 30),
            entry("empty", count: 0, lastAt: nil),
            entry("shrunk", count: 5, lastAt: 50),
            entry("jumped", count: 1, lastAt: 10),
            entry("gone", count: 1, lastAt: 10),
        ],
        remote: [
            entry("same", count: 3, lastAt: 30),
            entry("info", count: 3, lastAt: 30, phase: .idle),
            entry("grew", count: 5, lastAt: 50),
            entry("empty", count: 2, lastAt: 20),
            entry("shrunk", count: 4, lastAt: 40),
            entry("jumped", count: 500, lastAt: 5_000),
            entry("new", count: 1, lastAt: 10),
        ]
    )
    #expect(plan.prune == [SessionID("gone")])
    #expect(plan.fetchFull == [SessionID("empty"), SessionID("shrunk"), SessionID("jumped"), SessionID("new")])
    #expect(plan.fetchSince.map(\.sessionID) == [SessionID("grew")])
    // since = local lastItemAt − 60 s overlap
    #expect(plan.fetchSince.first?.since == base.addingTimeInterval(30 - 60))
    #expect(plan.infoOnly.map(\.id) == [SessionID("info")])
    #expect(plan.infoOnly.first?.phase == .idle)
}

@Test func reconcilePlanIsEmptyWhenCachesMatch() {
    let entries = [entry("a", count: 2, lastAt: 20), entry("b", count: 0, lastAt: nil)]
    let plan = SyncReconcilePlan.make(local: entries, remote: entries)
    #expect(plan.isEmpty)
}

@Test func reconcilePlanTreatsAMovedLastItemAsGrowth() {
    // Same count but the newest row moved (late-arriving row replaced the
    // tail): patch from the local high-water mark, don't replace.
    let plan = SyncReconcilePlan.make(
        local: [entry("moved", count: 3, lastAt: 30)],
        remote: [entry("moved", count: 3, lastAt: 31)]
    )
    #expect(plan.fetchFull.isEmpty)
    #expect(plan.fetchSince.map(\.sessionID) == [SessionID("moved")])
}

@Test func reconcilePlanHonoursTheLargeDeltaThreshold() {
    let small = SyncReconcilePlan.make(
        local: [entry("s", count: 10, lastAt: 10)],
        remote: [entry("s", count: 15, lastAt: 15)],
        largeDeltaThreshold: 4
    )
    #expect(small.fetchFull == [SessionID("s")])
    let patch = SyncReconcilePlan.make(
        local: [entry("s", count: 10, lastAt: 10)],
        remote: [entry("s", count: 14, lastAt: 14)],
        largeDeltaThreshold: 4
    )
    #expect(patch.fetchSince.map(\.sessionID) == [SessionID("s")])
}

@Test func lazyMirrorMovesByMarksNotByItsOwnRows() {
    // The mirror holds a tail of `held` (3 of the daemon's 5 rows at the
    // time of its mark); `stale` was rebuilt on the daemon; `summaryOnly`
    // and `quiet` were never opened; `gone` left the daemon.
    let plan = SyncReconcilePlan.lazy(
        local: [
            entry("held", count: 3, lastAt: 30),
            entry("stale", count: 3, lastAt: 30),
            entry("summaryOnly", count: 0, lastAt: nil, phase: .thinking),
            entry("quiet", count: 0, lastAt: nil),
            entry("gone", count: 1, lastAt: 10),
        ],
        remote: [
            entry("held", count: 7, lastAt: 70),
            entry("stale", count: 4, lastAt: 50),
            entry("summaryOnly", count: 400, lastAt: 4_000, phase: .idle),
            entry("quiet", count: 400, lastAt: 4_000),
            entry("new", count: 900, lastAt: 9_000),
        ],
        marks: [
            SessionID("held"): SessionSyncMark(timelineItemCount: 5, lastItemAt: base.addingTimeInterval(50), oldest: TimelineCursor(occurredAt: base.addingTimeInterval(30), id: TimelineItemID("x")), hasOlder: true),
            SessionID("stale"): SessionSyncMark(timelineItemCount: 5, lastItemAt: base.addingTimeInterval(50), oldest: TimelineCursor(occurredAt: base.addingTimeInterval(30), id: TimelineItemID("y")), hasOlder: false),
        ]
    )
    // Held and grown: patched from the mark's high-water mark (minus overlap),
    // whatever the mirror's own row count says.
    #expect(plan.fetchSince.map(\.sessionID) == [SessionID("held")])
    #expect(plan.fetchSince.first?.since == base.addingTimeInterval(50 - 60))
    // The newest row moved back: the daemon's copy changed under the mark.
    #expect(plan.rebuild == [SessionID("stale")])
    #expect(plan.fetchFull.isEmpty)
    // Everything else moves by summary alone, however far its timeline is.
    #expect(plan.infoOnly.map(\.id) == [SessionID("summaryOnly")])
    #expect(plan.insert.map(\.id) == [SessionID("new")])
    #expect(plan.prune == [SessionID("gone")])
    #expect(!plan.isEmpty)
}

@Test func heldSessionsAreClassifiedAgainstTheirMark() {
    let loaded = TimelineCursor(occurredAt: base, id: TimelineItemID("a"))
    let mark = SessionSyncMark(timelineItemCount: 5, lastItemAt: base.addingTimeInterval(50), oldest: loaded, hasOlder: true)
    #expect(SyncReconcilePlan.classify(remote: entry("s", count: 5, lastAt: 50), mark: mark) == .upToDate)
    #expect(SyncReconcilePlan.classify(remote: entry("s", count: 6, lastAt: 60), mark: mark) == .fetchSince(base.addingTimeInterval(50 - 60)))
    // Same newest row, different count: rows changed in place.
    #expect(SyncReconcilePlan.classify(remote: entry("s", count: 4, lastAt: 50), mark: mark) == .rebuild)
    #expect(SyncReconcilePlan.classify(remote: entry("s", count: 2, lastAt: 20), mark: mark) == .rebuild)
    #expect(SyncReconcilePlan.classify(remote: entry("s", count: 0, lastAt: nil), mark: mark) == .rebuild)
    // Live events moved the copy on and forgot the count: only the newest row counts.
    var moved = mark
    moved.timelineItemCount = nil
    #expect(SyncReconcilePlan.classify(remote: entry("s", count: 9, lastAt: 50), mark: moved) == .upToDate)
    // Nothing known yet about the daemon's rows: everything since the beginning.
    #expect(SyncReconcilePlan.classify(remote: entry("s", count: 3, lastAt: 30), mark: SessionSyncMark(oldest: loaded)) == .fetchSince(.distantPast))
}
