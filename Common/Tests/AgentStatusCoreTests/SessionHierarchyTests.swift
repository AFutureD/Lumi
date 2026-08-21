import AgentStatusTransport
import Foundation
import Testing
@testable import AgentStatusCore

private func summary(
    _ id: String,
    parent: String? = nil,
    lifecycle: SessionLifecycle = .running,
    phase: TurnPhase = .executing,
    at seconds: TimeInterval = 100
) -> SessionSummary {
    let date = Date(timeIntervalSince1970: seconds)
    return SessionSummary(
        id: SessionID(id), agent: parent == nil ? .codex : .codexSubagent, title: id,
        lifecycle: lifecycle, phase: phase, startedAt: date, updatedAt: date, lastActivityAt: date,
        lineage: parent.map { SessionLineage(parentSessionID: SessionID($0), subagentDepth: 1) }
    )
}

@Test func hierarchyFoldsEveryDescendantUnderTheTopListedAncestor() {
    let groups = SessionHierarchy.groups([
        summary("root", at: 50),
        summary("child", parent: "root", lifecycle: .completed, phase: .idle, at: 40),
        summary("grandchild", parent: "child", at: 45),
        summary("other", at: 30),
    ])
    #expect(groups.map(\.parent.id.rawValue) == ["root", "other"])
    // Grandchildren are subagents of the same group, in strip order
    // (running before done), not dropped because their parent is a child.
    #expect(groups[0].descendants.map(\.id.rawValue) == ["grandchild", "child"])
    #expect(groups[1].descendants.isEmpty)
}

@Test func hierarchyPromotesOrphansAndBreaksLineageLoops() {
    let groups = SessionHierarchy.groups([
        summary("orphan", parent: "missing"),
        summary("a", parent: "b"),
        summary("b", parent: "a"),
    ])
    // No listed parent: a row of its own. A loop: each is its own top level
    // rather than both vanishing.
    #expect(groups.map(\.parent.id.rawValue) == ["orphan", "a", "b"])
    #expect(groups.allSatisfy { $0.descendants.isEmpty })
}
