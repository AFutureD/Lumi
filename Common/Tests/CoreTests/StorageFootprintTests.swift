import Transport
import Foundation
import GRDB
import Testing
@testable import Core
@testable import Persistence

// One copy of each large tool-result value, one supersede rule for mirror
// rows, and database files that give deleted pages back.

private let base = Date(timeIntervalSince1970: 1_000)
private let image = String(repeating: "/9j/4AAQSkZJRg", count: 400) // ≥ 1 KiB, base64-like
private let output = String(repeating: "line of command output\n", count: 100)

/// A Read-of-a-screenshot result as Claude Code records it.
private func screenshotResult() -> [String: JSONValue] {
    [
        "content": .array([.object([
            "type": .string("image"),
            "source": .object([
                "type": .string("base64"),
                "media_type": .string("image/jpeg"),
                "data": .string(image),
            ]),
        ])]),
        "toolUseResult": .object([
            "type": .string("image"),
            "file": .object([
                "base64": .string(image),
                "type": .string("image/jpeg"),
                "originalSize": .number(808_698),
            ]),
        ]),
    ]
}

/// Follows an RFC 6901 pointer from the tool content object.
private func resolve(_ pointer: String, in root: JSONValue) -> JSONValue? {
    var value = root
    for token in pointer.split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
        let key = token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        switch value {
        case let .object(object): guard let next = object[key] else { return nil }; value = next
        case let .array(array): guard let index = Int(key), array.indices.contains(index) else { return nil }; value = array[index]
        default: return nil
        }
    }
    return value
}

/// Replaces every `{"lumi.sameAs": pointer}` with what it points at.
private func expandingReferences(_ value: JSONValue, root: JSONValue) -> JSONValue {
    switch value {
    case let .object(object):
        if object.count == 1, case let .string(pointer)? = object[ToolResultDeduplication.referenceKey] {
            return resolve(pointer, in: root) ?? value
        }
        return .object(object.mapValues { expandingReferences($0, root: root) })
    case let .array(array):
        return .array(array.map { expandingReferences($0, root: root) })
    default:
        return value
    }
}

private func reversible(_ original: [String: JSONValue]) -> Bool {
    let deduplicated = JSONValue.object(ToolResultDeduplication.deduplicated(original))
    return expandingReferences(deduplicated, root: deduplicated) == .object(original)
}

// MARK: Deduplication

@Test func screenshotIsStoredOnceWithAPointerToTheModelCopy() {
    let deduplicated = ToolResultDeduplication.deduplicated(screenshotResult())
    #expect(deduplicated["content"] == screenshotResult()["content"])
    guard case let .object(record)? = deduplicated["toolUseResult"],
          case let .object(file)? = record["file"] else {
        Issue.record("toolUseResult lost its shape")
        return
    }
    #expect(file["base64"] == .object(["lumi.sameAs": .string("/content/0/source/data")]))
    #expect(file["originalSize"] == .number(808_698))
    #expect(reversible(screenshotResult()))
}

@Test func deduplicationIsIdempotentAndLeavesShortOrUniqueValuesInline() {
    let once = ToolResultDeduplication.deduplicated(screenshotResult())
    #expect(ToolResultDeduplication.deduplicated(once) == once)

    let short: [String: JSONValue] = [
        "content": .string("ok"),
        "toolUseResult": .object(["stdout": .string("ok"), "other": .string(output)]),
    ]
    #expect(ToolResultDeduplication.deduplicated(short) == short)

    let onlyOne: [String: JSONValue] = ["content": .string(output)]
    #expect(ToolResultDeduplication.deduplicated(onlyOne) == onlyOne)
}

@Test func commandOutputRepeatedAsStdoutBecomesAReference() {
    let result: [String: JSONValue] = [
        "content": .string(output),
        "toolUseResult": .object(["stdout": .string(output), "stderr": .string(""), "interrupted": .boolean(false)]),
    ]
    let deduplicated = ToolResultDeduplication.deduplicated(result)
    #expect(deduplicated["toolUseResult"] == .object([
        "stdout": .object(["lumi.sameAs": .string("/content")]),
        "stderr": .string(""),
        "interrupted": .boolean(false),
    ]))
    #expect(reversible(result))
}

@Test func pointersEscapeSlashAndTildeInKeys() {
    let result: [String: JSONValue] = [
        "content": .object(["a/b~c": .string(output)]),
        "toolUseResult": .array([.string(output)]),
    ]
    let deduplicated = ToolResultDeduplication.deduplicated(result)
    #expect(deduplicated["toolUseResult"] == .array([.object(["lumi.sameAs": .string("/content/a~1b~0c")])]))
    #expect(reversible(result))
}

// MARK: Supersede rule

private func toolRow(_ id: String = "tool:s:t1:result", at offset: TimeInterval = 1, output: String) -> TimelineItem {
    TimelineItem(
        id: TimelineItemID(id), sessionID: SessionID("s"), turnID: TurnID("t1"),
        occurredAt: base.addingTimeInterval(offset),
        payload: .tool(ToolTimelinePayload(name: "Read", content: .string(output), status: .succeeded, toolUseID: "t1"))
    )
}

private let bulky = String(repeating: "x", count: 200_000)

@Test func trimmedCopyYieldsOnlyToTheWholeRowItWasCutFrom() {
    let whole = toolRow(output: bulky)
    let trimmed = TimelineContentBudget.trimmed(whole)
    #expect(trimmed.isTruncated)
    // The same row, trimmed: the whole one stays.
    #expect(!SessionDetailReduction.supersedes(trimmed, whole))
    // The row grew past the budget after a small whole copy was stored
    // (hook result first, transcript later): the trimmed newer one wins.
    let small = toolRow(output: "short")
    #expect(SessionDetailReduction.supersedes(trimmed, small))
    // An older copy never regresses a newer row, trimmed or not.
    #expect(!SessionDetailReduction.supersedes(toolRow(at: 0, output: "older"), small))
}

private func session(_ items: [TimelineItem]) -> SessionDetail {
    SessionDetail(
        summary: SessionSummary(
            id: SessionID("s"), agent: .claude, title: "s", lifecycle: .running, phase: .thinking,
            startedAt: base, updatedAt: base.addingTimeInterval(1), lastActivityAt: base.addingTimeInterval(1)
        ),
        timeline: items
    )
}

private func temporaryPath() -> (String, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return (directory.appendingPathComponent("sessions.sqlite3").path, directory)
}

@Test func mirrorTakesTheTrimmedCopyOfAGrownRowAndKeepsAWholeOne() async throws {
    let (path, directory) = temporaryPath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteSessionRepository(path: path)

    // Small whole copy first, then the trimmed copy of the grown row.
    try await repository.replaceSession(session([toolRow(output: "short")]))
    let grown = TimelineContentBudget.trimmed(toolRow(output: bulky))
    try await repository.mergeSession(session([grown]))
    #expect(try await repository.timelineItems(id: SessionID("s"), itemIDs: [grown.id])?.timeline == [grown])

    // A whole copy fetched on demand is not undone by its own trimmed copy.
    let whole = toolRow(output: bulky)
    try await repository.mergeSession(session([whole]))
    try await repository.mergeSession(session([grown]))
    #expect(try await repository.timelineItems(id: SessionID("s"), itemIDs: [whole.id])?.timeline == [whole])
}

// MARK: Migration and file compaction

@Test func dedupeMigrationRewritesStoredToolResults() async throws {
    let (path, directory) = temporaryPath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let duplicated = TimelineItem(
        id: TimelineItemID("tool:s:t1:result"), sessionID: SessionID("s"), turnID: TurnID("t1"),
        occurredAt: base.addingTimeInterval(1),
        payload: .tool(ToolTimelinePayload(name: "Read", content: .object(screenshotResult()), status: .succeeded, toolUseID: "t1"))
    )
    do {
        let repository = try SQLiteSessionRepository(path: path)
        try await repository.replaceSession(session([duplicated]))
    }
    // Stand the file back at v12 with the row as older builds stored it.
    let queue = try DatabaseQueue(path: path)
    try await queue.write { db in
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'lumi-v13-dedupe-tool-results'")
    }
    try queue.close()

    let reopened = try SQLiteSessionRepository(path: path)
    let stored = try #require(try await reopened.timelineItems(id: SessionID("s"), itemIDs: [duplicated.id])?.timeline.first)
    guard case let .tool(tool) = stored.payload else {
        Issue.record("not a tool row")
        return
    }
    #expect(tool.content == .object(ToolResultDeduplication.deduplicated(screenshotResult())))
    #expect(stored.occurredAt == duplicated.occurredAt)
}

// MARK: Lines read from records (lumi-v14)

/// Rows as builds before v14 stored them: every line kept beside its record.
private let storedBeforeV14: [(id: String, json: String)] = [
    ("tool:s:t1:call", #"{"id":"tool:s:t1:call","occurredAt":"1970-01-01T00:16:41.000Z","payload":{"tool":{"content":{"command":"ls -la","description":"List files"},"name":"Bash","status":"started","summary":"ls -la","toolUseID":"t1"},"type":"tool"},"sessionID":"s","turnID":"t1"}"#),
    ("tool:s:t1:result", #"{"id":"tool:s:t1:result","occurredAt":"1970-01-01T00:16:42.000Z","payload":{"tool":{"content":{"content":"total 8\nfile"},"name":"Tool","status":"succeeded","summary":"total 8","toolUseID":"t1"},"type":"tool"},"sessionID":"s","turnID":"t1"}"#),
    ("diagnostic:s:context:instructions:/repo/CLAUDE.md", #"{"id":"diagnostic:s:context:instructions:/repo/CLAUDE.md","occurredAt":"1970-01-01T00:16:43.000Z","payload":{"context":{"content":"/repo/CLAUDE.md","kind":"instructions","summary":"CLAUDE.md · session_start"},"type":"context"},"sessionID":"s"}"#),
    ("cfg", #"{"id":"cfg","occurredAt":"1970-01-01T00:16:44.000Z","payload":{"config":{"content":"/repo/.claude/settings.json","kind":"config_change","summary":"project_settings · settings.json"},"type":"config"},"sessionID":"s"}"#),
    ("codex_item:s:exec-1", #"{"id":"codex_item:s:exec-1","occurredAt":"1970-01-01T00:16:45.000Z","payload":{"tool":{"content":{"/repo/a.md":{"type":"update","unified_diff":"@@\n-a\n+b\n","move_path":null}},"name":"Apply patch","status":"succeeded","summary":"/repo/a.md","toolUseID":"exec-1"},"type":"tool"},"sessionID":"s","turnID":"t1"}"#),
    ("codex_item:s:exec-2", #"{"id":"codex_item:s:exec-2","occurredAt":"1970-01-01T00:16:46.000Z","payload":{"tool":{"content":"tsnet only ...","name":"web.search","status":"succeeded","summary":"tsnet only ...","toolUseID":"exec-2"},"type":"tool"},"sessionID":"s","turnID":"t1"}"#),
    ("codex_item:s:exec-3", #"{"id":"codex_item:s:exec-3","occurredAt":"1970-01-01T00:16:47.000Z","payload":{"tool":{"content":{"arguments":{"title":"New title"},"result":{"content":[{"text":"{}","type":"text"}]}},"durationMilliseconds":880,"name":"codex_app/set_thread_title","status":"succeeded","summary":"{}","toolUseID":"exec-3"},"type":"tool"},"sessionID":"s","turnID":"t1"}"#),
    ("codex_item:s:msg_1", #"{"id":"codex_item:s:msg_1","occurredAt":"1970-01-01T00:16:48.000Z","payload":{"message":{"role":"assistant","text":"done"},"type":"message"},"sessionID":"s","turnID":"t1"}"#),
]

@Test func storedLinesGoAndRowsTakeTheShapeLinesAreReadFrom() async throws {
    let (path, directory) = temporaryPath()
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        let repository = try SQLiteSessionRepository(path: path)
        try await repository.replaceSession(session([]))
    }
    // Stand the file back before v14, holding rows as older builds wrote them.
    let queue = try DatabaseQueue(path: path)
    try await queue.write { db in
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'lumi-v14-lines-read-from-records'")
        for (offset, row) in storedBeforeV14.enumerated() {
            try db.execute(
                sql: "INSERT INTO timeline(id, session_id, occurred_at, item) VALUES(?, 's', ?, ?)",
                arguments: [row.id, 1_001 + Double(offset), Data(row.json.utf8)]
            )
        }
    }
    try queue.close()

    let reopened = try SQLiteSessionRepository(path: path)
    let detail = try #require(try await reopened.timelineItems(
        id: SessionID("s"), itemIDs: storedBeforeV14.map { TimelineItemID($0.id) }
    ))
    let rows = TimelineProjection.rows(from: detail.timeline)
    #expect(rows.map(\.text) == [
        "Bash · List files",
        // Recorded as `Tool` in a later read than its call: named after it.
        "Bash · total 8",
        "CLAUDE.md · session_start",
        "project_settings · settings.json",
        "Edit · a.md +1 -1",
        "Web search · tsnet only ...",
        "codex_app/set_thread_title · New title · 880ms",
        "done",
    ])
    // No stored row names a summary any more, and the facts two hook
    // records kept only there now sit in their content.
    let raw = try await DatabaseQueue(path: path).read { db in
        try String.fetchAll(db, sql: "SELECT CAST(item AS TEXT) FROM timeline ORDER BY occurred_at")
    }
    #expect(raw.allSatisfy { !$0.contains("\"summary\"") })
    let byID = Dictionary(uniqueKeysWithValues: detail.timeline.map { ($0.id.rawValue, $0.payload) })
    #expect(byID["diagnostic:s:context:instructions:/repo/CLAUDE.md"] == .context(ContextTimelinePayload(
        kind: "instructions",
        content: .object(["file_path": .string("/repo/CLAUDE.md"), "load_reason": .string("session_start")])
    )))
    #expect(byID["cfg"] == .config(ConfigTimelinePayload(
        kind: "config_change",
        content: .object(["file_path": .string("/repo/.claude/settings.json"), "source": .string("project_settings")])
    )))
    guard case let .tool(search)? = byID["codex_item:s:exec-2"] else { Issue.record("not a tool row"); return }
    #expect(search.content == .object([
        "id": .string("exec-2"), "type": .string("Extension"), "kind": .string("web.search"), "query": .string("tsnet only ..."),
    ]))
}

@Test func backfillInstallsRowsWithoutTouchingTheSummaryAndSkipsOlderHistory() async throws {
    let (path, directory) = temporaryPath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteSessionRepository(path: path)
    let stored = toolRow("tool:s:t1:result", at: 10, output: "kept")
    try await repository.replaceSession(session([stored]))
    let before = try #require(try await repository.sessionSummary(id: SessionID("s")))

    func command(_ id: String, at offset: TimeInterval) -> TimelineItem {
        TimelineItem(
            id: TimelineItemID(id), sessionID: SessionID("s"), turnID: TurnID("t1"),
            occurredAt: base.addingTimeInterval(offset),
            payload: .tool(ToolTimelinePayload(
                name: "Shell", content: .object(["type": .string("CommandExecution"), "command": .array([.string("ls")])]),
                status: .succeeded, toolUseID: id
            ))
        )
    }
    // A subagent's rollout opens with its parent's history: rows older than
    // the session's first stored row are not this session's activity.
    let written = try await repository.backfillTimeline(
        [command("codex_item:s:parent", at: 2), command("codex_item:s:mine", at: 11)], sessionID: SessionID("s")
    )
    #expect(written == 1)
    let detail = try #require(try await repository.timelineItems(
        id: SessionID("s"), itemIDs: [stored.id, TimelineItemID("codex_item:s:mine"), TimelineItemID("codex_item:s:parent")]
    ))
    #expect(detail.timeline.map(\.id.rawValue) == ["tool:s:t1:result", "codex_item:s:mine"])
    #expect(try await repository.sessionSummary(id: SessionID("s")) == before)
    // A session that holds nothing takes nothing.
    #expect(try await repository.backfillTimeline([command("codex_item:x:1", at: 1)], sessionID: SessionID("missing")) == 0)

    #expect(try await repository.historyRevision() == nil)
    try await repository.setHistoryRevision(HistoryRevision.current)
    #expect(try await repository.historyRevision() == HistoryRevision.current)
}

private func header(_ path: String) async throws -> (mode: Int, freePages: Int) {
    let queue = try DatabaseQueue(path: path)
    defer { try? queue.close() }
    return try await queue.read { db in
        (try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? -1, try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? -1)
    }
}

@Test func newDatabaseFilesGiveDeletedPagesBack() async throws {
    let (path, directory) = temporaryPath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteSessionRepository(path: path)
    try await repository.replaceSession(session([toolRow(output: bulky)]))
    _ = try await repository.deleteAllSessions()
    let (mode, freePages) = try await header(path)
    #expect(mode == 1)
    #expect(freePages == 0)
}

@Test func olderFilesAreCompactedOnceOnOpen() async throws {
    let (path, directory) = temporaryPath()
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        let repository = try SQLiteSessionRepository(path: path)
        try await repository.replaceSession(session((0..<20).map { toolRow("tool:s:t\($0):result", at: Double($0), output: bulky) }))
    }
    // Turn the file back into one written before auto-vacuum, then delete
    // rows so it carries free pages.
    let queue = try DatabaseQueue(path: path)
    try await queue.writeWithoutTransaction { db in
        try db.execute(sql: "PRAGMA auto_vacuum = NONE")
        try db.execute(sql: "VACUUM")
        try db.execute(sql: "DELETE FROM timeline")
        try db.execute(sql: "DELETE FROM sessions")
    }
    try queue.close()
    let before = try await header(path)
    #expect(before.mode == 0)
    #expect(before.freePages > 0)
    let bytesBefore = try #require(try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber).intValue

    _ = try SQLiteSessionRepository(path: path)

    let after = try await header(path)
    #expect(after.mode == 1)
    #expect(after.freePages == 0)
    let bytesAfter = try #require(try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber).intValue
    #expect(bytesAfter < bytesBefore / 4)
}
