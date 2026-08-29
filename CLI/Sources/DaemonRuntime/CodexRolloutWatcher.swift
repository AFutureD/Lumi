import Adapters
import Core
import Diagnostics
import Logging
import Transport
import Foundation

private let log = Logger(label: "agent")
private let lifecycleLog = Logger(label: "lifecycle")

public final class CodexRolloutWatcher: @unchecked Sendable {
    private let rootDirectory: URL
    private let repository: any SessionRepository
    private let threadIdentities: any CodexThreadIdentityProviding
    private let adapter: CodexAdapter
    private let pollIntervalSeconds: Double
    /// One capped read per scan; a gap larger than this goes to the backfill
    /// worker whole instead of being tail-trimmed.
    private let maximumIncrementBytes = 32 * 1024 * 1024
    private let backfill: TranscriptBackfillQueue?
    private let onEvent: @Sendable (AgentIngressEvent) -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var scannedFileSizes: [String: UInt64] = [:]
    private static let ignoredExistingSession = SessionID("lumi-ignored-existing-session")

    public init(
        rootDirectory: URL,
        repository: any SessionRepository,
        threadIdentities: (any CodexThreadIdentityProviding)? = nil,
        pollIntervalSeconds: Double = 2,
        backfill: TranscriptBackfillQueue? = nil,
        onEvent: @escaping @Sendable (AgentIngressEvent) -> Void = { _ in }
    ) {
        self.rootDirectory = rootDirectory
        self.repository = repository
        self.backfill = backfill
        let resolvedThreadIdentities = threadIdentities ?? CodexThreadIdentityStore(
            databasePath: rootDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("state_5.sqlite")
                .path
        )
        self.threadIdentities = resolvedThreadIdentities
        adapter = CodexAdapter(threads: resolvedThreadIdentities)
        self.pollIntervalSeconds = pollIntervalSeconds
        self.onEvent = onEvent
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
        }
        lifecycleLog.info("rollout_watcher_started", metadata: .fields([
            "root": rootDirectory,
            "poll_seconds": pollIntervalSeconds,
        ]))
    }

    public func stop() {
        lock.lock()
        let currentTask = task
        task = nil
        lock.unlock()
        currentTask?.cancel()
        if currentTask != nil {
            lifecycleLog.info("rollout_watcher_stopped")
        }
    }

    public func scanOnce() async {
        await synchronizeThreadIdentities()
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else { return }
        let files = rolloutFiles()
        for (fileURL, fileSize) in files {
            guard !Task.isCancelled else { continue }
            guard needsScan(path: fileURL.path, fileSize: fileSize) else { continue }
            do {
                if try await scan(fileURL, fileSize: fileSize) {
                    markScanned(path: fileURL.path, fileSize: fileSize)
                }
            } catch {
                log.error("rollout_scan_failed", metadata: .fields(["path": fileURL.path, "error": error]))
            }
        }
    }

    /// Establishes the first-run watermark without importing pre-existing
    /// Codex history — while leaving everything the store already tracks
    /// alone. A database that ingested sessions before the baseline existed
    /// (hook-driven reads predate the always-on watcher) holds live cursors
    /// and sessions; ignoring those files would tombstone active sessions
    /// and skip their unread tails.
    public func prepareInitialBaseline() async throws {
        guard try await !repository.isRolloutBaselineInitialized() else { return }
        let files = rolloutFiles()
        lifecycleLog.info("rollout_baseline_initializing", metadata: .fields(["files": files.count]))
        for (fileURL, fileSize) in files {
            // A cursor means this file is already being read; the first scan
            // resumes from it (and picks up any hook-less tail).
            if try await repository.rolloutCursor(path: fileURL.path) != nil { continue }
            let sessionID = existingSessionID(in: fileURL)
            if let sessionID,
               try await repository.sessionDetail(id: sessionID, cursor: nil, limit: 1) != nil {
                // Known session without a cursor: its history arrived over
                // hooks; the watcher takes over from EOF.
                try await repository.saveRolloutCursor(RolloutCursor(
                    path: fileURL.path,
                    byteOffset: fileSize,
                    fileSize: fileSize,
                    sessionID: sessionID
                ))
                markScanned(path: fileURL.path, fileSize: fileSize)
                continue
            }
            if let sessionID {
                try await repository.markSessionIgnored(sessionID)
            }
            try await repository.saveRolloutCursor(RolloutCursor(
                path: fileURL.path,
                byteOffset: fileSize,
                fileSize: fileSize,
                sessionID: Self.ignoredExistingSession
            ))
            markScanned(path: fileURL.path, fileSize: fileSize)
        }
        try await repository.markRolloutBaselineInitialized()
    }

    /// Enumerates by relative path and rejoins onto the configured root:
    /// cursor rows key by path string, and the URL-based enumerator resolves
    /// symlinks (`/var` → `/private/var`), which would give the watcher
    /// different keys than the hook path derives from the same root.
    private func rolloutFiles() -> [(URL, UInt64)] {
        guard let enumerator = FileManager.default.enumerator(atPath: rootDirectory.path) else { return [] }
        var files: [(URL, UInt64)] = []
        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(".jsonl"),
                  !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
                  let attributes = enumerator.fileAttributes,
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            files.append((rootDirectory.appendingPathComponent(relative), size))
        }
        return files
    }

    /// The first scan after every daemon launch checks every rollout so events
    /// written while it was offline are recovered. Later polls only touch new
    /// or size-changed files, avoiding a SQLite cursor lookup per old Session.
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

    private func synchronizeThreadIdentities() async {
        do {
            let summaries = try await repository.listSessions(limit: 10_000)
                .filter { $0.agent.provider == .codex }
            let identities = threadIdentities.identities(for: summaries.map(\.id))
            for summary in summaries {
                guard let identity = identities[summary.id] else { continue }
                // The owning AaaS is the authority on the title: the native
                // thread name may only retitle sessions owned by an AaaS
                // that titles through it (ChatGPT / Codex), or sessions with
                // no recorded ownership (pre-ownership rows, watcher-only
                // discoveries). A Paseo / Raft title must survive the
                // session's end — no hook will ever re-assert it.
                let allowsNativeTitle = summary.aaas?.allowsNativeTitle ?? true
                let title = allowsNativeTitle ? (identity.displayTitle ?? summary.title) : summary.title
                // Mirror the reducer before deciding to emit: a fact-free
                // `.codex` identity (no lineage fields) must neither demote a
                // subagent nor blank its stored lineage. Diffing against the
                // raw identity here would emit exactly that event.
                let identityLineage = identity.lineage.isEmpty ? nil : identity.lineage
                let agent = (identity.agentKind == .codex
                    && identityLineage == nil
                    && summary.agent == .codexSubagent)
                    ? summary.agent
                    : identity.agentKind
                let lineage = identityLineage ?? summary.lineage
                guard title != summary.title
                    || agent != summary.agent
                    || lineage != summary.lineage else { continue }
                // Content-derived id: the same observed diff — across polls
                // and daemon restarts — dedupes, while a genuine A→B→A gets a
                // fresh id because the row's record clock advanced.
                let fingerprint = "\(title ?? "")|\(agent.rawValue)|\(String(describing: lineage))"
                let event = AgentIngressEvent(
                    eventID: EventID(
                        "codex-thread-identity:\(summary.id.rawValue)"
                            + ":\(summary.updatedAt.timeIntervalSince1970):\(StableHash.fnv1a(fingerprint))"
                    ),
                    sessionID: summary.id,
                    agent: agent,
                    occurredAt: Date(),
                    title: title,
                    lineage: lineage
                )
                if try await repository.apply(event) {
                    log.info("thread_identity_applied", metadata: .fields([
                        "session": summary.id.rawValue,
                        "agent": agent.rawValue,
                    ]))
                    onEvent(event)
                }
            }
        } catch {
            log.error("thread_identity_sync_failed", metadata: .fields(["error": error]))
        }
    }

    /// Catch a rollout file up to EOF through `RichSourceCatchUp` — the same
    /// increment routine as the hook path, so cross-line state (turn
    /// attribution, tool pairing, channel arbitration) is identical whether
    /// a record arrives via a hook-triggered read or this poll.
    private func scan(_ url: URL, fileSize: UInt64) async throws -> Bool {
        let path = url.path
        let cursor = try await repository.rolloutCursor(path: path)

        if cursor?.sessionID == Self.ignoredExistingSession {
            if fileSize != cursor?.fileSize {
                try await repository.saveRolloutCursor(RolloutCursor(
                    path: path,
                    byteOffset: fileSize,
                    fileSize: fileSize,
                    sessionID: Self.ignoredExistingSession
                ))
            }
            return true
        }

        var offset = cursor?.byteOffset ?? 0
        var knownSessionID = cursor?.sessionID
        if fileSize < offset {
            // Truncated / rewritten: the reader restarts at 0; the stale
            // cursor's session must not name the new content.
            offset = 0
            knownSessionID = nil
        }
        guard fileSize > offset else { return true }

        // The session id keys the cursor and the read; a file whose head has
        // no `session_meta` yet is retried on a later poll.
        guard let sessionID = knownSessionID ?? existingSessionID(in: url) else {
            log.debug("rollout_scan_no_session_meta", metadata: .fields(["path": path]))
            return false
        }

        // An offline gap larger than one capped read goes to the serial
        // backfill worker whole (its valve is far larger) — a tail-trimmed
        // read would silently drop the middle of the session.
        if offset > 0, fileSize - offset > UInt64(maximumIncrementBytes), let backfill {
            await backfill.enqueue(sessionID: sessionID, path: path)
            log.info("rollout_gap_delegated_to_backfill", metadata: .fields([
                "session": sessionID.rawValue,
                "path": path,
                "gap": fileSize - offset,
            ]))
            return true
        }

        // A brand-new rollout spawned for a subagent replays the parent's
        // history first; nothing may be ingested until the trigger record
        // marks where the subagent's own work starts.
        if offset == 0 {
            switch try Self.initialSubagentHistory(url: url) {
            case .waitingForTrigger:
                log.debug("rollout_scan_waiting_for_subagent_trigger", metadata: .fields(["path": path]))
                return false
            case let .ready(metaLine, triggerOffset):
                let context = RolloutRecordContext(path: path, byteOffset: 0, sessionID: sessionID)
                for event in try adapter.events(fromRolloutLine: metaLine, context: context) {
                    if try await repository.apply(event) { onEvent(event) }
                }
                try await repository.saveRolloutCursor(RolloutCursor(
                    path: path,
                    byteOffset: UInt64(triggerOffset),
                    fileSize: fileSize,
                    sessionID: sessionID
                ))
            case .none:
                break
            }
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
            log.info("rollout_scanned", metadata: .fields([
                "session": sessionID.rawValue,
                "path": path,
                "from": report.fromOffset,
                "to": report.toOffset,
                "lines": report.lines,
                "events": report.events,
                "applied": report.applied,
            ]))
        }
        return true
    }

    private static func initialSubagentHistory(url: URL) throws -> InitialSubagentHistory {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.readToEnd(), !data.isEmpty else { return .none }

        var lineStart = data.startIndex
        var consumed = 0
        var metaLine: Data?
        var isThreadSpawn = false

        while let newline = data[lineStart...].firstIndex(of: 0x0A) {
            if newline > lineStart,
               let object = try? JSONSerialization.jsonObject(
                   with: Data(data[lineStart..<newline])
               ) as? [String: Any],
               let type = object["type"] as? String,
               let payload = object["payload"] as? [String: Any] {
                if metaLine == nil {
                    metaLine = Data(data[lineStart..<newline])
                    let source = payload["source"] as? [String: Any]
                    let subagent = source?["subagent"] as? [String: Any]
                    isThreadSpawn = type == "session_meta"
                        && subagent?["thread_spawn"] is [String: Any]
                    if !isThreadSpawn { return .none }
                } else if type == "inter_agent_communication_metadata",
                          payload["trigger_turn"] as? Bool == true {
                    return .ready(
                        metaLine: metaLine ?? Data(),
                        triggerOffset: consumed
                    )
                }
            }

            let next = data.index(after: newline)
            consumed += data.distance(from: lineStart, to: next)
            lineStart = next
            if lineStart == data.endIndex { break }
        }

        return isThreadSpawn ? .waitingForTrigger : .none
    }

    private func existingSessionID(in url: URL) -> SessionID? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 128 * 1024), !data.isEmpty else { return nil }
        for line in data.split(separator: 0x0A).prefix(100) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any],
                  let id = payload["id"] as? String else { continue }
            return SessionID(id)
        }
        return nil
    }
}

private enum InitialSubagentHistory {
    case none
    case waitingForTrigger
    case ready(metaLine: Data, triggerOffset: Int)
}
