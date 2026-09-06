import Core
import Transport
import Foundation

/// What the Notch top bar draws for plan usage: one group per agent, each
/// an icon followed by the chosen percentages in the design's order.
struct HaloPlanUsageCluster: Hashable, Sendable {
    struct Entry: Hashable, Sendable {
        var item: PlanUsageItem
        /// `42%`, or `–` when the window is not reported.
        var text: String
        /// Used ≥ 90 % (remaining ≤ 10 %): drawn in the warning colour.
        var isWarning: Bool
        /// `Session resets in 2h 10m`; nothing for an unreported window.
        var help: String?
    }

    struct Group: Hashable, Sendable {
        var provider: AgentProvider
        /// False when the account has no current limits (not signed in,
        /// rejected, never fetched): the icon dims and entries read `–`.
        var isAvailable: Bool
        var entries: [Entry]
        /// The account's status, for the tooltip.
        var statusText: String?
    }

    var groups: [Group]
    /// `switchOnClick`: which agent a click would bring up next.
    var nextProvider: AgentProvider?

    var help: String {
        groups.map { group in
            let name = group.provider == .claude ? "Claude Code" : "Codex"
            let parts = group.entries.compactMap(\.help)
            if parts.isEmpty { return "\(name): \(group.statusText ?? "no limits reported")" }
            return "\(name) · " + parts.joined(separator: " · ")
        }.joined(separator: "\n")
    }
}

enum HaloPlanUsagePresentation {
    static let warningThreshold: Double = 90

    /// `nil` when the cluster has nothing to show — the top bar keeps its
    /// brand cluster: the feature is off, no account is switched on, or
    /// every chosen item belongs to an account that is off.
    static func cluster(state: PlanUsageState?, choices: HaloPlanUsageChoices, now: Date) -> HaloPlanUsageCluster? {
        guard choices.enabled, let state else { return nil }
        let providers: [AgentProvider] = [.claude, .codex]
        let eligible = providers.filter { provider in
            guard let account = state.accounts.first(where: { $0.provider == provider }), account.enabled else { return false }
            return PlanUsageItem.allCases.contains { $0.provider == provider && choices.items.contains($0) }
        }
        guard !eligible.isEmpty else { return nil }

        let shown: [AgentProvider]
        var next: AgentProvider?
        switch choices.agentsMode {
        case .showBoth:
            shown = eligible
        case .switchOnClick:
            let current = eligible.contains(choices.selectedProvider) ? choices.selectedProvider : eligible[0]
            shown = [current]
            next = eligible.first { $0 != current }
        }

        let groups = shown.compactMap { provider -> HaloPlanUsageCluster.Group? in
            guard let account = state.accounts.first(where: { $0.provider == provider }) else { return nil }
            let entries = PlanUsageItem.allCases
                .filter { $0.provider == provider && choices.items.contains($0) }
                .map { entry($0, account: account, style: choices.percentStyle, now: now) }
            return HaloPlanUsageCluster.Group(
                provider: provider,
                isAvailable: !account.limits.isEmpty,
                entries: entries,
                statusText: statusText(account)
            )
        }
        return HaloPlanUsageCluster(groups: groups, nextProvider: next)
    }

    static func entry(_ item: PlanUsageItem, account: PlanUsageAccount, style: PlanUsagePercentStyle, now: Date) -> HaloPlanUsageCluster.Entry {
        guard let limit = account.limit(item.window, model: item.model) else {
            return .init(item: item, text: "–", isWarning: false, help: nil)
        }
        let shown = style == .used ? limit.usedPercent : 100 - limit.usedPercent
        var help = "\(item.shortTitle) \(Int(shown.rounded()))% \(style == .used ? "used" : "left")"
        if let resetsAt = limit.resetsAt {
            help += resetsAt > now
                ? ", resets in \(SessionElapsedFormatter.string(from: resetsAt.timeIntervalSince(now)))"
                : ", resets now"
        }
        return .init(
            item: item,
            text: "\(Int(shown.rounded()))%",
            isWarning: limit.usedPercent >= warningThreshold,
            help: help
        )
    }

    /// The Settings row's subtitle and the Notch tooltip share these words.
    static func statusText(_ account: PlanUsageAccount, now: Date = Date()) -> String? {
        switch account.status {
        case .ok:
            return nil
        case .credentialsMissing:
            return "Not signed in" + (account.statusDetail.map { " · \($0)" } ?? "")
        case .signInExpired:
            return "Saved sign-in expired · sign in again with \(account.provider == .claude ? "Claude Code" : "Codex")"
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

    /// Stand-in numbers for the Settings preview while the daemon has none.
    static func sampleState(now: Date = Date()) -> PlanUsageState {
        PlanUsageState(
            accounts: [
                PlanUsageAccount(id: .claude, provider: .claude, email: "sample", plan: "Max 20x", enabled: true, status: .ok, limits: [
                    PlanUsageLimit(window: .session, usedPercent: 42, resetsAt: now.addingTimeInterval(2 * 3_600 + 600)),
                    PlanUsageLimit(window: .weekly, usedPercent: 18, resetsAt: now.addingTimeInterval(3 * 86_400)),
                    PlanUsageLimit(window: .weekly, model: "Fable", usedPercent: 7, resetsAt: now.addingTimeInterval(3 * 86_400)),
                ], fetchedAt: now),
                PlanUsageAccount(id: .codex, provider: .codex, email: "sample", plan: "Pro 20x", enabled: true, status: .ok, limits: [
                    PlanUsageLimit(window: .session, usedPercent: 5, resetsAt: now.addingTimeInterval(3_600)),
                    PlanUsageLimit(window: .weekly, usedPercent: 12, resetsAt: now.addingTimeInterval(5 * 86_400)),
                ], fetchedAt: now),
            ],
            generatedAt: now
        )
    }
}
