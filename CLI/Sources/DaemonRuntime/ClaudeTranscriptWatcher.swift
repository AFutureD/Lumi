import Adapters
import Core
import Diagnostics
import Logging
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
public final class ClaudeTranscriptWatcher: @unchecked Sendable {
    private let repository: any SessionRepository
    private let homeDirectory: URL
    private let pollIntervalSeconds: Double
    private let maximumIncrementBytes: Int
    private let onEvent: @Sendable (AgentIngressEvent) -> Void
    private let adapter = ClaudeAdapter()
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var scannedFileSizes: [String: UInt64] = [:]

    public init(
        repository: any SessionRepository,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        pollIntervalSeconds: Double = 2,
        maximumIncrementBytes: Int = 32 * 1024 * 1024,
        onEvent: @escaping @Sendable (AgentIngressEvent) -> Void = { _ in }
    ) {
        self.repository = repository
        self.homeDirectory = homeDirectory
        self.pollIntervalSeconds = pollIntervalSeconds
        self.maximumIncrementBytes = maximumIncrementBytes
        self.onEvent = onEvent
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
        }
        lifecycleLog.info("claude_watcher_started", metadata: .fields(["poll_seconds": pollIntervalSeconds]))
    }

    public func stop() {
        lock.lock()
        let currentTask = task
        task = nil
        lock.unlock()
        currentTask?.cancel()
        if currentTask != nil {
            lifecycleLog.info("claude_watcher_stopped")
        }
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

        let cursor = try await repository.rolloutCursor(path: path)
        let turns = try await repository.sessionDetail(id: summary.id, cursor: nil, limit: 1)?.turns ?? []
        let read = try RichSourceReader.read(
            path: path,
            sessionID: summary.id,
            adapter: adapter,
            fromOffset: cursor?.byteOffset ?? 0,
            initialTurnID: (turns.last(where: { $0.isOpen }) ?? turns.last)?.id,
            maximumBytes: maximumIncrementBytes
        )
        var applied = 0
        for event in read.events {
            if try await repository.apply(event) {
                applied += 1
                onEvent(event)
            }
        }
        if read.lines > 0 || read.cursor.byteOffset != cursor?.byteOffset {
            try await repository.saveRolloutCursor(read.cursor)
        }
        if read.lines > 0 {
            // The hook-less tail: whatever reached the transcript without a
            // hook (interrupts, late output) is visible only through this line.
            log.info("transcript_scanned", metadata: .fields([
                "session": summary.id.rawValue,
                "path": path,
                "from": cursor?.byteOffset ?? 0,
                "to": read.cursor.byteOffset,
                "lines": read.lines,
                "events": read.events.count,
                "applied": applied,
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
        lock.lock()
        defer { lock.unlock() }
        return scannedFileSizes[path] != fileSize
    }

    private func markScanned(path: String, fileSize: UInt64) {
        lock.lock()
        scannedFileSizes[path] = fileSize
        lock.unlock()
    }

    private func run() async {
        while !Task.isCancelled {
            await scanOnce()
            do {
                try await Task.sleep(for: .milliseconds(Int64(max(250, pollIntervalSeconds * 1_000))))
            } catch {
                return
            }
        }
    }
}
