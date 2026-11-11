import Adapters
import Core
import Diagnostics
import Logging
import ServiceLifecycle
import Transport
import Foundation

private let log = Logger(label: "convert")

/// Brings the stored history up to `HistoryRevision.current`, once.
///
/// Revision 2 stores Codex items whole — shell commands included, which
/// earlier builds did not keep at all. The database migration reshapes the
/// rows the store already holds; what it cannot produce is what was never
/// stored, so this service reads each retained Codex session's rollout again
/// and installs its item rows: timeline only, by id, nothing published and
/// no clock moved (`SessionRepository.backfillTimeline`).
///
/// The revision is recorded only when every session is done, then announced
/// (`onRevised`): mirrors compare it with the revision of their copy and take
/// the sessions again when it moved. A daemon stopped midway starts over on
/// the next launch — the rows upsert by id, so repeating is harmless.
public actor HistoryBackfill: Service {
    private let repository: any SessionRepository
    private let codexAdapter: any AgentAdapter
    private let onRevised: @Sendable () async -> Void

    public init(
        repository: any SessionRepository,
        codexAdapter: any AgentAdapter = CodexAdapter(),
        onRevised: @escaping @Sendable () async -> Void = {}
    ) {
        self.repository = repository
        self.codexAdapter = codexAdapter
        self.onRevised = onRevised
    }

    public func run() async throws {
        await bringUpToDate()
        // One-off work in a long-lived group: returning would read as the
        // daemon ending, so stay until shutdown.
        try? await gracefulShutdown()
    }

    /// The deterministic entry point for tests. Returns the rows written.
    @discardableResult
    public func bringUpToDate() async -> Int {
        let started = ContinuousClock.now
        do {
            let stored = try await repository.historyRevision() ?? HistoryRevision.first
            guard stored < HistoryRevision.current else { return 0 }
            let sessions = try await repository.listSessions(limit: 10_000)
                .filter { $0.agent == .codex || $0.agent == .codexSubagent }
            var written = 0
            var read = 0
            var unreadable = 0
            for session in sessions {
                if Task.isCancelled { return written }
                guard let path = try await repository.rolloutCursor(sessionID: session.id)?.path,
                      FileManager.default.isReadableFile(atPath: path) else {
                    // The rollout is gone: the session keeps the rows the
                    // migration reshaped.
                    unreadable += 1
                    continue
                }
                do {
                    written += try await backfill(sessionID: session.id, path: path)
                    read += 1
                } catch {
                    unreadable += 1
                    log.warning("history_backfill_session_failed", metadata: .fields([
                        "session": session.id.rawValue,
                        "path": path,
                        "error": error,
                    ]))
                }
                await Task.yield()
            }
            try await repository.setHistoryRevision(HistoryRevision.current)
            log.info("history_backfilled", metadata: .fields([
                "revision": HistoryRevision.current,
                "from_revision": stored,
                "sessions": sessions.count,
                "read": read,
                "unreadable": unreadable,
                "rows": written,
                "ms": LogClock.milliseconds(since: started),
            ]))
            await onRevised()
            return written
        } catch {
            // The revision stays where it was; the next launch tries again.
            log.error("history_backfill_failed", metadata: .fields(["error": error]))
            return 0
        }
    }

    /// The Codex item rows of one rollout, read from its first byte.
    private func backfill(sessionID: SessionID, path: String) async throws -> Int {
        let source = try RichSourceReader.read(
            path: path,
            sessionID: sessionID,
            adapter: codexAdapter,
            fromOffset: 0
        )
        let items = source.events.compactMap(\.timelineItem).filter { item in
            guard item.id.rawValue.hasPrefix("codex_item:"), case .tool = item.payload else { return false }
            return true
        }
        return try await repository.backfillTimeline(items, sessionID: sessionID)
    }
}

/// A tool result read in a later increment than its call does not know the
/// tool's name: the reader's state starts over with every read, so the
/// adapter records the placeholder `Tool`. The call is already stored by
/// then — the result takes its name before it is stored, so every copy of the
/// row carries it and no reader has to find the call first.
enum ToolResultNaming {
    static let placeholder = "Tool"

    static func named(_ event: AgentIngressEvent, in repository: any SessionRepository) async throws -> AgentIngressEvent {
        guard let item = event.timelineItem,
              case let .tool(tool) = item.payload,
              tool.isResult, tool.name == placeholder || tool.name.isEmpty,
              let toolUseID = tool.toolUseID else { return event }
        let callID = TimelineItemIDs.toolCall(event.sessionID, toolUseID: toolUseID)
        guard let call = try await repository.timelineItems(id: event.sessionID, itemIDs: [callID])?.timeline.first,
              case let .tool(callTool) = call.payload, !callTool.name.isEmpty else { return event }
        var copy = event
        copy.timelineItem = TimelineItem(
            id: item.id, sessionID: item.sessionID, turnID: item.turnID, occurredAt: item.occurredAt,
            payload: .tool(ToolTimelinePayload(
                name: callTool.name, content: tool.content, status: tool.status,
                durationMilliseconds: tool.durationMilliseconds, toolUseID: tool.toolUseID
            )),
            truncated: item.truncated
        )
        return copy
    }
}
