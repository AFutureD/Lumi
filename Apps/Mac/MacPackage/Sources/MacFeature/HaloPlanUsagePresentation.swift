import Core
import DesignSystem
import Transport
import Foundation

/// What the Notch top bar draws for plan usage: one group per agent, each
/// the agent's mark followed by `label value` cells in the design's order
/// (5 h → 7 d → model window).
struct HaloPlanUsageCluster: Hashable, Sendable {
    struct Entry: Hashable, Sendable {
        var item: PlanUsageItem
        /// `5h` / `7d` / `Fable`.
        var label: String
        /// `42%`.
        var text: String
        /// Used ≥ 90 %: drawn in the warning colour.
        var isWarning: Bool
        /// `Session 42% used, resets in 2h 10m`.
        var help: String
    }

    struct Group: Hashable, Sendable {
        var provider: AgentProvider
        var entries: [Entry]
    }

    var groups: [Group]
    /// `switchOnClick`: which agent a click would bring up next.
    var nextProvider: AgentProvider?

    var help: String {
        groups.map { group in
            "\(HaloPlanUsagePresentation.agentName(group.provider)) · " + group.entries.map(\.help).joined(separator: " · ")
        }.joined(separator: "\n")
    }
}

enum HaloPlanUsagePresentation {
    static let warningThreshold = DesignSystem.PlanUsage.warningPercent

    static func agentName(_ provider: AgentProvider) -> String {
        provider == .claude ? "Claude Code" : "Codex"
    }

    /// `nil` when the cluster has nothing to show — the top bar keeps its
    /// brand cluster: no item is chosen (that is the off state), no chosen
    /// item belongs to an account that is switched on, or none of those
    /// accounts reports a chosen window. Windows the provider did not report
    /// take no room; an agent with nothing to show takes none either.
    static func cluster(state: PlanUsageState?, choices: HaloPlanUsageChoices, now: Date) -> HaloPlanUsageCluster? {
        guard let state, !choices.items.isEmpty else { return nil }
        let candidates: [HaloPlanUsageCluster.Group] = [AgentProvider.claude, .codex].compactMap { provider in
            guard let account = state.accounts.first(where: { $0.provider == provider }), account.enabled else { return nil }
            let entries = PlanUsageItem.allCases
                .filter { $0.provider == provider && choices.items.contains($0) }
                .compactMap { entry($0, account: account, style: choices.percentStyle, now: now) }
            return entries.isEmpty ? nil : HaloPlanUsageCluster.Group(provider: provider, entries: entries)
        }
        guard !candidates.isEmpty else { return nil }
        switch choices.agentsMode {
        case .showBoth:
            return HaloPlanUsageCluster(groups: candidates, nextProvider: nil)
        case .switchOnClick:
            let current = candidates.first { $0.provider == choices.selectedProvider } ?? candidates[0]
            let next = candidates.first { $0.provider != current.provider }?.provider
            return HaloPlanUsageCluster(groups: [current], nextProvider: next)
        }
    }

    /// `nil` when the provider did not report the window.
    static func entry(_ item: PlanUsageItem, account: PlanUsageAccount, style: PlanUsagePercentStyle, now: Date) -> HaloPlanUsageCluster.Entry? {
        guard let limit = account.limit(item.window, model: item.model) else { return nil }
        let shown = style == .used ? limit.usedPercent : 100 - limit.usedPercent
        var help = "\(item.shortTitle) \(Int(shown.rounded()))% \(style == .used ? "used" : "left")"
        if let resetsAt = limit.resetsAt {
            help += resetsAt > now
                ? ", resets in \(SessionElapsedFormatter.string(from: resetsAt.timeIntervalSince(now)))"
                : ", resets now"
        }
        return .init(
            item: item,
            label: item.notchLabel,
            text: "\(Int(shown.rounded()))%",
            isWarning: limit.usedPercent >= warningThreshold,
            help: help
        )
    }

    /// The items an account can offer under Settings › Notch › Usage › Show:
    /// only windows the provider reported, only while the account is on.
    static func availableItems(_ account: PlanUsageAccount) -> [PlanUsageItem] {
        guard account.enabled else { return [] }
        return PlanUsageItem.allCases.filter { $0.provider == account.provider && account.limit($0.window, model: $0.model) != nil }
    }

    /// Why a Show row offers nothing, for the line under the agent's name.
    static func unavailableReason(_ account: PlanUsageAccount?, now: Date = Date()) -> String? {
        guard let account else { return "Daemon not connected" }
        if let status = statusText(account, now: now) { return status }
        if !account.enabled { return "Switched off · Settings › Usage" }
        if account.limits.isEmpty { return "Fetching from the provider…" }
        return nil
    }

    /// The Settings row's status and the Notch tooltip share these words.
    static func statusText(_ account: PlanUsageAccount, now: Date = Date()) -> String? {
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
    static func windowTitle(_ limit: PlanUsageLimit) -> String {
        if let model = limit.model { return "\(model) · 7 days".uppercased() }
        return limit.window == .session ? "SESSION · 5 HOURS" : "WEEKLY · 7 DAYS"
    }

    /// `resets in 2h 10m` / `resets now`.
    static func resetText(_ limit: PlanUsageLimit, now: Date) -> String? {
        guard let resetsAt = limit.resetsAt else { return nil }
        return resetsAt > now ? "resets in \(SessionElapsedFormatter.string(from: resetsAt.timeIntervalSince(now)))" : "resets now"
    }

    /// `updated 1m ago`.
    static func updatedText(_ fetchedAt: Date?, now: Date) -> String? {
        guard let fetchedAt else { return nil }
        let elapsed = max(0, now.timeIntervalSince(fetchedAt))
        if elapsed < 60 { return "updated just now" }
        if elapsed < 3_600 { return "updated \(Int(elapsed / 60))m ago" }
        if elapsed < 86_400 { return "updated \(Int(elapsed / 3_600))h ago" }
        return "updated \(Int(elapsed / 86_400))d ago"
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
