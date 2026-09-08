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
            "\(PlanUsagePresentation.agentName(group.provider)) · " + group.entries.map(\.help).joined(separator: " · ")
        }.joined(separator: "\n")
    }
}

enum HaloPlanUsagePresentation {
    static let warningThreshold = DesignSystem.PlanUsage.warningPercent

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
        let percent = PlanUsagePresentation.percent(limit, style: style)
        var help = "\(item.shortTitle) \(percent.value)% \(percent.word)"
        if let resetsAt = limit.resetsAt {
            help += resetsAt > now
                ? ", resets in \(SessionElapsedFormatter.string(from: resetsAt.timeIntervalSince(now)))"
                : ", resets now"
        }
        return .init(
            item: item,
            label: item.notchLabel,
            text: "\(percent.value)%",
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
        if let status = PlanUsagePresentation.statusText(account, now: now) { return status }
        if !account.enabled { return "Switched off · Settings › Usage" }
        if account.limits.isEmpty { return "Fetching from the provider…" }
        return nil
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
