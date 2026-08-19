import AgentStatusCore
import AgentStatusTransport
import Foundation

public enum SessionReingestError: Error, Equatable, Sendable {
    case sessionNotFound
    /// No transcript / rollout is known or readable for the session.
    case richSourceUnavailable
}

public struct SessionReingestReport: Sendable {
    public var path: String
    public var linesRead: Int
    public var eventsApplied: Int
    public var detail: SessionDetail
}

/// Rebuilds one session from its rich source alone.
///
/// The session's derived rows (summary, turns, timeline, cursors) are dropped
/// — no tombstone — and the whole transcript / rollout is reduced again from
/// byte 0. Hook-only facts that the rich source cannot express are carried
/// over from the previous state: session markers (start / end / compaction,
/// with `session_ended` restoring the completed lifecycle), and the title /
/// lineage when the rebuild produced none. Event ids are salted with the
/// `generation` so the daemon's idempotency table does not swallow the replay.
public struct SessionReingester: Sendable {
    public let repository: any SessionRepository
    public let claudeAdapter: any AgentAdapter
    public let codexAdapter: any AgentAdapter
    public let homeDirectory: URL
    public let codexSessionsDirectory: URL

    public init(
        repository: any SessionRepository,
        claudeAdapter: any AgentAdapter = ClaudeAdapter(),
        codexAdapter: any AgentAdapter = CodexAdapter(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        codexSessionsDirectory: URL? = nil
    ) {
        self.repository = repository
        self.claudeAdapter = claudeAdapter
        self.codexAdapter = codexAdapter
        self.homeDirectory = homeDirectory
        self.codexSessionsDirectory = codexSessionsDirectory
            ?? homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public func reingest(sessionID: SessionID, generation: String) async throws -> SessionReingestReport {
        guard let previous = try await fullDetail(sessionID) else {
            throw SessionReingestError.sessionNotFound
        }
        let isCodex = previous.summary.agent == .codex || previous.summary.agent == .codexSubagent
        guard let path = try await sourcePath(for: previous.summary, isCodex: isCodex),
              FileManager.default.isReadableFile(atPath: path) else {
            throw SessionReingestError.richSourceUnavailable
        }

        // Read everything before touching the store: an unreadable file must
        // not leave the session half-deleted.
        let read = try RichSourceReader.read(
            path: path,
            sessionID: sessionID,
            adapter: isCodex ? codexAdapter : claudeAdapter,
            fromOffset: 0
        )

        _ = try await repository.resetSession(id: sessionID)
        var applied = 0
        for event in read.events {
            if try await repository.apply(event.salted(generation)) { applied += 1 }
        }
        for event in Self.carriedOverEvents(from: previous, generation: generation) {
            if try await repository.apply(event) { applied += 1 }
        }
        if let rebuilt = try await repository.listSessions(limit: 10_000).first(where: { $0.id == sessionID }),
           let identity = Self.identityEvent(previous: previous.summary, rebuilt: rebuilt, generation: generation) {
            if try await repository.apply(identity) { applied += 1 }
        }
        try await repository.saveRolloutCursor(read.cursor)

        guard let detail = try await fullDetail(sessionID) else {
            throw SessionReingestError.sessionNotFound
        }
        return SessionReingestReport(path: path, linesRead: read.lines, eventsApplied: applied, detail: detail)
    }

    // MARK: - Pieces

    private func sourcePath(for summary: SessionSummary, isCodex: Bool) async throws -> String? {
        if let cursor = try await repository.rolloutCursor(sessionID: summary.id),
           FileManager.default.isReadableFile(atPath: cursor.path) {
            return cursor.path
        }
        return isCodex
            ? RichSourceLocator.codexRollout(for: summary.id, sessionsDirectory: codexSessionsDirectory)
            : RichSourceLocator.claudeTranscript(for: summary.id, cwd: summary.workspace, homeDirectory: homeDirectory)
    }

    private func fullDetail(_ sessionID: SessionID) async throws -> SessionDetail? {
        var cursor: PaginationCursor?
        var timeline: [TimelineItem] = []
        var summary: SessionSummary?
        var turns: [TurnSummary] = []
        repeat {
            guard let page = try await repository.sessionDetail(id: sessionID, cursor: cursor, limit: 500) else {
                return nil
            }
            summary = page.summary
            turns = page.turns
            timeline.append(contentsOf: page.timeline)
            cursor = page.nextCursor
        } while cursor != nil
        guard let summary else { return nil }
        return SessionDetail(summary: summary, turns: turns, timeline: timeline)
    }

    /// Items that only hooks produce — session markers and Claude subagent
    /// start/stop (sidechain records are not read from the transcript) — are
    /// replayed at their original time. `session_ended` re-applies the
    /// completed lifecycle only if nothing in the transcript happened after it
    /// (the reducer ignores older state changes).
    static func carriedOverEvents(from previous: SessionDetail, generation: String) -> [AgentIngressEvent] {
        previous.timeline.compactMap { item in
            let ended: Bool
            switch item.payload {
            case let .sessionMarker(marker): ended = marker.kind == .sessionEnded
            case let .subagent(subagent):
                // Phantom post-Stop SubagentStop rows recorded before the
                // adapter learned to drop them do not come back.
                guard !subagent.name.isEmpty else { return nil }
                ended = false
            default: return nil
            }
            return AgentIngressEvent(
                eventID: EventID("reingest:\(generation):\(item.id.rawValue)"),
                sessionID: previous.summary.id,
                turnID: item.turnID,
                agent: previous.summary.agent,
                occurredAt: item.occurredAt,
                lifecycle: ended ? .completed : nil,
                phase: ended ? .idle : nil,
                timelineItem: item
            )
        }
    }

    /// Title and lineage come from hooks / state databases as often as from
    /// the rich source; keep the previous values when the rebuild has none.
    static func identityEvent(previous: SessionSummary, rebuilt: SessionSummary, generation: String) -> AgentIngressEvent? {
        let defaultTitle = "\(rebuilt.agent.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) Session"
        let title = rebuilt.title == defaultTitle && previous.title != defaultTitle ? previous.title : nil
        let lineage = rebuilt.lineage == nil ? previous.lineage : nil
        guard title != nil || lineage != nil else { return nil }
        return AgentIngressEvent(
            eventID: EventID("reingest:\(generation):identity"),
            sessionID: previous.id,
            agent: previous.agent,
            occurredAt: rebuilt.updatedAt,
            title: title ?? rebuilt.title,
            lineage: lineage
        )
    }
}

extension AgentIngressEvent {
    /// Same event under a rebuild-specific id, so it passes idempotency again.
    func salted(_ generation: String) -> AgentIngressEvent {
        AgentIngressEvent(
            eventID: EventID("reingest:\(generation):\(eventID.rawValue)"),
            sessionID: sessionID,
            turnID: turnID,
            agent: agent,
            occurredAt: occurredAt,
            title: title,
            workspace: workspace,
            lifecycle: lifecycle,
            phase: phase,
            turn: turn,
            timelineItem: timelineItem,
            lineage: lineage,
            disposition: disposition
        )
    }
}
