import AgentStatusTransport

extension AgentKind {
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .codexSubagent: "Codex Subagent"
        case .claude: "Claude"
        case .claudeSubagent: "Claude Subagent"
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

extension AgentKind {
    /// Short chip label ("Codex" / "Claude"), same for parent and subagent.
    var providerName: String {
        switch provider {
        case .codex: "Codex"
        case .claude: "Claude"
        case .unknown: displayName
        }
    }
}
