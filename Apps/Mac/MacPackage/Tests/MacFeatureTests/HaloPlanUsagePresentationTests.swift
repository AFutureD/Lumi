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
            ], fetchedAt: now.addingTimeInterval(-90)),
            PlanUsageAccount(id: .codex, provider: .codex, enabled: codexEnabled, status: .ok, limits: [
                PlanUsageLimit(window: .weekly, usedPercent: 12, resetsAt: now.addingTimeInterval(-5)),
            ]),
        ],
        generatedAt: now
    )
}

private func choices(
    mode: PlanUsageAgentsMode = .showBoth,
    style: PlanUsagePercentStyle = .used,
    items: Set<PlanUsageItem> = PlanUsageItem.defaults,
    selected: AgentProvider = .claude
) -> HaloPlanUsageChoices {
    HaloPlanUsageChoices(agentsMode: mode, percentStyle: style, items: items, selectedProvider: selected)
}

@Test func clusterFollowsTheDesignOrderAndTheChosenItems() throws {
    let cluster = try #require(HaloPlanUsagePresentation.cluster(state: state(), choices: choices(), now: now))
    #expect(cluster.groups.map(\.provider) == [.claude, .codex])
    #expect(cluster.nextProvider == nil)
    let claude = cluster.groups[0]
    #expect(claude.entries.map(\.item) == [.claudeSession, .claudeWeekly, .claudeFable])
    #expect(claude.entries.map(\.label) == ["5h", "7d", "Fable"])
    #expect(claude.entries.map(\.text) == ["42%", "91%", "7%"])
    #expect(claude.entries.map(\.isWarning) == [false, true, false])
    #expect(claude.entries[0].help == "Session 42% used, resets in 2h 10m")
    let codex = cluster.groups[1]
    #expect(codex.entries.map(\.item) == [.codexWeekly])
    #expect(codex.entries[0].help == "Weekly 12% used, resets now")
    #expect(cluster.help.hasPrefix("Claude Code · Session 42% used"))

    // Codex session is off by default and, once on, sits before weekly —
    // but Codex reported no session window, so it takes no room.
    let more = try #require(HaloPlanUsagePresentation.cluster(state: state(), choices: choices(items: PlanUsageItem.defaults.union([.codexSession])), now: now))
    #expect(more.groups[1].entries.map(\.item) == [.codexWeekly])
    #expect(PlanUsageItem.allCases.filter { $0.provider == .codex } == [.codexSession, .codexWeekly])
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
    // No item picked is the off state.
    #expect(HaloPlanUsagePresentation.cluster(state: state(), choices: choices(items: []), now: now) == nil)
    #expect(HaloPlanUsagePresentation.cluster(state: nil, choices: choices(), now: now) == nil)
    #expect(HaloPlanUsagePresentation.cluster(state: state(claudeEnabled: false, codexEnabled: false), choices: choices(), now: now) == nil)
    // Every chosen item belongs to an account that is off.
    #expect(HaloPlanUsagePresentation.cluster(state: state(codexEnabled: false), choices: choices(items: [.codexWeekly]), now: now) == nil)
    // Chosen windows that no provider reports: nothing to draw.
    #expect(HaloPlanUsagePresentation.cluster(state: state(), choices: choices(items: [.codexSession]), now: now) == nil)
}

@Test func anAccountWithoutLimitsVanishesFromTheBarAndExplainsInSettings() throws {
    let expired = state(claudeStatus: .signInExpired, claudeLimits: [])
    let cluster = try #require(HaloPlanUsagePresentation.cluster(state: expired, choices: choices(), now: now))
    #expect(cluster.groups.map(\.provider) == [.codex])

    let claude = try #require(expired.account(.claude))
    #expect(HaloPlanUsagePresentation.availableItems(claude).isEmpty)
    #expect(HaloPlanUsagePresentation.unavailableReason(claude, now: now) == "Saved sign-in expired · sign in again with Claude Code")
    let off = try #require(state(claudeEnabled: false).account(.claude))
    #expect(HaloPlanUsagePresentation.availableItems(off).isEmpty)
    #expect(HaloPlanUsagePresentation.unavailableReason(off, now: now) == "Switched off · Settings › Usage")
    let live = try #require(state().account(.claude))
    #expect(HaloPlanUsagePresentation.availableItems(live) == [.claudeSession, .claudeWeekly, .claudeFable])
    #expect(HaloPlanUsagePresentation.availableItems(try #require(state().account(.codex))) == [.codexWeekly])
    #expect(HaloPlanUsagePresentation.unavailableReason(nil) == "Daemon not connected")
    let fetching = PlanUsageAccount(id: .codex, provider: .codex, enabled: true, status: .ok)
    #expect(HaloPlanUsagePresentation.unavailableReason(fetching, now: now) == "Fetching from the provider…")

    let limited = PlanUsageAccount(id: .codex, provider: .codex, enabled: true, status: .rateLimited, retryAt: now.addingTimeInterval(240))
    #expect(HaloPlanUsagePresentation.statusText(limited, now: now) == "Rate limited · retry in 4m 0s")
    let missing = PlanUsageAccount(id: .claude, provider: .claude, enabled: false, status: .credentialsMissing, statusDetail: "No ~/.claude/.credentials.json")
    #expect(HaloPlanUsagePresentation.statusText(missing) == "Not signed in · No ~/.claude/.credentials.json")
    #expect(HaloPlanUsagePresentation.statusText(PlanUsageAccount(id: .claude, provider: .claude, enabled: true, status: .ok)) == nil)
}

@Test func cardWordingFollowsTheHandoff() throws {
    let claude = try #require(state().account(.claude))
    #expect(claude.limits.map(HaloPlanUsagePresentation.windowTitle) == ["SESSION · 5 HOURS", "WEEKLY · 7 DAYS", "FABLE · 7 DAYS"])
    #expect(HaloPlanUsagePresentation.resetText(claude.limits[0], now: now) == "resets in 2h 10m")
    #expect(HaloPlanUsagePresentation.resetText(claude.limits[1], now: now) == nil)
    #expect(HaloPlanUsagePresentation.resetText(try #require(state().account(.codex)).limits[0], now: now) == "resets now")
    #expect(HaloPlanUsagePresentation.updatedText(claude.fetchedAt, now: now) == "updated 1m ago")
    #expect(HaloPlanUsagePresentation.updatedText(now.addingTimeInterval(-10), now: now) == "updated just now")
    #expect(HaloPlanUsagePresentation.updatedText(now.addingTimeInterval(-7_200), now: now) == "updated 2h ago")
    #expect(HaloPlanUsagePresentation.updatedText(nil, now: now) == nil)
}

@MainActor
@Test func preferencesRoundTripThroughDefaults() {
    let suite = "HaloPlanUsagePreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let fresh = HaloPlanUsagePreferences(defaults: defaults)
    #expect(fresh.agentsMode == .showBoth && fresh.percentStyle == .used)
    #expect(fresh.items == PlanUsageItem.defaults && fresh.selectedProvider == .claude)
    fresh.agentsMode = .switchOnClick
    fresh.percentStyle = .remaining
    fresh.toggle(.claudeFable)
    fresh.toggle(.codexSession)
    fresh.selectedProvider = .codex
    let reopened = HaloPlanUsagePreferences(defaults: defaults)
    #expect(reopened.agentsMode == .switchOnClick && reopened.percentStyle == .remaining)
    #expect(reopened.items == [.claudeSession, .claudeWeekly, .codexWeekly, .codexSession])
    #expect(reopened.selectedProvider == .codex)
    // Clearing every pill persists as an empty list, not as "unset".
    for item in reopened.items { reopened.setItem(item, on: false) }
    #expect(HaloPlanUsagePreferences(defaults: defaults).items.isEmpty)
}
