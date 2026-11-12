import Core
import Transport
import Foundation
import Testing
@testable import Adapters

// A Claude session's subagents end with its process and leave no record of
// their own; the session's end is what closes them.

private let base = Date(timeIntervalSince1970: 1_000)

private func summary(
    _ id: String,
    parent: String? = nil,
    agent: AgentKind? = nil,
    lifecycle: SessionLifecycle = .running,
    phase: TurnPhase = .thinking,
    at seconds: TimeInterval = 0
) -> SessionSummary {
    let date = base.addingTimeInterval(seconds)
    return SessionSummary(
        id: SessionID(id),
        agent: agent ?? (parent == nil ? .claude : .claudeSubagent),
        title: id,
        lifecycle: lifecycle,
        phase: phase,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date,
        lineage: parent.map { SessionLineage(parentSessionID: SessionID($0), subagentDepth: 1) }
    )
}

private typealias Markers = ClaudeSubagentIdentity.ProcessMarkers

@Test func aSubagentIsLeftBehindWhenItsSessionEnded() {
    let owner = summary("main", lifecycle: .completed, phase: .idle, at: 100)
    let ended = Markers(startedAt: base, startSource: "startup", endedAt: base.addingTimeInterval(100), endReason: "other")
    func closedAt(_ subagent: SessionSummary, _ markers: Markers = ended, owner: SessionSummary = owner) -> Date? {
        ClaudeSubagentIdentity.leftBehindAt(subagent, owner: owner, markers: markers)
    }
    // Still at work when the process went away: closed at the session's end…
    #expect(closedAt(summary("main:agent:busy", parent: "main", at: 90)) == base.addingTimeInterval(100))
    #expect(closedAt(summary("main:agent:ask", parent: "main", lifecycle: .waitingForInput, phase: .waitingForApproval, at: 80))
        == base.addingTimeInterval(100))
    // …or at its own last record, when the dying process still wrote one.
    #expect(closedAt(summary("main:agent:late", parent: "main", at: 101)) == base.addingTimeInterval(101))

    // Closed by its own record already, or never a Claude subagent.
    #expect(closedAt(summary("main:agent:done", parent: "main", lifecycle: .completed, phase: .idle, at: 70)) == nil)
    #expect(closedAt(summary("main:agent:cut", parent: "main", lifecycle: .interrupted, phase: .idle, at: 60)) == nil)
    #expect(closedAt(summary("codex-child", parent: "main", agent: .codexSubagent, at: 90)) == nil)

    // `/clear` ends the session, not the process.
    let cleared = Markers(startedAt: base, startSource: "startup", endedAt: base.addingTimeInterval(100), endReason: "clear")
    #expect(closedAt(summary("main:agent:busy", parent: "main", at: 90), cleared) == nil)
    // A session that is not ended is not judged by an old end marker.
    let resumed = summary("main", lifecycle: .running, phase: .thinking, at: 300)
    let restarted = Markers(startedAt: base.addingTimeInterval(200), startSource: "resume", endedAt: base.addingTimeInterval(100), endReason: "other")
    #expect(closedAt(summary("main:agent:new", parent: "main", at: 250), restarted, owner: resumed) == nil)
}

@Test func aSubagentIsLeftBehindWhenItsSessionStartedAgain() {
    // The process was killed without reporting its end: the session stays
    // parked and the subagent Running — until the session starts again.
    let parked = summary("main", lifecycle: .waitingForInput, phase: .idle, at: 50)
    let stale = summary("main:agent:stale", parent: "main", at: 90)
    func closedAt(_ source: String?, startedAfter seconds: TimeInterval) -> Date? {
        ClaudeSubagentIdentity.leftBehindAt(
            stale, owner: parked,
            markers: Markers(startedAt: base.addingTimeInterval(seconds), startSource: source)
        )
    }
    #expect(closedAt("resume", startedAfter: 200) == base.addingTimeInterval(200))
    #expect(closedAt("startup", startedAfter: 200) == base.addingTimeInterval(200))
    // The same process: a compaction restart closes nothing.
    #expect(closedAt("compact", startedAfter: 200) == nil)
    // Started before the subagent's last record: that subagent is this process's.
    #expect(closedAt("resume", startedAfter: 10) == nil)
    // No markers at all: nothing is known, nothing is closed.
    #expect(ClaudeSubagentIdentity.leftBehindAt(stale, owner: parked, markers: Markers()) == nil)
}

@Test func theProcessOwnerIsTheMainSessionAtTheTopOfTheLineage() {
    let sessions = [
        summary("main"),
        summary("main:agent:a", parent: "main"),
        summary("main:agent:a:agent:b", parent: "main:agent:a"),
        summary("orphan", parent: "gone"),
        summary("codex-main", agent: .codex),
        summary("codex-child", parent: "codex-main", agent: .codexSubagent),
        summary("loop-a", parent: "loop-b"),
        summary("loop-b", parent: "loop-a"),
    ]
    let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    func owner(_ id: String) -> String? {
        ClaudeSubagentIdentity.processOwner(of: byID[SessionID(id)]!, in: byID)?.id.rawValue
    }
    #expect(owner("main:agent:a") == "main")
    #expect(owner("main:agent:a:agent:b") == "main")
    #expect(owner("orphan") == nil)
    #expect(owner("codex-child") == nil)
    #expect(owner("loop-a") == nil)
}
