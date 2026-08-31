import Adapters
import Core
import Diagnostics
import Logging
import ServiceLifecycle
import Transport
import Foundation

private let log = Logger(label: "agent")

/// The one routine for "bring a session's rich source into the store":
/// read from the daemon's cursor (byte 0 when none), apply every event,
/// save the advanced cursor. The hook path uses it for the increment ahead
/// of each hook, `ClaudeTranscriptWatcher` and `CodexRolloutWatcher` for
/// hook-less tails, `TranscriptBackfillQueue` for whole histories — the same
/// code path, so callers can only ever race harmlessly (events dedupe by
/// id, the cursor save is last-writer-wins on identical content).
enum RichSourceCatchUp {
    struct Report {
        var fromOffset: UInt64
        var toOffset: UInt64
        var lines: Int
        var events: Int
        var applied: Int
        /// Turn left open (or last named) after the read — seeds the hook
        /// events reduced right after the increment.
        var finalTurnID: TurnID?
    }

    static func run(
        repository: any SessionRepository,
        sessionID: SessionID,
        path: String,
        adapter: any AgentAdapter,
        maximumBytes: Int,
        onEvent: @Sendable (AgentIngressEvent) -> Void
    ) async throws -> Report {
        let cursor = try await repository.rolloutCursor(path: path)
        let fromOffset = cursor?.byteOffset ?? 0
        // Reading from byte 0 must not inherit the newest known turn: the
        // history's own turn markers attribute its early records. The bridge
        // turn id is only for continuing a partially read source.
        let initialTurnID = fromOffset == 0
            ? nil
            : try await repository.currentTurnID(sessionID: sessionID)
        let read = try RichSourceReader.read(
            path: path,
            sessionID: sessionID,
            adapter: adapter,
            fromOffset: fromOffset,
            initialTurnID: initialTurnID,
            maximumBytes: maximumBytes
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
        return Report(
            fromOffset: fromOffset,
            toOffset: read.cursor.byteOffset,
            lines: read.lines,
            events: read.events.count,
            applied: applied,
            finalTurnID: read.finalTurnID
        )
    }
}

/// Rebuilds session histories the hook path refuses to replay inline: a
/// hook frame answers on a latency budget, so anything unbounded belongs
/// here — one serial worker inside the daemon, the single writer of the
/// store. Fed by `HookIngestService` on a cold start over a large history.
public actor TranscriptBackfillQueue: Service {
    private let repository: any SessionRepository
    private let claudeAdapter = ClaudeAdapter()
    private let codexAdapter = CodexAdapter()
    private let maximumIncrementBytes: Int
    private let onEvent: @Sendable (AgentIngressEvent) -> Void
    private var pendingPaths: [SessionID: String] = [:]
    private var order: [SessionID] = []
    private let signals: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation

    public init(
        repository: any SessionRepository,
        maximumIncrementBytes: Int = 128 * 1024 * 1024,
        onEvent: @escaping @Sendable (AgentIngressEvent) -> Void = { _ in }
    ) {
        self.repository = repository
        self.maximumIncrementBytes = maximumIncrementBytes
        self.onEvent = onEvent
        (signals, signal) = AsyncStream.makeStream(of: Void.self)
    }

    public func enqueue(sessionID: SessionID, path: String) {
        if pendingPaths[sessionID] == nil { order.append(sessionID) }
        pendingPaths[sessionID] = path
        signal.yield(())
    }

    /// Drains everything queued so far — the deterministic entry point for
    /// tests and for shutdown. An entry leaves the queue under actor
    /// isolation before its (awaiting) backfill starts, so a concurrent
    /// `run()` never processes the same session twice.
    public func flush() async {
        while let next = popNext() {
            await backfill(sessionID: next.sessionID, path: next.path)
        }
    }

    public func run() async throws {
        await cancelWhenGracefulShutdown {
            for await _ in self.signals {
                await self.flush()
            }
        }
        // Shut down after the watchers and the hook path: whatever they
        // queued before stopping still reaches the store.
        await flush()
    }

    private func popNext() -> (sessionID: SessionID, path: String)? {
        while !order.isEmpty {
            let sessionID = order.removeFirst()
            guard let path = pendingPaths.removeValue(forKey: sessionID) else { continue }
            return (sessionID, path)
        }
        return nil
    }

    private func backfill(sessionID: SessionID, path: String) async {
        guard FileManager.default.isReadableFile(atPath: path) else {
            log.warning("session_backfill_unreadable", metadata: .fields([
                "session": sessionID.rawValue,
                "path": path,
            ]))
            return
        }
        // The same heuristic the helper's provider detection uses: Claude
        // transcripts live under `.claude`, everything else is a Codex
        // rollout.
        let adapter: any AgentAdapter = path.contains("/.claude/") ? claudeAdapter : codexAdapter
        do {
            let report = try await RichSourceCatchUp.run(
                repository: repository,
                sessionID: sessionID,
                path: path,
                adapter: adapter,
                maximumBytes: maximumIncrementBytes,
                onEvent: onEvent
            )
            log.info("session_backfilled", metadata: .fields([
                "session": sessionID.rawValue,
                "path": path,
                "from": report.fromOffset,
                "to": report.toOffset,
                "lines": report.lines,
                "events": report.events,
                "applied": report.applied,
            ]))
        } catch {
            log.error("session_backfill_failed", metadata: .fields([
                "session": sessionID.rawValue,
                "path": path,
                "error": error,
            ]))
        }
    }
}
