import Core
import Diagnostics
import Logging
import Transport
import Foundation

private let log = Logger(label: "usage")

/// Builds `UsageReport`s for both askers — the Mac over IPC (two explicit
/// day ranges) and iPhones over the Relay (a calendar preset the daemon
/// expands with its own local days) — so the validation, the bucket read
/// and the fold live in one place.
public struct UsageReporting: Sendable {
    /// Longest range: a year and a day, so "this year" always fits.
    public static let maximumRangeDays = 366

    public enum Failure: Error, Equatable, Sendable {
        /// `since > until`, or more than `maximumRangeDays` days.
        case invalidRange(comparison: Bool)
    }

    private let store: any UsageStore
    private let scanner: UsageScanService
    private let prices: ModelPriceRefresher
    private let calendar: Calendar

    public init(store: any UsageStore, scanner: UsageScanService, prices: ModelPriceRefresher, calendar: Calendar = .current) {
        self.store = store
        self.scanner = scanner
        self.prices = prices
        self.calendar = calendar
    }

    /// A preset in this Mac's calendar, with the design's comparison period.
    public func report(preset: UsageRangePreset, now: Date) async throws -> UsageReport {
        let range = UsageRange.expand(preset, now: now, calendar: calendar)
        let comparison = range.comparison(calendar: calendar)
        return try await report(since: range.since, until: range.until, compareSince: comparison?.since, compareUntil: comparison?.until, now: now)
    }

    public func report(since: UsageDay, until: UsageDay, compareSince: UsageDay?, compareUntil: UsageDay?, now: Date) async throws -> UsageReport {
        guard since <= until, let days = since.days(until: until), days < Self.maximumRangeDays else {
            throw Failure.invalidRange(comparison: false)
        }
        // The optional comparison period is validated like the main one.
        var comparison: (since: UsageDay, until: UsageDay, buckets: [UsageBucket])?
        if let compareSince, let compareUntil {
            guard compareSince <= compareUntil, let span = compareSince.days(until: compareUntil), span < Self.maximumRangeDays else {
                throw Failure.invalidRange(comparison: true)
            }
            comparison = (compareSince, compareUntil, try await store.buckets(since: compareSince, until: compareUntil))
        }
        let buckets = try await store.buckets(since: since, until: until)
        let prices = await prices.current()
        let scan = await scanner.status()
        let calendar = calendar
        // Folding a month of buckets is CPU work; keep it off the caller's
        // actor so hook frames are not queued behind it.
        let report = await Task.detached(priority: .userInitiated) { [comparison] in
            UsageReportBuilder.build(
                buckets: buckets,
                prices: prices.table,
                since: since,
                until: until,
                comparison: comparison,
                generatedAt: now,
                pricing: prices.status,
                scan: scan,
                calendar: calendar
            )
        }.value
        log.debug("usage_report_built", metadata: .fields([
            "since": since.rawValue, "until": until.rawValue,
            "buckets": buckets.count, "projects": report.byProject.count, "models": report.byModel.count,
            "days": report.byDay.count, "trend": report.trend.count, "trend_unit": report.trendUnit.rawValue,
            "comparison": comparison?.buckets.count ?? 0,
        ]))
        return report
    }
}
