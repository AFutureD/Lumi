import Core
import Transport
import Foundation

/// What the History segment is looking at. Pure, so the transitions the
/// handoff fixes (which changes clear the selected bar) are testable:
/// changing the range or the chart's agent clears the selection; changing
/// the scope keeps it (the scope does not change the buckets).
struct UsageHistoryState: Equatable, Sendable {
    /// `custom` never appears here — the wire has no name for it.
    var range: UsageRangeKind = .thisWeek
    /// `nil` is `All Macs`.
    var scope: HostID? = nil
    /// Only the chart follows this; the figures card is always every agent.
    var chartAgent: UsageSummaryAgent = .all
    /// `UsageTrendBar.id` of the tapped bar.
    var selectedBucket: String? = nil

    var preset: UsageRangePreset { range.preset ?? .thisWeek }

    mutating func select(range newRange: UsageRangeKind) {
        guard newRange != range else { return }
        range = newRange
        selectedBucket = nil
    }

    mutating func select(scope newScope: HostID?) {
        scope = newScope
    }

    mutating func select(agent newAgent: UsageSummaryAgent) {
        guard newAgent != chartAgent else { return }
        chartAgent = newAgent
        selectedBucket = nil
    }

    /// Tapping the selected bar again clears it.
    mutating func toggle(bucket: String) {
        selectedBucket = selectedBucket == bucket ? nil : bucket
    }

    mutating func clearSelection() {
        selectedBucket = nil
    }

    /// A scope whose Mac was unpaired falls back to `All Macs`.
    mutating func reconcile(pairedHosts: Set<HostID>) {
        if let scope, !pairedHosts.contains(scope) {
            self.scope = nil
        }
    }
}

/// Wording of the History card that the shared `UsageFormatting` does not
/// already provide.
enum UsageHistoryText {
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// The card header's range: `Sep 1 – 7, 2026`, `Aug 31 – Sep 6, 2026`,
    /// or `Sep 7` for a single day.
    static func rangeCaption(since: UsageDay, until: UsageDay) -> String {
        if since == until {
            return "\(months[since.month - 1]) \(since.day)"
        }
        if since.year == until.year, since.month == until.month {
            return "\(months[since.month - 1]) \(since.day) – \(until.day), \(until.year)"
        }
        return "\(months[since.month - 1]) \(since.day) – \(months[until.month - 1]) \(until.day), \(until.year)"
    }

    /// `2 models have no price · counted in tokens, not in cost`.
    static func unpricedNotice(modelCount: Int) -> String? {
        guard modelCount > 0 else { return nil }
        return modelCount == 1
            ? "1 model has no price · counted in tokens, not in cost"
            : "\(modelCount) models have no price · counted in tokens, not in cost"
    }

    /// `Claude Code $4.05 · Codex $1.12` — the selected bar's split by agent
    /// (agents with nothing in the bar are left out); `Claude Code only`
    /// when the chart is filtered to one agent.
    static func bucketCostSplit(bar: UsageTrendBar, agent: UsageSummaryAgent) -> String {
        if let provider = agent.provider {
            return "\(UsageSummaryAgent(provider).title) only"
        }
        let parts = [AgentProvider.claude, .codex].compactMap { provider -> String? in
            let cost = bar.value(.cost, series: provider.rawValue)
            guard cost > 0 else { return nil }
            return "\(UsageSummaryAgent(provider).title) \(UsageFormatting.cost(cost))"
        }
        return parts.isEmpty ? "no spend in this bucket" : parts.joined(separator: " · ")
    }

    /// `offline · 5m ago` / `offline`.
    static func offlineStamp(lastSeen: Date?, now: Date) -> String {
        guard let lastSeen else { return "offline" }
        return "offline · \(SessionRelativeTimeFormatter.string(from: lastSeen, now: now)) ago"
    }

    /// The page-level banner: `Offline · showing numbers from 5m ago`.
    static func offlineBanner(lastSeen: Date?, now: Date) -> String {
        guard let lastSeen else { return "Offline · no numbers yet" }
        return "Offline · showing numbers from \(SessionRelativeTimeFormatter.string(from: lastSeen, now: now)) ago"
    }
}
