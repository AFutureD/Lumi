import Core
import Transport
import Foundation
import GRDB
import Testing
@testable import Adapters

@Test func userPromptHookBecomesRunningUserMessage() throws {
    let data = Data("""
    {
      "session_id":"session-1",
      "turn_id":"turn-1",
      "cwd":"/tmp/project",
      "hook_event_name":"UserPromptSubmit",
      "prompt":"Implement the feature"
    }
    """.utf8)

    let events = try CodexAdapter(threads: FixedThreadIdentities(
        identities: [SessionID("session-1"): CodexThreadIdentity(
            sessionID: SessionID("session-1"),
            title: "Authoritative thread title"
        )]
    )).events(fromHook: CodexHookPayload(data: data), raw: data, options: .hookOnly)
    #expect(events.count == 1)
    #expect(events[0].lifecycle == .running)
    #expect(events[0].phase == .thinking)
    #expect(events[0].title == "Authoritative thread title")
    #expect(events[0].timelineItem?.payload == .message(
        MessageTimelinePayload(role: .user, text: "Implement the feature")
    ))
}

@Test func threadIdentityStoreReadsTitlesAndSubagentRelationships() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-title-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databasePath = directory.appendingPathComponent("state_5.sqlite").path
    let database = try DatabaseQueue(path: databasePath)
    try database.write { db in
        try db.execute(sql: """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                first_user_message TEXT NOT NULL DEFAULT '',
                has_user_event INTEGER NOT NULL DEFAULT 0,
                thread_source TEXT,
                agent_nickname TEXT,
                agent_role TEXT,
                agent_path TEXT,
                source TEXT NOT NULL
            )
            """)
        try db.execute(
            sql: "INSERT INTO threads(id, title, source) VALUES(?, ?, ?)",
            arguments: ["session-1", "[macOS] Session list and detail", "cli"]
        )
        try db.execute(
            sql: """
                INSERT INTO threads(
                    id, title, first_user_message, thread_source,
                    agent_nickname, agent_path, source
                ) VALUES(?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                "subagent-1",
                "Parent request inherited by the subagent",
                "Parent request inherited by the subagent",
                "subagent",
                "Hypatia",
                "/root/docs_review",
                #"{"subagent":{"thread_spawn":{"parent_thread_id":"session-1","depth":1,"agent_path":"/root/docs_review","agent_nickname":"Hypatia","agent_role":null}}}"#,
            ]
        )
        try db.execute(
            sql: "INSERT INTO threads(id, title, thread_source, source) VALUES(?, ?, ?, ?)",
            arguments: [
                "guardian-1",
                "",
                "subagent",
                #"{"subagent":{"other":"guardian"}}"#,
            ]
        )
        try db.execute(
            sql: """
                INSERT INTO threads(
                    id, title, first_user_message, thread_source,
                    agent_nickname, agent_path, source
                ) VALUES(?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                "named-subagent",
                "Independent review",
                "Parent request",
                "subagent",
                "Noether",
                "/root/independent_review",
                #"{"subagent":{"thread_spawn":{"parent_thread_id":"session-1","depth":1,"agent_path":"/root/independent_review","agent_nickname":"Noether","agent_role":null}}}"#,
            ]
        )
        try db.execute(
            sql: """
                INSERT INTO threads(
                    id, title, first_user_message, has_user_event, thread_source,
                    agent_nickname, agent_path, source
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                "user-titled-subagent",
                "Direct subagent request",
                "Direct subagent request",
                1,
                "subagent",
                "Curie",
                "/root/direct_request",
                #"{"subagent":{"thread_spawn":{"parent_thread_id":"session-1","depth":1,"agent_path":"/root/direct_request","agent_nickname":"Curie","agent_role":null}}}"#,
            ]
        )
    }

    let store = CodexThreadIdentityStore(databasePath: databasePath)
    let regular = try #require(store.identity(for: SessionID("session-1")))
    #expect(regular.threadName == nil)
    let subagent = try #require(store.identity(for: SessionID("subagent-1")))
    let guardian = try #require(store.identity(for: SessionID("guardian-1")))
    let namedSubagent = try #require(store.identity(for: SessionID("named-subagent")))
    let userTitledSubagent = try #require(store.identity(for: SessionID("user-titled-subagent")))

    #expect(regular.displayTitle == "[macOS] Session list and detail")
    #expect(regular.agentKind == .codex)
    #expect(subagent.displayTitle == "Hypatia · docs_review")
    #expect(subagent.titleIsInheritedUserMessage)
    #expect(subagent.agentKind == .codexSubagent)
    #expect(subagent.parentSessionID == SessionID("session-1"))
    #expect(subagent.subagentDepth == 1)
    #expect(guardian.displayTitle == "Guardian")
    #expect(guardian.agentKind == .codexSubagent)
    #expect(guardian.parentSessionID == nil)
    #expect(namedSubagent.displayTitle == "Independent review")
    #expect(!namedSubagent.titleIsInheritedUserMessage)
    #expect(userTitledSubagent.displayTitle == "Direct subagent request")
    #expect(!userTitledSubagent.titleIsInheritedUserMessage)
    #expect(store.identity(for: SessionID("missing")) == nil)
}

@Test func threadIdentityStorePrefersRenamedThreadNameFromSessionIndex() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-title-index-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databasePath = directory.appendingPathComponent("state_5.sqlite").path
    let indexPath = directory.appendingPathComponent("session_index.jsonl").path
    let database = try DatabaseQueue(path: databasePath)
    try database.write { db in
        try db.execute(sql: """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                first_user_message TEXT NOT NULL DEFAULT '',
                has_user_event INTEGER NOT NULL DEFAULT 0,
                thread_source TEXT,
                agent_nickname TEXT,
                agent_role TEXT,
                agent_path TEXT,
                source TEXT NOT NULL
            )
            """)
        try db.execute(
            sql: "INSERT INTO threads(id, title, first_user_message, source) VALUES(?, ?, ?, ?)",
            arguments: ["session-1", "# Files mentioned by the user: long prompt", "# Files mentioned by the user: long prompt", "cli"]
        )
        try db.execute(
            sql: "INSERT INTO threads(id, title, first_user_message, source) VALUES(?, ?, ?, ?)",
            arguments: ["session-2", "Untouched title", "Untouched title", "cli"]
        )
        try db.execute(
            sql: """
                INSERT INTO threads(id, title, first_user_message, has_user_event, thread_source, agent_nickname, agent_path, source)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                "subagent-1",
                "# Files mentioned by the user: long prompt",
                "# Files mentioned by the user: long prompt",
                0,
                "subagent",
                "Hypatia",
                "/root/docs_review",
                #"{"subagent":{"thread_spawn":{"parent_thread_id":"session-1","depth":1,"agent_path":"/root/docs_review","agent_nickname":"Hypatia","agent_role":null}}}"#,
            ]
        )
    }
    // Append-only: the last line for an id wins; blank names and junk lines are ignored.
    try """
    {"id":"session-1","thread_name":"优化 Session Activity 时间轴","updated_at":"2026-08-18T04:12:45Z"}
    not json
    {"id":"session-1","thread_name":"[Feature] Session Activity 时间轴优化","updated_at":"2026-08-18T04:13:11Z"}
    {"id":"subagent-1","thread_name":"Docs review pass","updated_at":"2026-08-18T04:14:00Z"}
    {"id":"session-2","thread_name":"   ","updated_at":"2026-08-18T04:15:00Z"}

    """.write(toFile: indexPath, atomically: true, encoding: .utf8)

    let store = CodexThreadIdentityStore(databasePath: databasePath)
    let renamed = try #require(store.identity(for: SessionID("session-1")))
    #expect(renamed.threadName == "[Feature] Session Activity 时间轴优化")
    #expect(renamed.displayTitle == "[Feature] Session Activity 时间轴优化")
    #expect(store.identity(for: SessionID("session-2"))?.displayTitle == "Untouched title")
    let subagent = try #require(store.identity(for: SessionID("subagent-1")))
    #expect(subagent.displayTitle == "Docs review pass")
    #expect(subagent.agentKind == .codexSubagent)

    let batch = store.identities(for: [SessionID("session-1"), SessionID("subagent-1"), SessionID("missing")])
    #expect(batch[SessionID("session-1")]?.displayTitle == "[Feature] Session Activity 时间轴优化")
    #expect(batch[SessionID("subagent-1")]?.displayTitle == "Docs review pass")
    #expect(batch[SessionID("missing")] == nil)

    // A later rename is picked up once the file changes.
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: indexPath))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"id\":\"session-1\",\"thread_name\":\"Renamed again\"}\n".utf8))
    try handle.close()
    #expect(store.identity(for: SessionID("session-1"))?.displayTitle == "Renamed again")
}

@Test func rolloutMapsReasoningAndWorldStateToAgentDomain() throws {
    let adapter = CodexAdapter()
    let context = RolloutRecordContext(
        path: "/tmp/rollout.jsonl",
        byteOffset: 20,
        sessionID: SessionID("session-1")
    )
    let encryptedReasoning = Data("""
    {"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"reasoning","summary":["private"]}}
    """.utf8)
    let reasoning = Data("""
    {"timestamp":"2026-08-16T10:00:00Z","type":"event_msg","payload":{"type":"agent_reasoning","text":"Let me look"}}
    """.utf8)
    let worldState = Data("""
    {"timestamp":"2026-08-16T10:00:00Z","type":"world_state","payload":{"full":true,"state":{"secret":"private"}}}
    """.utf8)
    let worldStateDelta = Data("""
    {"timestamp":"2026-08-16T10:01:00Z","type":"world_state","payload":{"full":false,"state":{"environments":{"timezone":"UTC"}}}}
    """.utf8)

    // The encrypted response item is a duplicate of `agent_reasoning`.
    #expect(try adapter.events(fromRolloutLine: encryptedReasoning, context: context).isEmpty)
    let reasoningEvents = try adapter.events(fromRolloutLine: reasoning, context: context)
    let worldStateEvents = try adapter.events(fromRolloutLine: worldState, context: context)
    let worldStateDeltaEvents = try adapter.events(
        fromRolloutLine: worldStateDelta,
        context: RolloutRecordContext(
            path: context.path,
            byteOffset: 21,
            sessionID: context.sessionID
        )
    )

    guard case let .reasoning(reasoningPayload)? = reasoningEvents.first?.timelineItem?.payload,
          case let .context(worldStatePayload)? = worldStateEvents.first?.timelineItem?.payload else {
        Issue.record("Expected reasoning and turn-context payloads")
        return
    }
    #expect(reasoningPayload.text == "Let me look")
    #expect(worldStatePayload.kind == "world_state")
    #expect(worldStateEvents.first?.timelineItem?.id != worldStateDeltaEvents.first?.timelineItem?.id)
}

@Test func rolloutParsesSessionConfigurationAndBaseInstructions() throws {
    let adapter = CodexAdapter()
    let sessionLine = Data("""
    {"timestamp":"2026-08-16T10:00:00Z","type":"session_meta","payload":{"id":"session-1","cwd":"/tmp/project","model_provider":"openai","cli_version":"1.2.3","context_window":{"window_id":"window-1"},"base_instructions":"must be retained"}}
    """.utf8)
    let sessionEvents = try adapter.events(
        fromRolloutLine: sessionLine,
        context: RolloutRecordContext(path: "/tmp/rollout.jsonl", byteOffset: 0)
    )
    #expect(sessionEvents.first?.sessionID == SessionID("session-1"))
    #expect(sessionEvents.count == 3)
    guard case .sessionMarker(let marker)? = sessionEvents.first?.timelineItem?.payload else {
        Issue.record("Expected a session-started marker")
        return
    }
    #expect(marker.kind == .sessionStarted)
    #expect(sessionEvents.contains {
        guard case let .modelConfiguration(configuration)? = $0.timelineItem?.payload else { return false }
        return configuration.provider == "openai" && configuration.clientVersion == "1.2.3"
    })
    #expect(sessionEvents.contains {
        guard case let .context(context)? = $0.timelineItem?.payload else { return false }
        return context.kind == "base_instructions"
    })

    let completionLine = Data("""
    {"timestamp":"2026-08-16T10:01:00Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","duration_ms":60000,"last_agent_message":"not duplicated"}}
    """.utf8)
    let completionEvents = try adapter.events(
        fromRolloutLine: completionLine,
        context: RolloutRecordContext(
            path: "/tmp/rollout.jsonl",
            byteOffset: 200,
            sessionID: SessionID("session-1")
        )
    )
    #expect(completionEvents.first?.lifecycle == .waitingForInput)
    #expect(completionEvents.first?.turnID == TurnID("turn-1"))
    #expect(completionEvents.first?.turn?.outcome == .completed)
    guard case let .turnEnd(turnEnd)? = completionEvents.first?.timelineItem?.payload else {
        Issue.record("Expected a turn end item")
        return
    }
    #expect(turnEnd.message == "not duplicated")
    #expect(completionEvents.first?.timelineItem?.id == TimelineItemIDs.turnEnd(SessionID("session-1"), turnID: TurnID("turn-1")))
}

@Test func rolloutParsesTurnModelConfigurationAndContext() throws {
    let line = Data("""
    {"timestamp":"2026-08-16T10:00:00Z","type":"turn_context","payload":{"turn_id":"turn-1","model":"gpt-5.6","effort":"high","approval_policy":"never","summary":"retained context"}}
    """.utf8)
    let events = try CodexAdapter().events(
        fromRolloutLine: line,
        context: RolloutRecordContext(
            path: "/tmp/rollout.jsonl",
            byteOffset: 300,
            sessionID: SessionID("session-1")
        )
    )

    #expect(events.count == 2)
    #expect(events.allSatisfy { $0.turnID == TurnID("turn-1") })
    guard case let .modelConfiguration(configuration)? = events.first?.timelineItem?.payload else {
        Issue.record("Expected model configuration")
        return
    }
    #expect(configuration.model == "gpt-5.6")
    #expect(configuration.reasoningEffort == "high")
}

@Test func rolloutParsesTokenUsageAndRateLimits() throws {
    let line = Data("""
    {"timestamp":"2026-08-16T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":3,"cache_write_input_tokens":2,"output_tokens":5,"reasoning_output_tokens":1,"total_tokens":15},"total_token_usage":{"input_tokens":100,"cached_input_tokens":30,"cache_write_input_tokens":20,"output_tokens":50,"reasoning_output_tokens":10,"total_tokens":150},"model_context_window":258000},"rate_limits":{"primary":{"used_percent":12.5}}}}
    """.utf8)
    let events = try CodexAdapter().events(
        fromRolloutLine: line,
        context: RolloutRecordContext(
            path: "/tmp/rollout.jsonl",
            byteOffset: 400,
            sessionID: SessionID("session-1")
        )
    )

    guard case let .usageMetrics(usage)? = events.first?.timelineItem?.payload else {
        Issue.record("Expected usage metrics")
        return
    }
    #expect(usage.last?.totalTokens == 15)
    #expect(usage.total?.reasoningOutputTokens == 10)
    #expect(usage.modelContextWindow == 258_000)
    #expect(usage.rateLimits != nil)

    let laterEvents = try CodexAdapter().events(
        fromRolloutLine: line,
        context: RolloutRecordContext(
            path: "/tmp/rollout.jsonl",
            byteOffset: 401,
            sessionID: SessionID("session-1")
        )
    )
    #expect(laterEvents.first?.eventID != events.first?.eventID)
    #expect(laterEvents.first?.timelineItem?.id == events.first?.timelineItem?.id)
}

@Test func rolloutParsesThreadSettingsAndCompactedContext() throws {
    let adapter = CodexAdapter()
    let context = RolloutRecordContext(
        path: "/tmp/rollout.jsonl",
        byteOffset: 500,
        sessionID: SessionID("session-1")
    )
    let settingsLine = Data("""
    {"timestamp":"2026-08-16T10:00:00Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-5.6","model_provider_id":"openai","reasoning_effort":"xhigh"}}}
    """.utf8)
    let compactedLine = Data("""
    {"timestamp":"2026-08-16T10:01:00Z","type":"compacted","payload":{"message":"retained summary","replacement_history":[{"role":"user","content":"retained history"}],"window_number":2}}
    """.utf8)

    let settingsEvents = try adapter.events(fromRolloutLine: settingsLine, context: context)
    let compactedEvents = try adapter.events(
        fromRolloutLine: compactedLine,
        context: RolloutRecordContext(
            path: context.path,
            byteOffset: 600,
            sessionID: context.sessionID
        )
    )

    guard case let .modelConfiguration(configuration)? = settingsEvents.first?.timelineItem?.payload,
          case let .context(compacted)? = compactedEvents.first?.timelineItem?.payload else {
        Issue.record("Expected thread settings and compacted context")
        return
    }
    #expect(configuration.model == "gpt-5.6")
    #expect(configuration.provider == "openai")
    #expect(configuration.reasoningEffort == "xhigh")
    #expect(compacted.kind == "compacted")
}

@Test func rolloutParsesPlanSnapshot() throws {
    let input = #"{"explanation":"Ship in order","plan":[{"step":"Build","status":"completed"},{"step":"Test","status":"in_progress"}]}"#
    let escapedInput = input
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let line = Data("""
    {"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"custom_tool_call","name":"update_plan","input":"\(escapedInput)"}}
    """.utf8)
    let events = try CodexAdapter().events(
        fromRolloutLine: line,
        context: RolloutRecordContext(
            path: "/tmp/rollout.jsonl",
            byteOffset: 0,
            sessionID: SessionID("session-1")
        )
    )

    guard case let .plan(plan)? = events.first?.timelineItem?.payload else {
        Issue.record("Expected a plan timeline payload")
        return
    }
    #expect(plan.steps.map(\.status) == [.completed, .inProgress])
}

// A user stop writes only a `[Request interrupted by user]` user record to the
// transcript — no Stop hook fires — so the marker must end the turn itself.
@Test func claudeTranscriptInterruptMarkerEndsTheTurnAsAborted() throws {
    let adapter = ClaudeAdapter()
    var state = RolloutReadState()
    let context = RolloutRecordContext(path: "/tmp/session.jsonl", byteOffset: 0, sessionID: SessionID("session-1"))

    let prompt = Data("""
    {"type":"user","sessionId":"session-1","promptId":"p1","timestamp":"2026-08-20T09:44:42Z","origin":{"kind":"human"},"message":{"role":"user","content":"Do the thing"}}
    """.utf8)
    let promptEvents = try adapter.events(fromRolloutLine: prompt, context: context, state: &state)
    #expect(promptEvents.last?.lifecycle == .running)

    for marker in ["[Request interrupted by user]", "[Request interrupted by user for tool use]"] {
        let interrupt = Data("""
        {"type":"user","sessionId":"session-1","timestamp":"2026-08-20T09:44:44Z","message":{"role":"user","content":[{"type":"text","text":"\(marker)"}]}}
        """.utf8)
        let events = try adapter.events(
            fromRolloutLine: interrupt,
            context: RolloutRecordContext(path: context.path, byteOffset: 100, sessionID: context.sessionID),
            state: &state
        )
        #expect(events.count == 1)
        #expect(events[0].lifecycle == .interrupted)
        #expect(events[0].phase == .idle)
        #expect(events[0].turn?.outcome == .aborted)
        guard case let .turnEnd(end)? = events[0].timelineItem?.payload else {
            Issue.record("Expected a turn-end payload for \(marker)")
            continue
        }
        #expect(end.outcome == .aborted)
    }
}

// A capped read that starts at a nonzero cursor must land its new cursor at
// EOF, not past it: `fileSize - data.count` is already absolute. (Regression:
// the offset was added instead of assigned, overshooting by the start offset
// and making the next scan misread the file as truncated and replay it.)
@Test func cappedReadFromANonzeroCursorKeepsTheCursorInBounds() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("reader-cap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("rollout.jsonl").path
    let line = "{\"type\":\"ignored_record\"}\n"
    let content = String(repeating: line, count: 200)
    try content.write(toFile: path, atomically: true, encoding: .utf8)
    let fileSize = UInt64(content.utf8.count)
    let offset = UInt64(line.utf8.count * 50)

    let read = try RichSourceReader.read(
        path: path,
        sessionID: SessionID("session-1"),
        adapter: CodexAdapter(threads: FixedThreadIdentities(identities: [:])),
        fromOffset: offset,
        maximumBytes: line.utf8.count * 20
    )
    #expect(read.cursor.byteOffset == fileSize)
    #expect(read.cursor.fileSize == fileSize)
    #expect(read.lines <= 20)
}

struct FixedThreadIdentities: CodexThreadIdentityProviding {
    let identities: [SessionID: CodexThreadIdentity]

    func identity(for sessionID: SessionID) -> CodexThreadIdentity? {
        identities[sessionID]
    }
}

// Claude Code may write a `thinking` block that carries only its signature.
// The block still marks a thinking step and must yield a reasoning item;
// the projection renders the empty text as a placeholder.
@Test func claudeTranscriptEmptyThinkingBlockStillYieldsReasoning() throws {
    let adapter = ClaudeAdapter()
    var state = RolloutReadState()
    let context = RolloutRecordContext(path: "/tmp/session.jsonl", byteOffset: 0, sessionID: SessionID("session-1"))

    let line = Data("""
    {"type":"assistant","sessionId":"session-1","timestamp":"2026-08-21T12:51:16Z","message":{"role":"assistant","model":"claude-fable-5","content":[{"type":"thinking","thinking":"","signature":"sig"},{"type":"thinking","thinking":"  Real thought  ","signature":"sig2"}]}}
    """.utf8)
    let events = try adapter.events(fromRolloutLine: line, context: context, state: &state)
    let reasoning = events.compactMap { event -> (String, TurnPhase?)? in
        guard case let .reasoning(payload)? = event.timelineItem?.payload else { return nil }
        return (payload.text, event.phase)
    }
    #expect(reasoning.map(\.0) == ["", "Real thought"])
    #expect(reasoning.allSatisfy { $0.1 == .thinking })
}

// MARK: - item_completed (0.149+ channel switch)

private func rolloutLine(
    _ adapter: CodexAdapter,
    _ json: String,
    offset: UInt64,
    state: inout RolloutReadState
) throws -> [AgentIngressEvent] {
    try adapter.events(
        fromRolloutLine: Data(json.utf8),
        context: RolloutRecordContext(path: "/tmp/rollout.jsonl", byteOffset: offset, sessionID: SessionID("session-1")),
        state: &state
    )
}

@Test func itemCompletedCarriesMessagesToolsAndSubagents() throws {
    let adapter = CodexAdapter()
    var state = RolloutReadState()

    _ = try rolloutLine(adapter, """
    {"timestamp":"2026-08-25T10:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-9"}}
    """, offset: 0, state: &state)

    let user = try rolloutLine(adapter, """
    {"timestamp":"2026-08-25T10:00:01Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"um-1","content":[{"type":"text","text":"取一个中文名"}]}}}
    """, offset: 1, state: &state)
    #expect(user.first?.phase == .thinking)
    #expect(user.first?.turn?.prompt == "取一个中文名")
    #expect(user.first?.timelineItem?.payload == .message(MessageTimelinePayload(role: .user, text: "取一个中文名")))
    #expect(user.first?.timelineItem?.id == TimelineItemIDs.userPrompt(SessionID("session-1"), turnID: TurnID("turn-9")))

    let assistant = try rolloutLine(adapter, """
    {"timestamp":"2026-08-25T10:00:02Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"msg-1","phase":"commentary","content":[{"type":"Text","text":"我先看看仓库"}]}}}
    """, offset: 2, state: &state)
    #expect(assistant.first?.phase == .responding)
    #expect(assistant.first?.timelineItem?.payload == .message(MessageTimelinePayload(role: .assistant, text: "我先看看仓库")))

    let reasoning = try rolloutLine(adapter, """
    {"timestamp":"2026-08-25T10:00:03Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning","id":"rs-1","summary_text":["Planning the rename"],"raw_content":[]}}}
    """, offset: 3, state: &state)
    #expect(reasoning.first?.timelineItem?.payload == .reasoning(ReasoningTimelinePayload(text: "Planning the rename")))

    let mcp = try rolloutLine(adapter, """
    {"timestamp":"2026-08-25T10:00:04Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"McpToolCall","id":"exec-1","server":"node_repl","tool":"js","status":"failed","result":{"content":[{"type":"text","text":"Ambiguous"}]},"duration":{"secs":1,"nanos":349344500}}}}
    """, offset: 4, state: &state)
    guard case let .tool(mcpTool)? = mcp.first?.timelineItem?.payload else {
        Issue.record("Expected an MCP tool payload")
        return
    }
    #expect(mcpTool.name == "node_repl/js")
    #expect(mcpTool.status == .failed)
    #expect(mcpTool.durationMilliseconds == 1349)

    let patch = try rolloutLine(adapter, """
    {"timestamp":"2026-08-25T10:00:05Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","id":"exec-2","status":"completed","changes":{"/tmp/a.swift":{}},"stdout":"","stderr":""}}}
    """, offset: 5, state: &state)
    guard case let .tool(patchTool)? = patch.first?.timelineItem?.payload else {
        Issue.record("Expected a patch tool payload")
        return
    }
    #expect(patchTool.name == "Apply patch")
    #expect(patchTool.status == .succeeded)

    let subagent = try rolloutLine(adapter, """
    {"timestamp":"2026-08-25T10:00:06Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"SubAgentActivity","id":"call-1","kind":"started","agent_thread_id":"thread-2","agent_path":"/root/review"}}}
    """, offset: 6, state: &state)
    #expect(subagent.first?.phase == .executing)
    #expect(subagent.first?.timelineItem?.payload == .subagent(SubagentTimelinePayload(
        name: "/root/review", agentSessionID: "thread-2", status: .started
    )))

    let plan = try rolloutLine(adapter, """
    {"timestamp":"2026-08-25T10:00:07Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"Plan","id":"turn-9-plan","text":"# 改名计划"}}}
    """, offset: 7, state: &state)
    #expect(plan.first?.timelineItem?.payload == .plan(PlanTimelinePayload(explanation: "# 改名计划", steps: [])))

    // The compaction marker stays with the top-level `compacted` record.
    let compaction = try rolloutLine(adapter, """
    {"timestamp":"2026-08-25T10:00:09Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"ContextCompaction","id":"cc-1"}}}
    """, offset: 9, state: &state)
    #expect(compaction.isEmpty)
}

@Test func itemsAreStoredWholeAndReadByTheirOwnFields() throws {
    let adapter = CodexAdapter()
    var state = RolloutReadState()
    func row(_ line: String, offset: UInt64) throws -> (item: TimelineItem, tool: ToolTimelinePayload) {
        let event = try #require(try rolloutLine(adapter, line, offset: offset, state: &state).first)
        let item = try #require(event.timelineItem)
        guard case let .tool(tool) = item.payload else { throw AgentAdapterError.malformedJSON }
        return (item, tool)
    }
    func line(_ tool: ToolTimelinePayload) -> String { TimelineLineText.tool(tool, name: tool.name) }

    // A command as Codex 0.164 records it: the wrapped argv, its own reading
    // of the command, the exit code, the output, the duration.
    let read = try row("""
    {"timestamp":"2026-11-11T05:07:16Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"session-1","turn_id":"turn-9","item":{"type":"CommandExecution","id":"exec-3","process_id":"36464","command":["/bin/zsh","-lc","cat skills/i-have-adhd/SKILL.md"],"cwd":"file:///repo","parsed_cmd":[{"type":"read","cmd":"cat skills/i-have-adhd/SKILL.md","name":"SKILL.md","path":"skills/i-have-adhd/SKILL.md"}],"source":"unified_exec_startup","status":"completed","aggregated_output":"---\\nname: i-have-adhd\\n","exit_code":0,"duration":{"secs":0,"nanos":18875000}},"started_at_ms":1,"completed_at_ms":2}}
    """, offset: 0)
    #expect(read.item.id == TimelineItemID("codex_item:session-1:exec-3"))
    #expect(read.tool.name == "Shell")
    #expect(read.tool.status == .succeeded)
    #expect(read.tool.toolUseID == "exec-3")
    #expect(read.tool.durationMilliseconds == 18)
    #expect(line(read.tool) == "Read · SKILL.md · 18ms")
    // The item is the content, whole.
    #expect(read.tool.content?["aggregated_output"]?.stringValue == "---\nname: i-have-adhd\n")
    #expect(read.tool.content?["cwd"]?.stringValue == "file:///repo")
    #expect(read.tool.content?["process_id"]?.stringValue == "36464")

    let failed = try row("""
    {"timestamp":"2026-11-11T05:07:27Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"exec-4","command":["/bin/zsh","-lc","curl -L --fail https://example.com/docs"],"cwd":"file:///repo","parsed_cmd":[{"type":"unknown","cmd":"curl -L --fail https://example.com/docs"}],"status":"failed","aggregated_output":"curl: (56)","exit_code":56,"duration":{"secs":0,"nanos":486452625}}}}
    """, offset: 1)
    #expect(failed.tool.status == .failed)
    #expect(line(failed.tool) == "Run · curl -L --fail https://example.com/docs · exit 56 · 486ms")

    let patch = try row("""
    {"timestamp":"2026-11-11T05:07:30Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","id":"exec-5","status":"completed","changes":{"/repo/docs/model.md":{"type":"update","unified_diff":"@@ -1 +1,2 @@\\n-old\\n+new\\n+more\\n","move_path":null}},"stdout":"Success. Updated the following files:\\nM docs/model.md\\n","stderr":""}}}
    """, offset: 2)
    #expect(patch.tool.name == "Apply patch")
    #expect(line(patch.tool) == "Edit · model.md +2 -1")
    #expect(patch.tool.content?["stdout"]?.stringValue?.hasPrefix("Success.") == true)

    let search = try row("""
    {"timestamp":"2026-11-11T05:07:35Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"Extension","kind":"web.search","id":"exec-6","query":"site:tailscale.com tsnet ...","action":{"type":"search","query":null,"queries":["site:tailscale.com tsnet","site:tailscale.com ssh"]},"results":[{"type":"text_result","ref_id":"turn0search0","title":"Tailscale SSH","url":"https://tailscale.com/kb/ssh","snippet":"When you enable","domain":"tailscale.com"}]}}}
    """, offset: 3)
    #expect(search.tool.name == "web.search")
    #expect(line(search.tool) == "Web search · site:tailscale.com tsnet ...")
    guard case let .webSearch(reading)? = CodexItemShape(search.tool.content) else { Issue.record("not a web search"); return }
    #expect(reading.queries == ["site:tailscale.com tsnet", "site:tailscale.com ssh"])
    #expect(reading.results.first?.title == "Tailscale SSH")

    let mcp = try row("""
    {"timestamp":"2026-11-11T05:07:40Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"McpToolCall","id":"exec-7","server":"codex_app","tool":"set_thread_title","arguments":{"title":"[Rex] Remote login"},"pluginId":"codex-app-tools@openai-bundled","status":"completed","result":{"content":[{"type":"text","text":"{}"}],"isError":false},"duration":{"secs":0,"nanos":880338625}}}}
    """, offset: 4)
    #expect(line(mcp.tool) == "codex_app/set_thread_title · [Rex] Remote login · 880ms")
    #expect(mcp.tool.content?["pluginId"]?.stringValue == "codex-app-tools@openai-bundled")
}

@Test func theScriptCallAndItsOutputStayARowPairOfTheirOwn() throws {
    let adapter = CodexAdapter()
    var state = RolloutReadState()
    let call = try rolloutLine(adapter, """
    {"timestamp":"2026-11-11T05:07:14Z","type":"response_item","payload":{"type":"custom_tool_call","id":"ctc_1","status":"completed","call_id":"call_4319","name":"exec","input":"const r = await tools.exec_command({cmd:\\\"ls\\\"});\\ntext(r)"}}
    """, offset: 0, state: &state)
    let output = try rolloutLine(adapter, """
    {"timestamp":"2026-11-11T05:07:17Z","type":"response_item","payload":{"type":"custom_tool_call_output","id":"ctco_1","call_id":"call_4319","output":[{"type":"input_text","text":"Script completed\\nWall time 3.3 seconds\\nOutput:\\n"}]}}
    """, offset: 1, state: &state)
    guard case let .tool(callTool)? = call.first?.timelineItem?.payload,
          case let .tool(outputTool)? = output.first?.timelineItem?.payload else {
        Issue.record("Expected the wrapper pair")
        return
    }
    #expect(TimelineLineText.tool(callTool, name: callTool.name) == "exec · call_4319")
    #expect(TimelineLineText.tool(outputTool, name: outputTool.name) == "exec · call_4319")
    // The script itself stays in the record.
    #expect(callTool.content?.stringValue?.hasPrefix("const r = await tools.exec_command") == true)
}

@Test func channelArbitrationPrefersItemsOverLegacyEventTwins() throws {
    let adapter = CodexAdapter()
    var state = RolloutReadState()

    // Item first: the legacy event twin of the same family is suppressed.
    let item = try rolloutLine(adapter, """
    {"timestamp":"2026-08-25T10:00:00Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"msg-1","content":[{"type":"Text","text":"来自 item"}]}}}
    """, offset: 0, state: &state)
    let legacy = try rolloutLine(adapter, """
    {"timestamp":"2026-08-25T10:00:01Z","type":"event_msg","payload":{"type":"agent_message","message":"来自 event"}}
    """, offset: 1, state: &state)
    #expect(item.count == 1)
    #expect(legacy.isEmpty)

    // Legacy first (0.148 flow): it emits, and a later higher-priority item
    // is still admitted.
    let event = try rolloutLine(adapter, """
    {"timestamp":"2026-08-25T10:00:02Z","type":"event_msg","payload":{"type":"agent_reasoning","text":"event 推理"}}
    """, offset: 2, state: &state)
    let laterItem = try rolloutLine(adapter, """
    {"timestamp":"2026-08-25T10:00:03Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning","id":"rs-1","summary_text":["item 推理"]}}}
    """, offset: 3, state: &state)
    let laterEvent = try rolloutLine(adapter, """
    {"timestamp":"2026-08-25T10:00:04Z","type":"event_msg","payload":{"type":"agent_reasoning","text":"被抑制"}}
    """, offset: 4, state: &state)
    #expect(event.count == 1)
    #expect(laterItem.count == 1)
    #expect(laterEvent.isEmpty)
}
