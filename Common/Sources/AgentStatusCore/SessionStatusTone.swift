import AgentStatusTransport

/// A platform-neutral color role shared by every Agent Status client.
public enum SessionStatusTone: Equatable, Sendable {
    case blue
    case green
    case orange
    case gray

    public static func resolve(
        lifecycle: SessionLifecycle,
        phase: TurnPhase
    ) -> SessionStatusTone {
        switch lifecycle {
        case .starting, .running, .compacting:
            .blue
        case .waitingForInput:
            phase == .idle ? .green : .orange
        case .completed:
            .gray
        case .failed, .interrupted:
            .orange
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
