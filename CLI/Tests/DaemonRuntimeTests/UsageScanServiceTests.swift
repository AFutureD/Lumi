import Adapters
import Core
import Transport
import Foundation
import Testing
@testable import DaemonRuntime

private func claudeAssistant(messageID: String, requestID: String, uuid: String, model: String = "claude-fable-5", timestamp: String, cwd: String = "/Users/me/lumi") -> String {
    #"{"parentUuid":"u","isSidechain":false,"requestId":"\#(requestID)","type":"assistant","uuid":"\#(uuid)","timestamp":"\#(timestamp)","cwd":"\#(cwd)","sessionId":"sess-1","message":{"model":"\#(model)","id":"\#(messageID)","role":"assistant","content":[{"type":"text","text":"Hi"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":100,"output_tokens":20}}}"#
}

private func claudeUser(promptID: String, timestamp: String) -> String {
    #"{"isSidechain":false,"promptId":"\#(promptID)","type":"user","message":{"role":"user","content":[{"type":"text","text":"Go"}]},"uuid":"u-\#(promptID)","timestamp":"\#(timestamp)","origin":{"kind":"human"},"cwd":"/Users/me/lumi","sessionId":"sess-1"}"#
}

private func codexLines(sessionID: String, cwd: String, timestamp: String) -> [String] {
    [
        #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"\#(sessionID)","cwd":"\#(cwd)","source":"vscode"}}"#,
        #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"turn_id":"turn-\#(sessionID)","cwd":"\#(cwd)","model":"gpt-5.5"}}"#,
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":50,"reasoning_output_tokens":10}}}}"#,
    ]
}

private struct Harness {
    let home: URL
    let store = InMemoryUsageStore(calendar: Harness.utc)
    let scanner: UsageScanService

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        scanner = UsageScanService(
            roots: UsageScanService.roots(
                claudeProjectsDirectory: home.appendingPathComponent(".claude/projects"),
                codexSessionsDirectory: home.appendingPathComponent(".codex/sessions"),
                codexArchivedSessionsDirectory: home.appendingPathComponent(".codex/archived_sessions")
            ),
            store: store,
            pollIntervalSeconds: 3_600
        )
    }

    @discardableResult
    func write(_ relative: String, _ lines: [String]) throws -> String {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url.path
    }

    func append(_ relative: String, _ lines: [String]) throws {
        let url = home.appendingPathComponent(relative)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
        // Same-second appends must still read as a change.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: url.path)
    }

    func buckets() async throws -> [UsageBucket] {
        try await store.buckets(since: UsageDay(year: 2000, month: 1, day: 1), until: UsageDay(year: 2100, month: 1, day: 1))
    }

    func identity(_ relative: String, source: UsageSource) throws -> String {
        let path = home.appendingPathComponent(relative).path
        return UsageFileIdentity.identity(source: source, attributes: try FileManager.default.attributesOfItem(atPath: path), path: path)
    }
}

@Test func usageScannerWalksEveryRootAndReadsIncrementally() async throws {
    let harness = try Harness()
    try harness.write(".claude/projects/-Users-me-lumi/sess-1.jsonl", [
        claudeUser(promptID: "p1", timestamp: "2026-09-05T10:00:00.000Z"),
        claudeAssistant(messageID: "m1", requestID: "r1", uuid: "a1", timestamp: "2026-09-05T10:00:01.000Z"),
        claudeAssistant(messageID: "m1", requestID: "r1", uuid: "a2", timestamp: "2026-09-05T10:00:01.000Z"),
    ])
    try harness.write(".claude/projects/-Users-me-lumi/sess-1/subagents/agent-1.jsonl", [
        #"{"isSidechain":true,"promptId":"sp","type":"user","message":{"role":"user","content":[{"type":"text","text":"Explore"}]},"uuid":"su","timestamp":"2026-09-05T10:00:02.000Z","agentId":"1","cwd":"/Users/me/lumi","sessionId":"sess-1"}"#,
        #"{"isSidechain":true,"requestId":"rs","type":"assistant","uuid":"sa","timestamp":"2026-09-05T10:00:03.000Z","agentId":"1","cwd":"/Users/me/lumi","sessionId":"sess-1","message":{"model":"claude-sonnet-5","id":"ms","role":"assistant","content":[],"usage":{"input_tokens":5,"output_tokens":5}}}"#,
    ])
    try harness.write(".codex/sessions/2026/09/05/rollout-2026-09-05T10-00-00-c1.jsonl", codexLines(sessionID: "c1", cwd: "/Users/me/codex", timestamp: "2026-09-05T10:05:00.000Z"))
    try harness.write(".codex/archived_sessions/rollout-2026-08-01T10-00-00-c0.jsonl", codexLines(sessionID: "c0", cwd: "/Users/me/old", timestamp: "2026-08-01T10:05:00.000Z"))
    try harness.write(".claude/projects/-Users-me-lumi/.hidden/ignored.jsonl", [claudeAssistant(messageID: "mx", requestID: "rx", uuid: "ax", timestamp: "2026-09-05T10:00:01.000Z")])
    try harness.write(".claude/projects/-Users-me-lumi/notes.txt", ["not a transcript"])

    await harness.scanner.scanOnce()
    var status = await harness.scanner.status()
    #expect(status.scannedFiles == 4)
    #expect(status.pendingFiles == 0)
    #expect(status.lastScanAt != nil)
    #expect(!status.isScanning)

    var buckets = try await harness.buckets()
    #expect(buckets.count == 4)
    let claude = try #require(buckets.first { $0.agent == .claude })
    #expect(claude.calls == 1)
    #expect(claude.turnID == "p1")
    #expect(claude.tokens == UsageTokens(input: 10, cacheRead: 100, output: 20))
    let subagent = try #require(buckets.first { $0.agent == .claudeSubagent })
    #expect(subagent.sessionID == "sess-1")
    #expect(subagent.turnID == "sp")
    #expect(subagent.model == "claude-sonnet-5")
    let codex = buckets.filter { $0.agent == .codex }
    #expect(Set(codex.map(\.sessionID)) == ["c0", "c1"])
    #expect(codex.first { $0.sessionID == "c1" }?.tokens == UsageTokens(input: 600, cacheRead: 400, output: 50, reasoning: 10))

    // Nothing changed: the next poll opens nothing.
    await harness.scanner.scanOnce()
    #expect(try await harness.buckets() == buckets)

    // An append is read from the cursor, in the carried turn, once.
    try harness.append(".claude/projects/-Users-me-lumi/sess-1.jsonl", [
        claudeAssistant(messageID: "m2", requestID: "r2", uuid: "a3", timestamp: "2026-09-05T10:01:00.000Z"),
        claudeAssistant(messageID: "m2", requestID: "r2", uuid: "a4", timestamp: "2026-09-05T10:01:00.000Z"),
    ])
    await harness.scanner.scanOnce()
    buckets = try await harness.buckets()
    let grown = try #require(buckets.first { $0.agent == .claude })
    #expect(grown.calls == 2)
    #expect(grown.turnID == "p1")
    #expect(grown.tokens == UsageTokens(input: 20, cacheRead: 200, output: 40))
    status = await harness.scanner.status()
    #expect(status.scannedFiles == 4)
    let cursor = try #require(try await harness.store.cursor(identity: try harness.identity(".claude/projects/-Users-me-lumi/sess-1.jsonl", source: .claude)))
    #expect(cursor.byteOffset == cursor.fileSize)
    #expect(cursor.state.turnID == "p1")
    #expect(cursor.prefixLength == Int(min(4096, cursor.fileSize)))
    #expect(cursor.prefixHash.count == 64)
}

@Test func usageScannerFollowsAMovedFileAndStartsOverOnARewrittenOne() async throws {
    let harness = try Harness()
    let original = ".codex/sessions/2026/09/05/rollout-c1.jsonl"
    let archived = ".codex/archived_sessions/rollout-c1.jsonl"
    let lines = codexLines(sessionID: "c1", cwd: "/Users/me/codex", timestamp: "2026-09-05T10:05:00.000Z")
    try harness.write(original, lines)
    await harness.scanner.scanOnce()
    let identity = try harness.identity(original, source: .codex)
    #expect(try await harness.buckets().count == 1)
    #expect(await harness.scanner.status().scannedFiles == 1)

    // Codex `archive` moves the rollout: same inode, new path — the cursor follows, nothing is re-read.
    try FileManager.default.createDirectory(at: harness.home.appendingPathComponent(".codex/archived_sessions"), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: harness.home.appendingPathComponent(original), to: harness.home.appendingPathComponent(archived))
    await harness.scanner.scanOnce()
    #expect(await harness.scanner.status().scannedFiles == 1)
    #expect(try harness.identity(archived, source: .codex) == identity)
    let moved = try #require(try await harness.store.cursor(identity: identity))
    #expect(moved.path == harness.home.appendingPathComponent(archived).path)
    #expect(moved.byteOffset == moved.fileSize)
    #expect(try await harness.buckets().count == 1)

    // Rewritten in place with other content of the same length: the leading
    // bytes changed, so the read starts over with fresh state and the new
    // session lands in its own bucket — the old one is history, untouched.
    // (A different timestamp too: an identical call at the identical instant
    // would rightly be the same dedupe key.)
    let rewritten = lines.map { $0.replacingOccurrences(of: "c1", with: "c2").replacingOccurrences(of: "10:05:00", with: "10:06:00") }
    try Data((rewritten.joined(separator: "\n") + "\n").utf8).write(to: harness.home.appendingPathComponent(archived))
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: harness.home.appendingPathComponent(archived).path)
    await harness.scanner.scanOnce()
    let buckets = try await harness.buckets()
    #expect(Set(buckets.map(\.sessionID)) == ["c1", "c2"])
    #expect(buckets.allSatisfy { $0.calls == 1 && $0.turnID == "turn-\($0.sessionID)" })
    #expect(await harness.scanner.status().scannedFiles == 1)
}

@Test func usageScannerRecountsNothingWhenAFileIsRewritten() async throws {
    let harness = try Harness()
    let relative = ".codex/sessions/2026/09/05/rollout-c1.jsonl"
    try harness.write(relative, codexLines(sessionID: "c1", cwd: "/Users/me/codex", timestamp: "2026-09-05T10:05:00.000Z"))
    await harness.scanner.scanOnce()
    #expect(try await harness.buckets().count == 1)
    // Rewritten shorter with the same lines: the reader restarts at 0, the
    // dedupe keys refuse the repeats.
    try harness.write(relative, Array(codexLines(sessionID: "c1", cwd: "/Users/me/codex", timestamp: "2026-09-05T10:05:00.000Z").prefix(3)))
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: harness.home.appendingPathComponent(relative).path)
    await harness.scanner.scanOnce()
    let buckets = try await harness.buckets()
    #expect(buckets.count == 1)
    #expect(buckets[0].calls == 1)
}

@Test func serviceAnswersUsageReportsAndValidatesTheRange() async throws {
    let harness = try Harness()
    try harness.write(".claude/projects/-Users-me-lumi/sess-1.jsonl", [
        claudeUser(promptID: "p1", timestamp: "2026-09-05T10:00:00.000Z"),
        claudeAssistant(messageID: "m1", requestID: "r1", uuid: "a1", timestamp: "2026-09-05T10:00:01.000Z"),
        claudeAssistant(messageID: "m2", requestID: "r2", uuid: "a2", model: "<synthetic>", timestamp: "2026-09-06T10:00:01.000Z"),
    ])
    await harness.scanner.scanOnce()
    let prices = ModelPriceRefresher(
        cachePath: harness.home.appendingPathComponent("models-dev.json").path,
        fetchEnabled: false
    )
    let repository = InMemorySessionRepository()
    let service = DaemonService(repository: repository, socketPath: "/tmp/lumi.sock", executableHash: "test-hash")
    await service.attachUsage(store: harness.store, scanner: harness.scanner, prices: prices)

    let ok = await service.handle(TransportEnvelope(payload: IPCRequest(
        operation: .usageReport,
        since: UsageDay(year: 2026, month: 9, day: 1),
        until: UsageDay(year: 2026, month: 9, day: 30)
    )))
    #expect(ok.payload.status == .ok)
    let report = try #require(ok.payload.usage)
    #expect(report.totals.calls == 2)
    #expect(report.totals.sessions == 1)
    #expect(report.totals.turns == 1)
    #expect(report.totals.unpricedTokens == 130)
    let fable = try #require(ModelPriceTable.builtin.price(for: "claude-fable-5", agent: .claude))
    #expect(report.totals.costUSD == UsageCost.usd(tokens: UsageTokens(input: 10, cacheRead: 100, output: 20), price: fable))
    #expect(report.byModel.map(\.model) == ["claude-fable-5", "<synthetic>"])
    #expect(report.byModel[1].costUSD == nil)
    #expect(report.byProject.map(\.workspace) == ["/Users/me/lumi"])
    #expect(report.pricing.source == .builtin)
    #expect(report.pricing.modelCount == ModelPricingSnapshot.modelCount)
    #expect(report.scan.scannedFiles == 1)

    // Only the fifth is in range.
    let day = await service.handle(TransportEnvelope(payload: IPCRequest(
        operation: .usageReport, since: UsageDay(year: 2026, month: 9, day: 5), until: UsageDay(year: 2026, month: 9, day: 5)
    )))
    #expect(day.payload.usage?.totals.calls == 1)
    #expect(day.payload.usage?.totals.unpricedTokens == 0)

    let missing = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .usageReport)))
    #expect(missing.payload.failure?.code == "missing_usage_range")
    let backwards = await service.handle(TransportEnvelope(payload: IPCRequest(
        operation: .usageReport, since: UsageDay(year: 2026, month: 9, day: 5), until: UsageDay(year: 2026, month: 9, day: 4)
    )))
    #expect(backwards.payload.failure?.code == "invalid_usage_range")
    let tooLong = await service.handle(TransportEnvelope(payload: IPCRequest(
        operation: .usageReport, since: UsageDay(year: 2025, month: 1, day: 1), until: UsageDay(year: 2026, month: 9, day: 5)
    )))
    #expect(tooLong.payload.failure?.code == "invalid_usage_range")

    let bare = DaemonService(repository: repository, socketPath: "/tmp/lumi.sock", executableHash: "test-hash")
    let unavailable = await bare.handle(TransportEnvelope(payload: IPCRequest(
        operation: .usageReport, since: UsageDay(year: 2026, month: 9, day: 5), until: UsageDay(year: 2026, month: 9, day: 5)
    )))
    #expect(unavailable.payload.failure?.code == "usage_unavailable")
}

@Test func priceRefresherPrefersTheCacheAndKeepsTheBuiltinOtherwise() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("prices-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("models-dev.json").path

    let empty = ModelPriceRefresher(cachePath: path, fetchEnabled: false)
    await empty.loadCache()
    var current = await empty.current()
    #expect(current.status.source == .builtin)
    #expect(current.status.fetchedAt == nil)
    #expect(current.table.modelCount == ModelPricingSnapshot.modelCount)

    try Data(#"{"anthropic":{"models":{"claude-test":{"cost":{"input":1,"output":2}}}}}"#.utf8).write(to: URL(fileURLWithPath: path))
    let cached = ModelPriceRefresher(cachePath: path, fetchEnabled: false)
    await cached.loadCache()
    current = await cached.current()
    #expect(current.status.source == .fresh)
    #expect(current.table.modelCount == 1)
    #expect(current.table.price(for: "claude-test", agent: .claude)?.output == 2)
    // Fetching disabled: refreshIfStale is a no-op even for a stale cache.
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 24 * 3_600)], ofItemAtPath: path)
    let stale = ModelPriceRefresher(cachePath: path, fetchEnabled: false)
    await stale.loadCache()
    await stale.refreshIfStale()
    current = await stale.current()
    #expect(current.status.source == .cached)
    #expect(current.table.modelCount == 1)

    // An unreadable cache leaves the built-in table in force.
    try Data("nope".utf8).write(to: URL(fileURLWithPath: path))
    let broken = ModelPriceRefresher(cachePath: path, fetchEnabled: false)
    await broken.loadCache()
    #expect(await broken.current().status.source == .builtin)
}

@Test func usageScannerStoresEachCallUnderItsLongContextBand() async throws {
    let harness = try Harness()
    try harness.write(".codex/sessions/2026/09/05/rollout-big.jsonl", [
        #"{"timestamp":"2026-09-05T10:05:00.000Z","type":"session_meta","payload":{"id":"big","cwd":"/Users/me/codex","source":"vscode"}}"#,
        #"{"timestamp":"2026-09-05T10:05:00.000Z","type":"turn_context","payload":{"turn_id":"turn-big","cwd":"/Users/me/codex","model":"gpt-5.6-sol"}}"#,
        // 100K of context: base band.
        #"{"timestamp":"2026-09-05T10:05:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100000,"cached_input_tokens":90000,"output_tokens":50,"reasoning_output_tokens":10}}}}"#,
        // 300K of context (input_tokens is inclusive of the cached part): above the 272K band.
        #"{"timestamp":"2026-09-05T10:05:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":300000,"cached_input_tokens":280000,"output_tokens":60,"reasoning_output_tokens":10}}}}"#,
    ])
    await harness.scanner.scanOnce()
    let buckets = try await harness.buckets()
    #expect(buckets.map(\.tier) == [0, 1])
    #expect(buckets.allSatisfy { $0.turnID == "turn-big" && $0.model == "gpt-5.6-sol" && $0.calls == 1 })
    #expect(buckets[1].tokens == UsageTokens(input: 20_000, cacheRead: 280_000, output: 60, reasoning: 10))
}
