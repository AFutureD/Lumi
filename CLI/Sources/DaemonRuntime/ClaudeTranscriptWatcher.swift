import Adapters
import Core
import Diagnostics
import Logging
import ServiceLifecycle
import Synchronization
import Transport
import Foundation

private let log = Logger(label: "agent")
private let dbLog = Logger(label: "db")
private let lifecycleLog = Logger(label: "lifecycle")

/// Keeps Claude sessions in step with their transcripts when no hook says
/// so.
///
/// Claude ingest is hook-driven: every hook reads the transcript increment.
/// A user interrupt (Esc) fires no hook, yet is recorded only in the
/// transcript — `[Request interrupted by user]`, plus any `custom-title` /
/// assistant output written after the last hook. Without this watcher such a
/// session stays Running forever; so does one whose hooks arrived while the
/// daemon was away.
///
/// It does not poll. `SourceFileMonitor` names the transcripts that moved
/// (Claude Code closes a transcript after every write, so directory events
/// alone already hear each one; the file-level watch makes that independent
/// of how the writer handles the file), and a slow reconcile pass takes a
/// full inventory.
///
/// Two rules decide what is read:
///
/// - **Which sessions.** Only sessions the repository already holds. A
///   transcript names its session by its path (`<session>.jsonl`, or
///   `<parent>/subagents/agent-<id>.jsonl`); one the repository does not know
///   is left alone. Claude sessions enter Lumi through hooks, so there is no
///   first-run baseline to establish.
/// - **Which writes.** Any write to a known session's transcript, whatever
///   the session's state reads. A parked or ended session whose file moves
///   has a live writer; its displayed state never decides whether the write
///   is read. The first pass after launch therefore also brings in what was
///   written while the daemon was down.
///
/// The same watcher closes the subagents a gone process left behind
/// (`ClaudeSubagentIdentity.leftBehindAt`): they write nothing when their
/// process exits or is killed, so nothing else would ever stop them reading
/// Running — and keeping their parked parent Running with them. That is
/// judged when it can change: a session's start or end marker moves, a
/// subagent's own record is applied (`noteApplied`), and on every full pass.
public actor ClaudeTranscriptWatcher: Service {
    private struct SubagentChecks: Sendable {
        /// Subagents whose own record was just applied.
        var subagents: Set<SessionID> = []
        /// A Claude session started or ended: any of its subagents may now
        /// be left behind.
        var ownerMoved = false
        /// Sessions that just became known while their transcript was
        /// waiting, with the transcript's path.
        var arrived: [SessionID: String] = [:]

        /// Puts back what was taken and could not be answered.
        mutating func merge(_ other: SubagentChecks) {
            subagents.formUnion(other.subagents)
            ownerMoved = ownerMoved || other.ownerMoved
            arrived.merge(other.arrived) { current, _ in current }
        }
    }

    private let repository: any SessionRepository
    private let projectsDirectory: URL
    private let maximumIncrementBytes: Int
    private let backfill: TranscriptBackfillQueue?
    private let inventory: SourceInventory?
    private let onEvent: @Sendable (AgentIngressEvent) -> Void
    private let adapter = ClaudeAdapter()
    private let monitor: SourceFileMonitor
    private let hotWindowSeconds: Double
    private let subagentChecks = Mutex(SubagentChecks())
    /// Transcripts under the root whose session the repository did not hold
    /// when they were looked at, by the session their path names. When that
    /// session's first event is applied (`noteApplied`) the transcript is
    /// looked at again — it is not left to its next write.
    private let awaitedSessions = Mutex<[SessionID: String]>([:])
    private var scannedFileSizes: [String: UInt64] = [:]
    /// How many full passes have finished — the first is the launch pass.
    private(set) var completedPasses = 0

    /// - Parameters:
    ///   - projectsDirectory: Claude's transcript root; defaults to
    ///     `<home>/.claude/projects`.
    ///   - reconcileIntervalSeconds: how often a full inventory runs.
    ///   - hotWindowSeconds: a transcript written this recently is watched.
    ///   - watchLimit: how many files may be watched at once.
    ///   - inventory: a walk shared with the other slow passes; `nil` walks
    ///     the root itself every time.
    public init(
        repository: any SessionRepository,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        projectsDirectory: URL? = nil,
        reconcileIntervalSeconds: Double = 30,
        hotWindowSeconds: Double = 24 * 60 * 60,
        watchLimit: Int = 256,
        maximumIncrementBytes: Int = 32 * 1024 * 1024,
        backfill: TranscriptBackfillQueue? = nil,
        inventory: SourceInventory? = nil,
        onEvent: @escaping @Sendable (AgentIngressEvent) -> Void = { _ in }
    ) {
        self.repository = repository
        let projects = projectsDirectory
            ?? homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
        self.projectsDirectory = projects
        self.hotWindowSeconds = hotWindowSeconds
        self.maximumIncrementBytes = maximumIncrementBytes
        self.backfill = backfill
        self.inventory = inventory
        self.onEvent = onEvent
        let rootPath = projects.path
        monitor = SourceFileMonitor(
            root: projects,
            accepts: { isSourceFile($0, underRoot: rootPath) },
            reconcileInterval: .milliseconds(Int64(max(1, reconcileIntervalSeconds) * 1_000)),
            watchLimit: watchLimit
        )
    }

    public func run() async throws {
        // Listen first, then take inventory: a write that lands during the
        // pass is either seen by it or announced after it.
        let listening = monitor.start()
        lifecycleLog.info("claude_watcher_started", metadata: .fields([
            "root": projectsDirectory,
            "directory_events": listening,
            "reconcile_seconds": Int(monitor.reconcileInterval / .seconds(1)),
            "watch_limit": monitor.watchLimit,
        ]))
        await scanOnce()
        await cancelWhenGracefulShutdown {
            await withDiscardingTaskGroup { group in
                group.addTask { await self.monitor.runReconcileClock() }
                group.addTask {
                    while let batch = await self.monitor.next() {
                        await self.handle(batch)
                    }
                }
            }
        }
        monitor.stop()
        lifecycleLog.info("claude_watcher_stopped")
    }

    /// Every applied event passes here (the daemon's publish path), so the
    /// watcher acts when an answer may have changed instead of asking on a
    /// timer: a subagent may now be left behind, or a session has arrived
    /// whose transcript was set aside as unknown. Non-suspending: it records
    /// the question and wakes the watcher.
    public nonisolated func noteApplied(_ event: AgentIngressEvent) {
        guard event.agent == .claude || event.agent == .claudeSubagent else { return }
        let arrivedAt = awaitedSessions.withLock { $0.removeValue(forKey: event.sessionID) }
        let isMarker = if case .sessionMarker = event.timelineItem?.payload { true } else { false }
        guard arrivedAt != nil || event.agent == .claudeSubagent || isMarker else { return }
        subagentChecks.withLock { checks in
            if let arrivedAt { checks.arrived[event.sessionID] = arrivedAt }
            if event.agent == .claudeSubagent { checks.subagents.insert(event.sessionID) }
            if event.agent == .claude, isMarker { checks.ownerMoved = true }
        }
        monitor.signal()
    }

    /// One full pass over an inventory taken now — the level-triggered
    /// resync. Runs at launch, on the reconcile clock, and when directory
    /// events were dropped. Public so tests and the first launch can drive
    /// it.
    public func scanOnce() async {
        // What `noteApplied` asked before the list below is read is answered
        // by this pass. What it asks while the pass runs stays asked.
        let asked = subagentChecks.withLock { pending in
            defer { pending = SubagentChecks() }
            return pending
        }
        let summaries: [SessionSummary]
        do {
            summaries = try await repository.listSessions(limit: 10_000)
        } catch {
            subagentChecks.withLock { $0.merge(asked) }
            dbLog.error("claude_watcher_list_failed", metadata: .fields(["error": error]))
            return
        }
        // Working sessions by their own cursor: their transcript may live
        // outside the projects root (another `CLAUDE_CONFIG_DIR`).
        var workingPaths: [(path: String, sessionID: SessionID)] = []
        for summary in summaries where Self.isActive(summary) {
            guard let path = await transcriptPath(for: summary) else { continue }
            workingPaths.append((path, summary.id))
        }
        let files = inventory?.freshFiles(under: projectsDirectory) ?? jsonlFiles(under: projectsDirectory)
        let root = projectsDirectory.path

        // Watch before reading, for the same reason the directory events
        // start before the inventory: a write that lands while a file is
        // being read must still be announced. One rule for every file,
        // working session or not: written within the window, most recent
        // first. A session that reads Working but has written nothing for a
        // day holds no descriptor; the pass below still reads it.
        let cutoff = Date().addingTimeInterval(-hotWindowSeconds)
        var activity: [String: Date] = [:]
        for file in files where file.modifiedAt >= cutoff {
            activity[root + "/" + file.relativePath] = file.modifiedAt
        }
        for working in workingPaths where activity[working.path] == nil {
            if let modified = fileModificationDate(atPath: working.path), modified >= cutoff {
                activity[working.path] = modified
            }
        }
        monitor.setWatched(activity.sorted { $0.value > $1.value }.map { (path: $0.key, activity: $0.value) })

        var present = Set(workingPaths.map(\.path))
        present.reserveCapacity(files.count + workingPaths.count)
        for working in workingPaths {
            guard !Task.isCancelled else { return }
            await transcriptChanged(atPath: working.path, sessionID: working.sessionID)
        }
        // Every transcript under the root whose size is not the one last
        // read — on the first pass, all of them.
        for file in files {
            guard !Task.isCancelled else { return }
            let path = root + "/" + file.relativePath
            present.insert(path)
            guard scannedFileSizes[path] != file.size else { continue }
            await transcriptChanged(atPath: path, sessionID: nil)
        }
        scannedFileSizes = scannedFileSizes.filter { present.contains($0.key) }
        awaitedSessions.withLock { awaited in
            awaited = awaited.filter { present.contains($0.value) }
        }
        // A session that arrived while its transcript waited: read it now.
        for (sessionID, path) in asked.arrived {
            guard !Task.isCancelled else { return }
            await transcriptChanged(atPath: path, sessionID: sessionID, lookingAgain: true)
        }
        log.debug("transcripts_reconciled", metadata: .fields([
            "files": files.count,
            "working": workingPaths.count,
            "watched": monitor.watchedCount,
        ]))

        guard !Task.isCancelled else { return }
        await closeSubagentsLeftBehind(among: summaries)
        completedPasses += 1
    }

    /// The edge-triggered half: the files the monitor named, and the
    /// subagent questions `noteApplied` recorded.
    private func handle(_ batch: SourceFileMonitor.Batch) async {
        if batch.fullPass {
            await scanOnce()
        }
        // Named files are read even after a full pass: each read asks for
        // the size again, and one already at that size costs a lookup.
        // Transcripts all — the directory events are filtered to them, and
        // nothing else is watched.
        for path in batch.paths {
            guard !Task.isCancelled else { return }
            // Being written now, so it is watched first and read second — a
            // write that lands during the read is then announced.
            monitor.ensureWatched(path)
            await transcriptChanged(atPath: path, sessionID: nil)
        }
        if batch.signalled {
            await answerSubagentChecks()
        }
    }

    /// A session whose transcript is expected to move without a hook: the
    /// ones the full pass reads by cursor wherever the file lives, and whose
    /// files are watched first. Parked finished sessions
    /// (`waitingForInput · idle`) are not in this set — a write to their
    /// transcript is still read, through the inventory and the events.
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

    // MARK: Reading

    /// Reads one transcript if its size is not the one last read and its
    /// session is one the repository holds. The size is asked for here,
    /// never taken from an inventory or an event.
    ///
    /// - Parameter lookingAgain: the file was set aside at this size because
    ///   its session was unknown, and the session has arrived since.
    private func transcriptChanged(atPath path: String, sessionID known: SessionID?, lookingAgain: Bool = false) async {
        guard let fileSize = currentFileSize(atPath: path) else {
            scannedFileSizes[path] = nil
            return
        }
        guard lookingAgain || scannedFileSizes[path] != fileSize else { return }
        // Looked at again because its session arrived: no longer set aside,
        // so a read that fails below is retried by the next full pass.
        if lookingAgain { scannedFileSizes[path] = nil }
        do {
            let cursor = try await repository.rolloutCursor(path: path)
            let sessionID: SessionID
            if let named = known ?? cursor?.sessionID {
                sessionID = named
            } else {
                let candidate = Self.sessionID(namedByTranscriptAt: path)
                // Registered before the repository is asked, so a session
                // created between the question and the answer still reports
                // in through `noteApplied`.
                awaitedSessions.withLock { $0[candidate] = path }
                guard try await repository.sessionSummary(id: candidate) != nil else {
                    // Not a session Lumi holds: Claude sessions enter
                    // through hooks only. Set aside at this size until the
                    // file moves or the session arrives.
                    scannedFileSizes[path] = fileSize
                    return
                }
                awaitedSessions.withLock { _ = $0.removeValue(forKey: candidate) }
                sessionID = candidate
            }
            if let cursor, cursor.byteOffset == fileSize {
                scannedFileSizes[path] = fileSize
                return
            }
            try await catchUp(sessionID: sessionID, path: path, fileSize: fileSize, cursor: cursor)
            scannedFileSizes[path] = fileSize
        } catch {
            log.error("claude_watcher_scan_failed", metadata: .fields(["path": path, "error": error]))
        }
    }

    private func catchUp(sessionID: SessionID, path: String, fileSize: UInt64, cursor: RolloutCursor?) async throws {
        // An offline gap larger than one capped read goes to the serial
        // backfill worker whole — a tail-trimmed read would silently drop
        // the middle of the session.
        if let backfill, let offset = cursor?.byteOffset,
           offset > 0, fileSize > offset, fileSize - offset > UInt64(maximumIncrementBytes) {
            await backfill.enqueue(sessionID: sessionID, path: path)
            log.info("transcript_gap_delegated_to_backfill", metadata: .fields([
                "session": sessionID.rawValue,
                "path": path,
                "gap": fileSize - offset,
            ]))
            return
        }

        let report = try await RichSourceCatchUp.run(
            repository: repository,
            sessionID: sessionID,
            path: path,
            adapter: adapter,
            maximumBytes: maximumIncrementBytes,
            onEvent: onEvent
        )
        if report.lines > 0 {
            // The hook-less tail: whatever reached the transcript without a
            // hook (interrupts, late output) is visible only through this line.
            log.info("transcript_scanned", metadata: .fields([
                "session": sessionID.rawValue,
                "path": path,
                "from": report.fromOffset,
                "to": report.toOffset,
                "lines": report.lines,
                "events": report.events,
                "applied": report.applied,
            ]))
        }
    }

    /// The session a transcript's path names: `…/<session>.jsonl`, or a
    /// subagent's sidechain `…/<parent>/subagents/agent-<id>.jsonl`.
    private static func sessionID(namedByTranscriptAt path: String) -> SessionID {
        let url = URL(fileURLWithPath: path)
        let name = url.deletingPathExtension().lastPathComponent
        let directory = url.deletingLastPathComponent()
        guard directory.lastPathComponent == "subagents", name.hasPrefix("agent-") else {
            return SessionID(name)
        }
        return ClaudeSubagentIdentity.sessionID(
            parent: SessionID(directory.deletingLastPathComponent().lastPathComponent),
            agentID: String(name.dropFirst("agent-".count))
        )
    }

    /// Where a working session's transcript is, by what the store already
    /// knows: its own cursor, or — a subagent's sidechain sits under its
    /// parent's — the parent's. A session with neither has not been read
    /// yet; its transcript is found by name when it appears under the root.
    private func transcriptPath(for summary: SessionSummary) async -> String? {
        do {
            if let cursor = try await repository.rolloutCursor(sessionID: summary.id) {
                return cursor.path
            }
            if let (parent, agentID) = ClaudeSubagentIdentity.parse(summary.id),
               let parentPath = try await repository.rolloutCursor(sessionID: parent)?.path {
                return ClaudeSubagentIdentity.transcriptPath(
                    parentTranscriptPath: parentPath,
                    parent: parent,
                    agentID: agentID
                )
            }
            return nil
        } catch {
            dbLog.error("claude_watcher_cursor_failed", metadata: .fields(["session": summary.id.rawValue, "error": error]))
            return nil
        }
    }

    // MARK: Subagents left behind

    /// Answers what `noteApplied` asked since the last time. A session that
    /// arrived has a transcript waiting for it. A moved owner
    /// is a lineage question — which subagents were its process's — so the
    /// list answers it; a subagent's own record only concerns that subagent.
    private func answerSubagentChecks() async {
        let checks = subagentChecks.withLock { pending in
            defer { pending = SubagentChecks() }
            return pending
        }
        // A session that arrived while its transcript waited: read it now.
        for (sessionID, path) in checks.arrived {
            guard !Task.isCancelled else { return }
            await transcriptChanged(atPath: path, sessionID: sessionID, lookingAgain: true)
        }
        if checks.ownerMoved {
            do {
                let summaries = try await repository.listSessions(limit: 10_000)
                // Catch the sidechains up first, so a subagent's last
                // records are in before it is closed.
                for summary in summaries where summary.agent == .claudeSubagent && Self.isActive(summary) {
                    guard !Task.isCancelled else { return }
                    guard let path = await transcriptPath(for: summary) else { continue }
                    await transcriptChanged(atPath: path, sessionID: summary.id)
                }
                await closeSubagentsLeftBehind(among: summaries)
            } catch {
                dbLog.error("claude_watcher_list_failed", metadata: .fields(["error": error]))
            }
            return
        }
        for sessionID in checks.subagents {
            guard !Task.isCancelled else { return }
            await closeIfLeftBehind(sessionID)
        }
    }

    /// Every Claude subagent that still reads as at work is checked against
    /// its owning session's process (`ClaudeSubagentIdentity.leftBehindAt`).
    /// One state-only event closes it, `interrupted · idle`, through the
    /// same path as every event, so the mirrors close it too. The event id
    /// is fresh each time: the check is a state, and a subagent rebuilt from
    /// its transcript must be closable again.
    private func closeSubagentsLeftBehind(among listed: [SessionSummary]) async {
        let candidates = listed.filter { $0.agent == .claudeSubagent && Self.isActive($0) }
        guard !candidates.isEmpty else { return }
        do {
            // The pass before this may have moved any of them; read them again.
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
                try await close(subagent, ifLeftBehindBy: owner, markers: markers)
            }
        } catch {
            log.error("claude_watcher_close_failed", metadata: .fields(["error": error]))
        }
    }

    /// The same judgement for one subagent, reading only its own lineage.
    private func closeIfLeftBehind(_ sessionID: SessionID) async {
        do {
            guard let subagent = try await repository.sessionSummary(id: sessionID),
                  subagent.agent == .claudeSubagent, subagent.isAtWork else { return }
            var byID: [SessionID: SessionSummary] = [subagent.id: subagent]
            var current = subagent
            while let parentID = current.lineage?.parentSessionID, byID[parentID] == nil,
                  let parent = try await repository.sessionSummary(id: parentID) {
                byID[parentID] = parent
                current = parent
            }
            guard let owner = ClaudeSubagentIdentity.processOwner(of: subagent, in: byID) else { return }
            try await close(subagent, ifLeftBehindBy: owner, markers: try await processMarkers(of: owner.id))
        } catch {
            log.error("claude_watcher_close_failed", metadata: .fields(["session": sessionID.rawValue, "error": error]))
        }
    }

    private func close(
        _ subagent: SessionSummary,
        ifLeftBehindBy owner: SessionSummary,
        markers: ClaudeSubagentIdentity.ProcessMarkers
    ) async throws {
        guard let closedAt = ClaudeSubagentIdentity.leftBehindAt(subagent, owner: owner, markers: markers) else {
            return
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
}
