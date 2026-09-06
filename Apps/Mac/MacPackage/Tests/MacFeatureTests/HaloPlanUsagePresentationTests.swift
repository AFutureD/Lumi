import Transport
import Foundation
import Testing
@testable import MacFeature

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func state(claudeEnabled: Bool = true, codexEnabled: Bool = true, claudeStatus: PlanUsageAccountStatus = .ok, claudeLimits: [PlanUsageLimit]? = nil) -> PlanUsageState {
    PlanUsageState(
        accounts: [
            PlanUsageAccount(id: .claude, provider: .claude, enabled: claudeEnabled, status: claudeStatus, limits: claudeLimits ?? [
                PlanUsageLimit(window: .session, usedPercent: 42.4, resetsAt: now.addingTimeInterval(7_800)),
                PlanUsageLimit(window: .weekly, usedPercent: 91),
                PlanUsageLimit(window: .weekly, model: "Fable", usedPercent: 7),
            ]),
            PlanUsageAccount(id: .codex, provider: .codex, enabled: codexEnabled, status: .ok, limits: [
                PlanUsageLimit(window: .weekly, usedPercent: 12, resetsAt: now.addingTimeInterval(-5)),
            ]),
        ],
        generatedAt: now
    )
}

private func choices(
    enabled: Bool = true,
    mode: PlanUsageAgentsMode = .showBoth,
    style: PlanUsagePercentStyle = .used,
    items: Set<PlanUsageItem> = PlanUsageItem.defaults,
    selected: AgentProvider = .claude
) -> HaloPlanUsageChoices {
    HaloPlanUsageChoices(enabled: enabled, agentsMode: mode, percentStyle: style, items: items, selectedProvider: selected)
}

@Test func clusterFollowsTheDesignOrderAndTheChosenItems() throws {
    let cluster = try #require(HaloPlanUsagePresentation.cluster(state: state(), choices: choices(), now: now))
    #expect(cluster.groups.map(\.provider) == [.claude, .codex])
    #expect(cluster.nextProvider == nil)
    let claude = cluster.groups[0]
    #expect(claude.entries.map(\.item) == [.claudeSession, .claudeWeekly, .claudeFable])
    #expect(claude.entries.map(\.text) == ["42%", "91%", "7%"])
    #expect(claude.entries.map(\.isWarning) == [false, true, false])
    #expect(claude.entries[0].help == "Session 42% used, resets in 2h 10m")
    #expect(claude.isAvailable)
    let codex = cluster.groups[1]
    #expect(codex.entries.map(\.item) == [.codexWeekly])
    #expect(codex.entries[0].help == "Weekly 12% used, resets now")
    #expect(cluster.help.hasPrefix("Claude Code · Session 42% used"))

    // Codex session is off by default; switching it on adds it after weekly.
    let more = try #require(HaloPlanUsagePresentation.cluster(state: state(), choices: choices(items: PlanUsageItem.defaults.union([.codexSession])), now: now))
    #expect(more.groups[1].entries.map(\.item) == [.codexWeekly, .codexSession])
    // Codex reported no session window: a dash, no tooltip part.
    #expect(more.groups[1].entries[1].text == "–" && more.groups[1].entries[1].help == nil)
}

@Test func remainingIsTheComplementAndKeepsTheWarning() throws {
    let cluster = try #require(HaloPlanUsagePresentation.cluster(state: state(), choices: choices(style: .remaining), now: now))
    #expect(cluster.groups[0].entries.map(\.text) == ["58%", "9%", "93%"])
    #expect(cluster.groups[0].entries.map(\.isWarning) == [false, true, false])
    #expect(cluster.groups[0].entries[1].help == "Weekly 9% left")
}

@Test func switchOnClickShowsOneAgentAndNamesTheOther() throws {
    let claudeFirst = try #require(HaloPlanUsagePresentation.cluster(state: state(), choices: choices(mode: .switchOnClick), now: now))
    #expect(claudeFirst.groups.map(\.provider) == [.claude])
    #expect(claudeFirst.nextProvider == .codex)
    let codexSelected = try #require(HaloPlanUsagePresentation.cluster(state: state(), choices: choices(mode: .switchOnClick, selected: .codex), now: now))
    #expect(codexSelected.groups.map(\.provider) == [.codex])
    #expect(codexSelected.nextProvider == .claude)
    // The selected agent is off: the other one shows, with nothing to switch to.
    let only = try #require(HaloPlanUsagePresentation.cluster(state: state(codexEnabled: false), choices: choices(mode: .switchOnClick, selected: .codex), now: now))
    #expect(only.groups.map(\.provider) == [.claude] && only.nextProvider == nil)
}

@Test func nothingToShowHandsTheSlotBack() {
    #expect(HaloPlanUsagePresentation.cluster(state: state(), choices: choices(enabled: false), now: now) == nil)
    #expect(HaloPlanUsagePresentation.cluster(state: nil, choices: choices(), now: now) == nil)
    #expect(HaloPlanUsagePresentation.cluster(state: state(claudeEnabled: false, codexEnabled: false), choices: choices(), now: now) == nil)
    // Every chosen item belongs to an account that is off.
    #expect(HaloPlanUsagePresentation.cluster(state: state(codexEnabled: false), choices: choices(items: [.codexWeekly]), now: now) == nil)
}

@Test func anAccountWithoutLimitsDimsAndExplains() throws {
    let expired = state(claudeStatus: .signInExpired, claudeLimits: [])
    let cluster = try #require(HaloPlanUsagePresentation.cluster(state: expired, choices: choices(), now: now))
    let claude = cluster.groups[0]
    #expect(!claude.isAvailable)
    #expect(claude.entries.map(\.text) == ["–", "–", "–"])
    #expect(claude.statusText == "Saved sign-in expired · sign in again with Claude Code")
    #expect(cluster.help.hasPrefix("Claude Code: Saved sign-in expired"))

    let limited = PlanUsageAccount(id: .codex, provider: .codex, enabled: true, status: .rateLimited, retryAt: now.addingTimeInterval(240))
    #expect(HaloPlanUsagePresentation.statusText(limited, now: now) == "Rate limited · retry in 4m 0s")
    let missing = PlanUsageAccount(id: .claude, provider: .claude, enabled: false, status: .credentialsMissing, statusDetail: "No ~/.claude/.credentials.json")
    #expect(HaloPlanUsagePresentation.statusText(missing) == "Not signed in · No ~/.claude/.credentials.json")
    #expect(HaloPlanUsagePresentation.statusText(PlanUsageAccount(id: .claude, provider: .claude, enabled: true, status: .ok)) == nil)
}

@MainActor
@Test func preferencesRoundTripThroughDefaults() {
    let suite = "HaloPlanUsagePreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let fresh = HaloPlanUsagePreferences(defaults: defaults)
    #expect(!fresh.enabled && fresh.agentsMode == .showBoth && fresh.percentStyle == .used)
    #expect(fresh.items == PlanUsageItem.defaults && fresh.selectedProvider == .claude)
    fresh.enabled = true
    fresh.agentsMode = .switchOnClick
    fresh.percentStyle = .remaining
    fresh.setItem(.claudeFable, on: false)
    fresh.setItem(.codexSession, on: true)
    fresh.selectedProvider = .codex
    let reopened = HaloPlanUsagePreferences(defaults: defaults)
    #expect(reopened.enabled && reopened.agentsMode == .switchOnClick && reopened.percentStyle == .remaining)
    #expect(reopened.items == [.claudeSession, .claudeWeekly, .codexWeekly, .codexSession])
    #expect(reopened.selectedProvider == .codex)
}
