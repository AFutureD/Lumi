import AgentStatusCore
import AgentStatusTransport
import Foundation
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

    let events = try CodexAdapter().events(fromHookData: data)
    #expect(events.count == 1)
    #expect(events[0].lifecycle == .running)
    #expect(events[0].phase == .thinking)
    #expect(events[0].timelineItem?.payload == .message(
        MessageTimelinePayload(role: .user, text: "Implement the feature")
    ))
}

@Test func rolloutExcludesReasoningAndWorldState() throws {
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
    {"timestamp":"2026-08-16T10:00:00Z","type":"world_state","payload":{"state":{"secret":"private"}}}
    """.utf8)

    #expect(try adapter.events(fromRolloutLine: reasoning, context: context).isEmpty)
    #expect(try adapter.events(fromRolloutLine: worldState, context: context).isEmpty)
}

@Test func rolloutParsesSessionAndCompletionWithoutPrivateFields() throws {
    let adapter = CodexAdapter()
    let sessionLine = Data("""
    {"timestamp":"2026-08-16T10:00:00Z","type":"session_meta","payload":{"id":"session-1","cwd":"/tmp/project","base_instructions":"must not escape"}}
    """.utf8)
    let sessionEvents = try adapter.events(
        fromRolloutLine: sessionLine,
        context: RolloutRecordContext(path: "/tmp/rollout.jsonl", byteOffset: 0)
    )
    #expect(sessionEvents.first?.sessionID == SessionID("session-1"))

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
