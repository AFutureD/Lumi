import Core
import Diagnostics
import Logging
import Transport
import Foundation

private let log = Logger(label: "ui")

/// State behind the Usage page: the selected range, the last report, and
/// the polling that keeps the numbers moving while the page is on screen.
/// Presets are re-derived from the clock on every load, so "Today" rolls
/// over at midnight without a click.
@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var range: UsageRange
    @Published private(set) var report: UsageReport?
    @Published private(set) var isLoading = false
    /// The last failure, cleared by the next successful load.
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastLoadedAt: Date?

    private let client: UsageClient
    private let calendar: Calendar
    private let now: () -> Date
    private let pollInterval: Duration
    private let preferences: UsageRangePreferences
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
        preferences: UsageRangePreferences = UsageRangePreferences()
    ) {
        self.client = client
        self.calendar = calendar
        self.now = now
        self.pollInterval = pollInterval
        self.preferences = preferences
        let kind = preferences.kind
        if kind == .custom, let custom = preferences.customRange {
            range = UsageRange.custom(since: custom.since, until: custom.until, now: now(), calendar: calendar)
        } else {
            range = UsageRange.preset(kind == .custom ? .today : kind, now: now(), calendar: calendar)
        }
    }

    var today: UsageDay { UsageDay(now(), calendar: calendar) }

    func select(_ kind: UsageRangeKind) {
        preferences.kind = kind
        if kind == .custom {
            let custom = preferences.customRange ?? (range.since, range.until)
            range = UsageRange.custom(since: custom.since, until: custom.until, now: now(), calendar: calendar)
        } else {
            range = UsageRange.preset(kind, now: now(), calendar: calendar)
        }
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
        do {
            let report = try await client.report(since: requested.since, until: requested.until)
            // A newer request already answered (or the range moved on): drop this one.
            guard generation == loadGeneration else { return }
            self.report = report
            errorMessage = nil
            lastLoadedAt = now()
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = (error as? IPCFailure)?.message ?? error.localizedDescription
            log.warning("usage_report_failed", metadata: .fields([
                "since": requested.since.rawValue, "until": requested.until.rawValue, "error": error,
            ]))
        }
        isLoading = false
    }
}
