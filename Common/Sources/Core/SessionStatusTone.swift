import Transport

/// A platform-neutral color role shared by every Lumi client.
///
/// Design system §4.1 (Session lifecycle tiers plus a failure state):
/// - `blue`   — Running: the agent is working (thinking / responding / tool /
///   subagent / compacting all collapse here) — or its turn is over and a
///   subagent it spawned is still at work (`hasWorkingSubagents`): the
///   request is not finished until they are.
/// - `orange` — Waiting for approval: a human decision is blocking the turn
///   (permission or elicitation).
/// - `green`  — Turn finished but not looked at yet (`needsReview`): the
///   session to open next. Main sessions only — a subagent never carries
///   the flag (`SessionReduction`).
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

    /// The one place a session's tier is decided. `hasWorkingSubagents` has
    /// no default on purpose: a caller that cannot say whether subagents are
    /// still at work must not be able to resolve a tier.
    ///
    /// Working subagents lift only a session parked at its prompt
    /// (`waitingForInput · idle`). An ended session (`completed`) stays
    /// ended — its process is gone and took its subagents with it — and
    /// approval, failure and interruption keep their own tiers.
    public static func resolve(
        lifecycle: SessionLifecycle,
        phase: TurnPhase,
        needsReview: Bool,
        hasWorkingSubagents: Bool
    ) -> SessionStatusTone {
        switch lifecycle {
        case .starting, .running, .compacting:
            .blue
        case .waitingForInput:
            if phase != .idle {
                .orange
            } else if isKeptRunningBySubagents(lifecycle: lifecycle, phase: phase, hasWorkingSubagents: hasWorkingSubagents) {
                .blue
            } else {
                needsReview ? .green : .gray
            }
        case .completed:
            needsReview ? .green : .gray
        case .failed, .interrupted:
            .red
        }
    }

    /// The one state working subagents change: a session parked at its
    /// prompt (`waitingForInput · idle`) whose subagents are still at work.
    /// It reads Running, shows no finished turn, and gives no completion
    /// notice until they stop. `hasWorkingSubagents` alone is not this
    /// state — a session in the middle of its own turn, a failed one or an
    /// ended one can carry the mark too, and each keeps its own behaviour.
    /// Everything that treats the parked case specially asks here.
    public static func isKeptRunningBySubagents(
        lifecycle: SessionLifecycle,
        phase: TurnPhase,
        hasWorkingSubagents: Bool
    ) -> Bool {
        hasWorkingSubagents && lifecycle == .waitingForInput && phase == .idle
    }

    /// Lifecycle as displayed. `waitingForInput · idle` (turn finished, CLI
    /// back at its prompt) is presented as the Completed tier — or as
    /// Running while its subagents are still at work — so status text
    /// matches the tone on every surface.
    public static func displayLifecycle(
        lifecycle: SessionLifecycle,
        phase: TurnPhase,
        hasWorkingSubagents: Bool
    ) -> SessionLifecycle {
        guard lifecycle == .waitingForInput, phase == .idle else { return lifecycle }
        return isKeptRunningBySubagents(lifecycle: lifecycle, phase: phase, hasWorkingSubagents: hasWorkingSubagents)
            ? .running
            : .completed
    }

    /// `Running · Responding` — display lifecycle · phase. A parked session
    /// its subagents keep running reads `Running` alone: its own phase is
    /// idle, and the subagents' phases are theirs to show.
    public static func statusText(
        lifecycle: SessionLifecycle,
        phase: TurnPhase,
        hasWorkingSubagents: Bool
    ) -> String {
        let displayed = displayLifecycle(
            lifecycle: lifecycle,
            phase: phase,
            hasWorkingSubagents: hasWorkingSubagents
        )
        if isKeptRunningBySubagents(lifecycle: lifecycle, phase: phase, hasWorkingSubagents: hasWorkingSubagents) {
            return displayed.displayName
        }
        return "\(displayed.displayName) · \(phase.displayName)"
    }

    /// Whether the session's own agent is at work or held up on a human
    /// decision — the state that keeps a parked parent Running. `starting`
    /// is left out: a session that never asserted more than its start has
    /// done no work to wait for.
    public static func isAtWork(lifecycle: SessionLifecycle, phase: TurnPhase) -> Bool {
        switch lifecycle {
        case .running, .compacting: true
        case .waitingForInput: phase != .idle
        case .starting, .completed, .failed, .interrupted: false
        }
    }
}

public extension SessionSummary {
    var statusTone: SessionStatusTone {
        SessionStatusTone.resolve(
            lifecycle: lifecycle,
            phase: phase,
            needsReview: needsReview,
            hasWorkingSubagents: hasWorkingSubagents
        )
    }

    var displayLifecycle: SessionLifecycle {
        SessionStatusTone.displayLifecycle(
            lifecycle: lifecycle,
            phase: phase,
            hasWorkingSubagents: hasWorkingSubagents
        )
    }

    /// `Running · Responding`, as every status pill and tooltip reads.
    var statusText: String {
        SessionStatusTone.statusText(
            lifecycle: lifecycle,
            phase: phase,
            hasWorkingSubagents: hasWorkingSubagents
        )
    }

    /// The session's own agent is at work (`SessionStatusTone.isAtWork`).
    var isAtWork: Bool {
        SessionStatusTone.isAtWork(lifecycle: lifecycle, phase: phase)
    }

    /// Parked at its prompt with subagents still at work
    /// (`SessionStatusTone.isKeptRunningBySubagents`).
    var isKeptRunningBySubagents: Bool {
        SessionStatusTone.isKeptRunningBySubagents(
            lifecycle: lifecycle,
            phase: phase,
            hasWorkingSubagents: hasWorkingSubagents
        )
    }

    /// Whether opening the session now counts as looking at its finished
    /// turn. It does whenever the flag is set — except while subagents keep
    /// a parked session Running: opening it then is watching work in
    /// progress, and the flag must still be there, as the green tier, when
    /// they stop. Every end asks this before it marks a session reviewed.
    var isReviewedByOpening: Bool {
        needsReview && !isKeptRunningBySubagents
    }

    /// The summary after the human opened the session: review flag cleared
    /// and the attention bit re-derived from the session's own state, the
    /// way the reduction derives it.
    var reviewed: SessionSummary {
        let tone = SessionStatusTone.resolve(
            lifecycle: lifecycle,
            phase: phase,
            needsReview: false,
            hasWorkingSubagents: false
        )
        let attention = switch tone {
        case .orange, .green, .red: true
        case .blue, .gray: false
        }
        return withReviewState(needsAttention: attention, needsReview: false)
    }
}
