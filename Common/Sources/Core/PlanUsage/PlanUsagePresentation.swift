import Transport
import Foundation

/// The words every plan-usage surface shares — Mac Settings, the Notch
/// tooltip, the iPhone's Plan cards. Pure text from Transport values.
public enum PlanUsagePresentation {
    /// Plan usage writes `Claude Code`, never `Claude` (see the glossary).
    public static func agentName(_ provider: AgentProvider) -> String {
        provider == .claude ? "Claude Code" : "Codex"
    }

    /// The number a window shows and its wording: `(42, "used")` or, under
    /// `remaining`, `(58, "left")`. The bar always draws the used share.
    public static func percent(_ limit: PlanUsageLimit, style: PlanUsagePercentStyle) -> (value: Int, word: String) {
        let shown = style == .used ? limit.usedPercent : 100 - limit.usedPercent
        return (Int(shown.rounded()), style == .used ? "used" : "left")
    }

    /// The Settings row's status and the Notch tooltip share these words;
    /// `nil` while the last fetch succeeded.
    public static func statusText(_ account: PlanUsageAccount, now: Date = Date()) -> String? {
        switch account.status {
        case .ok:
            return nil
        case .credentialsMissing:
            return "Not signed in" + (account.statusDetail.map { " · \($0)" } ?? "")
        case .signInExpired:
            return "Saved sign-in expired · sign in again with \(agentName(account.provider))"
        case .signInRejected:
            return "Sign-in rejected by the service"
        case .rateLimited:
            if let retryAt = account.retryAt, retryAt > now {
                return "Rate limited · retry in \(SessionElapsedFormatter.string(from: retryAt.timeIntervalSince(now)))"
            }
            return "Rate limited"
        case .failed:
            return "Unavailable" + (account.statusDetail.map { " · \($0)" } ?? "")
        }
    }

    /// Card window title: `SESSION · 5 HOURS`, `WEEKLY · 7 DAYS`, `FABLE · 7 DAYS`.
    public static func windowTitle(_ limit: PlanUsageLimit) -> String {
        if let model = limit.model { return "\(model) · 7 days".uppercased() }
        return limit.window == .session ? "SESSION · 5 HOURS" : "WEEKLY · 7 DAYS"
    }

    /// `resets in 2h 10m` / `resets now`.
    public static func resetText(_ limit: PlanUsageLimit, now: Date) -> String? {
        guard let resetsAt = limit.resetsAt else { return nil }
        return resetsAt > now ? "resets in \(SessionElapsedFormatter.string(from: resetsAt.timeIntervalSince(now)))" : "resets now"
    }

    /// `updated 1m ago`.
    public static func updatedText(_ fetchedAt: Date?, now: Date) -> String? {
        guard let fetchedAt else { return nil }
        let elapsed = max(0, now.timeIntervalSince(fetchedAt))
        if elapsed < 60 { return "updated just now" }
        if elapsed < 3_600 { return "updated \(Int(elapsed / 60))m ago" }
        if elapsed < 86_400 { return "updated \(Int(elapsed / 3_600))h ago" }
        return "updated \(Int(elapsed / 86_400))d ago"
    }
}
