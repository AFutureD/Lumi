import AgentStatusCodex
import AgentStatusCore
import AgentStatusTransport
import Foundation

public final class CodexRolloutWatcher: @unchecked Sendable {
    private let rootDirectory: URL
    private let repository: any SessionRepository
    private let adapter: CodexAdapter
    private let pollIntervalSeconds: Double
    private let logger: @Sendable (String) -> Void
    private let onEvent: @Sendable (AgentIngressEvent) -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var scannedFileSizes: [String: UInt64] = [:]
    private static let ignoredExistingSession = SessionID("agent-status-ignored-existing-session")

    public init(
        rootDirectory: URL,
        repository: any SessionRepository,
        pollIntervalSeconds: Double = 2,
        logger: @escaping @Sendable (String) -> Void = { _ in },
        onEvent: @escaping @Sendable (AgentIngressEvent) -> Void = { _ in }
    ) {
        self.rootDirectory = rootDirectory
        self.repository = repository
        adapter = CodexAdapter()
        self.pollIntervalSeconds = pollIntervalSeconds
        self.logger = logger
        self.onEvent = onEvent
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    public func stop() {
        lock.lock()
        let currentTask = task
        task = nil
        lock.unlock()
        currentTask?.cancel()
    }

    public func scanOnce() async {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else { return }
        let files = rolloutFiles()
        for (fileURL, values) in files {
            guard !Task.isCancelled else { continue }
            let fileSize = UInt64(values.fileSize ?? 0)
            guard needsScan(path: fileURL.path, fileSize: fileSize) else { continue }
            do {
                try await scan(fileURL, fileSize: fileSize)
                markScanned(path: fileURL.path, fileSize: fileSize)
            } catch {
                logger("rollout_scan_failed path=\(fileURL.lastPathComponent) error=\(error)")
            }
        }
    }

    /// Establishes the first-run watermark without importing pre-existing Codex history.
    public func prepareInitialBaseline() async throws {
        guard try await !repository.isRolloutBaselineInitialized() else { return }
        for (fileURL, values) in rolloutFiles() {
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

    private func scan(_ url: URL, fileSize: UInt64) async throws {
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
            return
        }

        if fileSize < offset {
            offset = 0
            sessionID = nil
        }
        guard fileSize > offset else { return }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.readToEnd(), !data.isEmpty else { return }

        var lineStart = data.startIndex
        var consumed = 0
        while let newline = data[lineStart...].firstIndex(of: 0x0A) {
            if newline > lineStart {
                let line = Data(data[lineStart..<newline])
                let context = RolloutRecordContext(
                    path: path,
                    byteOffset: offset + UInt64(consumed),
                    sessionID: sessionID
                )
                let events = try adapter.events(fromRolloutLine: line, context: context)
                for event in events {
                    if try await repository.apply(event) { onEvent(event) }
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
