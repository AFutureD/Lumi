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

@Test func lazyMirrorFetchesOnlyWhatItAlreadyHolds() {
    let plan = SyncReconcilePlan.make(
        local: [
            entry("held", count: 3, lastAt: 30),
            entry("summaryOnly", count: 0, lastAt: nil, phase: .thinking),
            entry("quiet", count: 0, lastAt: nil),
            entry("gone", count: 1, lastAt: 10),
        ],
        remote: [
            entry("held", count: 5, lastAt: 50),
            entry("summaryOnly", count: 400, lastAt: 4_000, phase: .idle),
            entry("quiet", count: 400, lastAt: 4_000),
            entry("new", count: 900, lastAt: 9_000),
        ],
        materialized: [SessionID("held")]
    )
    // The one session whose timeline the mirror holds is patched as usual.
    #expect(plan.fetchSince.map(\.sessionID) == [SessionID("held")])
    #expect(plan.fetchFull.isEmpty)
    // Everything else moves by summary alone, however far its timeline is.
    #expect(plan.infoOnly.map(\.id) == [SessionID("summaryOnly")])
    #expect(plan.insert.map(\.id) == [SessionID("new")])
    #expect(plan.prune == [SessionID("gone")])
    #expect(!plan.isEmpty)
}
