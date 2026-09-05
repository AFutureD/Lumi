import Adapters
import Core
import Diagnostics
import Logging
import ServiceLifecycle
import Transport
import Foundation

private let log = Logger(label: "agent")
private let lifecycleLog = Logger(label: "lifecycle")

/// Keeps the usage buckets in step with the agents' own transcript files.
///
/// Independent of Session ingest by design: it walks the whole transcript
/// roots (every Claude project, the Codex sessions and archived sessions
/// trees), so usage covers sessions Lumi never saw — filtered ghosts,
/// history from before Lumi was installed, runs on other machines synced
/// into `~/.claude`. Each file has its own cursor, keyed by inode so a
/// rollout Codex archives continues where it left off; a poll only opens
/// files whose size or mtime moved, and a file whose leading bytes changed
/// is read again from the start. Not latency-bound: the page tolerates a
/// poll interval of tens of seconds, and the first full scan of a large
/// history yields between files so hook ingest stays responsive.
public actor UsageScanService: Service {
    public struct Root: Hashable, Sendable {
        public let directory: URL
        public let source: AgentProvider

        public init(directory: URL, source: AgentProvider) {
            self.directory = directory
            self.source = source
        }
    }

    private struct Candidate {
        let identity: String
        let path: String
        let source: AgentProvider
        let size: UInt64
        let modifiedAt: Date
    }

    private struct Known {
        let path: String
        let size: UInt64
        let modifiedAtMilliseconds: Int64
    }

    private let roots: [Root]
    private let store: any UsageStore
    /// The price table in force, consulted per call for its long-context
    /// band: the band is part of the bucket key and is decided once, here.
    private let priceTable: @Sendable () async -> ModelPriceTable
    private let pollIntervalSeconds: Double
    /// `(size, mtime)` of every file the store already holds, by identity:
    /// loaded from the store once, then kept in step as files are read.
    private var known: [String: Known] = [:]
    private var knownLoaded = false
    private var pendingFiles = 0
    private var lastScanAt: Date?
    private var isScanning = false

    public init(
        roots: [Root],
        store: any UsageStore,
        priceTable: @escaping @Sendable () async -> ModelPriceTable = { .builtin },
        pollIntervalSeconds: Double = 30
    ) {
        self.roots = roots
        self.store = store
        self.priceTable = priceTable
        self.pollIntervalSeconds = pollIntervalSeconds
    }

    public func run() async throws {
        lifecycleLog.info("usage_scanner_started", metadata: .fields([
            "roots": roots.map(\.directory.path).joined(separator: ","),
            "poll_seconds": pollIntervalSeconds,
        ]))
        await pollUntilShutdown(everySeconds: pollIntervalSeconds) { await self.scanOnce() }
        lifecycleLog.info("usage_scanner_stopped")
    }

    /// What the report tells the page about scan progress.
    public func status() -> UsageScanStatus {
        UsageScanStatus(
            scannedFiles: known.count,
            pendingFiles: pendingFiles,
            lastScanAt: lastScanAt,
            isScanning: isScanning
        )
    }

    /// One pass over every root: list, diff against the cursors, read what
    /// moved. Public so tests and the first launch can drive it directly.
    public func scanOnce() async {
        isScanning = true
        defer { isScanning = false }
        let started = ContinuousClock.now
        if !knownLoaded {
            do {
                let cursors = try await store.cursors()
                known = Dictionary(uniqueKeysWithValues: cursors.map {
                    ($0.identity, Known(path: $0.path, size: $0.fileSize, modifiedAtMilliseconds: Self.milliseconds($0.modifiedAt)))
                })
                knownLoaded = true
            } catch {
                log.error("usage_cursors_unavailable", metadata: .fields(["error": error]))
                return
            }
        }
        let listed = roots.flatMap { files(in: $0) }
        // A file that only moved (Codex `archive`) is not re-read; its
        // cursor just learns the new path.
        for candidate in listed {
            guard let entry = known[candidate.identity], entry.path != candidate.path else { continue }
            await relocate(candidate, from: entry)
        }
        // Newest first: on a first scan the page is already open, and the
        // recent days of both agents should land before the archive does.
        let candidates = listed.filter { candidate in
            guard let entry = known[candidate.identity] else { return true }
            return entry.size != candidate.size
                || entry.modifiedAtMilliseconds != Self.milliseconds(candidate.modifiedAt)
        }.sorted { $0.modifiedAt > $1.modifiedAt }
        pendingFiles = candidates.count
        guard !candidates.isEmpty else {
            lastScanAt = Date()
            return
        }
        log.info("usage_scan_started", metadata: .fields(["files": candidates.count]))
        var records = 0
        var applied = 0
        var failed = 0
        for candidate in candidates {
            guard !Task.isCancelled else { return }
            do {
                let result = try await scan(candidate)
                records += result.records
                applied += result.applied
            } catch {
                failed += 1
                log.error("usage_file_scan_failed", metadata: .fields(["path": candidate.path, "error": error]))
            }
            pendingFiles -= 1
            await Task.yield()
        }
        lastScanAt = Date()
        log.info("usage_scan_finished", metadata: .fields([
            "files": candidates.count,
            "records": records,
            "applied": applied,
            "failed": failed,
            "ms": Int((ContinuousClock.now - started) / .milliseconds(1)),
        ]))
    }

    private func relocate(_ candidate: Candidate, from entry: Known) async {
        do {
            guard var cursor = try await store.cursor(identity: candidate.identity) else { return }
            cursor.path = candidate.path
            try await store.apply(records: [], cursor: cursor)
            known[candidate.identity] = Known(path: candidate.path, size: entry.size, modifiedAtMilliseconds: entry.modifiedAtMilliseconds)
            log.debug("usage_file_moved", metadata: .fields(["from": entry.path, "to": candidate.path]))
        } catch {
            log.error("usage_file_move_failed", metadata: .fields(["path": candidate.path, "error": error]))
        }
    }

    private func scan(_ candidate: Candidate) async throws -> (records: Int, applied: Int) {
        let cursor = try await store.cursor(identity: candidate.identity)
        var offset: UInt64 = 0
        var state = UsageScanState()
        if let cursor {
            // A shorter file, a same-size file with a new mtime, or new
            // leading bytes: not an append. Start over with fresh state — the
            // dedupe keys keep the re-read from counting anything twice.
            let reason: String? = if candidate.size < cursor.byteOffset {
                "shrunk"
            } else if cursor.fileSize == candidate.size,
                      Self.milliseconds(cursor.modifiedAt) != Self.milliseconds(candidate.modifiedAt) {
                "touched"
            } else if try UsageFileIdentity.prefixHash(path: candidate.path, length: cursor.prefixLength) != cursor.prefixHash {
                "prefix"
            } else {
                nil
            }
            if let reason {
                log.warning("usage_file_rewritten", metadata: .fields([
                    "path": candidate.path, "reason": reason, "offset": cursor.byteOffset, "size": candidate.size,
                ]))
            } else {
                offset = cursor.byteOffset
                state = cursor.state
            }
        }
        // Off the actor: a large transcript would otherwise hold a
        // cooperative thread for the whole read and parse.
        let read = try await Task.detached(priority: .utility) { [offset, state] in
            try UsageFileReader.read(path: candidate.path, source: candidate.source, fromOffset: offset, state: state)
        }.value
        let prefixLength = Int(min(UInt64(UsageFileIdentity.prefixLimit), read.fileSize))
        let prefixHash = try UsageFileIdentity.prefixHash(path: candidate.path, length: prefixLength) ?? ""
        let prices = await priceTable()
        let records = read.records.map { record in
            var classified = record
            classified.tier = prices.tier(for: record.model, agent: record.agent.provider, context: record.context)
            return classified
        }
        let applied = try await store.apply(records: records, cursor: UsageCursor(
            identity: candidate.identity,
            path: candidate.path,
            source: candidate.source,
            byteOffset: read.byteOffset,
            fileSize: read.fileSize,
            modifiedAt: candidate.modifiedAt,
            prefixLength: prefixLength,
            prefixHash: prefixHash,
            state: read.state
        ))
        known[candidate.identity] = Known(path: candidate.path, size: candidate.size, modifiedAtMilliseconds: Self.milliseconds(candidate.modifiedAt))
        if read.lines > 0 {
            log.debug("usage_file_scanned", metadata: .fields([
                "path": candidate.path,
                "from": offset,
                "to": read.byteOffset,
                "lines": read.lines,
                "rejected": read.rejectedLines,
                "records": read.records.count,
                "applied": applied,
            ]))
        }
        return (read.records.count, applied)
    }

    /// The root's `.jsonl` files with the identity, size and mtime the
    /// change detection keys on.
    private func files(in root: Root) -> [Candidate] {
        jsonlFiles(under: root.directory).map { file in
            let path = root.directory.appendingPathComponent(file.relativePath).path
            return Candidate(
                identity: UsageFileIdentity.identity(source: root.source, attributes: file.attributes, path: path),
                path: path,
                source: root.source,
                size: (file.attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                modifiedAt: file.attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
            )
        }
    }

    /// File mtimes round-trip through SQLite with sub-microsecond noise;
    /// a millisecond is the finest change worth reacting to.
    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
