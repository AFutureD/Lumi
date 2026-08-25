import Core
import Transport
import Foundation

/// What the helper needs from the daemon. The executable backs this with the
/// Unix-socket IPC client; tests back it with an in-memory repository.
public protocol HelperDaemonPort: Sendable {
    func ingest(_ events: [AgentIngressEvent]) throws
    func rolloutCursor(path: String) throws -> RolloutCursor?
    func saveRolloutCursor(_ cursor: RolloutCursor) throws
    /// Summary + turns as the daemon holds them; the timeline page is not needed.
    func session(sessionID: SessionID) throws -> SessionDetail?
    /// Hands a history to the daemon's backfill worker: the daemon reads the
    /// rich source itself, off the hook path.
    func requestBackfill(sessionID: SessionID, path: String) throws
}

public enum HelperAgentSelection: String, Sendable {
    case auto
    case codex
    case claude
}

public struct HelperIngestReport: Hashable, Sendable {
    public var provider: AgentProvider
    public var sessionID: SessionID?
    public var hookEventName: String?
    public var richSourcePath: String?
    public var richSourceLinesRead: Int
    public var eventsSent: Int
    public var warnings: [String]
    /// Decisions worth surfacing under `--verbose` that are not problems.
    public var notes: [String]

    public init(
        provider: AgentProvider,
        sessionID: SessionID? = nil,
        hookEventName: String? = nil,
        richSourcePath: String? = nil,
        richSourceLinesRead: Int = 0,
        eventsSent: Int = 0,
        warnings: [String] = [],
        notes: [String] = []
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.hookEventName = hookEventName
        self.richSourcePath = richSourcePath
        self.richSourceLinesRead = richSourceLinesRead
        self.eventsSent = eventsSent
        self.warnings = warnings
        self.notes = notes
    }
}

/// The helper's whole job for one hook invocation:
///
/// 1. decide which agent produced the hook,
/// 2. read the newly appended part of that session's transcript / rollout
///    (cursor owned by the daemon) and reduce it to Agent-domain events,
/// 3. reduce the hook payload itself (lifecycle / phase / turn / markers),
/// 4. send everything to the daemon in one batch and advance the cursor.
///
/// The transcript is read *before* the hook so tool calls, thinking and text
/// that led up to this hook are already in place when its state lands.
public struct HelperIngestPipeline: Sendable {
    public var port: any HelperDaemonPort
    public var environment: [String: String]
    public var homeDirectory: URL
    public var codexAdapter: CodexAdapter
    public var claudeAdapter: ClaudeAdapter
    /// Safety valve for a resumed multi-megabyte transcript.
    public var maximumIncrementBytes: Int
    /// A hook is a real-time channel with an external kill timeout: when the
    /// daemon has no cursor for the source (cold start) and the file is
    /// bigger than this, the history is handed to the daemon's backfill
    /// worker instead of being replayed inline.
    public var maximumInlineHistoryBytes: Int

    public init(
        port: any HelperDaemonPort,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        codexAdapter: CodexAdapter = CodexAdapter(),
        claudeAdapter: ClaudeAdapter = ClaudeAdapter(),
        maximumIncrementBytes: Int = 32 * 1024 * 1024,
        maximumInlineHistoryBytes: Int = 1024 * 1024
    ) {
        self.port = port
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.codexAdapter = codexAdapter
        self.claudeAdapter = claudeAdapter
        self.maximumIncrementBytes = maximumIncrementBytes
        self.maximumInlineHistoryBytes = maximumInlineHistoryBytes
    }

    public func run(hookData: Data, agent selection: HelperAgentSelection = .auto) throws -> HelperIngestReport {
        guard let root = try JSONSerialization.jsonObject(with: hookData) as? [String: Any] else {
            throw AgentAdapterError.malformedJSON
        }
        guard let rawSession = root.string("session_id"), !rawSession.isEmpty else {
            throw AgentAdapterError.missingSessionID
        }
        let sessionID = SessionID(rawSession)
        let provider = Self.provider(for: root, selection: selection, environment: environment)
        var report = HelperIngestReport(
            provider: provider,
            sessionID: sessionID,
            hookEventName: root.string("hook_event_name")
        )

        let adapter: any AgentAdapter = provider == .claude ? claudeAdapter : codexAdapter
        var batch: [AgentIngressEvent] = []

        // 2. Rich source increment.
        let richPath = richSourcePath(provider: provider, sessionID: sessionID, hook: root)
        var richAvailable = false
        var cursorToSave: RolloutCursor?
        var childCursorsToSave: [RolloutCursor] = []
        var historyDelegated = false
        var currentTurnID: TurnID?
        if let richPath, FileManager.default.isReadableFile(atPath: richPath) {
            richAvailable = true
            report.richSourcePath = richPath
            do {
                switch try readIncrement(
                    path: richPath,
                    sessionID: sessionID,
                    adapter: adapter
                ) {
                case let .increment(events, cursor, lines, turnID):
                    batch.append(contentsOf: events)
                    cursorToSave = cursor
                    report.richSourceLinesRead = lines
                    currentTurnID = turnID
                case let .delegatedToDaemon(bytes):
                    // With the increment deferred, the hook must tell the
                    // whole story itself: its prompt / tool rows are the only
                    // live rows until the daemon's backfill upserts over them
                    // (both sides use the same stable item ids).
                    richAvailable = false
                    historyDelegated = true
                    report.notes.append("history_delegated_to_daemon bytes=\(bytes)")
                }
            } catch {
                // A failed read contributed nothing: fall back to hook-only
                // for this invocation rather than suppressing the hook's turn
                // and items on the promise of transcript data that never came.
                richAvailable = false
                report.warnings.append("rich_source_read_failed path=\(richPath) error=\(error)")
            }
        } else if let richPath {
            report.warnings.append("rich_source_unreadable path=\(richPath)")
        }

        // 2b. Claude subagent: a hook carrying `agent_id` (SubagentStart /
        // Stop, or a hook fired inside the agent) also advances the derived
        // child session — its sidechain transcript increment plus the title
        // and lineage from `.meta.json`.
        var childRichAvailable = false
        var childIdentity: AgentIngressEvent?
        if provider == .claude,
           let agentID = root.string("agent_id"),
           ClaudeAdapter.isRealSubagent(root) {
            let childID = ClaudeSubagentIdentity.sessionID(parent: sessionID, agentID: agentID)
            let childPath = root.string("agent_transcript_path").flatMap { $0.isEmpty ? nil : $0 }
                ?? richPath.map {
                    ClaudeSubagentIdentity.transcriptPath(parentTranscriptPath: $0, parent: sessionID, agentID: agentID)
                }
            if let childPath, FileManager.default.isReadableFile(atPath: childPath) {
                childRichAvailable = true
                do {
                    switch try readIncrement(path: childPath, sessionID: childID, adapter: adapter) {
                    case let .increment(events, cursor, _, _):
                        batch.append(contentsOf: events)
                        if let cursor { childCursorsToSave.append(cursor) }
                    case let .delegatedToDaemon(bytes):
                        childRichAvailable = false
                        report.notes.append("subagent_history_delegated_to_daemon bytes=\(bytes)")
                    }
                } catch {
                    report.warnings.append("subagent_transcript_read_failed path=\(childPath) error=\(error)")
                }
                if let meta = ClaudeSubagentIdentity.readMeta(atTranscriptPath: childPath) {
                    let agentType = root.string("agent_type")
                    // Appended after the hook's own child event so the spawn
                    // description wins over the agent-type fallback title.
                    childIdentity = AgentIngressEvent(
                        eventID: EventID("claude-subagent-meta:\(childID.rawValue):\(meta.hashValue)"),
                        sessionID: childID,
                        agent: .claudeSubagent,
                        occurredAt: root.date("timestamp") ?? Date(),
                        title: ClaudeSubagentIdentity.title(agentType: agentType, meta: meta),
                        lineage: ClaudeSubagentIdentity.lineage(parent: sessionID, agentType: agentType, meta: meta)
                    )
                }
            } else {
                report.notes.append("subagent_transcript_unavailable agent=\(agentID)")
            }
        }

        // 3. The hook itself. A Claude session that ends while the daemon
        // still holds it as provisional (no Turn ever) and never wrote a
        // transcript was never used — a desktop config-loading probe or a
        // launch quit before any prompt — and is discarded instead of ended.
        var options = HookIngestOptions(
            richSourceAvailable: root.string("agent_id") != nil && ClaudeAdapter.isRealSubagent(root)
                ? childRichAvailable
                : richAvailable,
            currentTurnID: currentTurnID
        )
        // A delegated history means the daemon is about to prove the session
        // was used — the discard heuristic must not race it.
        if provider == .claude, report.hookEventName == "SessionEnd", !richAvailable, !historyDelegated {
            options.sessionNeverUsed = sessionNeverUsed(sessionID)
            if options.sessionNeverUsed {
                report.notes.append("session_discarded_never_used")
            }
        }
        let hookEvents = try adapter.events(fromHookData: hookData, options: options)
        batch.append(contentsOf: hookEvents)
        if let childIdentity { batch.append(childIdentity) }

        // 4. Ship, then advance the cursor (only after the daemon accepted).
        if !batch.isEmpty {
            try port.ingest(batch)
            report.eventsSent = batch.count
        }
        if let cursorToSave {
            try port.saveRolloutCursor(cursorToSave)
        }
        for cursor in childCursorsToSave {
            try port.saveRolloutCursor(cursor)
        }
        return report
    }

    /// True only when the daemon confirms the session never had a Turn (or
    /// never saw it at all). Any lookup failure keeps the session: a missed
    /// query must never delete real work.
    func sessionNeverUsed(_ sessionID: SessionID) -> Bool {
        do {
            guard let detail = try port.session(sessionID: sessionID) else { return true }
            return detail.summary.isProvisional
        } catch {
            return false
        }
    }

    // MARK: - Provider detection

    static func provider(
        for hook: [String: Any],
        selection: HelperAgentSelection,
        environment: [String: String]
    ) -> AgentProvider {
        switch selection {
        case .codex: return .codex
        case .claude: return .claude
        case .auto: break
        }
        if environment["CLAUDE_PROJECT_DIR"] != nil { return .claude }
        if let transcript = hook.string("transcript_path"), transcript.contains("/.claude/") { return .claude }
        if hook["prompt_id"] != nil || hook["effort"] != nil { return .claude }
        if hook["turn_id"] != nil { return .codex }
        if environment["CODEX_HOME"] != nil { return .codex }
        return .codex
    }

    // MARK: - Rich source location

    func richSourcePath(provider: AgentProvider, sessionID: SessionID, hook: [String: Any]) -> String? {
        switch provider {
        case .claude:
            if let path = hook.string("transcript_path"), !path.isEmpty { return path }
            return RichSourceLocator.claudeTranscript(for: sessionID, cwd: hook.string("cwd"), homeDirectory: homeDirectory)
        case .codex:
            let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
            return RichSourceLocator.codexRollout(for: sessionID, sessionsDirectory: codexHome.appendingPathComponent("sessions", isDirectory: true))
        }
    }

    // MARK: - Increment reading

    enum IncrementRead {
        /// `currentTurnID` is the Turn the read left open (or last named) —
        /// seeded from the daemon's turns, advanced by the increment itself —
        /// so the hook events ingested right after attach to the right Turn.
        case increment(events: [AgentIngressEvent], cursor: RolloutCursor?, lines: Int, currentTurnID: TurnID?)
        /// Cold start on a large history: the daemon rebuilds it, this hook
        /// invocation ships only its own events.
        case delegatedToDaemon(bytes: UInt64)
    }

    func readIncrement(
        path: String,
        sessionID: SessionID,
        adapter: any AgentAdapter
    ) throws -> IncrementRead {
        let existing = try port.rolloutCursor(path: path)
        if existing == nil,
           let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value,
           size > UInt64(maximumInlineHistoryBytes) {
            try port.requestBackfill(sessionID: sessionID, path: path)
            return .delegatedToDaemon(bytes: size)
        }
        let turns = try port.session(sessionID: sessionID)?.turns ?? []
        let read = try RichSourceReader.read(
            path: path,
            sessionID: sessionID,
            adapter: adapter,
            fromOffset: existing?.byteOffset ?? 0,
            initialTurnID: (turns.last(where: { $0.isOpen }) ?? turns.last)?.id,
            maximumBytes: maximumIncrementBytes
        )
        guard read.lines > 0 || read.cursor.byteOffset != existing?.byteOffset else {
            return .increment(events: [], cursor: nil, lines: 0, currentTurnID: read.finalTurnID)
        }
        return .increment(events: read.events, cursor: read.cursor, lines: read.lines, currentTurnID: read.finalTurnID)
    }
}
