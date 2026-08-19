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
            return Self.claudeTranscript(for: sessionID, cwd: hook.string("cwd"), homeDirectory: homeDirectory)
        case .codex:
            let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
            return Self.codexRollout(for: sessionID, sessionsDirectory: codexHome.appendingPathComponent("sessions", isDirectory: true))
        case .unknown:
            return nil
        }
    }

    /// `~/.claude/projects/<slug-of-cwd>/<session>.jsonl`, falling back to a
    /// search over every project directory.
    static func claudeTranscript(for sessionID: SessionID, cwd: String?, homeDirectory: URL) -> String? {
        let projects = homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
        let fileName = "\(sessionID.rawValue).jsonl"
        if let cwd {
            let slug = cwd.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            let candidate = projects.appendingPathComponent(slug).appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        }
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        for directory in directories {
            let candidate = directory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    /// `~/.codex/sessions/YYYY/MM/DD/rollout-<stamp>-<session>.jsonl`. Newest
    /// day directories are searched first; the session id is the file suffix.
    static func codexRollout(for sessionID: SessionID, sessionsDirectory: URL) -> String? {
        let suffix = "-\(sessionID.rawValue).jsonl"
        let fm = FileManager.default
        guard let years = try? fm.contentsOfDirectory(atPath: sessionsDirectory.path) else { return nil }
        for year in years.sorted(by: >) {
            let yearURL = sessionsDirectory.appendingPathComponent(year, isDirectory: true)
            guard let months = try? fm.contentsOfDirectory(atPath: yearURL.path) else { continue }
            for month in months.sorted(by: >) {
                let monthURL = yearURL.appendingPathComponent(month, isDirectory: true)
                guard let days = try? fm.contentsOfDirectory(atPath: monthURL.path) else { continue }
                for day in days.sorted(by: >) {
                    let dayURL = monthURL.appendingPathComponent(day, isDirectory: true)
                    guard let files = try? fm.contentsOfDirectory(atPath: dayURL.path) else { continue }
                    if let match = files.first(where: { $0.hasSuffix(suffix) }) {
                        return dayURL.appendingPathComponent(match).path
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Increment reading

    func readIncrement(
        path: String,
        sessionID: SessionID,
        adapter: any AgentAdapter
    ) throws -> ([AgentIngressEvent], RolloutCursor?, Int) {
        let url = URL(fileURLWithPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let existing = try port.rolloutCursor(path: path)
        var offset = existing?.byteOffset ?? 0
        if fileSize < offset { offset = 0 }   // truncated / rewritten
        guard fileSize > offset else { return ([], nil, 0) }

        var state = RolloutReadState()
        let turns = try port.session(sessionID: sessionID)?.turns ?? []
        state.currentTurnID = (turns.last(where: { $0.isOpen }) ?? turns.last)?.id

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var data = try handle.readToEnd() ?? Data()
        if data.count > maximumIncrementBytes {
            // Keep the tail; skip to the first newline so we start on a line.
            data = Data(data.suffix(maximumIncrementBytes))
            if let newline = data.firstIndex(of: 0x0A) {
                let skipped = data.distance(from: data.startIndex, to: newline) + 1
                offset += UInt64(fileSize) - UInt64(data.count) + UInt64(skipped)
                data = Data(data[data.index(after: newline)...])
            }
        }

        var events: [AgentIngressEvent] = []
        var lines = 0
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
                if let lineEvents = try? adapter.events(fromRolloutLine: line, context: context, state: &state) {
                    events.append(contentsOf: lineEvents)
                }
                lines += 1
            }
            let next = data.index(after: newline)
            consumed += data.distance(from: lineStart, to: next)
            lineStart = next
            if lineStart == data.endIndex { break }
        }

        let cursor = RolloutCursor(
            path: path,
            byteOffset: offset + UInt64(consumed),
            fileSize: fileSize,
            sessionID: sessionID
        )
        return (events, cursor, lines)
    }
}
