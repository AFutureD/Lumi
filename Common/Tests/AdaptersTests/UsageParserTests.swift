import Core
import Transport
import Foundation
import Testing
@testable import Adapters

// MARK: - Fixtures (shapes copied from real Claude Code 2.1 / Codex 0.147 files)

private func claudeUser(
    text: String,
    promptID: String = "prompt-1",
    uuid: String = "u-1",
    human: Bool = true,
    sidechain: Bool = false,
    timestamp: String = "2026-08-26T21:16:47.994Z"
) -> String {
    let origin = human ? #","origin":{"kind":"human"}"# : ""
    let escaped = text.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
    return #"{"parentUuid":null,"isSidechain":\#(sidechain),"promptId":"\#(promptID)","type":"user","message":{"role":"user","content":[{"type":"text","text":"\#(escaped)"}]},"uuid":"\#(uuid)","timestamp":"\#(timestamp)"\#(origin),"cwd":"/Users/me/Developer/lumi","sessionId":"sess-1","version":"2.1.246"}"#
}

private func claudeAssistant(
    messageID: String = "msg_1",
    requestID: String = "req_1",
    uuid: String = "a-1",
    model: String = "claude-fable-5",
    usage: String = #"{"input_tokens":2,"cache_creation_input_tokens":21292,"cache_read_input_tokens":37690,"output_tokens":496,"output_tokens_details":{"thinking_tokens":146},"cache_creation":{"ephemeral_1h_input_tokens":21292,"ephemeral_5m_input_tokens":0}}"#,
    sidechain: Bool = false,
    timestamp: String = "2026-08-26T21:16:56.180Z",
    content: String = #"[{"type":"text","text":"Hi"}]"#
) -> String {
    #"{"parentUuid":"u-1","isSidechain":\#(sidechain),"requestId":"\#(requestID)","type":"assistant","uuid":"\#(uuid)","timestamp":"\#(timestamp)","cwd":"/Users/me/Developer/lumi","sessionId":"sess-1","version":"2.1.246","message":{"model":"\#(model)","id":"\#(messageID)","type":"message","role":"assistant","stop_reason":"tool_use","content":\#(content),"usage":\#(usage)}}"#
}

private func codexMeta(id: String = "019fdb8f-b265", cwd: String = "/Users/me/Documents/Codex/qit", subagent: Bool = false, timestamp: String = "2026-08-07T09:32:17.827Z") -> String {
    let source = subagent
        ? #"{"subagent":{"thread_spawn":{"parent_thread_id":"parent-1","depth":1}}}"#
        : #""vscode""#
    return #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"\#(id)","timestamp":"\#(timestamp)","cwd":"\#(cwd)","originator":"Codex Desktop","cli_version":"0.147.0","source":\#(source),"model_provider":"openai"}}"#
}

private func codexTurnContext(turnID: String, model: String = "gpt-5.6-sol", cwd: String = "/Users/me/Documents/Codex/qit", timestamp: String = "2026-08-07T09:32:18.752Z") -> String {
    #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"turn_id":"\#(turnID)","cwd":"\#(cwd)","model":"\#(model)","effort":"high"}}"#
}

/// `input` omitted → no `last_token_usage`; `total` omitted → no `total_token_usage`.
private func codexTokenCount(
    input: Int? = nil, cached: Int = 0, cacheWrite: Int = 0, output: Int = 0, reasoning: Int = 0,
    total: (input: Int, cached: Int, output: Int, reasoning: Int)? = nil,
    timestamp: String
) -> String {
    var info: [String] = []
    if let total {
        info.append(#""total_token_usage":{"input_tokens":\#(total.input),"cached_input_tokens":\#(total.cached),"cache_write_input_tokens":0,"output_tokens":\#(total.output),"reasoning_output_tokens":\#(total.reasoning),"total_tokens":\#(total.input + total.output)}"#)
    }
    if let input {
        info.append(#""last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":\#(cacheWrite),"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(input + output)}"#)
    }
    info.append(#""model_context_window":258400"#)
    return #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{\#(info.joined(separator: ","))},"rate_limits":null}}"#
}

private func parseAll(_ lines: [String], source: UsageSource) throws -> ([UsageRecord], UsageScanState) {
    var state = UsageScanState()
    var records: [UsageRecord] = []
    for line in lines {
        records.append(contentsOf: try UsageTranscriptParser.parse(line: Data(line.utf8), source: source, state: &state))
    }
    return (records, state)
}

private func temporaryFile(_ lines: [String]) throws -> String {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("usage-parser-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("t.jsonl").path
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: path))
    return path
}

// MARK: - Claude

@Test func claudeContentBlocksCountOnceAndALargerLaterCopyTopsTheOutputUp() throws {
    let streaming = #"{"input_tokens":2,"cache_creation_input_tokens":21292,"cache_read_input_tokens":37690,"output_tokens":3,"output_tokens_details":{"thinking_tokens":1},"cache_creation":{"ephemeral_1h_input_tokens":21292,"ephemeral_5m_input_tokens":0}}"#
    let (records, state) = try parseAll([
        claudeUser(text: "Add the Usage page", promptID: "prompt-A"),
        // The thinking block lands while the message still streams: a partial output count.
        claudeAssistant(uuid: "a-1", usage: streaming, content: #"[{"type":"thinking","thinking":"…"}]"#),
        claudeAssistant(uuid: "a-2", content: #"[{"type":"text","text":"On it"}]"#),
        claudeAssistant(uuid: "a-3", content: #"[{"type":"tool_use","id":"toolu_1","name":"Read","input":{}}]"#),
    ], source: .claude)
    #expect(records.count == 2)
    #expect(records[0].dedupeKey == "claude:msg_1:req_1")
    #expect(records[0].isCall)
    #expect(records[0].tokens.output == 3)
    // The final copy carries 496 output tokens: the difference is a top-up, not another call.
    #expect(records[1].dedupeKey == "claude:msg_1:req_1:more:59480")
    #expect(!records[1].isCall)
    #expect(records[1].tokens == UsageTokens(input: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, output: 493, reasoning: 145))
    #expect(records[1].reportedCostUSD == nil)
    // The top-up still names the whole call's context, so it lands in the same band.
    #expect(records[1].context == 2 + 37_690 + 21_292)
    #expect(records[0].context == records[1].context)
    #expect(state.claudeLastKey == "claude:msg_1:req_1")
    #expect(state.claudeLastTokens?.output == 496)
    #expect(state.turnID == "prompt-A")
    let record = records[0]
    #expect(record.agent == .claude)
    #expect(record.sessionID == "sess-1")
    #expect(record.turnID == "prompt-A")
    #expect(record.model == "claude-fable-5")
    #expect(record.workspace == "/Users/me/Developer/lumi")
    #expect(record.occurredAt == AdapterDates.parse("2026-08-26T21:16:56.180Z"))
    #expect(record.tokens == UsageTokens(input: 2, cacheRead: 37_690, cacheWrite5m: 0, cacheWrite1h: 21_292, output: 3, reasoning: 1))
}

@Test func claudeInjectedAndNonHumanPromptsDoNotOpenTurns() throws {
    let (records, state) = try parseAll([
        claudeUser(text: "First", promptID: "prompt-A", uuid: "u-1"),
        claudeAssistant(messageID: "msg_1", uuid: "a-1"),
        // An injected task notification carries a fresh promptId and no human
        // origin: it stays in the Turn it resumed.
        claudeUser(text: "<task-notification>done</task-notification>", promptID: "prompt-B", uuid: "u-2", human: false),
        claudeAssistant(messageID: "msg_2", requestID: "req_2", uuid: "a-2"),
        // An injected resume without a human origin.
        claudeUser(text: "Continue", promptID: "prompt-C", uuid: "u-3", human: false),
        claudeAssistant(messageID: "msg_3", requestID: "req_3", uuid: "a-3"),
        // The interrupt marker closes, never opens.
        claudeUser(text: "[Request interrupted by user]", promptID: "prompt-D", uuid: "u-4"),
        claudeUser(text: "Second", promptID: "prompt-E", uuid: "u-5"),
        claudeAssistant(messageID: "msg_4", requestID: "req_4", uuid: "a-4"),
    ], source: .claude)
    #expect(records.map(\.turnID) == ["prompt-A", "prompt-A", "prompt-A", "prompt-E"])
    #expect(state.turnID == "prompt-E")
}

@Test func claudeSidechainRecordsBelongToTheSubagentAndKeepTheParentSession() throws {
    let (records, _) = try parseAll([
        claudeUser(text: "Explore the repo", promptID: "prompt-S", uuid: "s-u-1", human: false, sidechain: true),
        claudeAssistant(messageID: "msg_s", requestID: "req_s", uuid: "s-a-1", usage: #"{"input_tokens":2,"cache_creation_input_tokens":42940,"cache_read_input_tokens":0,"output_tokens":5}"#, sidechain: true),
    ], source: .claude)
    #expect(records.count == 1)
    #expect(records[0].agent == .claudeSubagent)
    #expect(records[0].sessionID == "sess-1")
    #expect(records[0].turnID == "prompt-S")
    // No TTL split reported: the whole write is the 5-minute tier.
    #expect(records[0].tokens == UsageTokens(input: 2, cacheRead: 0, cacheWrite5m: 42_940, cacheWrite1h: 0, output: 5, reasoning: 0))
}

@Test func claudeRecordsWithoutUsageOrTimestampAreSkipped() throws {
    let noUsage = #"{"type":"assistant","uuid":"x","timestamp":"2026-08-26T21:16:56.180Z","sessionId":"sess-1","message":{"model":"claude-fable-5","id":"msg_x","role":"assistant","content":[]}}"#
    let noTimestamp = #"{"type":"assistant","uuid":"y","sessionId":"sess-1","message":{"model":"claude-fable-5","id":"msg_y","role":"assistant","content":[],"usage":{"input_tokens":1,"output_tokens":1}}}"#
    var state = UsageScanState()
    #expect(try UsageTranscriptParser.parse(line: Data(noUsage.utf8), source: .claude, state: &state).isEmpty)
    // Inherits the newest timestamp seen in the file once one exists.
    let inherited = try UsageTranscriptParser.parse(line: Data(noTimestamp.utf8), source: .claude, state: &state)
    #expect(inherited.first?.occurredAt == AdapterDates.parse("2026-08-26T21:16:56.180Z"))
    var fresh = UsageScanState()
    #expect(try UsageTranscriptParser.parse(line: Data(noTimestamp.utf8), source: .claude, state: &fresh).isEmpty)
    #expect(throws: UsageParseError.malformedJSON) {
        try UsageTranscriptParser.parse(line: Data("{not json".utf8), source: .claude, state: &fresh)
    }
    // An all-zero usage block (Claude's `<synthetic>` placeholders) is not a call…
    let synthetic = claudeAssistant(
        messageID: "msg_s", requestID: "req_s", uuid: "s-1", model: "<synthetic>",
        usage: #"{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}"#
    )
    #expect(try UsageTranscriptParser.parse(line: Data(synthetic.utf8), source: .claude, state: &state).isEmpty)
    // …and leaves the content-block state alone, so the next real message counts in full.
    let real = try UsageTranscriptParser.parse(line: Data(claudeAssistant(messageID: "msg_r", requestID: "req_r").utf8), source: .claude, state: &state)
    #expect(real.count == 1 && real[0].tokens.output == 496)
}

// MARK: - Codex

@Test func codexDeltasCarryTheTurnModelAndCwdAndSkipRepeatedEvents() throws {
    let (records, state) = try parseAll([
        codexMeta(),
        codexTurnContext(turnID: "turn-1"),
        codexTokenCount(input: 20_072, cached: 11_008, output: 142, timestamp: "2026-08-07T09:32:24.335Z"),
        // Codex re-emits an unchanged token_count on a stream boundary.
        codexTokenCount(input: 20_072, cached: 11_008, output: 142, timestamp: "2026-08-07T09:32:24.400Z"),
        codexTokenCount(input: 21_929, cached: 19_200, output: 488, reasoning: 225, timestamp: "2026-08-07T09:32:35.957Z"),
        // A replayed ancestor meta (fork) must not rename the session.
        codexMeta(id: "ancestor", cwd: "/elsewhere", timestamp: "2026-08-07T09:32:36.000Z"),
        codexTurnContext(turnID: "turn-2", model: "gpt-5.5", cwd: "/Users/me/Documents/Codex/qit/sub", timestamp: "2026-08-07T09:40:00.000Z"),
        codexTokenCount(input: 1_000, cached: 200, cacheWrite: 100, output: 50, reasoning: 80, timestamp: "2026-08-07T09:40:05.000Z"),
    ], source: .codex)
    #expect(records.count == 3)
    #expect(records.map(\.turnID) == ["turn-1", "turn-1", "turn-2"])
    #expect(records.map(\.model) == ["gpt-5.6-sol", "gpt-5.6-sol", "gpt-5.5"])
    #expect(records.map(\.workspace) == ["/Users/me/Documents/Codex/qit", "/Users/me/Documents/Codex/qit", "/Users/me/Documents/Codex/qit/sub"])
    #expect(records.allSatisfy { $0.sessionID == "019fdb8f-b265" && $0.agent == .codex })
    // input_tokens is inclusive of the cached part; reasoning is capped by output.
    #expect(records[0].tokens == UsageTokens(input: 9_064, cacheRead: 11_008, cacheWrite5m: 0, cacheWrite1h: 0, output: 142, reasoning: 0))
    #expect(records[2].tokens == UsageTokens(input: 700, cacheRead: 200, cacheWrite5m: 100, cacheWrite1h: 0, output: 50, reasoning: 50))
    #expect(records[0].dedupeKey.hasPrefix("codex:2026-08-07T09:32:24.335Z:"))
    #expect(Set(records.map(\.dedupeKey)).count == 3)
    #expect(state.codexSessionID == "019fdb8f-b265")
    #expect(state.codexLastSignature != nil)
    // The summed deltas are what the session's final total would report.
    let total = records.reduce(into: UsageTokens.zero) { $0.add($1.tokens) }
    #expect(total.input + total.cacheRead + total.cacheWrite5m == 20_072 + 21_929 + 1_000)
}

@Test func codexCallsAheadOfAnyContextWaitForItThenTakeItsTurnAndModel() throws {
    // The context arrives later: the held call is completed by it.
    let (completed, state) = try parseAll([
        codexMeta(id: "child", subagent: true),
        codexTokenCount(input: 100, output: 10, timestamp: "2026-08-07T09:32:20.000Z"),
        codexTokenCount(timestamp: "2026-08-07T09:32:21.000Z"),   // nothing to count
        codexTurnContext(turnID: "turn-1", model: "gpt-5.5", timestamp: "2026-08-07T09:32:22.000Z"),
        codexTokenCount(input: 50, output: 5, timestamp: "2026-08-07T09:32:23.000Z"),
    ], source: .codex)
    #expect(completed.count == 2)
    #expect(completed[0].agent == .codexSubagent)
    #expect(completed[0].tokens.total == 110)
    #expect(completed[0].turnID == "turn-1")
    #expect(completed[0].model == "gpt-5.5")
    #expect(completed[0].occurredAt == AdapterDates.parse("2026-08-07T09:32:20.000Z"))
    #expect(completed[1].tokens.total == 55)
    #expect(state.codexPending == nil)

    // No context ever: the next call releases the held one as it is; the
    // last one stays held in the state for the next read.
    let (released, waiting) = try parseAll([
        codexMeta(id: "bare"),
        codexTokenCount(input: 100, output: 10, timestamp: "2026-08-07T09:32:20.000Z"),
        codexTokenCount(input: 20, output: 2, timestamp: "2026-08-07T09:32:21.000Z"),
    ], source: .codex)
    #expect(released.count == 1)
    #expect(released[0].model == "")
    #expect(released[0].turnID == "")
    #expect(released[0].tokens.total == 110)
    #expect(waiting.codexPending?.tokens.total == 22)
}

@Test func codexForkedRolloutsSkipTheCopiedHistoryUntilTheChildsOwnWork() throws {
    // A spawned subagent: child meta, the parent's meta and history copied
    // in one burst (same instant), then the child's real calls seconds later.
    let (records, state) = try parseAll([
        codexMeta(id: "child", subagent: true, timestamp: "2026-08-16T12:57:35.366Z"),
        codexMeta(id: "parent", timestamp: "2026-08-16T12:57:35.366Z"),
        codexTurnContext(turnID: "parent-turn", timestamp: "2026-08-16T12:57:35.366Z"),
        codexTokenCount(input: 25_633, output: 100, total: (25_633, 0, 100, 0), timestamp: "2026-08-16T12:57:35.366Z"),
        codexTokenCount(input: 27_636, output: 100, total: (53_269, 0, 200, 0), timestamp: "2026-08-16T12:57:35.367Z"),
        codexMeta(id: "parent", timestamp: "2026-08-16T12:57:35.367Z"),   // a replayed ancestor meta
        codexTokenCount(input: 30_000, output: 100, total: (83_269, 0, 300, 0), timestamp: "2026-08-16T12:57:35.368Z"),
        codexTurnContext(turnID: "child-turn", timestamp: "2026-08-16T12:57:35.390Z"),
        // 15 s later: the child's own first call.
        codexTokenCount(input: 40_775, output: 50, total: (124_044, 0, 350, 0), timestamp: "2026-08-16T12:57:51.504Z"),
        codexTokenCount(input: 42_060, output: 60, total: (166_104, 0, 410, 0), timestamp: "2026-08-16T12:57:55.981Z"),
    ], source: .codex)
    #expect(records.map(\.tokens.input) == [40_775, 42_060])
    #expect(records.allSatisfy { $0.turnID == "child-turn" && $0.agent == .codexSubagent && $0.sessionID == "child" })
    #expect(!state.codexReplaying)
    #expect(state.codexResets == 0)

    // The explicit boundary: the child's own meta repeated ends the copy at once.
    let (explicit, _) = try parseAll([
        codexMeta(id: "child", timestamp: "2026-08-16T12:57:35.366Z").replacingOccurrences(of: #""source":"vscode""#, with: #""source":"vscode","forked_from_id":"parent""#),
        codexMeta(id: "parent", timestamp: "2026-08-16T12:57:35.366Z"),
        codexTurnContext(turnID: "parent-turn", timestamp: "2026-08-16T12:57:35.366Z"),
        codexTokenCount(input: 25_633, output: 100, total: (25_633, 0, 100, 0), timestamp: "2026-08-16T12:57:35.366Z"),
        codexMeta(id: "child", timestamp: "2026-08-16T12:57:35.367Z"),
        codexTokenCount(input: 500, output: 5, total: (26_133, 0, 105, 0), timestamp: "2026-08-16T12:57:35.368Z"),
    ], source: .codex)
    #expect(explicit.map(\.tokens.input) == [500])

    // Not a fork: nothing is skipped, however fast the calls come.
    let (plain, _) = try parseAll([
        codexMeta(id: "plain", timestamp: "2026-08-16T12:57:35.366Z"),
        codexTurnContext(turnID: "t", timestamp: "2026-08-16T12:57:35.366Z"),
        codexTokenCount(input: 100, output: 1, total: (100, 0, 1, 0), timestamp: "2026-08-16T12:57:35.366Z"),
        codexTokenCount(input: 200, output: 1, total: (300, 0, 2, 0), timestamp: "2026-08-16T12:57:35.367Z"),
    ], source: .codex)
    #expect(plain.count == 2)
}

@Test func codexCumulativeTotalsDetectRepeatsResetsAndLastLessEvents() throws {
    let (records, state) = try parseAll([
        codexMeta(),
        codexTurnContext(turnID: "turn-1"),
        codexTokenCount(input: 100, cached: 40, output: 10, total: (100, 40, 10, 0), timestamp: "2026-08-07T09:32:20.000Z"),
        // Same total again: a re-emission, not a call.
        codexTokenCount(input: 100, cached: 40, output: 10, total: (100, 40, 10, 0), timestamp: "2026-08-07T09:32:21.000Z"),
        // Identical per-call figures but the total moved: a second, real call.
        codexTokenCount(input: 100, cached: 40, output: 10, total: (200, 80, 20, 0), timestamp: "2026-08-07T09:32:22.000Z"),
        // No per-call figure: the difference from the last total.
        codexTokenCount(total: (230, 90, 25, 2), timestamp: "2026-08-07T09:32:23.000Z"),
        // Counters went backwards (a reset) with a per-call figure: counted, baseline rebuilt.
        codexTokenCount(input: 5, output: 1, total: (5, 0, 1, 0), timestamp: "2026-08-07T09:32:24.000Z"),
        // Reset without a per-call figure: nothing attributable.
        codexTokenCount(total: (3, 0, 0, 0), timestamp: "2026-08-07T09:32:25.000Z"),
    ], source: .codex)
    #expect(records.count == 4)
    #expect(records[0].tokens == UsageTokens(input: 60, cacheRead: 40, output: 10))
    #expect(records[1].tokens == UsageTokens(input: 60, cacheRead: 40, output: 10))
    #expect(records[0].dedupeKey != records[1].dedupeKey)
    #expect(records[2].tokens == UsageTokens(input: 20, cacheRead: 10, output: 5, reasoning: 2))
    #expect(records[3].tokens == UsageTokens(input: 5, output: 1))
    #expect(state.codexResets == 2)
    #expect(state.codexCumulative == UsageTokens(input: 3))
}

@Test func claudeKeepsReportedCostsAndSplitsAdvisorIterations() throws {
    let usage = #"{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":0,"output_tokens":20,"iterations":[{"type":"message","input_tokens":10,"output_tokens":20},{"type":"advisor_message","model":"claude-opus-5","input_tokens":300,"output_tokens":7,"cache_read_input_tokens":50,"cache_creation_input_tokens":4}]}"#
    var line = claudeAssistant(usage: usage)
    line = line.replacingOccurrences(of: #""type":"assistant","#, with: #""type":"assistant","costUSD":0.0123,"#)
    let (records, _) = try parseAll([claudeUser(text: "Go"), line], source: .claude)
    #expect(records.count == 2)
    #expect(records[0].reportedCostUSD == 0.0123)
    #expect(records[0].model == "claude-fable-5")
    #expect(records[0].dedupeKey == "claude:msg_1:req_1")
    #expect(records[1].model == "claude-opus-5")
    #expect(records[1].tokens == UsageTokens(input: 300, cacheRead: 50, cacheWrite5m: 4, output: 7))
    #expect(records[1].dedupeKey == "claude:msg_1:req_1:advisor:1")
    #expect(records[1].reportedCostUSD == nil)
    #expect(records[1].turnID == records[0].turnID)
}

@Test func impossibleCountersAndCostsRejectTheLine() throws {
    var state = UsageScanState()
    func claudeWith(_ usage: String, extra: String = "") throws -> [UsageRecord] {
        var line = claudeAssistant(usage: usage)
        if !extra.isEmpty { line = line.replacingOccurrences(of: #""type":"assistant","#, with: #""type":"assistant",\#(extra),"#) }
        return try UsageTranscriptParser.parse(line: Data(line.utf8), source: .claude, state: &state)
    }
    _ = try UsageTranscriptParser.parse(line: Data(claudeUser(text: "Go").utf8), source: .claude, state: &state)
    #expect(throws: UsageParseError.invalidCounter("input_tokens")) { try claudeWith(#"{"input_tokens":-1,"output_tokens":1}"#) }
    #expect(throws: UsageParseError.invalidCounter("output_tokens")) { try claudeWith(#"{"input_tokens":1,"output_tokens":true}"#) }
    #expect(throws: UsageParseError.invalidCounter("cache_read_input_tokens")) { try claudeWith(#"{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":1.5}"#) }
    #expect(throws: UsageParseError.invalidCounter("ephemeral_1h_input_tokens")) { try claudeWith(#"{"input_tokens":1,"output_tokens":1,"cache_creation":{"ephemeral_1h_input_tokens":"9"}}"#) }
    #expect(throws: UsageParseError.invalidCost) { try claudeWith(#"{"input_tokens":1,"output_tokens":1}"#, extra: #""costUSD":"abc""#) }
    #expect(throws: UsageParseError.invalidCost) { try claudeWith(#"{"input_tokens":1,"output_tokens":1}"#, extra: #""costUSD":-2"#) }
    // A null counter is simply absent.
    #expect(try claudeWith(#"{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":null}"#).count == 1)

    var codex = UsageScanState()
    _ = try UsageTranscriptParser.parse(line: Data(codexMeta().utf8), source: .codex, state: &codex)
    let negative = #"{"timestamp":"2026-08-07T09:32:24.335Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":-3,"output_tokens":1}}}}"#
    #expect(throws: UsageParseError.invalidCounter("cached_input_tokens")) {
        try UsageTranscriptParser.parse(line: Data(negative.utf8), source: .codex, state: &codex)
    }
}

// MARK: - Reader

@Test func fileReaderResumesFromTheCursorAndRestartsOnRewrite() throws {
    let path = try temporaryFile([
        claudeUser(text: "First", promptID: "prompt-A"),
        claudeAssistant(messageID: "msg_1", uuid: "a-1", content: #"[{"type":"thinking","thinking":"…"}]"#),
        claudeAssistant(messageID: "msg_1", uuid: "a-2"),
        #"{"usage": broken"#,
    ])
    let first = try UsageFileReader.read(path: path, source: .claude, fromOffset: 0, state: UsageScanState())
    #expect(first.records.count == 1)
    #expect(first.lines == 4)
    #expect(first.rejectedLines == 1)
    #expect(first.byteOffset == first.fileSize)
    #expect(first.state.turnID == "prompt-A")

    // Append: the next read continues with the carried turn.
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((claudeAssistant(messageID: "msg_2", requestID: "req_2", uuid: "a-3") + "\n").utf8))
    try handle.close()
    let second = try UsageFileReader.read(path: path, source: .claude, fromOffset: first.byteOffset, state: first.state)
    #expect(second.records.count == 1)
    #expect(second.records[0].turnID == "prompt-A")
    #expect(second.records[0].dedupeKey == "claude:msg_2:req_2")
    #expect(second.lines == 1)

    // Rewritten shorter: restart from zero with fresh state.
    try Data((claudeAssistant(messageID: "msg_9", requestID: "req_9", uuid: "a-9") + "\n").utf8).write(to: URL(fileURLWithPath: path))
    let third = try UsageFileReader.read(path: path, source: .claude, fromOffset: second.byteOffset, state: second.state)
    #expect(third.records.count == 1)
    #expect(third.records[0].turnID == "")
    #expect(third.byteOffset == third.fileSize)

    // A partial trailing line (no newline yet) is left for the next read.
    let partial = try temporaryFile([claudeUser(text: "x")]) + ""
    let partialHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: partial))
    try partialHandle.seekToEnd()
    try partialHandle.write(contentsOf: Data(#"{"type":"assistant""#.utf8))
    try partialHandle.close()
    let read = try UsageFileReader.read(path: partial, source: .claude, fromOffset: 0, state: UsageScanState())
    #expect(read.byteOffset < read.fileSize)
    #expect(read.lines == 1)
}

@Test func fileReaderReleasesACallStillWaitingForContextAtTheEndOfTheRead() throws {
    let path = try temporaryFile([
        codexMeta(id: "bare"),
        codexTokenCount(input: 100, output: 10, timestamp: "2026-08-07T09:32:20.000Z"),
    ])
    let read = try UsageFileReader.read(path: path, source: .codex, fromOffset: 0, state: UsageScanState())
    #expect(read.records.count == 1)
    #expect(read.records[0].model == "")
    #expect(read.records[0].tokens.total == 110)
    #expect(read.state.codexPending == nil)
    // The context in a later append no longer reaches it, but nothing is lost.
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((codexTurnContext(turnID: "turn-1") + "\n").utf8))
    try handle.close()
    let next = try UsageFileReader.read(path: path, source: .codex, fromOffset: read.byteOffset, state: read.state)
    #expect(next.records.isEmpty)
    #expect(next.state.turnID == "turn-1")
}

@Test func lineGateOnlyAdmitsLinesThatCanChangeTheResult() {
    #expect(UsageTranscriptParser.mightMatter(Data(claudeAssistant().utf8), source: .claude))
    #expect(UsageTranscriptParser.mightMatter(Data(claudeUser(text: "x").utf8), source: .claude))
    #expect(!UsageTranscriptParser.mightMatter(Data(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#.utf8), source: .claude))
    #expect(UsageTranscriptParser.mightMatter(Data(codexTokenCount(input: 1, cached: 0, output: 1, reasoning: 0, timestamp: "t").utf8), source: .codex))
    #expect(UsageTranscriptParser.mightMatter(Data(codexTurnContext(turnID: "t").utf8), source: .codex))
    #expect(UsageTranscriptParser.mightMatter(Data(codexMeta().utf8), source: .codex))
    #expect(!UsageTranscriptParser.mightMatter(Data(#"{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"assistant"}}"#.utf8), source: .codex))
}
