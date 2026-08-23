import Transport

/// A platform-neutral color role shared by every Lumi client.
///
/// Design system §4.1 (Session lifecycle tiers plus a failure state):
/// - `blue`   — Running: the agent is working (thinking / responding / tool /
///   subagent / compacting all collapse here).
/// - `orange` — Waiting for approval: a human decision is blocking the turn
///   (permission or elicitation).
/// - `green`  — Turn finished but not looked at yet (`needsReview`): the
///   session to open next.
/// - `gray`   — Completed / Idle and already reviewed. Adapters park a
///   normally finished turn in `waitingForInput · idle` (the CLI sits at its
///   prompt); that reads as this ladder, not as a waiting one — see
///   `displayLifecycle`.
/// - `red`    — Failed / Aborted.
public enum SessionStatusTone: Equatable, Sendable {
    case blue
    case orange
    case green
    case gray
    case red

    public static func resolve(
        lifecycle: SessionLifecycle,
        phase: TurnPhase,
        needsReview: Bool
    ) -> SessionStatusTone {
        switch lifecycle {
        case .starting, .running, .compacting:
            .blue
        case .waitingForInput:
            phase == .idle ? (needsReview ? .green : .gray) : .orange
        case .completed:
            needsReview ? .green : .gray
        case .failed, .interrupted:
            .red
        }
    }

    /// Lifecycle as displayed. `waitingForInput · idle` (turn finished, CLI
    /// back at its prompt) is presented as the Completed tier so status text
    /// matches the tone on every surface.
    public static func displayLifecycle(
        lifecycle: SessionLifecycle,
        phase: TurnPhase
    ) -> SessionLifecycle {
        lifecycle == .waitingForInput && phase == .idle ? .completed : lifecycle
    }
}

public extension SessionSummary {
    var statusTone: SessionStatusTone {
        SessionStatusTone.resolve(lifecycle: lifecycle, phase: phase, needsReview: needsReview)
    }

    var displayLifecycle: SessionLifecycle {
        SessionStatusTone.displayLifecycle(lifecycle: lifecycle, phase: phase)
    }

    /// The summary after the human opened the session: review flag cleared
    /// and the attention bit re-derived from the resulting tone.
    var reviewed: SessionSummary {
        let tone = SessionStatusTone.resolve(lifecycle: lifecycle, phase: phase, needsReview: false)
        let attention = switch tone {
        case .orange, .green, .red: true
        case .blue, .gray: false
        }
        return withReviewState(needsAttention: attention, needsReview: false)
    }
}
