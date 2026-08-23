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
        onEvent: @escaping @Sendable (AgentIngressEvent) -> Void = { _ in }
    ) {
        self.rootDirectory = rootDirectory
        self.repository = repository
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
        for (fileURL, values) in files {
            guard !Task.isCancelled else { continue }
            let fileSize = UInt64(values.fileSize ?? 0)
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

    /// Establishes the first-run watermark without importing pre-existing Codex history.
    public func prepareInitialBaseline() async throws {
        guard try await !repository.isRolloutBaselineInitialized() else { return }
        let files = rolloutFiles()
        lifecycleLog.info("rollout_baseline_initializing", metadata: .fields(["files": files.count]))
        for (fileURL, values) in files {
            if let sessionID = existingSessionID(in: fileURL) {
                try await repository.markSessionIgnored(sessionID)
            }
            let fileSize = UInt64(values.fileSize ?? 0)
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

    private func rolloutFiles() -> [(URL, URLResourceValues)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(URL, URLResourceValues)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl",
                  let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            files.append((fileURL, values))
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
            let identities = threadIdentities.identities(for: summaries.map(\.id))
            for summary in summaries {
                guard let identity = identities[summary.id] else { continue }
                let title = identity.displayTitle ?? summary.title
                let agent = identity.agentKind
                guard title != summary.title
                    || agent != summary.agent
                    || identity.lineage != summary.lineage else { continue }
                let event = AgentIngressEvent(
                    eventID: EventID(
                        "codex-thread-identity:\(summary.id.rawValue):\(UUID().uuidString)"
                    ),
                    sessionID: summary.id,
                    agent: agent,
                    occurredAt: Date(),
                    title: title,
                    lineage: identity.lineage
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

    private func scan(_ url: URL, fileSize: UInt64) async throws -> Bool {
        let path = url.path
        var cursor = try await repository.rolloutCursor(path: path)
        var offset = cursor?.byteOffset ?? 0
        var sessionID = cursor?.sessionID

        if sessionID == Self.ignoredExistingSession {
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

        if fileSize < offset {
            offset = 0
            sessionID = nil
        }
        guard fileSize > offset else { return true }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.readToEnd(), !data.isEmpty else { return true }

        let initialHistory = Self.initialSubagentHistory(in: data, offset: offset)
        if case .waitingForTrigger = initialHistory {
            log.debug("rollout_scan_waiting_for_subagent_trigger", metadata: .fields(["path": path]))
            return false
        }

        var lineStart = data.startIndex
        var consumed = 0
        var lines = 0
        var produced = 0
        var applied = 0
        while let newline = data[lineStart...].firstIndex(of: 0x0A) {
            if newline > lineStart {
                let line = Data(data[lineStart..<newline])
                let shouldProcess = switch initialHistory {
                case .none:
                    true
                case let .ready(metadataOffset, triggerOffset):
                    consumed == metadataOffset || consumed >= triggerOffset
                case .waitingForTrigger:
                    false
                }
                guard shouldProcess else {
                    let next = data.index(after: newline)
                    consumed += data.distance(from: lineStart, to: next)
                    lineStart = next
                    if lineStart == data.endIndex { break }
                    continue
                }
                let context = RolloutRecordContext(
                    path: path,
                    byteOffset: offset + UInt64(consumed),
                    sessionID: sessionID
                )
                let events = try adapter.events(fromRolloutLine: line, context: context)
                lines += 1
                produced += events.count
                for event in events {
                    if try await repository.apply(event) {
                        applied += 1
                        onEvent(event)
                    }
                    if sessionID == nil { sessionID = event.sessionID }
                }
            }
            let next = data.index(after: newline)
            consumed += data.distance(from: lineStart, to: next)
            lineStart = next
            if lineStart == data.endIndex { break }
        }

        cursor = RolloutCursor(
            path: path,
            byteOffset: offset + UInt64(consumed),
            fileSize: fileSize,
            sessionID: sessionID
        )
        try await repository.saveRolloutCursor(cursor!)
        if lines > 0 {
            log.info("rollout_scanned", metadata: .fields([
                "session": sessionID?.rawValue,
                "path": path,
                "from": offset,
                "to": offset + UInt64(consumed),
                "lines": lines,
                "events": produced,
                "applied": applied,
            ]))
        }
        return true
    }

    private static func initialSubagentHistory(
        in data: Data,
        offset: UInt64
    ) -> InitialSubagentHistory {
        guard offset == 0 else { return .none }

        var lineStart = data.startIndex
        var consumed = 0
        var metadataOffset: Int?
        var isThreadSpawn = false

        while let newline = data[lineStart...].firstIndex(of: 0x0A) {
            if newline > lineStart,
               let object = try? JSONSerialization.jsonObject(
                   with: Data(data[lineStart..<newline])
               ) as? [String: Any],
               let type = object["type"] as? String,
               let payload = object["payload"] as? [String: Any] {
                if metadataOffset == nil {
                    metadataOffset = consumed
                    let source = payload["source"] as? [String: Any]
                    let subagent = source?["subagent"] as? [String: Any]
                    isThreadSpawn = type == "session_meta"
                        && subagent?["thread_spawn"] is [String: Any]
                    if !isThreadSpawn { return .none }
                } else if type == "inter_agent_communication_metadata",
                          payload["trigger_turn"] as? Bool == true {
                    return .ready(
                        metadataOffset: metadataOffset ?? 0,
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
    case ready(metadataOffset: Int, triggerOffset: Int)
}
