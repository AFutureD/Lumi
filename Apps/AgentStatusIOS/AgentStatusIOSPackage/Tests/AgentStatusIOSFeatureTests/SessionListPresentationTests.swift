import AgentStatusTransport
import Foundation
import Testing
@testable import AgentStatusIOSFeature

private let now = Date(timeIntervalSince1970: 1_000_000)

private func session(
    _ id: String,
    title: String = "Session",
    lifecycle: SessionLifecycle = .running,
    phase: TurnPhase = .executing,
    needsReview: Bool = false,
    parent: String? = nil,
    activityAgo: TimeInterval = 0,
    startedAgo: TimeInterval = 60,
    timeline: [TimelinePayload] = [.message(.init(role: .user, text: "hello"))]
) -> SessionDetail {
    let sessionID = SessionID(id)
    let started = now.addingTimeInterval(-startedAgo)
    let last = now.addingTimeInterval(-activityAgo)
    return SessionDetail(
        summary: SessionSummary(
            id: sessionID, agent: .codex, title: title, workspace: "/Users/me/dev/app",
            lifecycle: lifecycle, phase: phase, startedAt: started, updatedAt: last, lastActivityAt: last,
            needsReview: needsReview,
            lineage: parent.map { SessionLineage(parentSessionID: SessionID($0), subagentDepth: 1) },
            firstTurnAt: started
        ),
        turns: [TurnSummary(id: TurnID("\(id)-turn"), sessionID: sessionID, phase: phase, startedAt: started, endedAt: lifecycle.isLive ? nil : last)],
        timeline: timeline.enumerated().map { index, payload in
            TimelineItem(id: TimelineItemID("\(id)-\(index)"), sessionID: sessionID, occurredAt: started.addingTimeInterval(Double(index)), payload: payload)
        }
    )
}

private func channel(_ host: String, sessions: [SessionDetail], online: Bool = true) -> MacChannelState {
    MacChannelState(
        hostID: HostID(host), displayName: host, pairedAt: now, isConnected: online, isHostOnline: online,
        hasCompleteSync: online, sessions: sessions, lastSyncAt: nil, lastError: nil
    )
}

@Test func subagentsFoldIntoTheirParentRow() {
    let parent = session("p", title: "Parent")
    let child = session("c", title: "worker", parent: "p", startedAgo: 125)
    let items = SessionListPresentation.items(from: [channel("Mac", sessions: [parent, child])])
    #expect(items.count == 1)
    #expect(items[0].subagents.map(\.name) == ["worker"])
    #expect(items[0].subagents[0].durationText(now: now) == "2m")
}

@Test func orphanChildIsARowOfItsOwn() {
    let child = session("c", title: "worker", parent: "missing")
    let items = SessionListPresentation.items(from: [channel("Mac", sessions: [child])])
    #expect(items.map(\.title) == ["worker"])
}

@Test func rowsMergeAcrossMacsNewestFirst() {
    let a = channel("A", sessions: [session("a1", title: "old", activityAgo: 300)])
    let b = channel("B", sessions: [session("b1", title: "new", activityAgo: 10)])
    let items = SessionListPresentation.items(from: [a, b])
    #expect(items.map(\.title) == ["new", "old"])
    #expect(items.map(\.deviceName) == ["B", "A"])
    #expect(items[0].timeText(now: now) == "10s")
}

@Test func offlineMacContributesNoRows() {
    let items = SessionListPresentation.items(from: [channel("A", sessions: [session("a1")], online: false)])
    #expect(items.isEmpty)
}

@Test func completedSessionsHideTheLatestLine() {
    let done = session("d", lifecycle: .completed, phase: .idle, timeline: [
        .message(.init(role: .user, text: "hi")),
        .message(.init(role: .assistant, text: "bye")),
    ])
    let running = session("r", timeline: [
        .message(.init(role: .user, text: "hi")),
        .tool(.init(name: "shell", summary: "swift test", status: .started, toolUseID: "t")),
    ])
    let items = SessionListPresentation.items(from: [channel("Mac", sessions: [done, running])])
    let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.sessionID.rawValue, $0) })
    #expect(byID["d"]?.latest == nil)
    #expect(byID["r"]?.latest?.label == "TOOL")
    #expect(byID["r"]?.latest?.text == "shell · swift test")
}

@Test func deviceFilterAndSearch() {
    let a = channel("A", sessions: [session("a1", title: "Refactor transport")])
    let b = channel("B", sessions: [session("b1", title: "Rebuild cache"), session("b2", title: "Other")])
    let items = SessionListPresentation.items(from: [a, b])
    #expect(SessionListPresentation.filter(items, excludingHosts: [HostID("A")], query: "").map(\.title).sorted() == ["Other", "Rebuild cache"])
    #expect(SessionListPresentation.filter(items, excludingHosts: [], query: "transport").map(\.title) == ["Refactor transport"])
    let macs = SessionListPresentation.macOptions(channels: [a, b], items: items, deselected: [HostID("A")])
    #expect(macs.map(\.name) == ["A", "B"])
    #expect(macs.map(\.isSelected) == [false, true])
    #expect(macs.map(\.count) == [1, 2])
}

@Test func statusGroupsFoldTheFiveTonesIntoThree() {
    let sessions = [
        session("r"),
        session("w", lifecycle: .waitingForInput, phase: .waitingForApproval),
        session("g", lifecycle: .completed, phase: .idle, needsReview: true),
        session("c", lifecycle: .completed, phase: .idle),
        session("f", lifecycle: .failed, phase: .idle),
    ]
    let items = SessionListPresentation.items(from: [channel("Mac", sessions: sessions)])
    let statuses = SessionListPresentation.statusOptions(items: items, deselected: [.completed])
    #expect(statuses.map(\.name) == ["Running", "Waiting", "Completed"])
    #expect(statuses.map(\.count) == [1, 1, 3])
    #expect(statuses.map(\.isSelected) == [true, true, false])
    #expect(SessionListPresentation.filter(items, excludingHosts: [], excludingStatuses: [.completed], query: "").map(\.sessionID.rawValue).sorted() == ["r", "w"])
}

@Test func aFilterGroupNeverEmpties() {
    let all = SessionStatusGroup.allCases
    var deselected: Set<SessionStatusGroup> = []
    deselected = SessionListPresentation.toggling(.running, in: deselected, all: all)
    deselected = SessionListPresentation.toggling(.waiting, in: deselected, all: all)
    #expect(deselected == [.running, .waiting])
    // The last one stays.
    deselected = SessionListPresentation.toggling(.completed, in: deselected, all: all)
    #expect(deselected == [.running, .waiting])
    deselected = SessionListPresentation.toggling(.running, in: deselected, all: all)
    #expect(deselected == [.waiting])
}

@Test func subagentSummaryListsOnlyNonZeroBuckets() {
    let parent = session("p", title: "Parent")
    let kids = [
        session("a", title: "a", parent: "p"),
        session("b", title: "b", parent: "p"),
        session("c", title: "c", lifecycle: .completed, phase: .idle, parent: "p"),
    ]
    let items = SessionListPresentation.items(from: [channel("Mac", sessions: [parent] + kids)])
    #expect(items[0].subagentSummary == "3 subagents · 2 running · 1 done")
    #expect(items[0].subagents.map(\.name) == ["a", "b", "c"])
    let single = SessionListPresentation.items(from: [channel("Mac", sessions: [parent, kids[0]])])
    #expect(single[0].subagentSummary == "1 subagent · 1 running")
}
