import Core
import Transport
import Foundation
import Testing
@testable import Adapters

/// In-memory daemon stand-in with the daemon's reductions applied inline.
final class MemoryDaemonPort: HelperDaemonPort, @unchecked Sendable {
    private(set) var ingested: [AgentIngressEvent] = []
    private var cursors: [String: RolloutCursor] = [:]
    private var summaries: [SessionID: SessionSummary] = [:]
    private var turnsBySession: [SessionID: [TurnID: TurnSummary]] = [:]
    private var items: [SessionID: [TimelineItemID: TimelineItem]] = [:]
    private var seen: Set<EventID> = []
    private(set) var ignored: Set<SessionID> = []
    /// Simulates a daemon that cannot answer `get_session`.
    var sessionLookupError: Error?

    func ingest(_ events: [AgentIngressEvent]) throws {
        ingested.append(contentsOf: events)
        for event in events where seen.insert(event.eventID).inserted {
            if event.disposition == .discard {
                ignored.insert(event.sessionID)
                summaries.removeValue(forKey: event.sessionID)
                turnsBySession.removeValue(forKey: event.sessionID)
                items.removeValue(forKey: event.sessionID)
                continue
            }
            summaries[event.sessionID] = SessionReduction.summary(applying: event, to: summaries[event.sessionID])
            if let turnID = event.turnID ?? event.turn?.id,
               let turn = TurnReduction.summary(applying: event, to: turnsBySession[event.sessionID]?[turnID]) {
                turnsBySession[event.sessionID, default: [:]][turnID] = turn
            }
            if let item = event.timelineItem {
                let existing = items[event.sessionID]?[item.id]
                if existing == nil || item.occurredAt >= existing!.occurredAt {
                    items[event.sessionID, default: [:]][item.id] = item
                }
            }
        }
    }

    func rolloutCursor(path: String) throws -> RolloutCursor? { cursors[path] }
    func saveRolloutCursor(_ cursor: RolloutCursor) throws { cursors[cursor.path] = cursor }

    private(set) var backfillRequests: [(sessionID: SessionID, path: String)] = []
    func requestBackfill(sessionID: SessionID, path: String) throws {
        backfillRequests.append((sessionID, path))
    }

    func session(sessionID: SessionID) throws -> SessionDetail? {
        if let sessionLookupError { throw sessionLookupError }
        return detail(sessionID)
    }

    func turns(sessionID: SessionID) -> [TurnSummary] {
        (turnsBySession[sessionID]?.values).map(Array.init)?.sorted { $0.startedAt < $1.startedAt } ?? []
    }

    func detail(_ sessionID: SessionID) -> SessionDetail? {
        guard let summary = summaries[sessionID] else { return nil }
        return SessionDetail(
            summary: summary,
            turns: turns(sessionID: sessionID),
            timeline: (items[sessionID]?.values).map(Array.init) ?? []
        )
    }
}

private struct StubLookupFailure: Error {}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("helper-pipeline-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func hook(_ fields: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: fields)
}

@Test func claudeHooksAndTranscriptFoldIntoOneTurnWithoutDuplicates() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let session = "11111111-2222-3333-4444-555555555555"
    let prompt = "prompt-aaaa"
    let projectDir = home.appendingPathComponent(".claude/projects/-tmp-proj", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let transcript = projectDir.appendingPathComponent("\(session).jsonl")

    let port = MemoryDaemonPort()
    let pipeline = HelperIngestPipeline(port: port, environment: [:], homeDirectory: home)
    let base: [String: Any] = [
        "session_id": session, "transcript_path": transcript.path, "cwd": "/tmp/proj",
        "permission_mode": "default", "prompt_id": prompt,
    ]

    // Turn 1: prompt hook before the transcript has flushed anything.
    try "".write(to: transcript, atomically: true, encoding: .utf8)
    var report = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "UserPromptSubmit", "prompt": "list files"]) { $1 }))
    #expect(report.provider == .claude)
    #expect(report.richSourcePath == transcript.path)

    // Transcript catches up: user record + assistant thinking + tool_use.
    let lines: [[String: Any]] = [
        ["type": "user", "uuid": "u1", "sessionId": session, "promptId": prompt, "timestamp": "2026-08-18T14:35:28.342Z", "cwd": "/tmp/proj",
         "message": ["role": "user", "content": "list files\n\n<system-reminder>be brief</system-reminder>"]],
        ["type": "assistant", "uuid": "a1", "sessionId": session, "timestamp": "2026-08-18T14:35:30.000Z",
         "message": ["role": "assistant", "model": "claude-opus-4-7", "content": [
            ["type": "thinking", "thinking": "I should run ls"],
            ["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "ls"]],
         ], "usage": ["input_tokens": 6, "cache_read_input_tokens": 100, "output_tokens": 20]]],
    ]
    try lines.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n").appending("\n")
        .write(to: transcript, atomically: true, encoding: .utf8)
    report = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_use_id": "toolu_1", "tool_input": ["command": "ls"]]) { $1 }))
    #expect(report.richSourceLinesRead == 2)

    // Result lands in transcript, then PostToolUse + Stop hooks.
    let more: [[String: Any]] = [
        ["type": "user", "uuid": "u2", "sessionId": session, "timestamp": "2026-08-18T14:35:31.000Z",
         "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "a\nb", "is_error": false]]],
         "toolUseResult": ["stdout": "a\nb"]],
        ["type": "attachment", "uuid": "at1", "sessionId": session, "timestamp": "2026-08-18T14:35:32.000Z",
         "attachment": ["type": "auto_mode", "bypass": true, "steerOnly": true]],
        ["type": "assistant", "uuid": "a2", "sessionId": session, "timestamp": "2026-08-18T14:35:33.000Z",
         "message": ["role": "assistant", "model": "claude-opus-4-7", "content": [["type": "text", "text": "Two files."]]]],
    ]
    let handle = try FileHandle(forWritingTo: transcript)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((more.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n") + "\n").utf8))
    try handle.close()
    _ = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_use_id": "toolu_1", "tool_response": ["stdout": "a\nb"]]) { $1 }))
    _ = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "Stop", "last_assistant_message": "Two files."]) { $1 }))

    let detail = try #require(port.detail(SessionID(session)))
    #expect(detail.summary.agent == .claude)
    #expect(detail.summary.lifecycle == .waitingForInput)
    #expect(detail.turns.count == 1)
    let turn = detail.turns[0]
    #expect(turn.id == TurnID(prompt))
    #expect(turn.prompt == "list files")
    #expect(turn.outcome == .completed)
    #expect(turn.toolCallCount == 1)

    let rows = TimelineProjection.rows(from: detail.timeline)
    let tags = rows.map(\.tag)
    #expect(tags == [.user, .context, .reasoning, .tool, .result, .config, .assistant, .turnEnd] || tags == [.context, .user, .reasoning, .tool, .result, .config, .assistant, .turnEnd])
    // auto_mode is a run-mode attachment: CONFIG, spanning the lanes.
    #expect(rows.first { $0.tag == .config }?.spansLanes == true)
    #expect(rows.filter { $0.tag == .tool }.count == 1)
    #expect(rows.filter { $0.tag == .result }.count == 1)
    #expect(rows.first { $0.tag == .result }?.toolUseID == "toolu_1")
    #expect(rows.first { $0.tag == .result }?.text.hasPrefix("Bash") == true)
    #expect(rows.first { $0.tag == .assistant }?.status == .succeeded)
    #expect(rows.allSatisfy { $0.tag == .context || $0.tag == .config || $0.turnID == TurnID(prompt) })

    // Nothing new: cursor at end, no extra events beyond the hook.
    let before = port.ingested.count
    let idle = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_use_id": "toolu_1"]) { $1 }))
    #expect(idle.richSourceLinesRead == 0)
    #expect(port.ingested.count == before + 1)
}

@Test func codexHooksAndRolloutFoldIntoTurnWithToolPairs() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let session = "01a01326-61da-7b30-8555-2b71d86d5ab4"
    let day = home.appendingPathComponent(".codex/sessions/2026/08/18", isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let rollout = day.appendingPathComponent("rollout-2026-08-18T12-34-37-\(session).jsonl")

    let records: [[String: Any]] = [
        ["timestamp": "2026-08-18T04:34:37.000Z", "type": "session_meta", "payload": ["id": session, "cwd": "/tmp/proj", "model_provider": "openai", "cli_version": "0.9", "base_instructions": "be good"]],
        ["timestamp": "2026-08-18T04:35:00.000Z", "type": "turn_context", "payload": ["turn_id": "turn-1", "model": "gpt-5", "effort": "high", "cwd": "/tmp/proj"]],
        ["timestamp": "2026-08-18T04:35:01.000Z", "type": "event_msg", "payload": ["type": "task_started", "turn_id": "turn-1"]],
        ["timestamp": "2026-08-18T04:35:01.500Z", "type": "event_msg", "payload": ["type": "user_message", "message": "fix the bug"]],
        ["timestamp": "2026-08-18T04:35:05.000Z", "type": "event_msg", "payload": ["type": "agent_reasoning", "text": "Looking at the code"]],
        ["timestamp": "2026-08-18T04:35:10.000Z", "type": "response_item", "payload": ["type": "custom_tool_call", "call_id": "call_1", "name": "exec", "input": "ls -la"]],
        ["timestamp": "2026-08-18T04:35:11.000Z", "type": "response_item", "payload": ["type": "custom_tool_call_output", "call_id": "call_1", "output": "{\"output\":\"total 0\",\"metadata\":{\"exit_code\":0}}"]],
        ["timestamp": "2026-08-18T04:35:12.000Z", "type": "response_item", "payload": ["type": "function_call", "call_id": "call_2", "name": "shell", "arguments": "{\"command\":[\"false\"]}"]],
        ["timestamp": "2026-08-18T04:35:13.000Z", "type": "response_item", "payload": ["type": "function_call_output", "call_id": "call_2", "output": "{\"output\":\"\",\"metadata\":{\"exit_code\":1}}"]],
        ["timestamp": "2026-08-18T04:35:20.000Z", "type": "event_msg", "payload": ["type": "agent_message", "message": "Fixed it."]],
        ["timestamp": "2026-08-18T04:35:21.000Z", "type": "event_msg", "payload": ["type": "task_complete", "turn_id": "turn-1", "last_agent_message": "Fixed it."]],
    ]
    try records.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n").appending("\n")
        .write(to: rollout, atomically: true, encoding: .utf8)

    let port = MemoryDaemonPort()
    let pipeline = HelperIngestPipeline(
        port: port,
        environment: ["CODEX_HOME": home.appendingPathComponent(".codex").path],
        homeDirectory: home,
        codexAdapter: CodexAdapter(threads: FixedThreadIdentities(identities: [:]))
    )
    let base: [String: Any] = ["session_id": session, "turn_id": "turn-1", "cwd": "/tmp/proj"]
    let report = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "Stop", "last_assistant_message": "Fixed it."]) { $1 }))
    #expect(report.provider == .codex)
    #expect(report.richSourcePath == rollout.path)
    #expect(report.richSourceLinesRead == records.count)

    let detail = try #require(port.detail(SessionID(session)))
    #expect(detail.summary.workspace == "/tmp/proj")
    #expect(detail.turns.count == 1)
    #expect(detail.turns[0].id == TurnID("turn-1"))
    #expect(detail.turns[0].prompt == "fix the bug")
    #expect(detail.turns[0].outcome == .completed)
    #expect(detail.turns[0].toolCallCount == 2)

    let rows = TimelineProjection.rows(from: detail.timeline)
    #expect(rows.map(\.tag) == [.session, .context, .config, .user, .reasoning, .tool, .result, .tool, .failed, .assistant, .turnEnd])
    #expect(rows[0].spansLanes)
    #expect(rows[1].count == 1)          // base instructions (model configuration is header metadata)
    #expect(rows[2].spansLanes)          // turn_context is configuration
    #expect(rows[5].toolUseID == "call_1" && rows[6].toolUseID == "call_1")
    #expect(rows[6].text.contains("exec"))
    #expect(rows[8].tag == .failed && rows[8].toolUseID == "call_2")
    #expect(rows[9].status == .succeeded)
    #expect(rows.dropFirst(2).allSatisfy { $0.turnID == TurnID("turn-1") })

    // Cursor persisted at end of file; a second read is empty.
    let cursor = try #require(try port.rolloutCursor(path: rollout.path))
    #expect(cursor.byteOffset == cursor.fileSize)
    #expect(try pipeline.run(hookData: hook(base.merging(["hook_event_name": "Stop"]) { $1 })).richSourceLinesRead == 0)
}

/// The Claude desktop app spawns one-shot CLI probes to load slash-command /
/// agent lists: SessionStart + SessionEnd ~2 s apart, no turn, no transcript.
@Test func claudeSessionEndingBeforeFirstTurnIsDiscarded() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let session = "63759c38-d24f-492e-96bd-358b126f85cc"
    let transcript = home.appendingPathComponent(".claude/projects/-Users-x/\(session).jsonl").path
    let port = MemoryDaemonPort()
    let pipeline = HelperIngestPipeline(port: port, environment: [:], homeDirectory: home)
    let base: [String: Any] = ["session_id": session, "transcript_path": transcript, "cwd": "/Users/x"]

    let start = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "SessionStart", "source": "startup"]) { $1 }))
    #expect(start.eventsSent == 1)
    let provisional = try #require(port.detail(SessionID(session)))
    #expect(provisional.summary.isProvisional)
    #expect(provisional.summary.firstTurnAt == nil)

    let end = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "SessionEnd", "reason": "other"]) { $1 }))
    #expect(end.notes == ["session_discarded_never_used"])
    #expect(end.eventsSent == 1)
    let last = try #require(port.ingested.last)
    #expect(last.disposition == .discard)
    #expect(last.lifecycle == nil && last.timelineItem == nil)
    #expect(port.detail(SessionID(session)) == nil)
    #expect(port.ignored.contains(SessionID(session)))
}

@Test func claudeSessionWithATurnEndsNormallyWithoutTranscript() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let session = "0696204b-47db-42b6-9a4a-b00792e596c7"
    let transcript = home.appendingPathComponent(".claude/projects/-Users-x/\(session).jsonl").path
    let port = MemoryDaemonPort()
    let pipeline = HelperIngestPipeline(port: port, environment: [:], homeDirectory: home)
    let base: [String: Any] = ["session_id": session, "transcript_path": transcript, "cwd": "/Users/x"]

    _ = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "SessionStart", "source": "startup"]) { $1 }))
    _ = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "UserPromptSubmit", "prompt_id": "p1", "prompt": "hi"]) { $1 }))
    let used = try #require(port.detail(SessionID(session)))
    #expect(!used.summary.isProvisional)
    #expect(used.summary.firstTurnAt != nil)

    let end = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "SessionEnd", "reason": "other"]) { $1 }))
    #expect(end.notes.isEmpty)
    let detail = try #require(port.detail(SessionID(session)))
    #expect(detail.summary.lifecycle == .completed)
    #expect(port.ingested.last?.disposition == nil)
    #expect(port.ignored.isEmpty)
}

@Test func claudeSessionEndKeepsSessionWhenTranscriptExistsOrLookupFails() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let port = MemoryDaemonPort()
    let pipeline = HelperIngestPipeline(port: port, environment: [:], homeDirectory: home)

    // Transcript on disk (even empty): resumed / real session, keep it.
    let withTranscript = "11111111-0000-0000-0000-000000000001"
    let projectDir = home.appendingPathComponent(".claude/projects/-Users-x", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let transcript = projectDir.appendingPathComponent("\(withTranscript).jsonl")
    try "".write(to: transcript, atomically: true, encoding: .utf8)
    var base: [String: Any] = ["session_id": withTranscript, "transcript_path": transcript.path, "cwd": "/Users/x"]
    _ = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "SessionStart", "source": "resume"]) { $1 }))
    let kept = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "SessionEnd", "reason": "other"]) { $1 }))
    #expect(kept.notes.isEmpty)
    #expect(port.detail(SessionID(withTranscript))?.summary.lifecycle == .completed)

    // Daemon cannot answer: never delete on a failed lookup.
    let unknown = "11111111-0000-0000-0000-000000000002"
    base = ["session_id": unknown, "transcript_path": projectDir.appendingPathComponent("\(unknown).jsonl").path, "cwd": "/Users/x"]
    _ = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "SessionStart", "source": "startup"]) { $1 }))
    port.sessionLookupError = StubLookupFailure()
    let failed = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "SessionEnd", "reason": "other"]) { $1 }))
    port.sessionLookupError = nil
    #expect(failed.notes.isEmpty)
    #expect(port.detail(SessionID(unknown))?.summary.lifecycle == .completed)
    #expect(port.ignored.isEmpty)
}

@Test func codexSessionEndIsNeverDiscarded() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let session = "01a01326-0000-7b30-8555-2b71d86d5ab4"
    let port = MemoryDaemonPort()
    let pipeline = HelperIngestPipeline(port: port, environment: [:], homeDirectory: home)
    let base: [String: Any] = ["session_id": session, "cwd": "/tmp/proj"]
    _ = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "SessionStart", "source": "startup"]) { $1 }), agent: .codex)
    let end = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "SessionEnd", "reason": "other"]) { $1 }), agent: .codex)
    #expect(end.notes.isEmpty)
    #expect(port.detail(SessionID(session))?.summary.lifecycle == .completed)
    #expect(port.ignored.isEmpty)
}

@Test func providerDetectionPrefersExplicitThenHeuristics() {
    #expect(HelperIngestPipeline.provider(for: ["turn_id": "t"], selection: .claude, environment: [:]) == .claude)
    #expect(HelperIngestPipeline.provider(for: [:], selection: .auto, environment: ["CLAUDE_PROJECT_DIR": "/x"]) == .claude)
    #expect(HelperIngestPipeline.provider(for: ["transcript_path": "/Users/x/.claude/projects/a/b.jsonl"], selection: .auto, environment: [:]) == .claude)
    #expect(HelperIngestPipeline.provider(for: ["turn_id": "t"], selection: .auto, environment: [:]) == .codex)
    #expect(HelperIngestPipeline.provider(for: [:], selection: .auto, environment: [:]) == .codex)
}

@Test func hookOnlyModeEmitsToolAndPromptItems() throws {
    let events = try ClaudeAdapter().events(fromHookData: hook([
        "session_id": "s", "prompt_id": "p", "hook_event_name": "PreToolUse",
        "tool_name": "Edit", "tool_use_id": "tu", "tool_input": ["file_path": "/a/b.swift"],
    ]), options: .hookOnly)
    #expect(events.count == 1)
    guard case let .tool(tool)? = events[0].timelineItem?.payload else {
        Issue.record("expected tool item"); return
    }
    #expect(tool.name == "Edit" && tool.toolUseID == "tu" && tool.summary == "/a/b.swift")
    #expect(events[0].timelineItem?.id == TimelineItemIDs.toolCall(SessionID("s"), toolUseID: "tu"))

    let rich = try ClaudeAdapter().events(fromHookData: hook([
        "session_id": "s", "prompt_id": "p", "hook_event_name": "PreToolUse", "tool_name": "Edit", "tool_use_id": "tu",
    ]), options: .withRichSource)
    #expect(rich[0].timelineItem == nil)
    #expect(rich[0].phase == .executing)

    let permission = try CodexAdapter(threads: FixedThreadIdentities(identities: [:])).events(fromHookData: hook([
        "session_id": "s", "turn_id": "t", "hook_event_name": "PermissionRequest", "tool_name": "Bash",
    ]))
    #expect(permission[0].timelineItem == nil)
    #expect(permission[0].lifecycle == .waitingForInput && permission[0].phase == .waitingForApproval)
}

@Test func phantomSubagentStopAfterStopDoesNotReopenTheSession() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let session = "aaaaaaaa-1111-2222-3333-444444444444"
    let port = MemoryDaemonPort()
    let pipeline = HelperIngestPipeline(port: port, environment: [:], homeDirectory: home)
    let base: [String: Any] = ["session_id": session, "cwd": "/tmp/proj", "prompt_id": "p1"]

    _ = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "UserPromptSubmit", "prompt": "hi"]) { $1 }))
    // A real subagent: agent_type present, start/stop paired.
    _ = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "SubagentStart", "agent_id": "a1", "agent_type": "Explore"]) { $1 }))
    #expect(port.detail(SessionID(session))?.summary.phase == .executing)
    _ = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "SubagentStop", "agent_id": "a1", "agent_type": "Explore"]) { $1 }))
    _ = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "Stop", "last_assistant_message": "done"]) { $1 }))

    // Claude Code's post-Stop internal fork: SubagentStop with empty agent_type, no start.
    let phantom = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "SubagentStop", "agent_id": "a2", "agent_type": ""]) { $1 }))
    #expect(phantom.eventsSent == 0)

    let detail = try #require(port.detail(SessionID(session)))
    #expect(detail.summary.lifecycle == .waitingForInput)
    #expect(detail.summary.phase == .idle)
    #expect(detail.turns.first?.phase == .idle)
    #expect(detail.turns.first?.subagentCount == 1)
    #expect(detail.timeline.filter { if case .subagent = $0.payload { return true }; return false }.count == 2)
}

@Test func claudeSubagentBecomesAChildSessionFedByItsSidechainTranscript() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let session = "528cd7c7-3b94-4f4c-a4b5-3397dd77c8f6"
    let agentID = "a1de7156f3465aae3"
    let projectDir = home.appendingPathComponent(".claude/projects/-tmp-proj", isDirectory: true)
    let transcript = projectDir.appendingPathComponent("\(session).jsonl")
    let agentDir = projectDir.appendingPathComponent("\(session)/subagents", isDirectory: true)
    try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
    try "".write(to: transcript, atomically: true, encoding: .utf8)
    let agentTranscript = agentDir.appendingPathComponent("agent-\(agentID).jsonl")
    try """
    {"agentType":"claude","description":"Output hi four times","toolUseId":"toolu_1","spawnDepth":1,"model":"haiku"}
    """.write(to: agentDir.appendingPathComponent("agent-\(agentID).meta.json"), atomically: true, encoding: .utf8)

    let port = MemoryDaemonPort()
    let pipeline = HelperIngestPipeline(port: port, environment: [:], homeDirectory: home)
    let base: [String: Any] = ["session_id": session, "transcript_path": transcript.path, "cwd": "/tmp/proj", "prompt_id": "p1"]
    _ = try pipeline.run(hookData: hook(base.merging([
        "hook_event_name": "UserPromptSubmit", "prompt": "spawn an agent", "timestamp": "2026-08-19T09:29:25.000Z",
    ]) { $1 }))

    // SubagentStart: the sidechain transcript already has the agent's prompt.
    let sidechain: [[String: Any]] = [
        ["type": "user", "uuid": "s1", "isSidechain": true, "agentId": agentID, "sessionId": session, "promptId": "agent-prompt",
         "timestamp": "2026-08-19T09:29:40.057Z", "cwd": "/tmp/proj",
         "message": ["role": "user", "content": "Output the word \"hi\" 4 times"]],
    ]
    try sidechain.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n").appending("\n")
        .write(to: agentTranscript, atomically: true, encoding: .utf8)
    _ = try pipeline.run(hookData: hook(base.merging([
        "hook_event_name": "SubagentStart", "agent_id": agentID, "agent_type": "claude",
        "timestamp": "2026-08-19T09:29:40.100Z",
    ]) { $1 }))

    let childID = ClaudeSubagentIdentity.sessionID(parent: SessionID(session), agentID: agentID)
    var child = try #require(port.detail(childID))
    #expect(child.summary.agent == .claudeSubagent)
    #expect(child.summary.title == "Output hi four times")
    #expect(child.summary.lineage?.parentSessionID == SessionID(session))
    #expect(child.summary.lineage?.agentRole == "claude")
    #expect(child.summary.lifecycle == .running)
    #expect(child.turns.first?.prompt == "Output the word \"hi\" 4 times")
    // The parent keeps its SUBAGENT row and stays on its own turn.
    let parent = try #require(port.detail(SessionID(session)))
    #expect(parent.summary.phase == .executing)
    #expect(parent.turns.count == 1)

    // The agent answers and stops; SubagentStop carries the transcript path.
    let reply: [[String: Any]] = [
        ["type": "assistant", "uuid": "s2", "isSidechain": true, "agentId": agentID, "sessionId": session, "timestamp": "2026-08-19T09:29:42.614Z",
         "message": ["role": "assistant", "model": "claude-haiku-4-5-20251001", "stop_reason": "end_turn",
                     "content": [["type": "text", "text": "hi\nhi\nhi\nhi"]],
                     "usage": ["input_tokens": 10, "output_tokens": 77]]],
    ]
    let handle = try FileHandle(forWritingTo: agentTranscript)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((reply.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n") + "\n").utf8))
    try handle.close()
    _ = try pipeline.run(hookData: hook(base.merging([
        "hook_event_name": "SubagentStop", "agent_id": agentID, "agent_type": "claude",
        "agent_transcript_path": agentTranscript.path, "timestamp": "2026-08-19T09:29:43.000Z",
        "last_assistant_message": "hi\nhi\nhi\nhi",
    ]) { $1 }))

    child = try #require(port.detail(childID))
    #expect(child.summary.lifecycle == .completed)
    #expect(child.turns.first?.outcome == .completed)
    #expect(child.timeline.contains { if case let .message(m) = $0.payload { return m.role == .assistant && m.text == "hi\nhi\nhi\nhi" }; return false })
    // Sidechain records never leak into the parent.
    #expect(port.detail(SessionID(session))?.timeline.contains { if case let .message(m) = $0.payload { return m.text == "hi\nhi\nhi\nhi" }; return false } == false)

    // Identity helpers round-trip.
    #expect(ClaudeSubagentIdentity.parse(childID)?.agentID == agentID)
    #expect(ClaudeSubagentIdentity.transcriptPath(parentTranscriptPath: transcript.path, parent: SessionID(session), agentID: agentID) == agentTranscript.path)
}

@Test func coldStartWithALargeHistoryDelegatesTheReplayToTheDaemon() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let session = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let prompt = "prompt-cold"
    let projectDir = home.appendingPathComponent(".claude/projects/-tmp-proj", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let transcript = projectDir.appendingPathComponent("\(session).jsonl")
    let lines: [[String: Any]] = [
        ["type": "user", "uuid": "u1", "sessionId": session, "promptId": prompt, "timestamp": "2026-08-18T14:35:28.342Z", "cwd": "/tmp/proj",
         "message": ["role": "user", "content": "long history"]],
        ["type": "assistant", "uuid": "a1", "sessionId": session, "timestamp": "2026-08-18T14:35:33.000Z",
         "message": ["role": "assistant", "model": "claude-opus-4-7", "stop_reason": "end_turn", "content": [["type": "text", "text": "Done."]]]],
    ]
    try lines.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n").appending("\n")
        .write(to: transcript, atomically: true, encoding: .utf8)

    let port = MemoryDaemonPort()
    // A threshold below the fixture's size: any cold read counts as "large".
    let pipeline = HelperIngestPipeline(port: port, environment: [:], homeDirectory: home, maximumInlineHistoryBytes: 16)
    let base: [String: Any] = [
        "session_id": session, "transcript_path": transcript.path, "cwd": "/tmp/proj", "prompt_id": prompt,
    ]

    let report = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "Stop", "last_assistant_message": "Done."]) { $1 }))

    // The history goes to the daemon: one backfill request, nothing read
    // inline, no cursor claimed.
    #expect(port.backfillRequests.count == 1)
    #expect(port.backfillRequests.first?.sessionID == SessionID(session))
    #expect(port.backfillRequests.first?.path == transcript.path)
    #expect(report.richSourceLinesRead == 0)
    #expect(try port.rolloutCursor(path: transcript.path) == nil)
    #expect(report.notes.contains { $0.hasPrefix("history_delegated_to_daemon") })

    // The hook's own state still lands immediately.
    let detail = try #require(port.detail(SessionID(session)))
    #expect(detail.summary.lifecycle == .waitingForInput)

    // A SessionEnd on the same cold session must not discard it while the
    // backfill is pending. It re-requests the backfill (the daemon's queue
    // dedupes) because the cursor still does not exist.
    let end = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "SessionEnd", "reason": "other"]) { $1 }))
    #expect(!end.notes.contains("session_discarded_never_used"))
    #expect(port.ignored.isEmpty)
    #expect(port.backfillRequests.count == 2)

    // Once the daemon owns a cursor, the same file is back to inline
    // increments and no further backfill is requested.
    try port.saveRolloutCursor(RolloutCursor(path: transcript.path, byteOffset: 0, fileSize: 0, sessionID: SessionID(session)))
    let warm = try pipeline.run(hookData: hook(base.merging(["hook_event_name": "UserPromptSubmit", "prompt": "again"]) { $1 }))
    #expect(warm.richSourceLinesRead == 2)
    #expect(port.backfillRequests.count == 2)
}
