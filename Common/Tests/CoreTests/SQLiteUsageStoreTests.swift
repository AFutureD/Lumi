import Transport
import Foundation
import GRDB
import Testing
@testable import Core
@testable import Persistence

private let utc = { () -> Calendar in
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func makeStore() throws -> (SQLiteSessionRepository, SQLiteUsageStore, String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("usage-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("sessions.sqlite3").path
    let repository = try SQLiteSessionRepository(path: path)
    return (repository, repository.makeUsageStore(calendar: utc), path)
}

private func record(
    agent: AgentKind = .claude,
    session: String = "s1",
    turn: String = "t1",
    model: String = "claude-fable-5",
    workspace: String = "/w",
    at: String = "2026-09-05T10:00:00.000Z",
    tokens: UsageTokens = UsageTokens(input: 10, cacheRead: 100, cacheWrite5m: 5, cacheWrite1h: 7, output: 20, reasoning: 3),
    key: String,
    reportedCostUSD: Double? = nil,
    isCall: Bool = true,
    tier: Int = 0
) -> UsageRecord {
    UsageRecord(
        agent: agent, sessionID: session, turnID: turn, model: model, workspace: workspace,
        occurredAt: AdapterDates.parse(at)!, tokens: tokens, dedupeKey: key, reportedCostUSD: reportedCostUSD, isCall: isCall, tier: tier
    )
}

private func cursor(identity: String = "claude:1:100", path: String = "/tmp/a.jsonl", offset: UInt64 = 10, state: UsageScanState = UsageScanState()) -> UsageCursor {
    UsageCursor(
        identity: identity, path: path, source: .claude, byteOffset: offset, fileSize: offset,
        modifiedAt: Date(timeIntervalSince1970: 1_000), prefixLength: 4, prefixHash: "abcd", state: state
    )
}

@Test func usageBucketsAccumulateByTurnModelAndDayAndCountEachKeyOnce() async throws {
    let (_, store, _) = try makeStore()
    let applied = try await store.apply(records: [
        record(key: "k1"),
        record(key: "k1"),                                           // repeat inside one read
        record(at: "2026-09-05T11:00:00.000Z", key: "k2"),           // same bucket, later call
        record(model: "claude-opus-5", key: "k3"),                   // other model, same turn
        record(turn: "t2", at: "2026-09-06T00:30:00.000Z", key: "k4"), // next local day
        record(agent: .codex, session: "c1", model: "gpt-5.5", workspace: "/c", key: "k5"),
        record(turn: "t3", key: "k6", reportedCostUSD: 0.5),                 // source-reported cost
        record(turn: "t3", at: "2026-09-05T12:00:00.000Z", key: "k7", reportedCostUSD: 0.25),
        record(turn: "t4", tokens: UsageTokens(output: 10), key: "k8"),
        record(turn: "t4", tokens: UsageTokens(output: 5), key: "k8:more:15", isCall: false),   // top-up, not a call
        record(turn: "t4", tokens: UsageTokens(input: 300_000), key: "k9", tier: 1),          // long-context band: its own bucket
    ], cursor: cursor())
    #expect(applied == 10)
    // Re-applying the same keys changes nothing.
    #expect(try await store.apply(records: [record(key: "k1"), record(key: "k5")], cursor: cursor(offset: 20)) == 0)

    let buckets = try await store.buckets(since: UsageDay(year: 2026, month: 9, day: 1), until: UsageDay(year: 2026, month: 9, day: 30))
    #expect(buckets.count == 7)
    let toppedUp = try #require(buckets.first { $0.turnID == "t4" && $0.tier == 0 })
    #expect(toppedUp.calls == 1)
    #expect(toppedUp.tokens.output == 15)
    let banded = try #require(buckets.first { $0.turnID == "t4" && $0.tier == 1 })
    #expect(banded.calls == 1)
    #expect(banded.tokens.input == 300_000)
    let first = try #require(buckets.first { $0.turnID == "t1" && $0.model == "claude-fable-5" })
    #expect(first.calls == 2)
    #expect(first.tokens == UsageTokens(input: 20, cacheRead: 200, cacheWrite5m: 10, cacheWrite1h: 14, output: 40, reasoning: 6))
    #expect(first.firstAt == AdapterDates.parse("2026-09-05T10:00:00.000Z"))
    #expect(first.lastAt == AdapterDates.parse("2026-09-05T11:00:00.000Z"))
    #expect(first.day == UsageDay(year: 2026, month: 9, day: 5))
    #expect(first.workspace == "/w")
    #expect(first.reportedCostUSD == nil)
    #expect(first.reportedCalls == 0)
    let reported = try #require(buckets.first { $0.turnID == "t3" })
    #expect(reported.calls == 2)
    #expect(reported.reportedCalls == 2)
    #expect(reported.reportedCostUSD == 0.75)
    #expect(buckets.first { $0.turnID == "t2" }?.day == UsageDay(year: 2026, month: 9, day: 6))
    #expect(buckets.first { $0.agent == .codex }?.workspace == "/c")

    // Range bounds are inclusive on both ends.
    let sixth = try await store.buckets(since: UsageDay(year: 2026, month: 9, day: 6), until: UsageDay(year: 2026, month: 9, day: 6))
    #expect(sixth.map(\.turnID) == ["t2"])
    let none = try await store.buckets(since: UsageDay(year: 2026, month: 9, day: 7), until: UsageDay(year: 2026, month: 9, day: 7))
    #expect(none.isEmpty)
}

@Test func usageCursorsRoundTripTheirParserState() async throws {
    let (_, store, _) = try makeStore()
    let pending = record(agent: .codex, session: "c", turn: "", model: "", workspace: "/c", key: "codex:pending")
    let state = UsageScanState(
        turnID: "prompt-A", lastTimestamp: Date(timeIntervalSince1970: 1_700_000_000.266),
        codexSessionID: "c", codexIsSubagent: true, codexWorkspace: "/c", codexModel: "gpt-5.5",
        codexCumulative: UsageTokens(input: 1, cacheRead: 2, output: 3), codexLastSignature: "1:2:3:4:5",
        codexResets: 1, codexPending: pending
    )
    try await store.apply(records: [], cursor: cursor(identity: "codex:1:2", path: "/tmp/b.jsonl", offset: 42, state: state))
    try await store.apply(records: [], cursor: cursor(identity: "claude:1:1", path: "/tmp/a.jsonl", offset: 7))
    let loaded = try #require(try await store.cursor(identity: "codex:1:2"))
    #expect(loaded.byteOffset == 42)
    #expect(loaded.path == "/tmp/b.jsonl")
    #expect(loaded.source == .claude)
    #expect(loaded.prefixLength == 4)
    #expect(loaded.prefixHash == "abcd")
    #expect(loaded.state.turnID == "prompt-A")
    #expect(loaded.state.codexIsSubagent)
    #expect(loaded.state.codexCumulative == UsageTokens(input: 1, cacheRead: 2, output: 3))
    #expect(loaded.state.codexLastSignature == "1:2:3:4:5")
    #expect(loaded.state.codexResets == 1)
    #expect(loaded.state.codexPending == pending)
    #expect(abs(loaded.state.lastTimestamp!.timeIntervalSince(state.lastTimestamp!)) < 0.001)
    #expect(try await store.cursors().map(\.path) == ["/tmp/a.jsonl", "/tmp/b.jsonl"])
    #expect(try await store.cursor(identity: "nope") == nil)
    // Advancing overwrites in place; a moved file keeps its identity and takes the new path.
    try await store.apply(records: [], cursor: cursor(identity: "codex:1:2", path: "/tmp/archived/b.jsonl", offset: 99))
    let moved = try #require(try await store.cursor(identity: "codex:1:2"))
    #expect(moved.byteOffset == 99)
    #expect(moved.path == "/tmp/archived/b.jsonl")
    #expect(try await store.cursors().count == 2)
}

@Test func usageSurvivesSessionDeletionAndClearHistory() async throws {
    let (repository, store, path) = try makeStore()
    let sessionID = SessionID("s1")
    #expect(try await repository.apply(AgentIngressEvent(
        eventID: EventID("e1"), sessionID: sessionID, agent: .claude,
        occurredAt: Date(timeIntervalSince1970: 100), lifecycle: .running, phase: .thinking
    )))
    try await store.apply(records: [record(session: "s1", key: "k1")], cursor: cursor())
    #expect(try await repository.deleteSession(id: sessionID) == [sessionID])
    _ = try await repository.resetSession(id: sessionID)
    _ = try await repository.deleteAllSessions()

    let range = (UsageDay(year: 2026, month: 9, day: 5), UsageDay(year: 2026, month: 9, day: 5))
    #expect(try await store.buckets(since: range.0, until: range.1).count == 1)
    #expect(try await store.cursors().count == 1)
    let database = try DatabaseQueue(path: path)
    let seen = try await database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM usage_seen") }
    #expect(seen == 1)
    let tables = try await database.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'usage_%' ORDER BY name") }
    #expect(tables == ["usage_buckets", "usage_cursors", "usage_seen"])
}

@Test func usageDayCalendarHelpersAgreeWithTheCalendar() throws {
    let day = UsageDay(Date(timeIntervalSince1970: 1_788_566_400), calendar: utc) // 2026-09-05T00:00:00Z
    #expect(day == UsageDay(year: 2026, month: 9, day: 5))
    #expect(day.start(in: utc) == Date(timeIntervalSince1970: 1_788_566_400))
    #expect(day.adding(days: -5, calendar: utc) == UsageDay(year: 2026, month: 8, day: 31))
    #expect(UsageDay(year: 2026, month: 8, day: 31).days(until: day, calendar: utc) == 5)
    #expect(UsageDay(year: 2026, month: 2, day: 30).start(in: utc) == nil)
    var tokyo = Calendar(identifier: .gregorian)
    tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    // 23:30 UTC is already the next day in Tokyo: buckets follow the local calendar.
    #expect(UsageDay(Date(timeIntervalSince1970: 1_788_566_400 - 1_800), calendar: tokyo) == UsageDay(year: 2026, month: 9, day: 5))
    #expect(UsageDay(Date(timeIntervalSince1970: 1_788_566_400 - 1_800), calendar: utc) == UsageDay(year: 2026, month: 9, day: 4))
}
