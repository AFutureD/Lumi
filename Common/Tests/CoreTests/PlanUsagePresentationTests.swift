import Core
import Transport
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func state() -> PlanUsageState {
    PlanUsageState(
        accounts: [
            PlanUsageAccount(id: .claude, provider: .claude, enabled: true, status: .ok, limits: [
                PlanUsageLimit(window: .session, usedPercent: 42.4, resetsAt: now.addingTimeInterval(7_800)),
                PlanUsageLimit(window: .weekly, usedPercent: 91),
                PlanUsageLimit(window: .weekly, model: "Fable", usedPercent: 7),
            ], fetchedAt: now.addingTimeInterval(-90)),
            PlanUsageAccount(id: .codex, provider: .codex, enabled: true, status: .ok, limits: [
                PlanUsageLimit(window: .weekly, usedPercent: 12, resetsAt: now.addingTimeInterval(-5)),
            ]),
        ],
        generatedAt: now
    )
}

@Test func statusWordingCoversEveryFailure() {
    let limited = PlanUsageAccount(id: .codex, provider: .codex, enabled: true, status: .rateLimited, retryAt: now.addingTimeInterval(240))
    #expect(PlanUsagePresentation.statusText(limited, now: now) == "Rate limited · retry in 4m 0s")
    #expect(PlanUsagePresentation.statusText(PlanUsageAccount(id: .codex, provider: .codex, enabled: true, status: .rateLimited), now: now) == "Rate limited")
    let missing = PlanUsageAccount(id: .claude, provider: .claude, enabled: false, status: .credentialsMissing, statusDetail: "No ~/.claude/.credentials.json")
    #expect(PlanUsagePresentation.statusText(missing) == "Not signed in · No ~/.claude/.credentials.json")
    #expect(PlanUsagePresentation.statusText(PlanUsageAccount(id: .claude, provider: .claude, enabled: true, status: .signInExpired)) == "Saved sign-in expired · sign in again with Claude Code")
    #expect(PlanUsagePresentation.statusText(PlanUsageAccount(id: .codex, provider: .codex, enabled: true, status: .signInRejected)) == "Sign-in rejected by the service")
    #expect(PlanUsagePresentation.statusText(PlanUsageAccount(id: .codex, provider: .codex, enabled: true, status: .failed, statusDetail: "HTTP 503")) == "Unavailable · HTTP 503")
    #expect(PlanUsagePresentation.statusText(PlanUsageAccount(id: .claude, provider: .claude, enabled: true, status: .ok)) == nil)
}

@Test func cardWordingFollowsTheHandoff() throws {
    let claude = try #require(state().account(.claude))
    #expect(claude.limits.map(PlanUsagePresentation.windowTitle) == ["SESSION · 5 HOURS", "WEEKLY · 7 DAYS", "FABLE · 7 DAYS"])
    #expect(PlanUsagePresentation.resetText(claude.limits[0], now: now) == "resets in 2h 10m")
    #expect(PlanUsagePresentation.resetText(claude.limits[1], now: now) == nil)
    #expect(PlanUsagePresentation.resetText(try #require(state().account(.codex)).limits[0], now: now) == "resets now")
    #expect(PlanUsagePresentation.updatedText(claude.fetchedAt, now: now) == "updated 1m ago")
    #expect(PlanUsagePresentation.updatedText(now.addingTimeInterval(-10), now: now) == "updated just now")
    #expect(PlanUsagePresentation.updatedText(now.addingTimeInterval(-7_200), now: now) == "updated 2h ago")
    #expect(PlanUsagePresentation.updatedText(nil, now: now) == nil)
}


@Test func percentFollowsTheStyleAndRounds() {
    let limit = PlanUsageLimit(window: .session, usedPercent: 42.4)
    #expect(PlanUsagePresentation.percent(limit, style: .used) == (42, "used"))
    #expect(PlanUsagePresentation.percent(limit, style: .remaining) == (58, "left"))
    #expect(PlanUsagePresentation.percent(PlanUsageLimit(window: .weekly, usedPercent: 100), style: .remaining) == (0, "left"))
}
