import Foundation
import Testing
import AgentStatusTransport
import NookApp
@testable import AgentStatusMacFeature

@Test func hookMergePreservesExistingIntegrationAndIsIdempotent() throws {
    let existing = Data("""
    {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"vibe-island-helper"}]}]},"custom":true}
    """.utf8)
    let once = try CodexHookInstaller.merging(existing, helperCommand: "'/tmp/agent-status-helper'")
    let twice = try CodexHookInstaller.merging(once, helperCommand: "'/tmp/agent-status-helper'")
    let root = try #require(JSONSerialization.jsonObject(with: twice) as? [String: Any])
    let hooks = try #require(root["hooks"] as? [String: Any])
    let stop = try #require(hooks["Stop"] as? [[String: Any]])

    #expect(root["custom"] as? Bool == true)
    #expect(stop.count == 2)
    #expect(Set(hooks.keys).isSuperset(of: CodexHookInstaller.supportedEvents))

    let removed = try CodexHookInstaller.removingAgentStatus(from: twice)
    let removedRoot = try #require(JSONSerialization.jsonObject(with: removed) as? [String: Any])
    let removedHooks = try #require(removedRoot["hooks"] as? [String: Any])
    let removedStop = try #require(removedHooks["Stop"] as? [[String: Any]])
    #expect(removedRoot["custom"] as? Bool == true)
    #expect(removedStop.count == 1)
    #expect(!String(data: removed, encoding: .utf8)!.contains("agent-status-helper"))
}

@Test @MainActor
func nookAppearanceIsPinnedAndAdjustmentDefaultsAreFilled() {
    let original = NookAppearancePreferences(
        chromePalette: .light,
        surfaceStyle: .translucent,
        presentation: .floating,
        hapticFeedbackEnabled: true,
        keepNookOpen: true
    )

    let normalized = AgentStatusNookController.normalizedAppearancePreferences(original)

    #expect(normalized.chromePalette == .dark)
    #expect(normalized.presentation == .notch)
    #expect(normalized.surfaceStyle == .translucent)
    #expect(normalized.hapticFeedbackEnabled)
    #expect(normalized.keepNookOpen)
    #expect(normalized.compactNotchWidth == AgentStatusNookAdjustmentDefaults.compactWidth)
    #expect(normalized.expandedNotchWidth == AgentStatusNookAdjustmentDefaults.expandedWidth)
    #expect(
        normalized.expandAnimationDuration
            == AgentStatusNookAdjustmentDefaults.expandAnimationDuration
    )
}

@Test @MainActor
func nookAppearancePreservesCustomAdjustments() {
    var original = NookAppearancePreferences.default
    original.compactNotchWidth = 96
    original.expandedNotchWidth = 608
    original.expandAnimationDuration = 0.72

    let normalized = AgentStatusNookController.normalizedAppearancePreferences(original)

    #expect(normalized.compactNotchWidth == 96)
    #expect(normalized.expandedNotchWidth == 608)
    #expect(normalized.expandAnimationDuration == 0.72)
}

@Test @MainActor
func pairingContentUsesVerticalLayoutBelowItsHorizontalMinimum() {
    #expect(PairingViewController.usesCompactContentLayout(availableWidth: 673))
    #expect(!PairingViewController.usesCompactContentLayout(availableWidth: 674))
}

@Test func nookSnapshotShowsTheCurrentTurnUserMessageAndExcludesCompletedSessions() {
    let active = nookSummary(id: "active", lifecycle: .running, phase: .executing, updatedAt: 20)
    let completed = nookSummary(id: "completed", lifecycle: .completed, phase: .idle, updatedAt: 10)
    let firstTurn = TurnID("turn-1")
    let currentTurn = TurnID("turn-2")
    let detail = SessionDetail(summary: active, timeline: [
        TimelineItem(
            id: TimelineItemID("first"),
            sessionID: active.id,
            turnID: firstTurn,
            occurredAt: Date(timeIntervalSince1970: 1),
            payload: .message(MessageTimelinePayload(role: .user, text: "Older request"))
        ),
        TimelineItem(
            id: TimelineItemID("current"),
            sessionID: active.id,
            turnID: currentTurn,
            occurredAt: Date(timeIntervalSince1970: 2),
            payload: .message(MessageTimelinePayload(role: .user, text: "Current request"))
        ),
    ])

    let visible = AgentStatusNookSnapshot.visibleSummaries(from: [active, completed])
    let rows = AgentStatusNookSnapshot.make(summaries: visible, details: [detail])

    #expect(rows.map(\.id) == [active.id])
    #expect(rows.first?.currentUserMessage == "Current request")
    #expect(rows.first?.statusText == "Running · Executing")

    let eligible = [active] + (1...4).map {
        nookSummary(id: "extra-\($0)", lifecycle: .running, phase: .executing, updatedAt: TimeInterval(20 - $0))
    }
    #expect(AgentStatusNookSnapshot.eligibleSummaries(from: eligible).count == 5)
    #expect(AgentStatusNookSnapshot.visibleSummaries(from: eligible).count == 4)
}

@Test func nookActivityDiffIncludesACompletedTransition() {
    let running = AgentStatusNookSession(
        id: SessionID("session"),
        title: "Session",
        lifecycle: .running,
        phase: .responding,
        currentUserMessage: "Build it",
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    let completed = AgentStatusNookSession(
        id: running.id,
        title: running.title,
        lifecycle: .completed,
        phase: .idle,
        currentUserMessage: running.currentUserMessage,
        updatedAt: Date(timeIntervalSince1970: 2)
    )

    #expect(AgentStatusNookActivityDiff.changedSessions(
        previous: [running],
        current: [completed]
    ) == [completed])
}

@Test func nookActivityDiffOnlyQueuesApprovalWhenEnteringOrLeavingThatPhase() {
    let waiting = AgentStatusNookSession(
        id: SessionID("session"),
        title: "Session",
        lifecycle: .waitingForInput,
        phase: .waitingForApproval,
        currentUserMessage: "Approve it",
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    let unchanged = AgentStatusNookSession(
        id: waiting.id,
        title: waiting.title,
        lifecycle: waiting.lifecycle,
        phase: waiting.phase,
        currentUserMessage: waiting.currentUserMessage,
        updatedAt: Date(timeIntervalSince1970: 2)
    )
    let idle = AgentStatusNookSession(
        id: waiting.id,
        title: waiting.title,
        lifecycle: waiting.lifecycle,
        phase: .idle,
        currentUserMessage: waiting.currentUserMessage,
        updatedAt: Date(timeIntervalSince1970: 3)
    )

    #expect(AgentStatusNookActivityDiff.changedSessions(
        previous: [waiting],
        current: [unchanged]
    ).isEmpty)
    #expect(AgentStatusNookActivityDiff.changedSessions(
        previous: [waiting],
        current: [idle]
    ) == [idle])
}

@Test func relayRecoveryResendsAnUnchangedSnapshot() {
    #expect(RelayPublishDecision.shouldSchedule(
        previousRevision: 10,
        currentRevision: 10,
        wasDaemonAvailable: true,
        isDaemonAvailable: false
    ))
    #expect(!RelayPublishDecision.shouldSchedule(
        previousRevision: 10,
        currentRevision: 10,
        wasDaemonAvailable: true,
        isDaemonAvailable: true
    ))
    #expect(RelayPublishDecision.shouldSendSnapshot(wasUnavailable: true, previous: [], current: []))
    #expect(!RelayPublishDecision.shouldSendSnapshot(wasUnavailable: false, previous: [], current: []))

    let diagnosticSummary = nookSummary(
        id: "diagnostic",
        lifecycle: .running,
        phase: .thinking,
        updatedAt: 10
    )
    let previous = SessionDetail(summary: diagnosticSummary, timeline: [])
    let current = SessionDetail(summary: diagnosticSummary, timeline: [
        TimelineItem(
            id: TimelineItemID("usage"),
            sessionID: diagnosticSummary.id,
            occurredAt: diagnosticSummary.updatedAt,
            payload: .usageMetrics(UsageMetricsTimelinePayload(
                total: TokenUsage(totalTokens: 100)
            ))
        ),
    ])
    #expect(RelayPublishDecision.shouldSendSnapshot(
        wasUnavailable: false,
        previous: [previous],
        current: [current]
    ))
}

@Test func sessionListPresentationShowsTitleAgentAndStatus() {
    let date = Date(timeIntervalSince1970: 100)
    let summary = SessionSummary(
        id: SessionID("claude-session"),
        agent: .unknown("claude"),
        title: "Rewrite Session\n  module",
        lifecycle: .running,
        phase: .thinking,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date
    )

    let presentation = SessionListRowPresentation(session: summary)

    #expect(presentation.title == "Rewrite Session module")
    #expect(presentation.agent == "Claude")
    #expect(presentation.status == "Running · Thinking")

    let codexSubagent = SessionListRowPresentation(session: SessionSummary(
        id: SessionID("codex-subagent"),
        agent: .codexSubagent,
        title: "Hypatia · docs_review",
        lifecycle: .running,
        phase: .executing,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date
    ))
    #expect(codexSubagent.agent == "Codex Subagent")
}

@Test func sessionListHierarchyNestsSubagentsAndKeepsOrphansReachable() throws {
    let main = hierarchySummary(id: "main")
    let child = hierarchySummary(id: "child", parentID: "main", depth: 1)
    let grandchild = hierarchySummary(id: "grandchild", parentID: "child", depth: 2)
    let orphan = hierarchySummary(id: "orphan", parentID: "missing", depth: 1)
    let cycleA = hierarchySummary(id: "cycle-a", parentID: "cycle-b", depth: 1)
    let cycleB = hierarchySummary(id: "cycle-b", parentID: "cycle-a", depth: 1)

    let hierarchy = SessionListHierarchy.build(from: [
        child, main, orphan, grandchild, cycleA, cycleB,
    ])

    #expect(hierarchy.roots.map { $0.summary.id.rawValue } == [
        "main", "orphan", "cycle-a", "cycle-b",
    ])
    let mainNode = try #require(hierarchy.nodesByID[main.id])
    let childNode = try #require(hierarchy.nodesByID[child.id])
    #expect(mainNode.children.map { $0.summary.id } == [child.id])
    #expect(childNode.children.map { $0.summary.id } == [grandchild.id])
}

@Test func sessionDetailPresentationShowsEveryInformationModule() throws {
    let date = Date(timeIntervalSince1970: 100)
    let summary = SessionSummary(
        id: SessionID("complete-detail"),
        agent: .codex,
        title: "Complete detail",
        workspace: "/tmp/agent-status",
        lifecycle: .running,
        phase: .responding,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date,
        needsAttention: true,
        lineage: SessionLineage(
            threadSource: "subagent",
            parentSessionID: SessionID("parent-session"),
            subagentDepth: 1,
            agentNickname: "Hypatia",
            agentPath: "/root/docs_review",
            subagentKind: "thread_spawn"
        )
    )
    let turnID = TurnID("turn-1")
    let timeline = [
        TimelineItem(
            id: TimelineItemID("model"),
            sessionID: summary.id,
            turnID: turnID,
            occurredAt: date,
            payload: .modelConfiguration(ModelConfigurationTimelinePayload(
                source: "session_meta",
                model: "gpt-5.6",
                provider: "openai",
                contextWindow: 200_000,
                reasoningEffort: "high",
                clientVersion: "1.0",
                settings: .object(["sandbox": .string("workspace-write")])
            ))
        ),
        TimelineItem(
            id: TimelineItemID("usage"),
            sessionID: summary.id,
            turnID: turnID,
            occurredAt: date.addingTimeInterval(1),
            payload: .usageMetrics(UsageMetricsTimelinePayload(
                last: TokenUsage(inputTokens: 30, outputTokens: 20, totalTokens: 50),
                total: TokenUsage(inputTokens: 70, outputTokens: 30, totalTokens: 100),
                modelContextWindow: 200_000,
                rateLimits: .object(["remaining": .string("90%")])
            ))
        ),
        TimelineItem(
            id: TimelineItemID("context"),
            sessionID: summary.id,
            turnID: turnID,
            occurredAt: date.addingTimeInterval(2),
            payload: .internalContext(InternalContextTimelinePayload(
                kind: "turn_context",
                content: .object(["secret": .string("retained-value")])
            ))
        ),
        TimelineItem(
            id: TimelineItemID("message"),
            sessionID: summary.id,
            turnID: turnID,
            occurredAt: date.addingTimeInterval(3),
            payload: .message(MessageTimelinePayload(role: .user, text: "Show all information"))
        ),
    ]

    let modules = SessionDetailPresentationBuilder.modules(for: SessionDetail(
        summary: summary,
        timeline: timeline
    ))

    #expect(modules.map(\.kind) == [.overview, .modelConfiguration, .usage, .internalContext, .activity])
    let overview = try #require(modules.first { $0.kind == .overview })
    let model = try #require(modules.first { $0.kind == .modelConfiguration })
    let usage = try #require(modules.first { $0.kind == .usage })
    let context = try #require(modules.first { $0.kind == .internalContext })
    let activity = try #require(modules.first { $0.kind == .activity })

    #expect(overview.rows.contains { $0.title == "Session ID" && $0.body == "complete-detail" })
    #expect(overview.rows.contains { $0.title == "Parent Session ID" && $0.body == "parent-session" })
    #expect(overview.rows.contains { $0.title == "Agent Nickname" && $0.body == "Hypatia" })
    #expect(model.rows.first?.body.contains("Model: gpt-5.6") == true)
    #expect(model.rows.first?.body.contains("workspace-write") == true)
    #expect(usage.rows.first?.body.contains("Total tokens: 100") == true)
    #expect(usage.rows.first?.body.contains("90%") == true)
    #expect(context.rows.first?.body.contains("retained-value") == true)
    #expect(activity.rows.first?.body.contains("Show all information") == true)
    #expect(activity.rows.first?.body.contains("Turn ID: turn-1") == true)
}

private func nookSummary(
    id: String,
    lifecycle: SessionLifecycle,
    phase: TurnPhase,
    updatedAt: TimeInterval
) -> SessionSummary {
    let date = Date(timeIntervalSince1970: updatedAt)
    return SessionSummary(
        id: SessionID(id),
        agent: .codex,
        title: id.capitalized,
        lifecycle: lifecycle,
        phase: phase,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date
    )
}

private func hierarchySummary(
    id: String,
    parentID: String? = nil,
    depth: Int? = nil
) -> SessionSummary {
    let date = Date(timeIntervalSince1970: 100)
    let lineage = parentID.map {
        SessionLineage(
            threadSource: "subagent",
            parentSessionID: SessionID($0),
            subagentDepth: depth,
            agentPath: "/root/\(id)",
            subagentKind: "thread_spawn"
        )
    }
    return SessionSummary(
        id: SessionID(id),
        agent: lineage == nil ? .codex : .codexSubagent,
        title: id,
        lifecycle: .running,
        phase: .thinking,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date,
        lineage: lineage
    )
}
