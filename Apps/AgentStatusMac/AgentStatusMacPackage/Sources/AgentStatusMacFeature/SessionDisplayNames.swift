import AgentStatusTransport

extension AgentKind {
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .codexSubagent: "Codex Subagent"
        case let .unknown(value): value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

extension SessionLifecycle {
    var displayName: String {
        rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

extension TurnPhase {
    var displayName: String {
        rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
