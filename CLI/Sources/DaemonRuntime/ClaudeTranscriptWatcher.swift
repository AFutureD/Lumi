import Adapters
import Core
import Diagnostics
import Logging
import ServiceLifecycle
import Transport
import Foundation

private let log = Logger(label: "agent")
private let dbLog = Logger(label: "db")
private let lifecycleLog = Logger(label: "lifecycle")

/// Polls the transcripts of *active* Claude sessions so records written when
/// no hook will ever fire still reach the daemon.
///
/// Claude ingest is hook-driven: the helper reads the transcript increment on
/// every hook. A user interrupt (Esc) fires no hook, yet is recorded only in
/// the transcript — `[Request interrupted by user]`, plus any `custom-title` /
/// assistant output written after the last hook. Without this watcher such a
/// session stays Running forever. Unlike `CodexRolloutWatcher` it never scans
/// a directory: only sessions already in the repository and still active are
/// polled, so there is no first-run baseline to establish.
public actor ClaudeTranscriptWatcher: Service {
    private let repository: any SessionRepository
    private let homeDirectory: URL
    private let pollIntervalSeconds: Double
    private let maximumIncrementBytes: Int
    private let backfill: TranscriptBackfillQueue?
    private let onEvent: @Sendable (AgentIngressEvent) -> Void
    private let adapter = ClaudeAdapter()
    private var scannedFileSizes: [String: UInt64] = [:]

    public init(
        repository: any SessionRepository,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        pollIntervalSeconds: Double = 2,
        maximumIncrementBytes: Int = 32 * 1024 * 1024,
        backfill: TranscriptBackfillQueue? = nil,
        onEvent: @escaping @Sendable (AgentIngressEvent) -> Void = { _ in }
    ) {
        self.repository = repository
        self.homeDirectory = homeDirectory
        self.pollIntervalSeconds = pollIntervalSeconds
        self.maximumIncrementBytes = maximumIncrementBytes
        self.backfill = backfill
        self.onEvent = onEvent
    }

    public func run() async throws {
        lifecycleLog.info("claude_watcher_started", metadata: .fields(["poll_seconds": pollIntervalSeconds]))
        await pollUntilShutdown(everySeconds: pollIntervalSeconds) { await self.scanOnce() }
        lifecycleLog.info("claude_watcher_stopped")
    }

    public func scanOnce() async {
        let summaries: [SessionSummary]
        do {
            summaries = try await repository.listSessions(limit: 10_000)
        } catch {
            dbLog.error("claude_watcher_list_failed", metadata: .fields(["error": error]))
            return
        }
        for summary in summaries where Self.isActive(summary) {
            guard !Task.isCancelled else { return }
            do {
                try await scan(summary)
            } catch {
                log.error("claude_watcher_scan_failed", metadata: .fields(["session": summary.id.rawValue, "error": error]))
            }
        }
    }

    /// A session whose transcript can still change without a hook arriving.
    /// Parked finished sessions (`waitingForInput · idle`) are excluded: their
    /// next transcript write comes with a `UserPromptSubmit` hook anyway.
    static func isActive(_ summary: SessionSummary) -> Bool {
        guard summary.agent == .claude || summary.agent == .claudeSubagent else { return false }
        switch summary.lifecycle {
        case .starting, .running, .compacting:
            return true
        case .waitingForInput:
            return summary.phase != .idle
        case .completed, .failed, .interrupted:
            return false
        }
    }

    private func scan(_ summary: SessionSummary) async throws {
        guard let path = try await transcriptPath(for: summary) else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value else { return }
        guard needsScan(path: path, fileSize: fileSize) else { return }

        // An offline gap larger than one capped read goes to the serial
        // backfill worker whole — a tail-trimmed read would silently drop
        // the middle of the session.
        if let backfill,
           let offset = try await repository.rolloutCursor(path: path)?.byteOffset,
           offset > 0, fileSize > offset, fileSize - offset > UInt64(maximumIncrementBytes) {
            await backfill.enqueue(sessionID: summary.id, path: path)
            log.info("transcript_gap_delegated_to_backfill", metadata: .fields([
                "session": summary.id.rawValue,
                "path": path,
                "gap": fileSize - offset,
            ]))
            markScanned(path: path, fileSize: fileSize)
            return
        }

        let report = try await RichSourceCatchUp.run(
            repository: repository,
            sessionID: summary.id,
            path: path,
            adapter: adapter,
            maximumBytes: maximumIncrementBytes,
            onEvent: onEvent
        )
        if report.lines > 0 {
            // The hook-less tail: whatever reached the transcript without a
            // hook (interrupts, late output) is visible only through this line.
            log.info("transcript_scanned", metadata: .fields([
                "session": summary.id.rawValue,
                "path": path,
                "from": report.fromOffset,
                "to": report.toOffset,
                "lines": report.lines,
                "events": report.events,
                "applied": report.applied,
            ]))
        }
        markScanned(path: path, fileSize: fileSize)
    }

    /// The session's cursor names its transcript; a session that never had a
    /// successful read (it died seconds after starting) falls back to deriving
    /// the path. A subagent's sidechain transcript sits under its parent's.
    private func transcriptPath(for summary: SessionSummary) async throws -> String? {
        if let cursor = try await repository.rolloutCursor(sessionID: summary.id) {
            return cursor.path
        }
        if let (parent, agentID) = ClaudeSubagentIdentity.parse(summary.id) {
            let parentPath = try await repository.rolloutCursor(sessionID: parent)?.path
                ?? RichSourceLocator.claudeTranscript(
                    for: parent,
                    cwd: summary.workspace,
                    homeDirectory: homeDirectory
                )
            return parentPath.map {
                ClaudeSubagentIdentity.transcriptPath(parentTranscriptPath: $0, parent: parent, agentID: agentID)
            }
        }
        return RichSourceLocator.claudeTranscript(
            for: summary.id,
            cwd: summary.workspace,
            homeDirectory: homeDirectory
        )
    }

    private func needsScan(path: String, fileSize: UInt64) -> Bool {
        scannedFileSizes[path] != fileSize
    }

    private func markScanned(path: String, fileSize: UInt64) {
        scannedFileSizes[path] = fileSize
    }
}
