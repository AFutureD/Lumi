import Adapters
import Core
import Foundation
import Testing
import Transport
@testable import DaemonRuntime

// Rows earlier builds never stored are read back from the rollout once, as
// timeline-only writes, and the history revision moves when all is done.

private func temporaryRollout(_ lines: [String]) throws -> (path: String, directory: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumi-backfill-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("rollout-test.jsonl")
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    return (url.path, directory)
}

private actor Flag {
    private(set) var count = 0
    func raise() { count += 1 }
}

@Test func backfillInstallsCommandRowsAndMovesTheRevisionOnce() async throws {
    let session = SessionID("s1")
    let (path, directory) = try temporaryRollout([
        #"{"timestamp":"2026-11-11T05:07:06Z","type":"session_meta","payload":{"id":"s1","cwd":"/repo"}}"#,
        #"{"timestamp":"2026-11-11T05:07:16Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"exec-1","command":["/bin/zsh","-lc","ls Sources"],"cwd":"file:///repo","parsed_cmd":[{"type":"list_files","cmd":"ls Sources","path":"Sources"}],"status":"completed","exit_code":0,"aggregated_output":"a\nb\n","duration":{"secs":0,"nanos":5000000}}}}"#,
        #"{"timestamp":"2026-11-11T05:07:20Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"msg-1","content":[{"type":"Text","text":"done"}]}}}"#,
    ])
    defer { try? FileManager.default.removeItem(at: directory) }

    // The session as an earlier build left it: started, nothing of the command.
    let repository = InMemorySessionRepository()
    let started = try #require(AdapterDates.parse("2026-11-11T05:07:06Z"))
    #expect(try await repository.apply(AgentIngressEvent(
        eventID: EventID("start"), sessionID: session, agent: .codex, occurredAt: started,
        lifecycle: .completed, phase: .idle,
        timelineItem: TimelineItem(
            id: TimelineItemIDs.sessionMarker(session, .sessionStarted), sessionID: session, occurredAt: started,
            payload: .sessionMarker(SessionMarkerTimelinePayload(kind: .sessionStarted))
        )
    )))
    try await repository.saveRolloutCursor(RolloutCursor(path: path, byteOffset: 10, fileSize: 10, sessionID: session))
    let before = try #require(try await repository.sessionSummary(id: session))

    let announced = Flag()
    let backfill = HistoryBackfill(repository: repository, onRevised: { await announced.raise() })
    #expect(await backfill.bringUpToDate() == 1)

    let command = TimelineItemID("codex_item:s1:exec-1")
    let rows = try #require(try await repository.timelineItems(id: session, itemIDs: [command, TimelineItemID("codex_item:s1:msg-1")]))
    // Only the item rows the store was missing: the message is not a tool row.
    #expect(rows.timeline.map(\.id) == [command])
    guard case let .tool(tool)? = rows.timeline.first?.payload else { Issue.record("not a tool row"); return }
    #expect(TimelineLineText.tool(tool, name: tool.name) == "List · Sources · 5ms")
    // Timeline only: no state, no clock, no flag of the session moved.
    #expect(try await repository.sessionSummary(id: session) == before)
    #expect(try await repository.historyRevision() == HistoryRevision.current)
    #expect(await announced.count == 1)

    // Up to date: nothing is read or announced again.
    #expect(await backfill.bringUpToDate() == 0)
    #expect(await announced.count == 1)
}

@Test func aSessionWhoseRolloutIsGoneStillLetsTheRevisionMove() async throws {
    let session = SessionID("gone")
    let repository = InMemorySessionRepository()
    #expect(try await repository.apply(AgentIngressEvent(
        eventID: EventID("start"), sessionID: session, agent: .codex, occurredAt: Date(timeIntervalSince1970: 100),
        lifecycle: .completed, phase: .idle
    )))
    try await repository.saveRolloutCursor(RolloutCursor(path: "/nonexistent/rollout.jsonl", byteOffset: 0, fileSize: 0, sessionID: session))
    let backfill = HistoryBackfill(repository: repository)
    #expect(await backfill.bringUpToDate() == 0)
    #expect(try await repository.historyRevision() == HistoryRevision.current)
}

@Test func aResultReadAfterItsCallTakesTheCallsName() async throws {
    let session = SessionID("s")
    let repository = InMemorySessionRepository()
    let at = Date(timeIntervalSince1970: 100)
    func event(_ id: String, _ tool: ToolTimelinePayload, itemID: TimelineItemID) -> AgentIngressEvent {
        AgentIngressEvent(
            eventID: EventID(id), sessionID: session, agent: .codex, occurredAt: at,
            timelineItem: TimelineItem(id: itemID, sessionID: session, occurredAt: at, payload: .tool(tool))
        )
    }
    let call = event("call", ToolTimelinePayload(name: "exec", content: .string("text(1)"), status: .started, toolUseID: "call_1"),
                     itemID: TimelineItemIDs.toolCall(session, toolUseID: "call_1"))
    #expect(try await repository.apply(call))

    // A later read: the reader's state started over, so the adapter knew no name.
    let result = event("result", ToolTimelinePayload(name: "Tool", content: .string("Script completed"), status: .succeeded, toolUseID: "call_1"),
                       itemID: TimelineItemIDs.toolResult(session, toolUseID: "call_1"))
    let named = try await ToolResultNaming.named(result, in: repository)
    guard case let .tool(tool)? = named.timelineItem?.payload else { Issue.record("not a tool row"); return }
    #expect(tool.name == "exec")
    #expect(tool.content == .string("Script completed"))
    #expect(TimelineLineText.tool(tool, name: tool.name) == "exec · call_1")

    // No stored call: the event is left as it came.
    let orphan = event("orphan", ToolTimelinePayload(name: "Tool", status: .succeeded, toolUseID: "call_9"),
                       itemID: TimelineItemIDs.toolResult(session, toolUseID: "call_9"))
    #expect(try await ToolResultNaming.named(orphan, in: repository) == orphan)
}
