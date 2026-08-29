import Adapters
import Core
import Transport
import Foundation
import Testing
@testable import DaemonRuntime

struct FixedThreadIdentities: CodexThreadIdentityProviding {
    let identities: [SessionID: CodexThreadIdentity]

    func identity(for sessionID: SessionID) -> CodexThreadIdentity? {
        identities[sessionID]
    }
}

/// Ordered record of every event the service applied and published.
private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentIngressEvent] = []

    func append(_ event: AgentIngressEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [AgentIngressEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct Harness {
    let home: URL
    let repository: InMemorySessionRepository
    let backfill: TranscriptBackfillQueue
    let service: HookIngestService
    let recorder: EventRecorder

    init(
        codexThreads: [SessionID: CodexThreadIdentity] = [:],
        maximumInlineHistoryBytes: Int = 1024 * 1024
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let repository = InMemorySessionRepository()
        let recorder = EventRecorder()
        let backfill = TranscriptBackfillQueue(repository: repository, onEvent: { recorder.append($0) })
        self.repository = repository
        self.recorder = recorder
        self.backfill = backfill
        service = HookIngestService(
            repository: repository,
            backfill: backfill,
            codexAdapter: CodexAdapter(threads: FixedThreadIdentities(identities: codexThreads)),
            homeDirectory: home,
            codexSessionsDirectory: home.appendingPathComponent(".codex/sessions", isDirectory: true),
            maximumInlineHistoryBytes: maximumInlineHistoryBytes,
            onEvent: { recorder.append($0) }
        )
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    func ingest(_ fields: [String: Any], agent: AgentProvider) async throws -> HookIngestService.Report {
        try await service.ingest(
            data: JSONSerialization.data(withJSONObject: fields),
            agent: agent,
            environment: [:],
            createdAt: Date()
        )
    }

    func ingest(
        _ fields: [String: Any],
        agent: AgentProvider,
        environment: [String: String]
    ) async throws -> HookIngestService.Report {
        try await service.ingest(
            data: JSONSerialization.data(withJSONObject: fields),
            agent: agent,
            environment: environment,
            createdAt: Date()
        )
    }

    func detail(_ id: SessionID) async throws -> SessionDetail? {
        try await repository.sessionDetail(id: id, cursor: nil, limit: 500)
    }
}

private func jsonLines(_ objects: [[String: Any]]) -> String {
    objects.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
        .joined(separator: "\n").appending("\n")
}

@Test func claudeHooksAndTranscriptFoldIntoOneTurnWithoutDuplicates() async throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let session = "11111111-2222-3333-4444-555555555555"
    let prompt = "prompt-aaaa"
    let projectDir = harness.home.appendingPathComponent(".claude/projects/-tmp-proj", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let transcript = projectDir.appendingPathComponent("\(session).jsonl")

    let base: [String: Any] = [
        "session_id": session, "transcript_path": transcript.path, "cwd": "/tmp/proj",
        "permission_mode": "default", "prompt_id": prompt,
    ]

    // Turn 1: prompt hook before the transcript has flushed anything.
    try "".write(to: transcript, atomically: true, encoding: .utf8)
    var report = try await harness.ingest(base.merging(["hook_event_name": "UserPromptSubmit", "prompt": "list files"]) { $1 }, agent: .claude)
    #expect(report.provider == .claude)
    #expect(report.richSourcePath == transcript.path)

    // Transcript catches up: user record + assistant thinking + tool_use.
    let lines: [[String: Any]] = [
        ["type": "user", "uuid": "u1", "sessionId": session, "promptId": prompt, "timestamp": "2026-08-18T14:35:28.342Z", "cwd": "/tmp/proj",
         "origin": ["kind": "human"],
         "message": ["role": "user", "content": "list files\n\n<system-reminder>be brief</system-reminder>"]],
        ["type": "assistant", "uuid": "a1", "sessionId": session, "timestamp": "2026-08-18T14:35:30.000Z",
         "message": ["role": "assistant", "model": "claude-opus-4-7", "content": [
            ["type": "thinking", "thinking": "I should run ls"],
            ["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "ls"]],
         ], "usage": ["input_tokens": 6, "cache_read_input_tokens": 100, "output_tokens": 20]]],
    ]
    try jsonLines(lines).write(to: transcript, atomically: true, encoding: .utf8)
    report = try await harness.ingest(base.merging(["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_use_id": "toolu_1", "tool_input": ["command": "ls"]]) { $1 }, agent: .claude)
    #expect(report.richSourceLinesRead == 2)

    // Result lands in transcript, then PostToolUse + Stop hooks.
    let more: [[String: Any]] = [
        ["type": "user", "uuid": "u2", "sessionId": session, "timestamp": "2026-08-18T14:35:31.000Z",
         "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "a\nb", "is_error": false]]],
         "toolUseResult": ["stdout": "a\nb"]],
        ["type": "attachment", "uuid": "at1", "sessionId": session, "timestamp": "2026-08-18T14:35:32.000Z",
         "attachment": ["type": "auto_mode", "bypass": true, "steerOnly": true]],
        ["type": "assistant", "uuid": "a2", "sessionId": session, "timestamp": "2026-08-18T14:35:33.000Z",
         "message": ["role": "assistant", "model": "claude-opus-4-7", "stop_reason": "end_turn", "content": [["type": "text", "text": "Two files."]]]],
    ]
    let handle = try FileHandle(forWritingTo: transcript)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(jsonLines(more).utf8))
    try handle.close()
    _ = try await harness.ingest(base.merging(["hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_use_id": "toolu_1", "tool_response": ["stdout": "a\nb"]]) { $1 }, agent: .claude)
    _ = try await harness.ingest(base.merging(["hook_event_name": "Stop", "last_assistant_message": "Two files."]) { $1 }, agent: .claude)

    let detail = try #require(try await harness.detail(SessionID(session)))
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
    let before = harness.recorder.events.count
    let idle = try await harness.ingest(base.merging(["hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_use_id": "toolu_1"]) { $1 }, agent: .claude)
    #expect(idle.richSourceLinesRead == 0)
    #expect(harness.recorder.events.count == before + 1)
}

@Test func codexHooksAndRolloutFoldIntoTurnWithToolPairs() async throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let session = "01a01326-61da-7b30-8555-2b71d86d5ab4"
    let day = harness.home.appendingPathComponent(".codex/sessions/2026/08/18", isDirectory: true)
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
    try jsonLines(records).write(to: rollout, atomically: true, encoding: .utf8)

    let base: [String: Any] = ["session_id": session, "turn_id": "turn-1", "cwd": "/tmp/proj"]
    let report = try await harness.ingest(base.merging(["hook_event_name": "Stop", "last_assistant_message": "Fixed it."]) { $1 }, agent: .codex)
    #expect(report.provider == .codex)
    #expect(report.richSourcePath == rollout.path)
    #expect(report.richSourceLinesRead == records.count)

    let detail = try #require(try await harness.detail(SessionID(session)))
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
    let cursor = try #require(try await harness.repository.rolloutCursor(path: rollout.path))
    #expect(cursor.byteOffset == cursor.fileSize)
    let second = try await harness.ingest(base.merging(["hook_event_name": "Stop"]) { $1 }, agent: .codex)
    #expect(second.richSourceLinesRead == 0)
}

/// The Claude desktop app spawns one-shot CLI probes to load slash-command /
/// agent lists: SessionStart + SessionEnd ~2 s apart, no turn, no transcript.
@Test func claudeSessionEndingBeforeFirstTurnIsDiscarded() async throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let session = "63759c38-d24f-492e-96bd-358b126f85cc"
    let transcript = harness.home.appendingPathComponent(".claude/projects/-Users-x/\(session).jsonl").path
    let base: [String: Any] = ["session_id": session, "transcript_path": transcript, "cwd": "/Users/x"]

    let start = try await harness.ingest(base.merging(["hook_event_name": "SessionStart", "source": "startup"]) { $1 }, agent: .claude)
    #expect(start.eventsApplied == 1)
    let provisional = try #require(try await harness.detail(SessionID(session)))
    #expect(provisional.summary.isProvisional)
    #expect(provisional.summary.firstTurnAt == nil)

    let end = try await harness.ingest(base.merging(["hook_event_name": "SessionEnd", "reason": "other"]) { $1 }, agent: .claude)
    #expect(end.notes == ["session_discarded_never_used"])
    #expect(end.eventsApplied == 1)
    let last = try #require(harness.recorder.events.last)
    #expect(last.disposition == .discard)
    #expect(last.lifecycle == nil && last.timelineItem == nil)
    #expect(try await harness.detail(SessionID(session)) == nil)
    #expect(try await harness.repository.isSessionIgnored(SessionID(session)))
}

@Test func claudeSessionWithATurnEndsNormallyWithoutTranscript() async throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let session = "0696204b-47db-42b6-9a4a-b00792e596c7"
    let transcript = harness.home.appendingPathComponent(".claude/projects/-Users-x/\(session).jsonl").path
    let base: [String: Any] = ["session_id": session, "transcript_path": transcript, "cwd": "/Users/x"]

    _ = try await harness.ingest(base.merging(["hook_event_name": "SessionStart", "source": "startup"]) { $1 }, agent: .claude)
    _ = try await harness.ingest(base.merging(["hook_event_name": "UserPromptSubmit", "prompt_id": "p1", "prompt": "hi"]) { $1 }, agent: .claude)
    let used = try #require(try await harness.detail(SessionID(session)))
    #expect(!used.summary.isProvisional)
    #expect(used.summary.firstTurnAt != nil)

    let end = try await harness.ingest(base.merging(["hook_event_name": "SessionEnd", "reason": "other"]) { $1 }, agent: .claude)
    #expect(end.notes.isEmpty)
    let detail = try #require(try await harness.detail(SessionID(session)))
    #expect(detail.summary.lifecycle == .completed)
    #expect(harness.recorder.events.last?.disposition == nil)
    #expect(try await !harness.repository.isSessionIgnored(SessionID(session)))
}

@Test func claudeSessionEndKeepsSessionWhenTranscriptExists() async throws {
    let harness = try Harness()
    defer { harness.tearDown() }

    // Transcript on disk (even empty): resumed / real session, keep it.
    let withTranscript = "11111111-0000-0000-0000-000000000001"
    let projectDir = harness.home.appendingPathComponent(".claude/projects/-Users-x", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let transcript = projectDir.appendingPathComponent("\(withTranscript).jsonl")
    try "".write(to: transcript, atomically: true, encoding: .utf8)
    let base: [String: Any] = ["session_id": withTranscript, "transcript_path": transcript.path, "cwd": "/Users/x"]
    _ = try await harness.ingest(base.merging(["hook_event_name": "SessionStart", "source": "resume"]) { $1 }, agent: .claude)
    let kept = try await harness.ingest(base.merging(["hook_event_name": "SessionEnd", "reason": "other"]) { $1 }, agent: .claude)
    #expect(kept.notes.isEmpty)
    #expect(try await harness.detail(SessionID(withTranscript))?.summary.lifecycle == .completed)
    #expect(try await !harness.repository.isSessionIgnored(SessionID(withTranscript)))
}

@Test func codexSessionEndIsNeverDiscarded() async throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let session = "01a01326-0000-7b30-8555-2b71d86d5ab4"
    let base: [String: Any] = ["session_id": session, "cwd": "/tmp/proj"]
    _ = try await harness.ingest(base.merging(["hook_event_name": "SessionStart", "source": "startup"]) { $1 }, agent: .codex)
    let end = try await harness.ingest(base.merging(["hook_event_name": "SessionEnd", "reason": "other"]) { $1 }, agent: .codex)
    #expect(end.notes.isEmpty)
    #expect(try await harness.detail(SessionID(session))?.summary.lifecycle == .completed)
    #expect(try await !harness.repository.isSessionIgnored(SessionID(session)))
}

@Test func hookOnlyModeEmitsToolAndPromptItems() throws {
    func data(_ fields: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: fields)
    }
    let preToolUse = data([
        "session_id": "s", "prompt_id": "p", "hook_event_name": "PreToolUse",
        "tool_name": "Edit", "tool_use_id": "tu", "tool_input": ["file_path": "/a/b.swift"],
    ])
    let events = try ClaudeAdapter().events(
        fromHook: ClaudeHookPayload(data: preToolUse),
        raw: preToolUse,
        options: .hookOnly
    )
    #expect(events.count == 1)
    guard case let .tool(tool)? = events[0].timelineItem?.payload else {
        Issue.record("expected tool item"); return
    }
    #expect(tool.name == "Edit" && tool.toolUseID == "tu" && tool.summary == "/a/b.swift")
    #expect(events[0].timelineItem?.id == TimelineItemIDs.toolCall(SessionID("s"), toolUseID: "tu"))

    let richData = data([
        "session_id": "s", "prompt_id": "p", "hook_event_name": "PreToolUse", "tool_name": "Edit", "tool_use_id": "tu",
    ])
    let rich = try ClaudeAdapter().events(
        fromHook: ClaudeHookPayload(data: richData),
        raw: richData,
        options: .withRichSource
    )
    #expect(rich[0].timelineItem == nil)
    #expect(rich[0].phase == .executing)

    let permissionData = data([
        "session_id": "s", "turn_id": "t", "hook_event_name": "PermissionRequest", "tool_name": "Bash",
    ])
    let permission = try CodexAdapter(threads: FixedThreadIdentities(identities: [:])).events(
        fromHook: CodexHookPayload(data: permissionData),
        raw: permissionData,
        options: .hookOnly
    )
    #expect(permission[0].timelineItem == nil)
    #expect(permission[0].lifecycle == .waitingForInput && permission[0].phase == .waitingForApproval)
}

@Test func phantomSubagentStopAfterStopDoesNotReopenTheSession() async throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let session = "aaaaaaaa-1111-2222-3333-444444444444"
    let base: [String: Any] = ["session_id": session, "cwd": "/tmp/proj", "prompt_id": "p1"]

    _ = try await harness.ingest(base.merging(["hook_event_name": "UserPromptSubmit", "prompt": "hi"]) { $1 }, agent: .claude)
    // A real subagent: agent_type present, start/stop paired.
    _ = try await harness.ingest(base.merging(["hook_event_name": "SubagentStart", "agent_id": "a1", "agent_type": "Explore"]) { $1 }, agent: .claude)
    #expect(try await harness.detail(SessionID(session))?.summary.phase == .executing)
    _ = try await harness.ingest(base.merging(["hook_event_name": "SubagentStop", "agent_id": "a1", "agent_type": "Explore"]) { $1 }, agent: .claude)
    _ = try await harness.ingest(base.merging(["hook_event_name": "Stop", "last_assistant_message": "done"]) { $1 }, agent: .claude)

    // Claude Code's post-Stop internal fork: SubagentStop with empty agent_type, no start.
    let phantom = try await harness.ingest(base.merging(["hook_event_name": "SubagentStop", "agent_id": "a2", "agent_type": ""]) { $1 }, agent: .claude)
    #expect(phantom.eventsApplied == 0)

    let detail = try #require(try await harness.detail(SessionID(session)))
    #expect(detail.summary.lifecycle == .waitingForInput)
    #expect(detail.summary.phase == .idle)
    #expect(detail.turns.first?.phase == .idle)
    #expect(detail.turns.first?.subagentCount == 1)
    #expect(detail.timeline.filter { if case .subagent = $0.payload { return true }; return false }.count == 2)
}

@Test func claudeSubagentBecomesAChildSessionFedByItsSidechainTranscript() async throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let session = "528cd7c7-3b94-4f4c-a4b5-3397dd77c8f6"
    let agentID = "a1de7156f3465aae3"
    let projectDir = harness.home.appendingPathComponent(".claude/projects/-tmp-proj", isDirectory: true)
    let transcript = projectDir.appendingPathComponent("\(session).jsonl")
    let agentDir = projectDir.appendingPathComponent("\(session)/subagents", isDirectory: true)
    try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
    try "".write(to: transcript, atomically: true, encoding: .utf8)
    let agentTranscript = agentDir.appendingPathComponent("agent-\(agentID).jsonl")
    try """
    {"agentType":"claude","description":"Output hi four times","toolUseId":"toolu_1","spawnDepth":1,"model":"haiku"}
    """.write(to: agentDir.appendingPathComponent("agent-\(agentID).meta.json"), atomically: true, encoding: .utf8)

    let base: [String: Any] = ["session_id": session, "transcript_path": transcript.path, "cwd": "/tmp/proj", "prompt_id": "p1"]
    let parentPrompt: [String: Any] = [
        "type": "user", "uuid": "u1", "sessionId": session, "promptId": "p1",
        "timestamp": "2026-08-19T09:29:24.900Z", "cwd": "/tmp/proj",
        "origin": ["kind": "human"],
        "message": ["role": "user", "content": "spawn an agent"],
    ]
    try jsonLines([parentPrompt]).write(to: transcript, atomically: true, encoding: .utf8)
    _ = try await harness.ingest(base.merging([
        "hook_event_name": "UserPromptSubmit", "prompt": "spawn an agent", "timestamp": "2026-08-19T09:29:25.000Z",
    ]) { $1 }, agent: .claude)

    // SubagentStart: the sidechain transcript already has the agent's prompt.
    let sidechain: [[String: Any]] = [
        ["type": "user", "uuid": "s1", "isSidechain": true, "agentId": agentID, "sessionId": session, "promptId": "agent-prompt",
         "timestamp": "2026-08-19T09:29:40.057Z", "cwd": "/tmp/proj",
         "message": ["role": "user", "content": "Output the word \"hi\" 4 times"]],
    ]
    try jsonLines(sidechain).write(to: agentTranscript, atomically: true, encoding: .utf8)
    _ = try await harness.ingest(base.merging([
        "hook_event_name": "SubagentStart", "agent_id": agentID, "agent_type": "claude",
        "timestamp": "2026-08-19T09:29:40.100Z",
    ]) { $1 }, agent: .claude)

    let childID = ClaudeSubagentIdentity.sessionID(parent: SessionID(session), agentID: agentID)
    var child = try #require(try await harness.detail(childID))
    #expect(child.summary.agent == .claudeSubagent)
    #expect(child.summary.title == "Output hi four times")
    #expect(child.summary.lineage?.parentSessionID == SessionID(session))
    #expect(child.summary.lineage?.agentRole == "claude")
    #expect(child.summary.lifecycle == .running)
    #expect(child.turns.first?.prompt == "Output the word \"hi\" 4 times")
    // The parent keeps its SUBAGENT row and stays on its own turn.
    let parent = try #require(try await harness.detail(SessionID(session)))
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
    try handle.write(contentsOf: Data(jsonLines(reply).utf8))
    try handle.close()
    _ = try await harness.ingest(base.merging([
        "hook_event_name": "SubagentStop", "agent_id": agentID, "agent_type": "claude",
        "agent_transcript_path": agentTranscript.path, "timestamp": "2026-08-19T09:29:43.000Z",
        "last_assistant_message": "hi\nhi\nhi\nhi",
    ]) { $1 }, agent: .claude)

    child = try #require(try await harness.detail(childID))
    #expect(child.summary.lifecycle == .completed)
    #expect(child.turns.first?.outcome == .completed)
    #expect(child.timeline.contains { if case let .message(m) = $0.payload { return m.role == .assistant && m.text == "hi\nhi\nhi\nhi" }; return false })
    // Sidechain records never leak into the parent.
    let parentTimeline = try #require(try await harness.detail(SessionID(session))).timeline
    #expect(!parentTimeline.contains { if case let .message(m) = $0.payload { return m.text == "hi\nhi\nhi\nhi" }; return false })

    // Identity helpers round-trip.
    #expect(ClaudeSubagentIdentity.parse(childID)?.agentID == agentID)
    #expect(ClaudeSubagentIdentity.transcriptPath(parentTranscriptPath: transcript.path, parent: SessionID(session), agentID: agentID) == agentTranscript.path)
}

@Test func coldStartWithALargeHistoryDelegatesTheReplayToTheBackfill() async throws {
    let harness = try Harness(maximumInlineHistoryBytes: 16)
    defer { harness.tearDown() }
    let session = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let prompt = "prompt-cold"
    let projectDir = harness.home.appendingPathComponent(".claude/projects/-tmp-proj", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let transcript = projectDir.appendingPathComponent("\(session).jsonl")
    let lines: [[String: Any]] = [
        ["type": "user", "uuid": "u1", "sessionId": session, "promptId": prompt, "timestamp": "2026-08-18T14:35:28.342Z", "cwd": "/tmp/proj",
         "origin": ["kind": "human"],
         "message": ["role": "user", "content": "long history"]],
        ["type": "assistant", "uuid": "a1", "sessionId": session, "timestamp": "2026-08-18T14:35:33.000Z",
         "message": ["role": "assistant", "model": "claude-opus-4-7", "stop_reason": "end_turn", "content": [["type": "text", "text": "Done."]]]],
    ]
    try jsonLines(lines).write(to: transcript, atomically: true, encoding: .utf8)

    let base: [String: Any] = [
        "session_id": session, "transcript_path": transcript.path, "cwd": "/tmp/proj", "prompt_id": prompt,
    ]

    let report = try await harness.ingest(base.merging(["hook_event_name": "Stop", "last_assistant_message": "Done."]) { $1 }, agent: .claude)

    // The history goes to the backfill worker: nothing read inline.
    #expect(report.richSourceLinesRead == 0)
    #expect(report.notes.contains { $0.hasPrefix("history_delegated_to_backfill") })

    // The hook's own state still lands immediately.
    let detail = try #require(try await harness.detail(SessionID(session)))
    #expect(detail.summary.lifecycle == .waitingForInput)

    // A SessionEnd on the same cold session must not discard it — either the
    // delegation is still pending (heuristic skipped) or the backfill already
    // proved the session was used.
    let end = try await harness.ingest(base.merging(["hook_event_name": "SessionEnd", "reason": "other"]) { $1 }, agent: .claude)
    #expect(!end.notes.contains("session_discarded_never_used"))
    #expect(try await !harness.repository.isSessionIgnored(SessionID(session)))

    // Once the backfill drained, the whole history is in the store and the
    // cursor is claimed: the same file is back to inline increments.
    await harness.backfill.flush()
    let cursor = try #require(try await harness.repository.rolloutCursor(path: transcript.path))
    #expect(cursor.byteOffset == cursor.fileSize)
    let replayed = try #require(try await harness.detail(SessionID(session)))
    #expect(replayed.turns.first?.prompt == "long history")
    let warm = try await harness.ingest(base.merging(["hook_event_name": "UserPromptSubmit", "prompt": "again"]) { $1 }, agent: .claude)
    #expect(warm.richSourceLinesRead == 0)
    #expect(!warm.notes.contains { $0.hasPrefix("history_delegated_to_backfill") })
}

// MARK: - Wrapper apps (Paseo / Raft)

private func writePaseoTitle(home: URL, agentID: String, title: String) throws {
    let dir = home.appendingPathComponent(".paseo/agents/Users-x-proj", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try #"{"id":"\#(agentID)","provider":"claude","title":"\#(title)"}"#
        .write(to: dir.appendingPathComponent("\(agentID).json"), atomically: true, encoding: .utf8)
}

@Test func paseoTitleOverridesTheDefaultClaudeTitleAndFollowsRenames() async throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let session = "7d0a6a1e-0000-4000-8000-000000000001"
    let paseoAgent = "14d83292-45c5-45dd-9825-be971183e17b"
    try writePaseoTitle(home: harness.home, agentID: paseoAgent, title: "你会使用 computer use 么？")

    let environment = ["PASEO_AGENT_ID": paseoAgent, "CLAUDE_PROJECT_DIR": "/tmp/proj"]
    let base: [String: Any] = [
        "session_id": session,
        "transcript_path": harness.home.appendingPathComponent(".claude/projects/-tmp-proj/\(session).jsonl").path,
        "cwd": "/tmp/proj",
    ]
    let report = try await harness.ingest(base.merging(["hook_event_name": "SessionStart", "source": "startup"]) { $1 }, agent: .claude, environment: environment)
    #expect(report.aaasKind == "paseo")
    #expect(report.aaasAgentID == paseoAgent)
    let owned = try #require(try await harness.detail(SessionID(session))?.summary)
    #expect(owned.title == "你会使用 computer use 么？")
    #expect(owned.aaas == SessionAaaS(kind: .paseo, agentID: paseoAgent))
    let identity = try #require(harness.recorder.events.last)
    #expect(identity.title != nil && identity.lifecycle == nil && identity.timelineItem == nil)
    #expect(identity.agent == .claude)

    // Renamed in Paseo: the next hook re-asserts the new title.
    try writePaseoTitle(home: harness.home, agentID: paseoAgent, title: "改名之后")
    _ = try await harness.ingest(base.merging(["hook_event_name": "UserPromptSubmit", "prompt": "hi"]) { $1 }, agent: .claude, environment: environment)
    #expect(try await harness.detail(SessionID(session))?.summary.title == "改名之后")
}

@Test func paseoTitleBeatsTheNativeCodexThreadTitle() async throws {
    let session = "01a01326-0000-7000-8000-000000000002"
    let paseoAgent = "aaaaaaaa-0000-0000-0000-000000000003"
    let harness = try Harness(codexThreads: [
        SessionID(session): CodexThreadIdentity(sessionID: SessionID(session), title: "Native thread title"),
    ])
    defer { harness.tearDown() }
    try writePaseoTitle(home: harness.home, agentID: paseoAgent, title: "Paseo 里的标题")

    _ = try await harness.ingest([
        "session_id": session, "turn_id": "turn-1", "cwd": "/tmp/proj", "hook_event_name": "Stop",
    ], agent: .codex, environment: ["PASEO_AGENT_ID": paseoAgent])
    #expect(try await harness.detail(SessionID(session))?.summary.title == "Paseo 里的标题")
}

@Test func raftSessionsAreTitledByTheAgentName() async throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let session = "084a5101-0000-4000-8000-000000000004"
    let transport = harness.home.appendingPathComponent(".slock/cli-transport/agent/pid-1", isDirectory: true)
    try FileManager.default.createDirectory(at: transport, withIntermediateDirectories: true)
    try #"You are "Fable", an AI agent in Raft (former Slock) — a collaborative platform."#
        .write(to: transport.appendingPathComponent("claude-system-prompt.md"), atomically: true, encoding: .utf8)

    let report = try await harness.ingest([
        "session_id": session,
        "transcript_path": harness.home.appendingPathComponent(".claude/projects/-tmp-proj/\(session).jsonl").path,
        "cwd": "/tmp/proj",
        "hook_event_name": "SessionStart",
        "source": "startup",
    ], agent: .claude, environment: [
        "SLOCK_AGENT_ID": "65e8e001-1d5e-4fe0-b977-aac119612fc6",
        "SLOCK_CLI_TRANSPORT_DIR": transport.path,
        "CLAUDE_PROJECT_DIR": "/tmp/proj",
    ])
    #expect(report.aaasKind == "raft")
    #expect(try await harness.detail(SessionID(session))?.summary.title == "Fable")
}

@Test func wrapperWithoutAReadableTitleLeavesTheDefaultAndNotes() async throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let session = "7d0a6a1e-0000-4000-8000-000000000005"
    let report = try await harness.ingest([
        "session_id": session,
        "transcript_path": harness.home.appendingPathComponent(".claude/projects/-tmp-proj/\(session).jsonl").path,
        "cwd": "/tmp/proj",
        "hook_event_name": "SessionStart",
        "source": "startup",
    ], agent: .claude, environment: ["PASEO_AGENT_ID": "no-such-agent", "CLAUDE_PROJECT_DIR": "/tmp/proj"])
    #expect(report.aaasKind == "paseo")
    #expect(report.notes.contains("aaas_title_unavailable kind=paseo"))
    #expect(try await harness.detail(SessionID(session))?.summary.title == "Claude Session")
}

// MARK: - AaaS ownership (two-layer model)

@Test func codexSessionFromTheChatGPTAppIsOwnedByChatGPT() async throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let session = "01a01326-0000-7000-8000-000000000006"

    let report = try await harness.ingest([
        "session_id": session, "turn_id": "turn-1", "cwd": "/tmp/proj",
        "hook_event_name": "UserPromptSubmit", "prompt": "hi",
    ], agent: .codex, environment: ["__CFBundleIdentifier": "com.openai.codex"])
    #expect(report.aaasKind == "chatgpt")
    // No wrapper store: no title event, the native chain keeps titling.
    #expect(!report.notes.contains { $0.hasPrefix("aaas_title_unavailable") })
    let summary = try #require(try await harness.detail(SessionID(session))?.summary)
    #expect(summary.aaas == SessionAaaS(kind: .chatgpt))
    #expect(summary.aaas?.allowsNativeTitle == true)
    #expect(summary.title == "Codex Session")
}

@Test func terminalClaudeSessionIsOwnedByClaudeCodeWithItsTerminal() async throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let session = "7d0a6a1e-0000-4000-8000-000000000007"

    let report = try await harness.ingest([
        "session_id": session,
        "transcript_path": harness.home.appendingPathComponent(".claude/projects/-tmp-proj/\(session).jsonl").path,
        "cwd": "/tmp/proj",
        "hook_event_name": "SessionStart",
        "source": "startup",
    ], agent: .claude, environment: ["CLAUDE_CODE_ENTRYPOINT": "cli", "TERM_PROGRAM": "ghostty"])
    #expect(report.aaasKind == "claude_code")
    #expect(report.aaasTerminalProgram == "ghostty")
    let summary = try #require(try await harness.detail(SessionID(session))?.summary)
    #expect(summary.aaas == SessionAaaS(kind: .claudeCode, terminalProgram: "ghostty"))
}

// A mis-registered / version-skewed hook event must degrade to
// increment-only: the rich-source read window still runs, only the hook
// itself reduces nothing.
@Test func unsupportedHookEventStillCatchesUpTheTranscript() async throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let session = "7d0a6a1e-0000-4000-8000-000000000009"
    let projectDir = harness.home.appendingPathComponent(".claude/projects/-tmp-proj", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let transcript = projectDir.appendingPathComponent("\(session).jsonl")
    try jsonLines([
        ["type": "user", "uuid": "u1", "sessionId": session, "promptId": "p1",
         "timestamp": "2026-08-29T09:00:00.000Z", "cwd": "/tmp/proj",
         "origin": ["kind": "human"],
         "message": ["role": "user", "content": "hello"]],
    ]).write(to: transcript, atomically: true, encoding: .utf8)

    let report = try await harness.ingest([
        "session_id": session,
        "transcript_path": transcript.path,
        "cwd": "/tmp/proj",
        "hook_event_name": "BrandNewEventFromTheFuture",
    ], agent: .claude)
    #expect(report.warnings.contains("hook_event_unsupported name=BrandNewEventFromTheFuture"))
    #expect(report.richSourceLinesRead == 1)
    let detail = try #require(try await harness.detail(SessionID(session)))
    #expect(detail.turns.first?.prompt == "hello")
}

// On a wrapper-owned session the adapters' native thread name must not ride
// the ownership-stamped hook events past the reduction gate — even while the
// wrapper's own title store is unreadable, the session keeps its default.
@Test func wrapperOwnedSessionIgnoresNativeThreadNamesEvenWithoutAWrapperTitle() async throws {
    let session = "01a01326-0000-7000-8000-00000000000a"
    let harness = try Harness(codexThreads: [
        SessionID(session): CodexThreadIdentity(sessionID: SessionID(session), title: "Native thread title"),
    ])
    defer { harness.tearDown() }

    let report = try await harness.ingest([
        "session_id": session, "turn_id": "turn-1", "cwd": "/tmp/proj",
        "hook_event_name": "UserPromptSubmit", "prompt": "hi",
    ], agent: .codex, environment: ["PASEO_AGENT_ID": "no-such-agent"])
    #expect(report.aaasKind == "paseo")
    let summary = try #require(try await harness.detail(SessionID(session))?.summary)
    #expect(summary.aaas?.kind == .paseo)
    #expect(summary.title == "Codex Session")
}

@Test func ownershipFlipsWhenTheSameSessionResumesUnderAnotherHost() async throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let session = "7d0a6a1e-0000-4000-8000-000000000008"
    let base: [String: Any] = [
        "session_id": session,
        "transcript_path": harness.home.appendingPathComponent(".claude/projects/-tmp-proj/\(session).jsonl").path,
        "cwd": "/tmp/proj",
    ]

    _ = try await harness.ingest(base.merging(["hook_event_name": "SessionStart", "source": "startup"]) { $1 },
                                 agent: .claude, environment: ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop"])
    #expect(try await harness.detail(SessionID(session))?.summary.aaas?.kind == .claudeDesktop)

    _ = try await harness.ingest(base.merging(["hook_event_name": "UserPromptSubmit", "prompt": "hi"]) { $1 },
                                 agent: .claude, environment: ["CLAUDE_CODE_ENTRYPOINT": "cli", "TERM_PROGRAM": "WarpTerminal"])
    let summary = try #require(try await harness.detail(SessionID(session))?.summary)
    #expect(summary.aaas == SessionAaaS(kind: .claudeCode, terminalProgram: "WarpTerminal"))
}
