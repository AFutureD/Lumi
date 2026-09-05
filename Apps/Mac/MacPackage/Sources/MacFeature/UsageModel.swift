import Core
import Diagnostics
import Logging
import Transport
import Foundation

private let log = Logger(label: "ui")

/// State behind the Usage page: the selected range, the last report (with
/// the comparison period the daemon folded into it), the four view choices
/// (Summary agent, trend metric, Detail grouping and time unit), and the
/// polling that keeps the numbers moving while the page is on screen.
/// Presets are re-derived from the clock on every load, so "Today" rolls
/// over at midnight without a click.
@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var range: UsageRange
    @Published private(set) var report: UsageReport?
    @Published private(set) var isLoading = false
    /// The last failure, cleared by the next successful load.
    @Published private(set) var errorMessage: String?

    /// Which agent the Summary card describes. Detail never follows it.
    @Published var summaryAgent: UsageSummaryAgent {
        didSet { preferences.summaryAgent = summaryAgent }
    }
    @Published var trendMetric: UsageTrendMetric {
        didSet { preferences.trendMetric = trendMetric }
    }
    @Published var detailGroup: UsageDetailGroup {
        didSet { preferences.detailGroup = detailGroup }
    }
    @Published var detailTimeUnit: UsageDetailTimeUnit {
        didSet { preferences.detailTimeUnit = detailTimeUnit }
    }
    /// Group rows folded in the Detail table (by row id); kept across range changes.
    @Published var collapsedGroups: Set<String> = []

    private let client: UsageClient
    let calendar: Calendar
    private let now: () -> Date
    private let pollInterval: Duration
    private let preferences: UsagePreferences
    private var isVisible = false
    private var pollTask: Task<Void, Never>?
    private var loadGeneration = 0
    /// The load a range change or Refresh kicked off; awaited by tests so
    /// they never race it with a load of their own.
    private(set) var pendingLoad: Task<Void, Never>?

    init(
        client: UsageClient = UsageClient(),
        calendar: Calendar = .current,
        now: @escaping () -> Date = { Date() },
        pollInterval: Duration = .seconds(30),
        preferences: UsagePreferences = UsagePreferences()
    ) {
        self.client = client
        self.calendar = calendar
        self.now = now
        self.pollInterval = pollInterval
        self.preferences = preferences
        range = Self.range(for: preferences.kind, preferences: preferences, now: now(), calendar: calendar)
        summaryAgent = preferences.summaryAgent
        trendMetric = preferences.trendMetric
        detailGroup = preferences.detailGroup
        detailTimeUnit = preferences.detailTimeUnit
    }

    var today: UsageDay { UsageDay(now(), calendar: calendar) }

    /// `vs yesterday` / `vs last week` / … for the current range.
    var comparisonLabel: String { range.comparisonLabel(calendar: calendar) }

    func select(_ kind: UsageRangeKind) {
        preferences.kind = kind
        range = Self.range(for: kind, preferences: preferences, now: now(), calendar: calendar)
        log.info("usage_range_selected", metadata: .fields(["kind": kind.rawValue, "since": range.since.rawValue, "until": range.until.rawValue]))
        pendingLoad = Task { await load() }
    }

    func setCustom(since: UsageDay, until: UsageDay) {
        let clamped = UsageRange.custom(since: since, until: until, now: now(), calendar: calendar)
        preferences.kind = .custom
        preferences.customRange = (clamped.since, clamped.until)
        guard clamped != range else { return }
        range = clamped
        pendingLoad = Task { await load() }
    }

    /// Polling runs only while the page is on screen; showing it loads at once.
    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        pollTask?.cancel()
        pollTask = nil
        guard visible else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.load()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(30))
            }
        }
    }

    /// Toolbar Refresh: an immediate load of the current range.
    func refresh() {
        pendingLoad = Task { await load() }
    }

    func load() async {
        // Presets follow the clock; a stale "Today" would silently show yesterday.
        if range.kind != .custom {
            let fresh = UsageRange.preset(range.kind, now: now(), calendar: calendar)
            if fresh != range { range = fresh }
        }
        loadGeneration += 1
        let generation = loadGeneration
        let requested = range
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let report = try await client.report(range: requested, comparison: requested.comparison(calendar: calendar))
            // A newer request already answered (or the range moved on): drop this one.
            guard generation == loadGeneration else { return }
            self.report = report
            errorMessage = nil
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = (error as? IPCFailure)?.message ?? error.localizedDescription
            log.warning("usage_report_failed", metadata: .fields([
                "since": requested.since.rawValue, "until": requested.until.rawValue, "error": error,
            ]))
        }
    }

    /// The saved kind as a range: the remembered dates for Custom (today when
    /// none were saved), the calendar preset otherwise.
    private static func range(for kind: UsageRangeKind, preferences: UsagePreferences, now: Date, calendar: Calendar) -> UsageRange {
        guard kind == .custom else { return UsageRange.preset(kind, now: now, calendar: calendar) }
        let today = UsageDay(now, calendar: calendar)
        let custom = preferences.customRange ?? (today, today)
        return UsageRange.custom(since: custom.since, until: custom.until, now: now, calendar: calendar)
    }
}
