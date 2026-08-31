import Transport
import Foundation

/// Consulted by the repositories exactly once per session, inside `apply`, on
/// the event that carries the session's first user-classified message
/// (`SessionReduction.startsFilterEvaluation`). Only the daemon installs one
/// — mirrors replay the same reduction without it and keep the streamed
/// verdict.
public protocol SessionFilterEvaluating: Sendable {
    func shouldHide(summary: SessionSummary, event: AgentIngressEvent) -> Bool
}

/// Pure rule evaluation. Hide when ANY enabled rule matches; within a rule
/// EVERY condition must match. Missing inputs (no AaaS ownership, no
/// workspace, no first message on the transition event) fail their condition
/// — the bias is always toward showing a session.
public enum SessionFilterMatcher {
    public static func shouldHide(
        rules: [SessionFilterRule],
        summary: SessionSummary,
        firstUserMessage: String?
    ) -> Bool {
        rules.contains { rule in
            rule.isEnabled
                && !rule.conditions.isEmpty
                && rule.conditions.allSatisfy {
                    matches($0, summary: summary, firstUserMessage: firstUserMessage)
                }
        }
    }

    /// The text a `message` condition inspects: the user-classified timeline
    /// message on the triggering event. Classification only — `turn.prompt`
    /// and raw hook fields are deliberately not consulted.
    public static func firstUserMessage(of event: AgentIngressEvent) -> String? {
        guard case let .message(message)? = event.timelineItem?.payload,
              message.role == .user else { return nil }
        return message.text
    }

    private static func matches(
        _ condition: SessionFilterCondition,
        summary: SessionSummary,
        firstUserMessage: String?
    ) -> Bool {
        guard !condition.value.isEmpty else { return false }
        switch condition.field {
        case .agent:
            return optionValues(condition.value).contains(summary.agent.provider.rawValue)
        case .application:
            guard let kind = summary.aaas?.kind else { return false }
            return optionValues(condition.value).contains(kind.rawValue)
        case .message:
            guard let message = firstUserMessage, case let .text(value) = condition.value,
                  !value.isEmpty
            else { return false }
            switch condition.op {
            case .contains: return message.contains(value)
            case .startsWith: return message.hasPrefix(value)
            case .is: return false
            }
        case .folder:
            guard let workspace = summary.workspace, case let .text(value) = condition.value,
                  !value.isEmpty
            else { return false }
            // Component-safe prefix: the folder itself and everything under
            // it, never `/a/bc` for a `/a/b` rule. Values are stored as
            // expanded absolute paths.
            let folder = value.hasSuffix("/") ? String(value.dropLast()) : value
            return workspace == folder || workspace.hasPrefix(folder + "/")
        }
    }

    /// Enum fields carry canonical raw values; `is` holds one, `contains`
    /// holds an OR-ed list. Either shape is read as a set.
    private static func optionValues(_ value: SessionFilterValue) -> Set<String> {
        switch value {
        case .text(let single): [single]
        case .options(let values): Set(values)
        }
    }
}
