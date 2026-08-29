import Core
import Transport
import Foundation
import Testing
@testable import Adapters

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
         "origin": ["kind": "human"],
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
    // `turn` mirrors the pipeline: with the rich source readable it hands the
    // adapter the Turn the transcript reader holds open.
    func apply(_ fields: [String: Any], at timestamp: String? = nil, rich: Bool = true, turn: TurnID? = nil) async throws {
        var merged = base.merging(fields) { $1 }
        if let timestamp { merged["timestamp"] = timestamp }
        let data = hookData(merged)
        for event in try adapter.events(
            fromHook: ClaudeHookPayload(data: data),
            raw: data,
            options: HookIngestOptions(richSourceAvailable: rich, currentTurnID: turn)
        ) {
            _ = try await repository.apply(event)
        }
    }
    // Live history: start, prompt, stop, then a stray running event after the
    // stop leaves the session stuck in running/thinking.
    try await apply(["hook_event_name": "SessionStart", "source": "startup"], at: "2026-08-19T06:40:00Z")
    try await apply(["hook_event_name": "UserPromptSubmit", "prompt_id": "p1", "prompt": "commit"], at: "2026-08-19T06:42:07Z")
    try await apply(["hook_event_name": "SubagentStart", "prompt_id": "p1", "agent_id": "a1", "agent_type": "Explore"], at: "2026-08-19T06:42:20Z", turn: TurnID("p1"))
    try await apply(["hook_event_name": "SubagentStop", "prompt_id": "p1", "agent_id": "a1", "agent_type": "Explore"], at: "2026-08-19T06:43:00Z", turn: TurnID("p1"))
    let live = try RichSourceReader.read(path: path, sessionID: sid, adapter: adapter, fromOffset: 0)
    for event in live.events { _ = try await repository.apply(event) }
    try await repository.saveRolloutCursor(live.cursor)
    try await apply(["hook_event_name": "Stop", "prompt_id": "p1", "last_assistant_message": "Committed."], at: "2026-08-19T06:43:58Z", turn: TurnID("p1"))
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

// A resumed Claude Code session's transcript slice can open with control
// records (`custom-title`, `bridge-session`) that carry no `timestamp`
// field at all. A reingest must not let the fallback for that missing
// timestamp outrun the real, later-timestamped turns that follow it in the
// same file — see RolloutReadState.lastTimestamp.
@Test func reingestDoesNotStallOnATimestamplessLeadRecord() async throws {
    let session = "99999999-1111-2222-3333-444444444444"
    let sid = SessionID(session)
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let projectDir = home.appendingPathComponent(".claude/projects/-tmp-proj", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let path = projectDir.appendingPathComponent("\(session).jsonl").path
    let records: [[String: Any]] = [
        // Real Claude Code resume transcripts open with control records like
        // these two, timestamped nowhere in their own JSON. Only the
        // queue-operation ahead of them carries a real time to inherit.
        ["type": "queue-operation", "operation": "enqueue", "timestamp": "2026-08-19T06:41:00.000Z", "sessionId": session, "content": "commit"],
        ["type": "custom-title", "customTitle": "Resumed work", "sessionId": session],
        ["type": "bridge-session", "sessionId": session, "bridgeSessionId": "cse_1", "lastSequenceNum": 0],
    ] + claudeTranscript(session: session, prompt: "p1")
    try jsonl(records).write(toFile: path, atomically: true, encoding: .utf8)

    let repository = InMemorySessionRepository()
    let adapter = ClaudeAdapter()
    // A session must already be known before a reingest will touch it — the
    // daemon's live pipeline is what first creates the row; simulate that
    // with the same full-file read reingest itself will later redo.
    let live = try RichSourceReader.read(path: path, sessionID: sid, adapter: adapter, fromOffset: 0)
    for event in live.events { _ = try await repository.apply(event) }
    try await repository.saveRolloutCursor(live.cursor)

    let reingester = SessionReingester(repository: repository, claudeAdapter: adapter, homeDirectory: home)
    let report = try await reingester.reingest(sessionID: sid, generation: "g1")

    #expect(report.detail.summary.lifecycle == .waitingForInput)
    #expect(report.detail.summary.phase == .idle)
    #expect(report.detail.turns.first?.outcome == .completed)
}

// The very first record in the whole file can be one of those timestampless
// control records, with nothing earlier in the window to inherit from — and
// real Claude Code transcripts are not strictly time-ordered even among the
// records that do carry a timestamp (a queued-prompt record can be logged
// ahead of the session-start hook chronologically before it). The fallback
// must still land at or before every real event that follows, not at
// wall-clock `Date()` — see RichSourceReader.earliestTimestamp.
@Test func reingestDoesNotStallWhenTheFirstRecordInTheFileHasNoTimestamp() async throws {
    let session = "88888888-1111-2222-3333-444444444444"
    let sid = SessionID(session)
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let projectDir = home.appendingPathComponent(".claude/projects/-tmp-proj", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let path = projectDir.appendingPathComponent("\(session).jsonl").path
    let records: [[String: Any]] = [
        ["type": "custom-title", "customTitle": "Fresh session", "sessionId": session],
        ["type": "mode", "mode": "normal", "sessionId": session],
        // This is the only other record ahead of the transcript itself, and
        // its own timestamp is LATER than the transcript's first record
        // below — a naive "first timestamp found" fallback would seed the
        // two control records above at 06:45, after the first real turn
        // events at 06:42–06:43, stalling them exactly like `Date()` would.
        ["type": "queue-operation", "operation": "enqueue", "timestamp": "2026-08-19T06:45:00.000Z", "sessionId": session, "content": "commit"],
    ] + claudeTranscript(session: session, prompt: "p1")
    try jsonl(records).write(toFile: path, atomically: true, encoding: .utf8)

    let repository = InMemorySessionRepository()
    let adapter = ClaudeAdapter()
    let live = try RichSourceReader.read(path: path, sessionID: sid, adapter: adapter, fromOffset: 0)
    for event in live.events { _ = try await repository.apply(event) }
    try await repository.saveRolloutCursor(live.cursor)

    let reingester = SessionReingester(repository: repository, claudeAdapter: adapter, homeDirectory: home)
    let report = try await reingester.reingest(sessionID: sid, generation: "g1")

    #expect(report.detail.summary.lifecycle == .waitingForInput)
    #expect(report.detail.summary.phase == .idle)
    #expect(report.detail.turns.first?.outcome == .completed)
}

// Opening a session (gray) and archiving it from the Notch are human acts
// recorded only on the summary. The rebuild replays every turn end, which
// would flip `needsReview` back to green — the flags must be carried over.
@Test func reingestKeepsReviewedAndNotchArchivedFlags() async throws {
    let session = "abababab-1111-2222-3333-444444444444"
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
    try await repository.saveRolloutCursor(live.cursor)
    let reingester = SessionReingester(repository: repository, claudeAdapter: adapter, homeDirectory: home)

    // Unreviewed (green) stays unreviewed across a rebuild.
    let green = try await reingester.reingest(sessionID: sid, generation: "g0")
    #expect(green.detail.summary.needsReview)

    try await repository.markSessionReviewed(sid)
    try await repository.markSessionHiddenInNotch(sid)
    let before = try #require(try await repository.sessionDetail(id: sid, cursor: nil, limit: 500))
    #expect(!before.summary.needsReview)
    #expect(before.summary.statusTone == .gray)

    let report = try await reingester.reingest(sessionID: sid, generation: "g1")
    #expect(!report.detail.summary.needsReview)
    #expect(!report.detail.summary.needsAttention)
    #expect(report.detail.summary.statusTone == .gray)
    #expect(report.detail.summary.hiddenInNotch)
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
    let endData = hookData([
        "session_id": session, "cwd": "/tmp/proj", "hook_event_name": "SessionEnd", "reason": "exit", "timestamp": "2026-08-19T06:50:00Z",
    ])
    for event in try adapter.events(fromHook: ClaudeHookPayload(data: endData), raw: endData, options: .withRichSource) {
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

@Test func reingestBackfillsClaudeSubagentChildSessions() async throws {
    let session = "ffffffff-1111-2222-3333-444444444444"
    let sid = SessionID(session)
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let projectDir = home.appendingPathComponent(".claude/projects/-tmp-proj", isDirectory: true)
    let agentDir = projectDir.appendingPathComponent("\(session)/subagents", isDirectory: true)
    try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let path = projectDir.appendingPathComponent("\(session).jsonl").path
    try jsonl(claudeTranscript(session: session, prompt: "p1")).write(toFile: path, atomically: true, encoding: .utf8)
    try jsonl([
        ["type": "user", "uuid": "s1", "isSidechain": true, "agentId": "a9", "sessionId": session, "promptId": "ap", "timestamp": "2026-08-19T06:42:30.000Z", "cwd": "/tmp/proj",
         "message": ["role": "user", "content": "Find the tests"]],
        ["type": "assistant", "uuid": "s2", "isSidechain": true, "agentId": "a9", "sessionId": session, "timestamp": "2026-08-19T06:42:50.000Z",
         "message": ["role": "assistant", "model": "claude-haiku-4-5", "stop_reason": "end_turn", "content": [["type": "text", "text": "Tests live in Tests/."]]]],
    ]).write(toFile: agentDir.appendingPathComponent("agent-a9.jsonl").path, atomically: true, encoding: .utf8)
    try #"{"agentType":"Explore","description":"Locate the tests","spawnDepth":1,"model":"haiku"}"#
        .write(toFile: agentDir.appendingPathComponent("agent-a9.meta.json").path, atomically: true, encoding: .utf8)

    let repository = InMemorySessionRepository()
    let adapter = ClaudeAdapter()
    // Recorded by an older helper: the parent exists, the child never did.
    let base: [String: Any] = ["session_id": session, "cwd": "/tmp/proj", "transcript_path": path, "timestamp": "2026-08-19T06:42:07Z"]
    let promptData = hookData(base.merging(["hook_event_name": "UserPromptSubmit", "prompt_id": "p1", "prompt": "commit"]) { $1 })
    for event in try adapter.events(fromHook: ClaudeHookPayload(data: promptData), raw: promptData, options: .withRichSource) {
        _ = try await repository.apply(event)
    }
    let live = try RichSourceReader.read(path: path, sessionID: sid, adapter: adapter, fromOffset: 0)
    for event in live.events { _ = try await repository.apply(event) }
    try await repository.saveRolloutCursor(live.cursor)

    let reingester = SessionReingester(repository: repository, claudeAdapter: adapter, homeDirectory: home)
    _ = try await reingester.reingest(sessionID: sid, generation: "g1")

    let childID = ClaudeSubagentIdentity.sessionID(parent: sid, agentID: "a9")
    let child = try #require(try await repository.sessionDetail(id: childID, cursor: nil, limit: 500))
    #expect(child.summary.agent == .claudeSubagent)
    #expect(child.summary.title == "Locate the tests")
    #expect(child.summary.lineage?.parentSessionID == sid)
    #expect(child.summary.lineage?.agentRole == "Explore")
    #expect(child.summary.workspace == "/tmp/proj")
    #expect(child.summary.lifecycle == .completed)
    #expect(child.turns.first?.prompt == "Find the tests")
    #expect(child.turns.first?.outcome == .completed)
    // The child's own reingest works off its cursor.
    let rebuilt = try await reingester.reingest(sessionID: childID, generation: "g2")
    #expect(rebuilt.detail.summary.lifecycle == .completed)
    #expect(rebuilt.detail.summary.title == "Locate the tests")
    #expect(rebuilt.detail.summary.lineage?.parentSessionID == sid)
}
