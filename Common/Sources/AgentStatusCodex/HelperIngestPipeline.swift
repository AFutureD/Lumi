import AgentStatusCore
import AgentStatusTransport
import Foundation

/// What the helper needs from the daemon. The executable backs this with the
/// Unix-socket IPC client; tests back it with an in-memory repository.
public protocol HelperDaemonPort: Sendable {
    func ingest(_ events: [AgentIngressEvent]) throws
    func rolloutCursor(path: String) throws -> RolloutCursor?
    func saveRolloutCursor(_ cursor: RolloutCursor) throws
    /// Summary + turns as the daemon holds them; the timeline page is not needed.
    func session(sessionID: SessionID) throws -> SessionDetail?
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

    public init(
        port: any HelperDaemonPort,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        codexAdapter: CodexAdapter = CodexAdapter(),
        claudeAdapter: ClaudeAdapter = ClaudeAdapter(),
        maximumIncrementBytes: Int = 32 * 1024 * 1024
    ) {
        self.port = port
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.codexAdapter = codexAdapter
        self.claudeAdapter = claudeAdapter
        self.maximumIncrementBytes = maximumIncrementBytes
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
        if let richPath, FileManager.default.isReadableFile(atPath: richPath) {
            richAvailable = true
            report.richSourcePath = richPath
            do {
                let (events, cursor, lines) = try readIncrement(
                    path: richPath,
                    sessionID: sessionID,
                    adapter: adapter
                )
                batch.append(contentsOf: events)
                cursorToSave = cursor
                report.richSourceLinesRead = lines
            } catch {
                report.warnings.append("rich_source_read_failed path=\(richPath) error=\(error)")
            }
        } else if let richPath {
            report.warnings.append("rich_source_unreadable path=\(richPath)")
        }

        // 3. The hook itself. A Claude session that ends while the daemon
        // still holds it as provisional (no Turn ever) and never wrote a
        // transcript was never used — a desktop config-loading probe or a
        // launch quit before any prompt — and is discarded instead of ended.
        var options = HookIngestOptions(richSourceAvailable: richAvailable)
        if provider == .claude, report.hookEventName == "SessionEnd", !richAvailable {
            options.sessionNeverUsed = sessionNeverUsed(sessionID)
            if options.sessionNeverUsed {
                report.notes.append("session_discarded_never_used")
            }
        }
        let hookEvents = try adapter.events(fromHookData: hookData, options: options)
        batch.append(contentsOf: hookEvents)

        // 4. Ship, then advance the cursor (only after the daemon accepted).
        if !batch.isEmpty {
            try port.ingest(batch)
            report.eventsSent = batch.count
        }
        if let cursorToSave {
            try port.saveRolloutCursor(cursorToSave)
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
        case .unknown:
            return nil
        }
    }

    // MARK: - Increment reading

    func readIncrement(
        path: String,
        sessionID: SessionID,
        adapter: any AgentAdapter
    ) throws -> ([AgentIngressEvent], RolloutCursor?, Int) {
        let existing = try port.rolloutCursor(path: path)
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
            return ([], nil, 0)
        }
        return (read.events, read.cursor, read.lines)
    }
}
