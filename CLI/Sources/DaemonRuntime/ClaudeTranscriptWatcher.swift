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
///
/// The same pass closes the subagents a gone process left behind
/// (`ClaudeSubagentIdentity.leftBehindAt`): they write nothing when their
/// process exits or is killed, so nothing else would ever stop them reading
/// Running — and keeping their parked parent Running with them.
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
        guard !Task.isCancelled else { return }
        await closeSubagentsLeftBehind(among: summaries)
    }

    /// After the transcripts are caught up — so a subagent's last records
    /// are in before it is closed — every Claude subagent that still reads
    /// as at work is checked against its owning session's process
    /// (`ClaudeSubagentIdentity.leftBehindAt`). One state-only event closes
    /// it, `interrupted · idle`, through the same path as every event, so
    /// the mirrors close it too. The event id is fresh each time: the check
    /// is a state, and a subagent rebuilt from its transcript must be
    /// closable again.
    private func closeSubagentsLeftBehind(among listed: [SessionSummary]) async {
        let candidates = listed.filter { $0.agent == .claudeSubagent && Self.isActive($0) }
        guard !candidates.isEmpty else { return }
        do {
            // The pass above may have moved any of them; read them again.
            let summaries = try await repository.listSessions(limit: 10_000)
            let byID = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var markersByOwner: [SessionID: ClaudeSubagentIdentity.ProcessMarkers] = [:]
            for candidate in candidates {
                guard !Task.isCancelled else { return }
                guard let subagent = byID[candidate.id], subagent.isAtWork,
                      let owner = ClaudeSubagentIdentity.processOwner(of: subagent, in: byID) else { continue }
                let markers: ClaudeSubagentIdentity.ProcessMarkers
                if let known = markersByOwner[owner.id] {
                    markers = known
                } else {
                    markers = try await processMarkers(of: owner.id)
                    markersByOwner[owner.id] = markers
                }
                guard let closedAt = ClaudeSubagentIdentity.leftBehindAt(subagent, owner: owner, markers: markers) else {
                    continue
                }
                let event = AgentIngressEvent(
                    eventID: EventID("claude-subagent-left-behind:\(subagent.id.rawValue):\(UUID().uuidString)"),
                    sessionID: subagent.id,
                    agent: .claudeSubagent,
                    occurredAt: closedAt,
                    lifecycle: .interrupted,
                    phase: .idle
                )
                let applied = try await repository.apply(event)
                if applied { onEvent(event) }
                log.info("subagent_closed_with_its_process", metadata: .fields([
                    "session": subagent.id.rawValue,
                    "owner": owner.id.rawValue,
                    "owner_lifecycle": owner.lifecycle.rawValue,
                    "owner_started": markers.startSource ?? "-",
                    "owner_ended": markers.endReason ?? "-",
                    "applied": applied,
                ]))
            }
        } catch {
            log.error("claude_watcher_close_failed", metadata: .fields(["error": error]))
        }
    }

    /// The owning session's latest start and end, read from its two marker
    /// rows (one row per kind, rewritten by each newer start / end).
    private func processMarkers(of owner: SessionID) async throws -> ClaudeSubagentIdentity.ProcessMarkers {
        let startedID = TimelineItemIDs.sessionMarker(owner, .sessionStarted)
        let endedID = TimelineItemIDs.sessionMarker(owner, .sessionEnded)
        let rows = try await repository.timelineItems(id: owner, itemIDs: [startedID, endedID])?.timeline ?? []
        func marker(_ id: TimelineItemID) -> (at: Date, detail: String?)? {
            guard let item = rows.first(where: { $0.id == id }),
                  case let .sessionMarker(payload) = item.payload else { return nil }
            return (item.occurredAt, payload.detail)
        }
        let started = marker(startedID)
        let ended = marker(endedID)
        return ClaudeSubagentIdentity.ProcessMarkers(
            startedAt: started?.at,
            startSource: started?.detail,
            endedAt: ended?.at,
            endReason: ended?.detail
        )
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
