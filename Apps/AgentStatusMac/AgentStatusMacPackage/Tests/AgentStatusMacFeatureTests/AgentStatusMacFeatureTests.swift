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
    let rows = AgentStatusNookSnapshot.make(
        summaries: visible,
        currentUserMessages: [active.id: AgentStatusNookSnapshot.currentTurnUserMessage(in: detail)!]
    )

    #expect(rows.map(\.id) == [active.id])
    #expect(rows.first?.currentUserMessage == "Current request")
    #expect(rows.first?.statusText == "Running · Executing")

    let eligible = [active] + (1...4).map {
        nookSummary(id: "extra-\($0)", lifecycle: .running, phase: .executing, updatedAt: TimeInterval(20 - $0))
    }
    #expect(AgentStatusNookSnapshot.eligibleSummaries(from: eligible).count == 5)
    #expect(AgentStatusNookSnapshot.visibleSummaries(from: eligible).count == 4)
}

@Test @MainActor
func selectedSessionDetailMergesLiveEventsWithoutAFullReload() {
    let sessionID = SessionID("selected")
    let initialDate = Date(timeIntervalSince1970: 10)
    let initialSummary = SessionSummary(
        id: sessionID,
        agent: .codex,
        title: "Selected",
        lifecycle: .running,
        phase: .thinking,
        startedAt: initialDate,
        updatedAt: initialDate,
        lastActivityAt: initialDate
    )
    let original = TimelineItem(
        id: TimelineItemID("original"),
        sessionID: sessionID,
        occurredAt: initialDate,
        payload: .message(MessageTimelinePayload(role: .assistant, text: "Old"))
    )
    let detail = SessionDetail(summary: initialSummary, timeline: [original])
    let appended = TimelineItem(
        id: TimelineItemID("appended"),
        sessionID: sessionID,
        occurredAt: initialDate.addingTimeInterval(1),
        payload: .message(MessageTimelinePayload(role: .user, text: "New"))
    )
    let replacement = TimelineItem(
        id: original.id,
        sessionID: sessionID,
        occurredAt: initialDate.addingTimeInterval(2),
        payload: .message(MessageTimelinePayload(role: .assistant, text: "Updated"))
    )
    let updatedDate = initialDate.addingTimeInterval(2)
    let updatedSummary = SessionSummary(
        id: sessionID,
        agent: .codex,
        title: "Selected",
        lifecycle: .running,
        phase: .responding,
        startedAt: initialDate,
        updatedAt: updatedDate,
        lastActivityAt: updatedDate
    )
    let merged = MacSessionStore.merging(
        detail,
        summary: updatedSummary,
        events: [
            AgentIngressEvent(
                eventID: EventID("append"),
                sessionID: sessionID,
                agent: .codex,
                occurredAt: appended.occurredAt,
                timelineItem: appended
            ),
            AgentIngressEvent(
                eventID: EventID("replace"),
                sessionID: sessionID,
                agent: .codex,
                occurredAt: replacement.occurredAt,
                timelineItem: replacement
            ),
        ]
    )

    #expect(merged.summary == updatedSummary)
    #expect(merged.timeline.map(\.id) == [appended.id, original.id])
    #expect(merged.timeline.last?.payload == replacement.payload)
}

@Test func nookActivityDiffIncludesACompletedTransition() {
    let running = AgentStatusNookSession(
        id: SessionID("session"),
        title: "Session",
        lifecycle: .running,
        phase: .responding,
        currentUserMessage: "Build it"
    )
    let completed = AgentStatusNookSession(
        id: running.id,
        title: running.title,
        lifecycle: .completed,
        phase: .idle,
        currentUserMessage: running.currentUserMessage
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
        currentUserMessage: "Approve it"
    )
    let unchanged = AgentStatusNookSession(
        id: waiting.id,
        title: waiting.title,
        lifecycle: waiting.lifecycle,
        phase: waiting.phase,
        currentUserMessage: waiting.currentUserMessage
    )
    let idle = AgentStatusNookSession(
        id: waiting.id,
        title: waiting.title,
        lifecycle: waiting.lifecycle,
        phase: .idle,
        currentUserMessage: waiting.currentUserMessage
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

@Test func nookActivityDiffIgnoresRoutineRunningStateChurn() {
    let running = AgentStatusNookSession(
        id: SessionID("session"),
        title: "Session",
        lifecycle: .running,
        phase: .executing,
        currentUserMessage: "Build it"
    )
    let waiting = AgentStatusNookSession(
        id: running.id,
        title: running.title,
        lifecycle: .waitingForInput,
        phase: .idle,
        currentUserMessage: running.currentUserMessage
    )

    #expect(AgentStatusNookActivityDiff.changedSessions(
        previous: [running],
        current: [waiting]
    ).isEmpty)
}

@Test func nookActivityDiffDoesNotQueueSessionsWithoutABaseline() {
    let running = AgentStatusNookSession(
        id: SessionID("existing-session"),
        title: "Existing Session",
        lifecycle: .running,
        phase: .executing,
        currentUserMessage: "Build it"
    )

    #expect(AgentStatusNookActivityDiff.changedSessions(
        previous: [],
        current: [running]
    ).isEmpty)
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

@Test func sessionListHierarchyReusesNodesAndReloadsOnlyVisibleChanges() throws {
    let original = SessionListHierarchy.build(from: [
        hierarchySummary(id: "main"),
        hierarchySummary(id: "child", parentID: "main", depth: 1),
    ])
    let timestampOnly = SessionListHierarchy.build(from: [
        hierarchySummary(id: "main", updatedAt: 200),
        hierarchySummary(id: "child", parentID: "main", depth: 1, updatedAt: 200),
    ])

    #expect(original.hasSameStructure(as: timestampOnly))
    #expect(original.updateSummaries(from: timestampOnly.roots.flatMap(flatten)) == [])
    let originalMain = try #require(original.nodesByID[SessionID("main")])
    #expect(originalMain.summary.updatedAt == Date(timeIntervalSince1970: 200))

    let phaseChange = SessionListHierarchy.build(from: [
        hierarchySummary(id: "main", phase: .executing, updatedAt: 201),
        hierarchySummary(id: "child", parentID: "main", depth: 1, updatedAt: 201),
    ])
    #expect(original.hasSameStructure(as: phaseChange))
    #expect(original.updateSummaries(from: phaseChange.roots.flatMap(flatten)) == [SessionID("main")])

    let reordered = SessionListHierarchy.build(from: [
        hierarchySummary(id: "child", parentID: "main", depth: 1),
        hierarchySummary(id: "main"),
    ])
    #expect(original.hasSameStructure(as: reordered))

    let detached = SessionListHierarchy.build(from: [
        hierarchySummary(id: "main"),
        hierarchySummary(id: "child"),
    ])
    #expect(!original.hasSameStructure(as: detached))
}

@Test func sessionPagePresentationBuildsSummaryAndCategorizesActivity() throws {
    let date = Date(timeIntervalSince1970: 100)
    let summary = SessionSummary(
        id: SessionID("session-page"),
        agent: .codex,
        title: "Session page",
        workspace: "/tmp/agent-status",
        lifecycle: .running,
        phase: .responding,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date,
        needsAttention: true,
        lineage: SessionLineage(
            threadSource: "subagent",
            parentSessionID: SessionID("parent"),
            subagentDepth: 1,
            agentNickname: "Hypatia"
        )
    )
    let timeline: [TimelineItem] = [
        TimelineItem(
            id: TimelineItemID("model"),
            sessionID: summary.id,
            occurredAt: date,
            payload: .modelConfiguration(ModelConfigurationTimelinePayload(
                source: "turn_context",
                model: "gpt-5.6",
                provider: "openai",
                contextWindow: 200_000,
                reasoningEffort: "high",
                clientVersion: "1.0",
                settings: .object(["must-not-render": .string("raw-json")])
            ))
        ),
        TimelineItem(
            id: TimelineItemID("usage"),
            sessionID: summary.id,
            occurredAt: date.addingTimeInterval(1),
            payload: .usageMetrics(UsageMetricsTimelinePayload(
                total: TokenUsage(
                    inputTokens: 70,
                    cachedInputTokens: 20,
                    cacheWriteInputTokens: 10,
                    outputTokens: 30,
                    reasoningOutputTokens: 5,
                    totalTokens: 100
                ),
                modelContextWindow: 200_000
            ))
        ),
        activityItem(
            id: "system",
            sessionID: summary.id,
            date: date.addingTimeInterval(2),
            payload: .internalContext(InternalContextTimelinePayload(
                kind: "base_instructions",
                content: .object(["text": .string("System instruction")])
            ))
        ),
        activityItem(
            id: "context",
            sessionID: summary.id,
            date: date.addingTimeInterval(3),
            payload: .internalContext(InternalContextTimelinePayload(
                kind: "turn_context",
                content: .object(["type": .string("context")])
            ))
        ),
        activityItem(
            id: "reasoning",
            sessionID: summary.id,
            date: date.addingTimeInterval(4),
            payload: .internalContext(InternalContextTimelinePayload(
                kind: "reasoning",
                content: .string("Reasoning")
            ))
        ),
        activityItem(
            id: "user",
            sessionID: summary.id,
            date: date.addingTimeInterval(5),
            payload: .message(MessageTimelinePayload(role: .user, text: "User message"))
        ),
        activityItem(
            id: "assistant",
            sessionID: summary.id,
            date: date.addingTimeInterval(6),
            payload: .message(MessageTimelinePayload(role: .assistant, text: "Assistant message"))
        ),
        activityItem(
            id: "tool",
            sessionID: summary.id,
            date: date.addingTimeInterval(7),
            payload: .tool(ToolTimelinePayload(name: "Build", status: .succeeded))
        ),
        activityItem(
            id: "subagent",
            sessionID: summary.id,
            date: date.addingTimeInterval(8),
            payload: .subagent(SubagentTimelinePayload(name: "Reviewer", status: .completed))
        ),
        activityItem(
            id: "other",
            sessionID: summary.id,
            date: date.addingTimeInterval(9),
            payload: .error(ErrorTimelinePayload(
                title: "Failure",
                message: "Something failed",
                recoverable: true
            ))
        ),
    ]

    let presentation = SessionPagePresentationBuilder.presentation(
        for: SessionDetail(summary: summary, timeline: timeline)
    )

    #expect(presentation.summarySections.map(\.kind) == [
        .overview,
        .lineage,
        .modelConfiguration,
        .usage,
    ])
    let model = try #require(
        presentation.summarySections.first { $0.kind == .modelConfiguration }
    )
    #expect(model.fields.map(\.label) == [
        "Source",
        "Model",
        "Provider",
        "Context Window",
        "Reasoning Effort",
        "Client Version",
    ])
    #expect(!model.fields.contains { $0.value.contains("raw-json") })
    #expect(model.fields.first { $0.label == "Context Window" }?.value == "200,000")
    let usage = try #require(presentation.summarySections.first { $0.kind == .usage })
    #expect(usage.fields.first { $0.label == "Total Tokens" }?.value == "100")
    #expect(presentation.activities.map(\.category) == [
        .system,
        .context,
        .assistantReasoning,
        .user,
        .assistant,
        .tool,
        .subagent,
        .other,
    ])
    #expect(presentation.activities.first { $0.category == .user }?.content == "User message")
    let userActivity = try #require(presentation.activities.first { $0.category == .user })
    #expect(
        SessionPagePresentationBuilder.rawData(for: userActivity.rawItem)
            .contains("User message")
    )
}

@Test func sessionActivityCategoriesMapToTimelineLanes() {
    #expect([
        SessionActivityCategory.system,
        .context,
        .user,
    ].map(\.lane) == [.input, .input, .input])
    #expect([
        SessionActivityCategory.tool,
        .subagent,
        .other,
    ].map(\.lane) == [.tools, .tools, .tools])
    #expect([
        SessionActivityCategory.assistantReasoning,
        .assistant,
    ].map(\.lane) == [.model, .model])
}

@Test func sessionPageRendererBuildsOnItsOwnActor() async throws {
    let date = Date(timeIntervalSince1970: 100)
    let summary = SessionSummary(
        id: SessionID("actor-render"),
        agent: .codex,
        title: "Actor render",
        lifecycle: .running,
        phase: .thinking,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date
    )
    let renderer = SessionPagePresentationRenderer()
    let presentation = await renderer.presentation(
        for: SessionDetail(summary: summary, timeline: [])
    )

    #expect(presentation?.summarySections.map(\.kind) == [
        .overview,
        .modelConfiguration,
        .usage,
    ])
}


private func activityItem(
    id: String,
    sessionID: SessionID,
    date: Date,
    payload: TimelinePayload
) -> TimelineItem {
    TimelineItem(
        id: TimelineItemID(id),
        sessionID: sessionID,
        occurredAt: date,
        payload: payload
    )
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
    depth: Int? = nil,
    phase: TurnPhase = .thinking,
    updatedAt: TimeInterval = 100
) -> SessionSummary {
    let date = Date(timeIntervalSince1970: updatedAt)
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
        phase: phase,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date,
        lineage: lineage
    )
}

private func flatten(_ node: SessionListNode) -> [SessionSummary] {
    [node.summary] + node.children.flatMap(flatten)
}
