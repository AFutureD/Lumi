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
