import Core
import Transport
import Foundation

/// Reduces one transcript / rollout line to usage records. Pure: everything
/// carried between lines lives in `UsageScanState`. Malformed JSON and
/// impossible counters throw (the reader counts and skips the line); a
/// record that simply carries no usage returns nothing.
public enum UsageTranscriptParser {
    /// Cheap byte gate applied before JSON parsing: transcripts are mostly
    /// tool output, and only a minority of lines can change the result.
    public static func mightMatter(_ line: Data, source: AgentProvider) -> Bool {
        switch source {
        case .claude:
            return line.range(of: Self.claudeUsageNeedle) != nil
                || line.range(of: Self.claudePromptNeedle) != nil
        case .codex:
            return line.range(of: Self.codexTokenCountNeedle) != nil
                || line.range(of: Self.codexTurnContextNeedle) != nil
                || line.range(of: Self.codexSessionMetaNeedle) != nil
        }
    }

    public static func parse(
        line: Data,
        source: AgentProvider,
        state: inout UsageScanState
    ) throws -> [UsageRecord] {
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            throw UsageParseError.malformedJSON
        }
        let records = switch source {
        case .claude: try claude(root, state: &state)
        case .codex: try codex(root, state: &state)
        }
        // No tokens and no bill is not a model call: Claude's `<synthetic>`
        // placeholders carry an all-zero usage block, Codex re-emits
        // zero deltas, an advisor iteration can be empty.
        return records.filter { !$0.isEmpty }
    }

    // MARK: - Claude

    /// Claude Code transcript: `user` records open Turns under the same
    /// content-driven rule as Session ingest (`ClaudeAdapter.opensTurn`),
    /// `assistant` records carry the call's `message.usage`. Every content
    /// block of one message repeats that usage under the same
    /// `message.id` / `requestId` — the dedupe key — but `output_tokens`
    /// grows while the message streams, so a later copy with more tokens
    /// tops the earlier count up. An advisor iteration inside
    /// `usage.iterations` is its own call on its own model.
    private static func claude(_ root: [String: Any], state: inout UsageScanState) throws -> [UsageRecord] {
        let isSidechain = root.bool("isSidechain") == true
        if let timestamp = root.date("timestamp") { state.lastTimestamp = timestamp }
        switch root.string("type") {
        case "user":
            if ClaudeAdapter.opensTurn(root, isSubagentSession: isSidechain) {
                state.turnID = root.string("promptId") ?? root.string("uuid")
            }
            return []
        case "assistant":
            guard let message = root.dictionary("message"),
                  let usage = message.dictionary("usage"),
                  let occurredAt = state.lastTimestamp else { return [] }
            let messageID = message.string("id") ?? root.string("uuid") ?? ""
            let requestID = root.string("requestId") ?? ""
            let key = "claude:\(messageID):\(requestID)"
            let tokens = try claudeTokens(usage)
            let reportedCost = try reportedCost(root["costUSD"])
            var base = UsageRecord(
                agent: isSidechain ? .claudeSubagent : .claude,
                sessionID: root.string("sessionId") ?? "",
                turnID: state.turnID ?? "",
                model: message.string("model") ?? "",
                workspace: root.string("cwd") ?? "",
                occurredAt: occurredAt,
                tokens: tokens,
                dedupeKey: key,
                reportedCostUSD: reportedCost
            )
            if state.claudeLastKey == key, let counted = state.claudeLastTokens {
                // Another content block of the message already counted.
                guard tokens.total > counted.total else { return [] }
                state.claudeLastTokens = tokens
                base.tokens = Self.delta(tokens, from: counted)
                base.dedupeKey = "\(key):more:\(tokens.total)"
                base.reportedCostUSD = nil
                base.isCall = false
                base.context = tokens.context
                return [base]
            }
            state.claudeLastKey = key
            state.claudeLastTokens = tokens
            var records = [base]
            for (index, iteration) in (usage["iterations"] as? [[String: Any]] ?? []).enumerated()
                where iteration.string("type") == "advisor_message" {
                var advisor = base
                advisor.model = iteration.string("model") ?? ""
                advisor.tokens = try claudeTokens(iteration)
                advisor.dedupeKey = "\(key):advisor:\(index)"
                advisor.reportedCostUSD = nil
                records.append(advisor)
            }
            return records
        default:
            return []
        }
    }

    private static func claudeTokens(_ usage: [String: Any]) throws -> UsageTokens {
        let output = try count(usage, "output_tokens") ?? 0
        let cacheCreation = usage.dictionary("cache_creation")
        let write5m = try cacheCreation.flatMap { try count($0, "ephemeral_5m_input_tokens") }
        let write1h = try cacheCreation.flatMap { try count($0, "ephemeral_1h_input_tokens") }
        let writeTotal = try count(usage, "cache_creation_input_tokens") ?? 0
        let thinking = try usage.dictionary("output_tokens_details").flatMap { try count($0, "thinking_tokens") } ?? 0
        return UsageTokens(
            input: try count(usage, "input_tokens") ?? 0,
            cacheRead: try count(usage, "cache_read_input_tokens") ?? 0,
            // The TTL split is authoritative when present; otherwise the
            // whole write is the (cheaper) 5-minute tier.
            cacheWrite5m: write5m ?? (write1h == nil ? writeTotal : 0),
            cacheWrite1h: write1h ?? 0,
            output: output,
            reasoning: min(thinking, output)
        )
    }

    // MARK: - Codex

    /// Codex rollout: the first `session_meta` names the session and cwd
    /// (fork rollouts replay ancestor metas after it — those never replace
    /// the child's identity), `turn_context` carries turn id / model / cwd
    /// forward, and `event_msg/token_count` reports the call. Its
    /// `total_token_usage` is the baseline: a repeated total is a
    /// re-emission, a lower one a reset, and a `last`-less event counts as
    /// the difference. Codex reports `input_tokens` inclusive of the cached
    /// part, so the uncached remainder is derived.
    private static func codex(_ root: [String: Any], state: inout UsageScanState) throws -> [UsageRecord] {
        guard let payload = root.dictionary("payload") else { return [] }
        if let timestamp = root.date("timestamp") { state.lastTimestamp = timestamp }
        switch root.string("type") {
        case "session_meta":
            let id = payload.string("id") ?? payload.string("session_id")
            guard state.codexSessionID == nil else {
                // The child's own meta repeated after the copied history is
                // the explicit end of the copy.
                if state.codexReplaying, id == state.codexSessionID { state.codexReplaying = false }
                return []
            }
            guard let id else { return [] }
            state.codexSessionID = id
            let spawned = payload.dictionary("source")?["subagent"] != nil
            state.codexIsSubagent = spawned
            if let cwd = payload.string("cwd") { state.codexWorkspace = cwd }
            if payload.string("forked_from_id") != nil || spawned {
                state.codexReplaying = true
                state.codexReplayAnchor = root.date("timestamp")
            }
            return []
        case "turn_context":
            if state.codexReplaying, let stamp = root.date("timestamp") { state.codexReplayAnchor = stamp }
            if let turnID = payload.string("turn_id"), !turnID.isEmpty { state.turnID = turnID }
            if let model = payload.string("model"), !model.isEmpty { state.codexModel = model }
            if let cwd = payload.string("cwd") { state.codexWorkspace = cwd }
            // The context this call was waiting for.
            guard var pending = state.codexPending else { return [] }
            state.codexPending = nil
            if pending.turnID.isEmpty { pending.turnID = state.turnID ?? "" }
            if pending.model.isEmpty { pending.model = state.codexModel ?? "" }
            if pending.workspace.isEmpty { pending.workspace = state.codexWorkspace ?? "" }
            return [pending]
        case "event_msg":
            guard payload.string("type") == "token_count",
                  let info = payload.dictionary("info"),
                  let occurredAt = state.lastTimestamp else { return [] }
            let cumulative = try info.dictionary("total_token_usage").map(codexTokens)
            let last = try info.dictionary("last_token_usage").map(codexTokens)
            if state.codexReplaying {
                // Copied history is written in one burst; the child's first
                // real call follows a model round trip. Copied calls keep the
                // cumulative baseline moving so the first real one is not a reset.
                let anchor = state.codexReplayAnchor ?? occurredAt
                if occurredAt.timeIntervalSince(anchor) < Self.forkCopyMaximumGap {
                    state.codexReplayAnchor = occurredAt
                    if let cumulative { state.codexCumulative = cumulative }
                    return []
                }
                state.codexReplaying = false
            }
            let usage: UsageTokens
            if let cumulative {
                // Codex re-emits an unchanged token_count on some stream
                // boundaries: same total, nothing new to count.
                guard cumulative != state.codexCumulative else { return [] }
                let previous = state.codexCumulative
                let reset = previous.map { cumulative.context < $0.context || cumulative.output < $0.output } ?? false
                state.codexCumulative = cumulative
                if let last {
                    usage = last
                } else if !reset {
                    usage = Self.delta(cumulative, from: previous)
                } else {
                    // Counters went backwards and the event carries no
                    // per-call figure: nothing attributable.
                    return []
                }
            } else {
                guard let last else { return [] }
                let signature = Self.signature(last)
                guard signature != state.codexLastSignature else { return [] }
                state.codexLastSignature = signature
                usage = last
            }
            let stamp = root.string("timestamp") ?? String(occurredAt.timeIntervalSince1970)
            let record = UsageRecord(
                agent: state.codexIsSubagent ? .codexSubagent : .codex,
                sessionID: state.codexSessionID ?? "",
                turnID: state.turnID ?? "",
                model: state.codexModel ?? "",
                workspace: state.codexWorkspace ?? "",
                occurredAt: occurredAt,
                tokens: usage,
                dedupeKey: "codex:\(stamp):\(StableHash.fnv1a(Self.signature(usage)))"
            )
            // Ahead of any context line: hold this call for the context, and
            // let a call already held go as it is.
            guard state.turnID != nil, state.codexModel != nil else {
                let released = state.codexPending
                state.codexPending = record
                return released.map { [$0] } ?? []
            }
            return [record]
        default:
            return []
        }
    }

    private static func codexTokens(_ raw: [String: Any]) throws -> UsageTokens {
        let input = try count(raw, "input_tokens") ?? 0
        let cached = try count(raw, "cached_input_tokens") ?? 0
        let write = try count(raw, "cache_write_input_tokens") ?? 0
        let output = try count(raw, "output_tokens") ?? 0
        let reasoning = try count(raw, "reasoning_output_tokens") ?? 0
        return UsageTokens(
            input: max(0, input - cached - write),
            cacheRead: cached,
            cacheWrite5m: write,
            cacheWrite1h: 0,
            output: output,
            reasoning: min(reasoning, output)
        )
    }

    /// Field-wise difference of two cumulative readings; a field that went
    /// backwards on its own contributes nothing.
    private static func delta(_ current: UsageTokens, from previous: UsageTokens?) -> UsageTokens {
        guard let previous else { return current }
        return UsageTokens(
            input: max(0, current.input - previous.input),
            cacheRead: max(0, current.cacheRead - previous.cacheRead),
            cacheWrite5m: max(0, current.cacheWrite5m - previous.cacheWrite5m),
            cacheWrite1h: max(0, current.cacheWrite1h - previous.cacheWrite1h),
            output: max(0, current.output - previous.output),
            reasoning: max(0, current.reasoning - previous.reasoning)
        )
    }

    /// Copied history lands within milliseconds of the copy; a real call
    /// cannot follow the previous line faster than this.
    static let forkCopyMaximumGap: TimeInterval = 1

    static func signature(_ tokens: UsageTokens) -> String {
        "\(tokens.input):\(tokens.cacheRead):\(tokens.cacheWrite5m):\(tokens.output):\(tokens.reasoning)"
    }

    // MARK: - Counters

    /// A token counter: absent (or null) is zero for the caller; anything
    /// present must be a non-negative integer number — never a boolean
    /// (`NSNumber(0)`/`(1)` bridge to `Bool`, so the CF type decides), a
    /// fraction, or something out of range.
    private static func count(_ raw: [String: Any], _ key: String) throws -> Int64? {
        guard let value = raw[key], !(value is NSNull) else { return nil }
        guard let number = JSONNumber.nonBoolean(value) else { throw UsageParseError.invalidCounter(key) }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double <= 1e15, double.rounded(.towardZero) == double else {
            throw UsageParseError.invalidCounter(key)
        }
        return number.int64Value
    }

    private static func reportedCost(_ value: Any?) throws -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = JSONNumber.nonBoolean(value), number.doubleValue.isFinite, number.doubleValue >= 0 else {
            throw UsageParseError.invalidCost
        }
        return number.doubleValue
    }

    private static let claudeUsageNeedle = Data("\"usage\"".utf8)
    private static let claudePromptNeedle = Data("\"promptId\"".utf8)
    private static let codexTokenCountNeedle = Data("\"token_count\"".utf8)
    private static let codexTurnContextNeedle = Data("\"turn_context\"".utf8)
    private static let codexSessionMetaNeedle = Data("\"session_meta\"".utf8)
}

