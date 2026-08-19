import AgentStatusTransport

/// A platform-neutral color role shared by every Agent Status client.
///
/// Design system §4.1 (Session lifecycle, three tiers plus a failure state):
/// - `blue`  — Running: the agent is working (thinking / responding / tool /
///   subagent / compacting all collapse here).
/// - `green` — Waiting for input: a human needs to act (awaiting input or a
///   permission decision). The only tier that sorts a session to the top.
/// - `gray`  — Completed / Idle.
/// - `red`   — Failed / Aborted; sorts like Completed.
public enum SessionStatusTone: Equatable, Sendable {
    case blue
    case green
    case gray
    case red

    public static func resolve(
        lifecycle: SessionLifecycle,
        phase: TurnPhase
    ) -> SessionStatusTone {
        switch lifecycle {
        case .starting, .running, .compacting:
            .blue
        case .waitingForInput:
            .green
        case .completed:
            .gray
        case .failed, .interrupted:
            .red
        case .unknown:
            .gray
        }
    }
}

public extension SessionSummary {
    var statusTone: SessionStatusTone {
        SessionStatusTone.resolve(lifecycle: lifecycle, phase: phase)
    }
}
