import Core
import Transport
import Foundation
import Testing
@testable import MacFeature

/// Saturday 2026-09-05 14:00 UTC.
private let now = Date(timeIntervalSince1970: 1_788_616_800)

@Test func presetsFollowTheCalendarWithMondayWeeks() {
    let today = UsageDay(year: 2026, month: 9, day: 5)
    #expect(UsageRange.preset(.today, now: now, calendar: utc) == UsageRange(kind: .today, since: today, until: today))
    #expect(UsageRange.preset(.thisWeek, now: now, calendar: utc) == UsageRange(kind: .thisWeek, since: UsageDay(year: 2026, month: 8, day: 31), until: today))
    #expect(UsageRange.preset(.thisMonth, now: now, calendar: utc) == UsageRange(kind: .thisMonth, since: UsageDay(year: 2026, month: 9, day: 1), until: today))
    // A Monday's week is itself; a Sunday's week started six days earlier.
    let monday = Date(timeIntervalSince1970: 1_788_616_800 + 2 * 86_400)
    #expect(UsageRange.preset(.thisWeek, now: monday, calendar: utc).since == UsageDay(year: 2026, month: 9, day: 7))
    let sunday = Date(timeIntervalSince1970: 1_788_616_800 + 86_400)
    #expect(UsageRange.preset(.thisWeek, now: sunday, calendar: utc).since == UsageDay(year: 2026, month: 8, day: 31))
}

@Test func customRangesAreClampedToTodayAndOrdered() {
    let today = UsageDay(year: 2026, month: 9, day: 5)
    let future = UsageDay(year: 2026, month: 12, day: 31)
    let past = UsageDay(year: 2026, month: 8, day: 1)
    #expect(UsageRange.custom(since: past, until: future, now: now, calendar: utc) == UsageRange(kind: .custom, since: past, until: today))
    #expect(UsageRange.custom(since: today, until: past, now: now, calendar: utc) == UsageRange(kind: .custom, since: past, until: past))
    #expect(UsageRange.custom(since: future, until: future, now: now, calendar: utc) == UsageRange(kind: .custom, since: today, until: today))
}

@Test func comparisonPeriodsMatchTheRangeKind() {
    let today = UsageDay(year: 2026, month: 9, day: 5)
    // Today → yesterday.
    let day = UsageRange.preset(.today, now: now, calendar: utc)
    #expect(day.comparison(calendar: utc) == UsageRange(kind: .custom, since: UsageDay(year: 2026, month: 9, day: 4), until: UsageDay(year: 2026, month: 9, day: 4)))
    #expect(day.comparisonLabel(calendar: utc) == "yesterday")
    // This week (Mon 31 – Sat 5) → the same days last week.
    let week = UsageRange.preset(.thisWeek, now: now, calendar: utc)
    #expect(week.comparison(calendar: utc) == UsageRange(kind: .custom, since: UsageDay(year: 2026, month: 8, day: 24), until: UsageDay(year: 2026, month: 8, day: 29)))
    #expect(week.comparisonLabel(calendar: utc) == "last week")
    // This month (Sep 1 – 5) → Aug 1 – 5.
    let month = UsageRange.preset(.thisMonth, now: now, calendar: utc)
    #expect(month.comparison(calendar: utc) == UsageRange(kind: .custom, since: UsageDay(year: 2026, month: 8, day: 1), until: UsageDay(year: 2026, month: 8, day: 5)))
    #expect(month.comparisonLabel(calendar: utc) == "last month")
    // A whole 31-day month compared with a 30-day one stops at its end.
    let october = UsageRange(kind: .thisMonth, since: UsageDay(year: 2026, month: 10, day: 1), until: UsageDay(year: 2026, month: 10, day: 31))
    #expect(october.comparison(calendar: utc) == UsageRange(kind: .custom, since: UsageDay(year: 2026, month: 9, day: 1), until: UsageDay(year: 2026, month: 9, day: 30)))
    // Custom N days → the N days before.
    let custom = UsageRange.custom(since: UsageDay(year: 2026, month: 8, day: 7), until: today, now: now, calendar: utc)
    #expect(custom.dayCount(calendar: utc) == 30)
    #expect(custom.comparison(calendar: utc) == UsageRange(kind: .custom, since: UsageDay(year: 2026, month: 7, day: 8), until: UsageDay(year: 2026, month: 8, day: 6)))
    #expect(custom.comparisonLabel(calendar: utc) == "previous 30 days")
    let single = UsageRange.custom(since: today, until: today, now: now, calendar: utc)
    #expect(single.comparisonLabel(calendar: utc) == "previous day")
}

@Test func preferencesRoundTrip() {
    let suite = "Lumi.UsageRangeTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = UsagePreferences(defaults: defaults)
    #expect(preferences.kind == .today)
    #expect(preferences.customRange == nil)
    #expect(preferences.summaryAgent == .all)
    #expect(preferences.trendMetric == .cost)
    #expect(preferences.detailGroup == .project)
    #expect(preferences.detailTimeUnit == .day)
    preferences.kind = .thisMonth
    preferences.customRange = (UsageDay(year: 2026, month: 8, day: 1), UsageDay(year: 2026, month: 8, day: 31))
    preferences.summaryAgent = .codex
    preferences.trendMetric = .tokens
    preferences.detailGroup = .time
    preferences.detailTimeUnit = .week
    #expect(preferences.kind == .thisMonth)
    #expect(preferences.customRange?.since == UsageDay(year: 2026, month: 8, day: 1))
    #expect(preferences.customRange?.until == UsageDay(year: 2026, month: 8, day: 31))
    #expect(preferences.summaryAgent == .codex && preferences.trendMetric == .tokens)
    #expect(preferences.detailGroup == .time && preferences.detailTimeUnit == .week)
    defaults.set("garbage", forKey: "Lumi.Usage.RangeKind")
    defaults.set("garbage", forKey: "Lumi.Usage.DetailGroup")
    #expect(preferences.kind == .today)
    #expect(preferences.detailGroup == .project)
}

// MARK: - Model against a scripted daemon

private final class ScriptedUsageDaemon: MacDaemonClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [IPCRequest] = []
    var failure: IPCFailure?

    func request(_ request: IPCRequest, socketPath: String, timeoutSeconds: Int64) throws -> IPCResponse {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        if let failure { return IPCResponse(status: .error, failure: failure) }
        guard request.operation == .usageReport, let since = request.since, let until = request.until else {
            return IPCResponse(status: .error, failure: IPCFailure(code: "unexpected", message: "not a usage request", retryable: false))
        }
        var comparison: UsageComparison?
        if let compareSince = request.compareSince, let compareUntil = request.compareUntil {
            comparison = UsageComparison(since: compareSince, until: compareUntil, totals: UsageSlice(costUSD: 0.5), byAgent: [])
        }
        let report = UsageReport(
            since: since, until: until, generatedAt: now,
            totals: UsageSlice(tokens: UsageTokens(input: 1), costUSD: 1, calls: 1, sessions: 1, turns: 1),
            byAgent: [], byProject: [], byModel: [],
            comparison: comparison,
            pricing: UsagePricingStatus(source: .fresh, fetchedAt: now, modelCount: 1),
            scan: UsageScanStatus(scannedFiles: 1, pendingFiles: 0, lastScanAt: now, isScanning: false)
        )
        return IPCResponse(status: .ok, usage: report)
    }
}

@MainActor
private func makeModel(daemon: ScriptedUsageDaemon) -> UsageModel {
    let suite = "Lumi.UsageModelTests.\(UUID().uuidString)"
    return UsageModel(
        client: UsageClient(client: daemon, socketPath: "/tmp/none.sock"),
        calendar: utc,
        now: { now },
        pollInterval: .seconds(3_600),
        preferences: UsagePreferences(defaults: UserDefaults(suiteName: suite)!)
    )
}

@Test @MainActor func modelLoadsTheSelectedRangeAndSurfacesFailures() async throws {
    let daemon = ScriptedUsageDaemon()
    let model = makeModel(daemon: daemon)
    #expect(model.range.kind == .today)
    await model.load()
    #expect(model.report?.since == UsageDay(year: 2026, month: 9, day: 5))
    #expect(model.report?.until == UsageDay(year: 2026, month: 9, day: 5))
    #expect(model.errorMessage == nil)
    // One request carries both the range and yesterday, the delta's comparison period.
    #expect(daemon.requests.count == 1)
    #expect(daemon.requests.last?.compareSince == UsageDay(year: 2026, month: 9, day: 4))
    #expect(daemon.requests.last?.compareUntil == UsageDay(year: 2026, month: 9, day: 4))
    #expect(model.report?.comparison?.since == UsageDay(year: 2026, month: 9, day: 4))
    #expect(model.comparisonLabel == "yesterday")

    model.setCustom(since: UsageDay(year: 2026, month: 8, day: 20), until: UsageDay(year: 2026, month: 12, day: 1))
    #expect(model.range == UsageRange(kind: .custom, since: UsageDay(year: 2026, month: 8, day: 20), until: UsageDay(year: 2026, month: 9, day: 5)))
    // A range change loads on its own; wait for that load rather than racing it.
    await model.pendingLoad?.value
    #expect(daemon.requests.last?.since == UsageDay(year: 2026, month: 8, day: 20))
    #expect(daemon.requests.last?.until == UsageDay(year: 2026, month: 9, day: 5))
    #expect(daemon.requests.last?.compareSince == UsageDay(year: 2026, month: 8, day: 3))
    #expect(daemon.requests.last?.compareUntil == UsageDay(year: 2026, month: 8, day: 19))
    #expect(model.comparisonLabel == "previous 17 days")

    daemon.failure = IPCFailure(code: "usage_unavailable", message: "The daemon runs without a usage scanner.", retryable: false)
    await model.load()
    #expect(model.errorMessage == "The daemon runs without a usage scanner.")
    // The last good report stays on screen under the error.
    #expect(model.report != nil)
    daemon.failure = nil
    await model.load()
    #expect(model.errorMessage == nil)
}

@Test @MainActor func pricingTextNamesTheTableInForce() {
    #expect(UsageViewController.pricingText(nil) == "Usage from this Mac's Claude Code and Codex transcripts")
    #expect(UsageViewController.pricingText(UsagePricingStatus(source: .builtin, modelCount: 1)) == "Prices · built-in snapshot")
    let fetched = UsagePricingStatus(source: .cached, fetchedAt: now.addingTimeInterval(-3 * 3_600), modelCount: 1)
    #expect(UsageViewController.pricingText(fetched, now: now) == "Prices · models.dev · updated 3h ago")
}
