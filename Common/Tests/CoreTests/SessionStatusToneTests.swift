import Transport
import Foundation
import Testing
@testable import Core

@Test func sessionStatusToneFollowsTheSharedCrossPlatformPalette() {
    #expect(summary(lifecycle: .starting, phase: .idle).statusTone == .blue)
    #expect(summary(lifecycle: .running, phase: .thinking).statusTone == .blue)
    // A finished turn parks in `waitingForInput · idle`: reviewed reads as
    // the Completed tier, unreviewed keeps the green "open me next" tier.
    #expect(summary(lifecycle: .waitingForInput, phase: .idle).statusTone == .gray)
    #expect(summary(lifecycle: .waitingForInput, phase: .idle, needsReview: true).statusTone == .green)
    #expect(summary(lifecycle: .waitingForInput, phase: .idle).displayLifecycle == .completed)
    // A human decision blocking the turn is orange, viewed or not.
    #expect(summary(lifecycle: .waitingForInput, phase: .waitingForApproval).statusTone == .orange)
    #expect(summary(lifecycle: .waitingForInput, phase: .waitingForApproval, needsReview: true).statusTone == .orange)
    #expect(summary(lifecycle: .waitingForInput, phase: .waitingForApproval).displayLifecycle == .waitingForInput)
    #expect(summary(lifecycle: .completed, phase: .idle).statusTone == .gray)
    #expect(summary(lifecycle: .completed, phase: .idle, needsReview: true).statusTone == .green)
    #expect(summary(lifecycle: .failed, phase: .idle).statusTone == .red)
    #expect(summary(lifecycle: .failed, phase: .idle, needsReview: true).statusTone == .red)
    #expect(summary(lifecycle: .interrupted, phase: .idle).statusTone == .red)
}

@Test func reviewingClearsTheFlagAndTheDerivedAttentionBit() {
    let unreviewed = summary(lifecycle: .waitingForInput, phase: .idle, needsReview: true, needsAttention: true)
    let reviewed = unreviewed.reviewed
    #expect(reviewed.needsReview == false)
    #expect(reviewed.needsAttention == false)
    #expect(reviewed.statusTone == .gray)

    // An approval prompt keeps demanding attention after a review.
    let blocked = summary(lifecycle: .waitingForInput, phase: .waitingForApproval, needsReview: true, needsAttention: true)
    #expect(blocked.reviewed.needsAttention == true)
    #expect(blocked.reviewed.statusTone == .orange)
}

private func summary(
    lifecycle: SessionLifecycle,
    phase: TurnPhase,
    needsReview: Bool = false,
    needsAttention: Bool = false
) -> SessionSummary {
    let date = Date(timeIntervalSince1970: 0)
    return SessionSummary(
        id: SessionID("tone"),
        agent: .codex,
        title: "Tone",
        lifecycle: lifecycle,
        phase: phase,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date,
        needsAttention: needsAttention,
        needsReview: needsReview
    )
}
