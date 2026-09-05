import Core
import Diagnostics
import Logging
import ServiceLifecycle
import Transport
import Foundation

private let log = Logger(label: "lifecycle")

/// Keeps the models.dev price table current: a cached `api.json` beside the
/// database, refetched once it is older than the refresh interval, and the
/// compiled-in snapshot when there is nothing else. Failures keep whatever
/// table is in force — a stale price beats no price — and are logged.
public actor ModelPriceRefresher: Service {
    public static let sourceURL = URL(string: "https://models.dev/api.json")!
    public static let refreshInterval: TimeInterval = 24 * 60 * 60

    private let cachePath: String
    private let fetchEnabled: Bool
    private let session: URLSession
    private let checkIntervalSeconds: Double
    private var table: ModelPriceTable
    private var status: UsagePricingStatus
    private var didLoadCache = false

    public init(
        cachePath: String,
        fetchEnabled: Bool,
        session: URLSession = .shared,
        checkIntervalSeconds: Double = 15 * 60
    ) {
        self.cachePath = cachePath
        self.fetchEnabled = fetchEnabled
        self.session = session
        self.checkIntervalSeconds = checkIntervalSeconds
        table = .builtin
        status = UsagePricingStatus(source: .builtin, fetchedAt: nil, modelCount: ModelPriceTable.builtin.modelCount)
    }

    public func current() -> (table: ModelPriceTable, status: UsagePricingStatus) {
        (table, status)
    }

    public func run() async throws {
        await loadCache()
        await pollUntilShutdown(everySeconds: checkIntervalSeconds) { await self.refreshIfStale() }
    }

    /// The on-disk copy, whatever its age: usable immediately, refreshed later.
    /// Once per process — Lumen calls it ahead of the scanner, `run()` again.
    public func loadCache() async {
        guard !didLoadCache else { return }
        didLoadCache = true
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: cachePath),
              let modifiedAt = attributes[.modificationDate] as? Date,
              let data = FileManager.default.contents(atPath: cachePath) else { return }
        do {
            let cached = try ModelPriceTable(modelsDevJSON: data)
            table = cached
            status = UsagePricingStatus(
                source: Date().timeIntervalSince(modifiedAt) < Self.refreshInterval ? .fresh : .cached,
                fetchedAt: modifiedAt,
                modelCount: cached.modelCount
            )
            log.info("model_prices_loaded", metadata: .fields([
                "source": status.source.rawValue, "models": cached.modelCount, "path": cachePath,
            ]))
        } catch {
            log.error("model_prices_cache_unreadable", metadata: .fields(["path": cachePath, "error": error]))
        }
    }

    /// Fetches when nothing was fetched within the refresh interval.
    public func refreshIfStale(now: Date = Date()) async {
        guard fetchEnabled else { return }
        if let fetchedAt = status.fetchedAt, now.timeIntervalSince(fetchedAt) < Self.refreshInterval { return }
        await refresh(now: now)
    }

    public func refresh(now: Date = Date()) async {
        var request = URLRequest(url: Self.sourceURL)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let fetched = try ModelPriceTable(modelsDevJSON: data)
            // Atomic replace: a partial write must never become the cache.
            try data.write(to: URL(fileURLWithPath: cachePath), options: .atomic)
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: cachePath)
            table = fetched
            status = UsagePricingStatus(source: .fresh, fetchedAt: now, modelCount: fetched.modelCount)
            log.info("model_prices_refreshed", metadata: .fields(["models": fetched.modelCount, "bytes": data.count]))
        } catch {
            // Keep the table in force; the age shown to the page stays honest.
            if status.source == .fresh { status.source = .cached }
            log.error("model_prices_fetch_failed", metadata: .fields([
                "error": error, "in_force": status.source.rawValue,
            ]))
        }
    }
}
