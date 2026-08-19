import AgentStatusCore
import AgentStatusTransport
import Foundation
import Testing
@testable import AgentStatusCodex

private func jsonl(_ records: [[String: Any]]) -> String {
    records.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
        .joined(separator: "\n") + "\n"
}

private func hookData(_ fields: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: fields)
}

private func claudeTranscript(session: String, prompt: String) -> [[String: Any]] {
    [
        ["type": "user", "uuid": "u1", "sessionId": session, "promptId": prompt, "timestamp": "2026-08-19T06:42:07.000Z", "cwd": "/tmp/proj",
         "message": ["role": "user", "content": "commit"]],
        ["type": "assistant", "uuid": "a1", "sessionId": session, "timestamp": "2026-08-19T06:43:52.000Z",
         "message": ["role": "assistant", "model": "claude-opus-4-7", "stop_reason": "tool_use", "content": [
            ["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "git commit"]],
         ]]],
        ["type": "user", "uuid": "u2", "sessionId": session, "timestamp": "2026-08-19T06:43:53.000Z",
         "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "ok", "is_error": false]]]],
        ["type": "assistant", "uuid": "a2", "sessionId": session, "timestamp": "2026-08-19T06:43:56.000Z",
         "message": ["role": "assistant", "model": "claude-opus-4-7", "stop_reason": "end_turn", "content": [
            ["type": "text", "text": "Committed."],
         ], "usage": ["input_tokens": 6, "output_tokens": 20]]],
    ]
}

@Test func claudeTranscriptEndTurnClosesTheTurnByItself() throws {
    let session = "cccccccc-1111-2222-3333-444444444444"
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("\(session).jsonl").path
    try jsonl(claudeTranscript(session: session, prompt: "p1")).write(toFile: path, atomically: true, encoding: .utf8)

    let read = try RichSourceReader.read(path: path, sessionID: SessionID(session), adapter: ClaudeAdapter(), fromOffset: 0)
    #expect(read.lines == 4)
    let end = try #require(read.events.last(where: { $0.lifecycle == .waitingForInput }))
    #expect(end.phase == .idle)
    #expect(end.turn?.outcome == .completed)
    #expect(end.turn?.lastAssistantMessage == "Committed.")
    #expect(end.timelineItem?.id == TimelineItemIDs.turnEnd(SessionID(session), turnID: TurnID("p1")))
    // tool_use messages never end the turn.
    #expect(read.events.filter { $0.lifecycle == .waitingForInput }.count == 1)
    #expect(read.events.first(where: { $0.lifecycle == .waitingForInput })!.occurredAt > read.events[0].occurredAt)
}

@Test func reingestRebuildsFromTranscriptAndKeepsHookOnlyFacts() async throws {
    let session = "dddddddd-1111-2222-3333-444444444444"
    let sid = SessionID(session)
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let projectDir = home.appendingPathComponent(".claude/projects/-tmp-proj", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let path = projectDir.appendingPathComponent("\(session).jsonl").path
    try jsonl(claudeTranscript(session: session, prompt: "p1")).write(toFile: path, atomically: true, encoding: .utf8)

    let repository = InMemorySessionRepository()
    let adapter = ClaudeAdapter()
    let base: [String: Any] = ["session_id": session, "cwd": "/tmp/proj", "transcript_path": path]
    func apply(_ fields: [String: Any], at timestamp: String? = nil, rich: Bool = true) async throws {
        var merged = base.merging(fields) { $1 }
        if let timestamp { merged["timestamp"] = timestamp }
        for event in try adapter.events(fromHookData: hookData(merged), options: HookIngestOptions(richSourceAvailable: rich)) {
            _ = try await repository.apply(event)
        }
    }
    // Live history: start, prompt, stop, then a stray running event after the
    // stop leaves the session stuck in running/thinking.
    try await apply(["hook_event_name": "SessionStart", "source": "startup"], at: "2026-08-19T06:40:00Z")
    try await apply(["hook_event_name": "UserPromptSubmit", "prompt_id": "p1", "prompt": "commit"], at: "2026-08-19T06:42:07Z")
    try await apply(["hook_event_name": "SubagentStart", "prompt_id": "p1", "agent_id": "a1", "agent_type": "Explore"], at: "2026-08-19T06:42:20Z")
    try await apply(["hook_event_name": "SubagentStop", "prompt_id": "p1", "agent_id": "a1", "agent_type": "Explore"], at: "2026-08-19T06:43:00Z")
    let live = try RichSourceReader.read(path: path, sessionID: sid, adapter: adapter, fromOffset: 0)
    for event in live.events { _ = try await repository.apply(event) }
    try await repository.saveRolloutCursor(live.cursor)
    try await apply(["hook_event_name": "Stop", "prompt_id": "p1", "last_assistant_message": "Committed."], at: "2026-08-19T06:43:58Z")
    _ = try await repository.apply(AgentIngressEvent(
        eventID: EventID("stray"), sessionID: sid, turnID: TurnID("p1"), agent: .claude,
        occurredAt: ISO8601DateFormatter().date(from: "2026-08-19T06:44:01Z")!, lifecycle: .running, phase: .thinking
    ))
    _ = try await repository.apply(AgentIngressEvent(
        eventID: EventID("title"), sessionID: sid, agent: .claude,
        occurredAt: ISO8601DateFormatter().date(from: "2026-08-19T06:44:02Z")!, title: "Commit work"
    ))
    let before = try #require(try await repository.sessionDetail(id: sid, cursor: nil, limit: 500))
    #expect(before.summary.lifecycle == .running)
    #expect(before.summary.title == "Commit work")

    let reingester = SessionReingester(repository: repository, claudeAdapter: adapter, homeDirectory: home)
    let report = try await reingester.reingest(sessionID: sid, generation: "g1")
    #expect(report.path == path)
    #expect(report.linesRead == 4)

    let after = report.detail
    #expect(after.summary.lifecycle == .waitingForInput)
    #expect(after.summary.phase == .idle)
    #expect(after.summary.title == "Commit work")
    #expect(after.summary.firstTurnAt != nil)
    #expect(after.turns.count == 1)
    #expect(after.turns[0].outcome == .completed)
    #expect(after.turns[0].phase == .idle)
    #expect(after.turns[0].prompt == "commit")
    #expect(after.turns[0].toolCallCount == 1)
    #expect(after.turns[0].subagentCount == 1)
    // Hook-only items (session marker, subagent start/stop) survive; the
    // transcript's own items are back once each.
    #expect(after.timeline.contains { if case let .sessionMarker(m) = $0.payload { return m.kind == .sessionStarted }; return false })
    #expect(after.timeline.filter { if case .subagent = $0.payload { return true }; return false }.count == 2)
    #expect(after.timeline.filter { if case .tool = $0.payload { return true }; return false }.count == 2)
    #expect(after.timeline.filter { if case .turnEnd = $0.payload { return true }; return false }.count == 1)
    // Cursor sits at EOF so the helper continues incrementally.
    let cursor = try #require(try await repository.rolloutCursor(sessionID: sid))
    #expect(cursor.path == path)
    #expect(cursor.byteOffset == UInt64(try Data(contentsOf: URL(fileURLWithPath: path)).count))

    // A second rebuild with a new generation is idempotent in outcome.
    let again = try await reingester.reingest(sessionID: sid, generation: "g2")
    #expect(again.detail.summary.lifecycle == .waitingForInput)
    #expect(again.detail.turns.count == 1)
    #expect(again.detail.timeline.count == after.timeline.count)
}

@Test func reingestKeepsCompletedLifecycleFromSessionEnd() async throws {
    let session = "eeeeeeee-1111-2222-3333-444444444444"
    let sid = SessionID(session)
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let projectDir = home.appendingPathComponent(".claude/projects/-tmp-proj", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let path = projectDir.appendingPathComponent("\(session).jsonl").path
    try jsonl(claudeTranscript(session: session, prompt: "p1")).write(toFile: path, atomically: true, encoding: .utf8)

    let repository = InMemorySessionRepository()
    let adapter = ClaudeAdapter()
    let live = try RichSourceReader.read(path: path, sessionID: sid, adapter: adapter, fromOffset: 0)
    for event in live.events { _ = try await repository.apply(event) }
    for event in try adapter.events(fromHookData: hookData([
        "session_id": session, "cwd": "/tmp/proj", "hook_event_name": "SessionEnd", "reason": "exit", "timestamp": "2026-08-19T06:50:00Z",
    ]), options: .withRichSource) {
        _ = try await repository.apply(event)
    }
    let reingester = SessionReingester(repository: repository, claudeAdapter: adapter, homeDirectory: home)
    let report = try await reingester.reingest(sessionID: sid, generation: "g1")
    #expect(report.detail.summary.lifecycle == .completed)
    #expect(report.detail.timeline.contains { if case let .sessionMarker(m) = $0.payload { return m.kind == .sessionEnded }; return false })

    await #expect(throws: SessionReingestError.sessionNotFound) {
        _ = try await reingester.reingest(sessionID: SessionID("missing"), generation: "g1")
    }
}
