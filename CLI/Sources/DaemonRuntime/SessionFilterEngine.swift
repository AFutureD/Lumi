import Core
import Diagnostics
import Logging
import Synchronization
import Transport
import Foundation

private let log = Logger(label: "agent")

/// The daemon's live copy of the session filter rules, and the one place a
/// verdict is decided. Installed into the repository as its
/// `SessionFilterEvaluating`, so `shouldHide` runs synchronously inside the
/// repository's write — the verdict commits atomically with the event that
/// carries the session's first user message.
///
/// A hide verdict is parked in `pendingVerdicts` for the publisher: the
/// ingest `onEvent` drains it right after publishing the event itself, so
/// mirrors always see the creating event before the verdict summary frame.
///
/// Rule contents are user content (folder paths, message text) — logs carry
/// rule ids and counts only.
public final class SessionFilterEngine: SessionFilterEvaluating, Sendable {
    private struct State {
        var rules: [SessionFilterRule] = []
        var pendingVerdicts: [SessionID: SessionSummary] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    public func update(rules: [SessionFilterRule]) {
        state.withLock { $0.rules = rules }
    }

    public func currentRules() -> [SessionFilterRule] {
        state.withLock { $0.rules }
    }

    public func shouldHide(summary: SessionSummary, event: AgentIngressEvent) -> Bool {
        let rules = state.withLock { $0.rules }
        guard !rules.isEmpty else { return false }
        let message = SessionFilterMatcher.firstUserMessage(of: event)
        let matched = rules.first {
            SessionFilterMatcher.shouldHide(rules: [$0], summary: summary, firstUserMessage: message)
        }
        guard let matched else { return false }
        state.withLock { $0.pendingVerdicts[summary.id] = summary.withHiddenByFilter(true) }
        log.info("session_filter_hidden", metadata: .fields([
            "session": summary.id.rawValue,
            "matched_rule": matched.id.rawValue,
            "rules": rules.count,
        ]))
        return true
    }

    /// The freshly stamped summary of a session hidden by the last `apply`,
    /// handed out once so the publisher can follow the event frame with a
    /// summary frame.
    public func takeVerdict(for sessionID: SessionID) -> SessionSummary? {
        state.withLock { $0.pendingVerdicts.removeValue(forKey: sessionID) }
    }
}
