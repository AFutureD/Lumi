import DaemonRuntime
import Transport
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 100_000)

private func event(
    _ id: String,
    session: String = "s1",
    payload: TimelinePayload,
    age: TimeInterval = 0
) -> AgentIngressEvent {
    let sessionID = SessionID(session)
    return AgentIngressEvent(
        eventID: EventID(id),
        sessionID: sessionID,
        agent: .claude,
        occurredAt: now.addingTimeInterval(-age),
        timelineItem: TimelineItem(
            id: TimelineItemID("item-\(id)"),
            sessionID: sessionID,
            occurredAt: now.addingTimeInterval(-age),
            payload: payload
        )
    )
}

private func summary(
    _ id: String,
    title: String = "Session title",
    lifecycle: SessionLifecycle = .running,
    firstTurnAt: Date? = now,
    parent: String? = nil
) -> SessionSummary {
    SessionSummary(
        id: SessionID(id), agent: .claude, title: title,
        lifecycle: lifecycle, phase: .idle,
        startedAt: now, updatedAt: now, lastActivityAt: now,
        lineage: parent.map { SessionLineage(parentSessionID: SessionID($0)) },
        firstTurnAt: firstTurnAt
    )
}

@Test func onlyTurnBoundariesAndFailuresAreNotable() {
    let events = [
        event("end", payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed, message: "Done."))),
        event("fail", payload: .turnEnd(TurnEndTimelinePayload(outcome: .failed, message: "Broke."))),
        event("abort", payload: .turnEnd(TurnEndTimelinePayload(outcome: .aborted))),
        event("error", payload: .error(ErrorTimelinePayload(title: "Error", message: "context limit", recoverable: false))),
        // `.user` is L3 but marks the human's own message: never an alert.
        event("user", payload: .message(MessageTimelinePayload(role: .user, text: "hi"))),
        event("reply", payload: .message(MessageTimelinePayload(role: .assistant, text: "hello"))),
    ]
    let notable = PushNotificationPolicy.notableEvents(events, now: now)
    #expect(notable.map(\.tag) == [.turnEnd, .turnFailed, .aborted, .turnFailed])
}

@Test func longTitlesShrinkToTheRelayBoundInUTF16Units() {
    let long = String(repeating: "标", count: 200)
    let notable = PushNotificationPolicy.notableEvents(
        [event("e", payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed)))],
        now: now
    )
    let candidates = PushNotificationPolicy.candidates(
        notable: notable,
        summaries: [SessionID("s1"): summary("s1", title: long)],
        retainedParents: [], lastPushAt: [:], now: now
    )
    let title = candidates[0].title
    #expect(title.utf16.count <= 120)
    #expect(title.hasSuffix("…"))

    // Emoji count as two UTF-16 units: the bound follows the Relay's counting.
    let emoji = String(repeating: "🚀", count: 100)
    #expect(PushNotificationPolicy.boundedTitle(emoji).utf16.count <= 120)
    #expect(PushNotificationPolicy.boundedTitle("short") == "short")
}

@Test func subtitlesUseTheStatusCapsuleVocabulary() {
    #expect(PushNotificationPolicy.subtitle(for: .turnEnd) == "Completed")
    #expect(PushNotificationPolicy.subtitle(for: .turnFailed) == "Failed")
    #expect(PushNotificationPolicy.subtitle(for: .aborted) == "Interrupted")
}

@Test func staleEventsNeverAlert() {
    let events = [
        event("old", payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed)), age: PushNotificationPolicy.freshnessWindow + 1),
        event("fresh", payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed))),
    ]
    #expect(PushNotificationPolicy.notableEvents(events, now: now).map(\.sessionID) == [SessionID("s1")])
    #expect(PushNotificationPolicy.notableEvents([events[0]], now: now).isEmpty)
}

@Test func oneCandidatePerSessionLatestEventWins() {
    let notable = PushNotificationPolicy.notableEvents([
        event("first", payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed, message: "First")), age: 10),
        event("second", payload: .turnEnd(TurnEndTimelinePayload(outcome: .failed, message: "Second")), age: 5),
        event("other", session: "s2", payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed, message: "Other")), age: 1),
    ], now: now)
    let candidates = PushNotificationPolicy.candidates(
        notable: notable,
        summaries: [SessionID("s1"): summary("s1"), SessionID("s2"): summary("s2", title: "Other title")],
        retainedParents: [],
        lastPushAt: [:],
        now: now
    )
    #expect(candidates.map(\.subtitle) == ["Failed", "Completed"])
    #expect(candidates.map(\.title) == ["Session title", "Other title"])
}

@Test func subagentsWithRetainedParentsStayQuietOrphansAlert() {
    let notable = PushNotificationPolicy.notableEvents([
        event("sub", session: "child", payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed))),
        event("orphan", session: "lone", payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed))),
    ], now: now)
    let summaries = [
        SessionID("child"): summary("child", parent: "parent"),
        SessionID("lone"): summary("lone", parent: "gone"),
    ]
    let candidates = PushNotificationPolicy.candidates(
        notable: notable, summaries: summaries,
        retainedParents: [SessionID("parent")], lastPushAt: [:], now: now
    )
    #expect(candidates.map(\.sessionID) == [SessionID("lone")])
}

@Test func provisionalAndUnknownSessionsStayQuiet() {
    let notable = PushNotificationPolicy.notableEvents([
        event("prov", session: "prov", payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed))),
        event("ghost", session: "ghost", payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed))),
    ], now: now)
    let candidates = PushNotificationPolicy.candidates(
        notable: notable,
        summaries: [SessionID("prov"): summary("prov", lifecycle: .starting, firstTurnAt: nil)],
        retainedParents: [], lastPushAt: [:], now: now
    )
    #expect(candidates.isEmpty)
}

@Test func cooldownHoldsRepeatAlertsForASession() {
    let notable = PushNotificationPolicy.notableEvents(
        [event("e", payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed)))],
        now: now
    )
    let summaries = [SessionID("s1"): summary("s1")]
    let inCooldown = PushNotificationPolicy.candidates(
        notable: notable, summaries: summaries, retainedParents: [],
        lastPushAt: [SessionID("s1"): now.addingTimeInterval(-1)], now: now
    )
    #expect(inCooldown.isEmpty)
    let after = PushNotificationPolicy.candidates(
        notable: notable, summaries: summaries, retainedParents: [],
        lastPushAt: [SessionID("s1"): now.addingTimeInterval(-PushNotificationPolicy.cooldown)], now: now
    )
    #expect(after.count == 1)
}

@Test func collapseIDsStayHeaderSafe() {
    #expect(PushNotificationPolicy.collapseID(for: SessionID("abc-123.DEF:x_y")) == "abc-123.DEF:x_y")
    let long = PushNotificationPolicy.collapseID(for: SessionID(String(repeating: "a", count: 80)))
    #expect(long.count == 32)
    let unsafe = PushNotificationPolicy.collapseID(for: SessionID("路径/含 空格"))
    #expect(unsafe.count == 32)
    #expect(unsafe.allSatisfy { $0.isHexDigit })
}
