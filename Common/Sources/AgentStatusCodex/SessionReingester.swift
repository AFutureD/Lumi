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
    /// The session and every subagent session rebuilt with it.
    public var rebuiltSessionIDs: [SessionID]
}

/// Rebuilds one session from its rich source alone.
///
/// The session's derived rows (summary, turns, timeline, cursors) are dropped
/// — no tombstone — and the whole transcript / rollout is reduced again from
/// byte 0. Hook-only facts that the rich source cannot express are carried
/// over from the previous state: session markers (start / end / compaction,
/// with `session_ended` restoring the completed lifecycle), the title /
/// lineage when the rebuild produced none, and the human-set review /
/// Notch-archive flags. Event ids are salted with the
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
        try await restoreHumanFlags(from: previous.summary, on: sessionID)
        try await repository.saveRolloutCursor(read.cursor)

        // A Claude parent also rebuilds its subagents' child sessions from the
        // sidechain transcripts next to it — the way to backfill children for
        // sessions recorded before subagents became sessions of their own.
        var rebuilt = [sessionID]
        if !isCodex, !ClaudeSubagentIdentity.isSubagentSession(sessionID) {
            let children = try await reingestClaudeSubagents(
                parent: sessionID,
                parentTranscriptPath: path,
                workspace: previous.summary.workspace,
                generation: generation
            )
            applied += children.applied
            rebuilt += children.ids
        }

        guard let detail = try await fullDetail(sessionID) else {
            throw SessionReingestError.sessionNotFound
        }
        return SessionReingestReport(path: path, linesRead: read.lines, eventsApplied: applied, detail: detail, rebuiltSessionIDs: rebuilt)
    }

    /// `<project>/<session>/subagents/agent-*.jsonl` → one child session each
    /// (`ClaudeSubagentIdentity`), reduced from byte 0 and titled from `.meta.json`.
    /// A child the user deleted (tombstoned, no row) stays deleted.
    private func reingestClaudeSubagents(
        parent: SessionID,
        parentTranscriptPath: String,
        workspace: String?,
        generation: String
    ) async throws -> (applied: Int, ids: [SessionID]) {
        let directory = (parentTranscriptPath as NSString).deletingLastPathComponent
            + "/\(parent.rawValue)/subagents"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return (0, []) }
        var applied = 0
        var ids: [SessionID] = []
        for file in files.sorted() where file.hasPrefix("agent-") && file.hasSuffix(".jsonl") {
            let agentID = String(file.dropFirst("agent-".count).dropLast(".jsonl".count))
            guard !agentID.isEmpty else { continue }
            let path = directory + "/" + file
            let childID = ClaudeSubagentIdentity.sessionID(parent: parent, agentID: agentID)
            let read = try RichSourceReader.read(path: path, sessionID: childID, adapter: claudeAdapter, fromOffset: 0)
            guard !read.events.isEmpty else { continue }
            let previousChild = try await repository.sessionDetail(id: childID, cursor: nil, limit: 1)?.summary
            if previousChild == nil, try await repository.isSessionIgnored(childID) { continue }
            ids.append(childID)
            _ = try await repository.resetSession(id: childID)
            for event in read.events {
                if try await repository.apply(event.salted(generation)) { applied += 1 }
            }
            let meta = ClaudeSubagentIdentity.readMeta(atTranscriptPath: path)
            let identity = AgentIngressEvent(
                eventID: EventID("reingest:\(generation):\(childID.rawValue):identity"),
                sessionID: childID,
                agent: .claudeSubagent,
                occurredAt: read.events.map(\.occurredAt).max() ?? Date(),
                title: ClaudeSubagentIdentity.title(agentType: meta?.agentType, meta: meta) ?? "Claude Agent",
                workspace: workspace,
                lineage: ClaudeSubagentIdentity.lineage(parent: parent, agentType: meta?.agentType, meta: meta)
            )
            if try await repository.apply(identity) { applied += 1 }
            if let previousChild {
                try await restoreHumanFlags(from: previousChild, on: childID)
            }
            try await repository.saveRolloutCursor(read.cursor)
        }
        return (applied, ids)
    }

    /// Human-set summary flags live outside the event stream, so the replay
    /// cannot restore them: `needsReview` is cleared only by the human opening
    /// the session, and the rebuilt turn ends would flip it green again;
    /// `hiddenInNotch` is set only by the human archiving from the Notch, and
    /// the rebuilt user prompts would unhide it.
    private func restoreHumanFlags(from previous: SessionSummary, on sessionID: SessionID) async throws {
        if !previous.needsReview {
            try await repository.markSessionReviewed(sessionID)
        }
        if previous.hiddenInNotch {
            try await repository.markSessionHiddenInNotch(sessionID)
        }
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
