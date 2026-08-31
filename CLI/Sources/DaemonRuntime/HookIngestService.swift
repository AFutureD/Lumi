import Adapters
import Core
import Diagnostics
import Logging
import Transport
import Foundation

private let log = Logger(label: "agent")

/// The daemon's whole job for one forwarded hook frame:
///
/// 1. decode the frame's raw stdin per agent into the typed payload,
/// 2. read the newly appended part of that session's transcript / rollout
///    (`RichSourceCatchUp`) and apply its Agent-domain events,
/// 3. reduce the hook payload itself (lifecycle / phase / turn / markers),
/// 4. detect the AaaS wrapper from the frame's environment and re-assert its
///    title last, so it wins over any adapter-supplied title.
///
/// The increment is read *before* the hook so tool calls, thinking and text
/// that led up to this hook are already in place when its state lands — and
/// so the hook events attach to the Turn the increment left open.
///
/// One actor: hook frames are processed strictly in arrival order. Watchers
/// and backfill run outside it, which is safe — events dedupe by id and the
/// cursor save is last-writer-wins on identical content.
public actor HookIngestService {
    public struct Report: Sendable {
        public var provider: AgentProvider
        public var sessionID: SessionID?
        public var eventName: String?
        public var richSourcePath: String?
        public var richSourceLinesRead = 0
        public var eventsApplied = 0
        public var warnings: [String] = []
        public var notes: [String] = []
        public var aaasKind: String?
        public var aaasAgentID: String?
        public var aaasTerminalProgram: String?
    }

    private let repository: any SessionRepository
    private let backfill: TranscriptBackfillQueue
    private let codexAdapter: CodexAdapter
    private let claudeAdapter = ClaudeAdapter()
    private let homeDirectory: URL
    /// The daemon's own Codex sessions directory; a `CODEX_HOME` forwarded in
    /// the frame's environment overrides it per invocation.
    private let codexSessionsDirectory: URL
    /// Safety valve for a resumed multi-megabyte transcript.
    private let maximumIncrementBytes: Int
    /// No cursor for the source (cold start) and a file bigger than this →
    /// the history goes to the backfill worker instead of the hook path.
    private let maximumInlineHistoryBytes: Int
    private let onEvent: @Sendable (AgentIngressEvent) -> Void

    public init(
        repository: any SessionRepository,
        backfill: TranscriptBackfillQueue,
        codexAdapter: CodexAdapter = CodexAdapter(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        codexSessionsDirectory: URL? = nil,
        maximumIncrementBytes: Int = 32 * 1024 * 1024,
        maximumInlineHistoryBytes: Int = 1024 * 1024,
        onEvent: @escaping @Sendable (AgentIngressEvent) -> Void = { _ in }
    ) {
        self.repository = repository
        self.backfill = backfill
        self.codexAdapter = codexAdapter
        self.homeDirectory = homeDirectory
        self.codexSessionsDirectory = codexSessionsDirectory
            ?? homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
        self.maximumIncrementBytes = maximumIncrementBytes
        self.maximumInlineHistoryBytes = maximumInlineHistoryBytes
        self.onEvent = onEvent
    }

    public func ingest(
        data: Data,
        agent: AgentProvider,
        environment: [String: String],
        createdAt: Date
    ) async throws -> Report {
        var report = Report(provider: agent)
        var batch: [AgentIngressEvent] = []
        let sessionID: SessionID
        var richAvailable = false
        var historyDelegated = false
        var currentTurnID: TurnID?
        var hookEvents: [AgentIngressEvent] = []
        var childIdentity: AgentIngressEvent?

        switch agent {
        case .codex:
            let payload: CodexHookPayload
            do {
                payload = try CodexHookPayload(data: data)
            } catch let AgentAdapterError.unsupportedEvent(name) {
                return try await unsupportedEventCatchUp(
                    name: name, data: data, agent: agent, environment: environment, report: report
                )
            }
            sessionID = SessionID(payload.sessionID)
            report.sessionID = sessionID
            report.eventName = payload.eventName.rawValue

            let richPath = codexRolloutPath(for: sessionID, environment: environment)
            (richAvailable, historyDelegated, currentTurnID) = await catchUp(
                path: richPath, sessionID: sessionID, adapter: codexAdapter, report: &report
            )

            let options = HookIngestOptions(
                richSourceAvailable: richAvailable,
                currentTurnID: currentTurnID,
                receivedAt: createdAt
            )
            hookEvents = try codexAdapter.events(fromHook: payload, raw: data, options: options)

        case .claude:
            let payload: ClaudeHookPayload
            do {
                payload = try ClaudeHookPayload(data: data)
            } catch let AgentAdapterError.unsupportedEvent(name) {
                return try await unsupportedEventCatchUp(
                    name: name, data: data, agent: agent, environment: environment, report: report
                )
            }
            sessionID = SessionID(payload.sessionID)
            report.sessionID = sessionID
            report.eventName = payload.eventName.rawValue

            let richPath = payload.transcriptPath.flatMap { $0.isEmpty ? nil : $0 }
                ?? RichSourceLocator.claudeTranscript(for: sessionID, cwd: payload.cwd, homeDirectory: homeDirectory)
            (richAvailable, historyDelegated, currentTurnID) = await catchUp(
                path: richPath, sessionID: sessionID, adapter: claudeAdapter, report: &report
            )

            // A hook carrying `agent_id` also advances the derived child
            // session — its sidechain transcript increment plus the title and
            // lineage from `.meta.json`.
            var childRichAvailable = false
            if let agentID = payload.agentID, payload.isRealSubagent {
                let childID = ClaudeSubagentIdentity.sessionID(parent: sessionID, agentID: agentID)
                let childPath = payload.agentTranscriptPath.flatMap { $0.isEmpty ? nil : $0 }
                    ?? report.richSourcePath.map {
                        ClaudeSubagentIdentity.transcriptPath(parentTranscriptPath: $0, parent: sessionID, agentID: agentID)
                    }
                if let childPath, FileManager.default.isReadableFile(atPath: childPath) {
                    var childReport = Report(provider: .claude)
                    (childRichAvailable, _, _) = await catchUp(
                        path: childPath, sessionID: childID, adapter: claudeAdapter, report: &childReport
                    )
                    report.warnings.append(contentsOf: childReport.warnings)
                    report.notes.append(contentsOf: childReport.notes)
                    if let meta = ClaudeSubagentIdentity.readMeta(atTranscriptPath: childPath) {
                        let occurredAt = payload.timestamp ?? createdAt
                        let fingerprint = [meta.agentType, meta.description, meta.model, payload.agentType]
                            .map { $0 ?? "" }.joined(separator: "|")
                        // Applied after the hook's own child event so the spawn
                        // description wins over the agent-type fallback title.
                        // The timestamp keeps the id unique per hook (each hook
                        // must re-assert past the child event's own title) while
                        // a replay of the same frame stays deduplicated.
                        childIdentity = AgentIngressEvent(
                            eventID: EventID(
                                "claude-subagent-meta:\(childID.rawValue)"
                                    + ":\(occurredAt.timeIntervalSince1970):\(StableHash.fnv1a(fingerprint))"
                            ),
                            sessionID: childID,
                            agent: .claudeSubagent,
                            occurredAt: occurredAt,
                            title: ClaudeSubagentIdentity.title(agentType: payload.agentType, meta: meta),
                            lineage: ClaudeSubagentIdentity.lineage(parent: sessionID, agentType: payload.agentType, meta: meta)
                        )
                    }
                } else {
                    report.notes.append("subagent_transcript_unavailable agent=\(agentID)")
                }
            }

            var options = HookIngestOptions(
                richSourceAvailable: payload.agentID != nil && payload.isRealSubagent
                    ? childRichAvailable
                    : richAvailable,
                currentTurnID: currentTurnID,
                receivedAt: createdAt
            )
            // A Claude session that ends while the daemon still holds it as
            // provisional (no Turn ever) and never wrote a transcript was
            // never used — a config-loading probe — and is discarded instead
            // of ended. A delegated history means the backfill is about to
            // prove the session was used; the heuristic must not race it.
            if payload.eventName == .sessionEnd, !richAvailable, !historyDelegated {
                options.sessionNeverUsed = await sessionNeverUsed(sessionID)
                if options.sessionNeverUsed {
                    report.notes.append("session_discarded_never_used")
                }
            }
            hookEvents = try claudeAdapter.events(fromHook: payload, raw: data, options: options)
        }

        // The AaaS layer: which application hosts this session. Detection is
        // total; ownership rides on every main-session hook event so it lands
        // whatever subset of the batch survives deduplication. Subagent child
        // sessions keep a nil ownership on purpose — their titles stay with
        // the spawn metadata / native chains.
        let aaas = AaaS.detect(provider: agent, environment: environment, homeDirectory: homeDirectory)
        report.aaasKind = aaas.kind.rawValue
        report.aaasAgentID = aaas.agentID
        report.aaasTerminalProgram = aaas.terminalProgram
        let ownership = aaas.ownership
        batch.append(contentsOf: hookEvents.map { event in
            guard event.sessionID == sessionID else { return event }
            var stamped = event
            stamped.aaas = ownership
            // The owning AaaS is the sole title authority on wrapper-owned
            // sessions: adapters stamp the native thread name on hook events,
            // and an ownership-stamped event passes the reduction's title
            // gate — so strip it here. The wrapper-title event below is the
            // only retitler, even while its store is unreadable.
            if !ownership.allowsNativeTitle { stamped.title = nil }
            return stamped
        })
        if let childIdentity { batch.append(childIdentity) }

        // Only the wrappers carry a title store of their own; the other AaaS
        // title through the agent's native channels. Re-asserted on every
        // hook so renames follow; applied last so it beats any title an
        // adapter event in this batch carried. A batch that discards the
        // session gets no title.
        if !batch.contains(where: { $0.disposition == .discard }) {
            if let title = aaas.title {
                batch.append(AgentIngressEvent(
                    eventID: EventID(
                        "aaas-title:\(aaas.kind.rawValue):\(sessionID.rawValue)"
                            + ":\(createdAt.timeIntervalSince1970):\(StableHash.fnv1a(title))"
                    ),
                    sessionID: sessionID,
                    agent: agent == .claude ? .claude : .codex,
                    occurredAt: createdAt,
                    title: title,
                    aaas: ownership
                ))
            } else if aaas.kind == .paseo || aaas.kind == .raft {
                report.notes.append("aaas_title_unavailable kind=\(aaas.kind.rawValue)")
            }
        }

        for event in batch {
            if try await repository.apply(event) {
                report.eventsApplied += 1
                onEvent(event)
            }
        }
        return report
    }

    private func codexRolloutPath(for sessionID: SessionID, environment: [String: String]) -> String? {
        let sessionsDirectory = environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("sessions", isDirectory: true) }
            ?? codexSessionsDirectory
        return RichSourceLocator.codexRollout(for: sessionID, sessionsDirectory: sessionsDirectory)
    }

    /// An event name outside the closed vocabulary is a mis-registered hook.
    /// The frame still marks a read moment: degrade to increment-only — run
    /// the rich-source catch-up, log the name, reduce nothing — instead of
    /// losing the read window with the frame.
    private func unsupportedEventCatchUp(
        name: String,
        data: Data,
        agent: AgentProvider,
        environment: [String: String],
        report initial: Report
    ) async throws -> Report {
        guard let context = HookFallback.context(data: data) else {
            throw AgentAdapterError.unsupportedEvent(name)
        }
        var report = initial
        let sessionID = SessionID(context.sessionID)
        report.sessionID = sessionID
        report.eventName = name
        report.warnings.append("hook_event_unsupported name=\(name)")
        let path: String?
        let adapter: any AgentAdapter
        switch agent {
        case .codex:
            path = codexRolloutPath(for: sessionID, environment: environment)
            adapter = codexAdapter
        case .claude:
            path = context.transcriptPath.flatMap { $0.isEmpty ? nil : $0 }
                ?? RichSourceLocator.claudeTranscript(for: sessionID, cwd: context.cwd, homeDirectory: homeDirectory)
            adapter = claudeAdapter
        }
        _ = await catchUp(path: path, sessionID: sessionID, adapter: adapter, report: &report)
        return report
    }

    /// Brings the rich source up to date ahead of the hook reduction.
    /// Returns (readable, delegatedToBackfill, turn the read left open).
    private func catchUp(
        path: String?,
        sessionID: SessionID,
        adapter: any AgentAdapter,
        report: inout Report
    ) async -> (Bool, Bool, TurnID?) {
        guard let path, FileManager.default.isReadableFile(atPath: path) else {
            if let path { report.warnings.append("rich_source_unreadable path=\(path)") }
            return (false, false, nil)
        }
        report.richSourcePath = path
        do {
            // Cold start on a large history: the hook path is latency-bound,
            // so the backfill worker replays it and this invocation reduces
            // the hook alone. Both sides use the same stable item ids, so the
            // backfill later upserts over the hook's placeholder rows.
            if try await repository.rolloutCursor(path: path) == nil,
               let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value,
               size > UInt64(maximumInlineHistoryBytes) {
                await backfill.enqueue(sessionID: sessionID, path: path)
                report.notes.append("history_delegated_to_backfill bytes=\(size)")
                return (false, true, nil)
            }
            let result = try await RichSourceCatchUp.run(
                repository: repository,
                sessionID: sessionID,
                path: path,
                adapter: adapter,
                maximumBytes: maximumIncrementBytes,
                onEvent: onEvent
            )
            report.richSourceLinesRead += result.lines
            report.eventsApplied += result.applied
            return (true, false, result.finalTurnID)
        } catch {
            // A failed read contributed nothing: fall back to hook-only for
            // this invocation rather than suppressing the hook's turn and
            // items on the promise of transcript data that never came.
            report.warnings.append("rich_source_read_failed path=\(path) error=\(error)")
            return (false, false, nil)
        }
    }

    /// True only when the store confirms the session never had a Turn (or
    /// never saw it at all). Any lookup failure keeps the session: a missed
    /// query must never delete real work.
    private func sessionNeverUsed(_ sessionID: SessionID) async -> Bool {
        do {
            guard let summary = try await repository.sessionSummary(id: sessionID) else {
                return true
            }
            return summary.isProvisional
        } catch {
            return false
        }
    }
}


