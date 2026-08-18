import AgentStatusCore
import AgentStatusTransport
import Foundation
import GRDB
import Testing
@testable import AgentStatusCodex

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
    )).events(fromHookData: data)
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

@Test func rolloutRetainsReasoningAndWorldStateAsInternalContext() throws {
    let adapter = CodexAdapter()
    let context = RolloutRecordContext(
        path: "/tmp/rollout.jsonl",
        byteOffset: 20,
        sessionID: SessionID("session-1")
    )
    let reasoning = Data("""
    {"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"reasoning","summary":["private"]}}
    """.utf8)
    let worldState = Data("""
    {"timestamp":"2026-08-16T10:00:00Z","type":"world_state","payload":{"full":true,"state":{"secret":"private"}}}
    """.utf8)
    let worldStateDelta = Data("""
    {"timestamp":"2026-08-16T10:01:00Z","type":"world_state","payload":{"full":false,"state":{"environments":{"timezone":"UTC"}}}}
    """.utf8)

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

    guard case let .internalContext(reasoningPayload)? = reasoningEvents.first?.timelineItem?.payload,
          case let .internalContext(worldStatePayload)? = worldStateEvents.first?.timelineItem?.payload else {
        Issue.record("Expected retained internal context payloads")
        return
    }
    #expect(reasoningPayload.kind == "reasoning")
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
    #expect(sessionEvents.contains {
        guard case let .modelConfiguration(configuration)? = $0.timelineItem?.payload else { return false }
        return configuration.provider == "openai" && configuration.clientVersion == "1.2.3"
    })
    #expect(sessionEvents.contains {
        guard case .internalContext = $0.timelineItem?.payload else { return false }
        return true
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
    #expect(completionEvents.first?.timelineItem == nil)
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
          case let .internalContext(internalContext)? = compactedEvents.first?.timelineItem?.payload else {
        Issue.record("Expected thread settings and compacted context")
        return
    }
    #expect(configuration.model == "gpt-5.6")
    #expect(configuration.provider == "openai")
    #expect(configuration.reasoningEffort == "xhigh")
    #expect(internalContext.kind == "compacted")
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

private struct FixedThreadIdentities: CodexThreadIdentityProviding {
    let identities: [SessionID: CodexThreadIdentity]

    func identity(for sessionID: SessionID) -> CodexThreadIdentity? {
        identities[sessionID]
    }
}
