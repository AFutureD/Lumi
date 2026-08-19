import AgentStatusTransport
import Foundation
import Testing
@testable import AgentStatusCore

@Test func sessionStatusToneFollowsTheSharedCrossPlatformPalette() {
    #expect(summary(lifecycle: .starting, phase: .idle).statusTone == .blue)
    #expect(summary(lifecycle: .running, phase: .thinking).statusTone == .blue)
    #expect(summary(lifecycle: .waitingForInput, phase: .idle).statusTone == .green)
    #expect(summary(lifecycle: .waitingForInput, phase: .waitingForApproval).statusTone == .green)
    #expect(summary(lifecycle: .completed, phase: .idle).statusTone == .gray)
    #expect(summary(lifecycle: .failed, phase: .idle).statusTone == .red)
    #expect(summary(lifecycle: .interrupted, phase: .idle).statusTone == .red)
    #expect(summary(lifecycle: .unknown("future"), phase: .unknown("future")).statusTone == .gray)
}

private func summary(lifecycle: SessionLifecycle, phase: TurnPhase) -> SessionSummary {
    let date = Date(timeIntervalSince1970: 0)
    return SessionSummary(
        id: SessionID("tone"),
        agent: .codex,
        title: "Tone",
        lifecycle: lifecycle,
        phase: phase,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date
    )
}
