import Foundation

// Usage: token consumption and cost across every agent transcript on this
// Mac. Independent of Session storage — the daemon scans the agents' own
// transcript / rollout files (Claude `~/.claude/projects`, Codex
// `~/.codex/sessions` + `archived_sessions`) and keeps per
// `(agent, session, turn, model, day)` token buckets; deleting a Session in
// Lumi never touches them. Cost is computed at query time against the
// models.dev price table, so a price refresh applies to history.
//
// These types cross the daemon ↔ Mac IPC boundary (`usage_report`), so they
// live in Transport.

/// A calendar day in the daemon's local time zone, `YYYY-MM-DD` on the wire.
/// Usage ranges are inclusive on both ends and never finer than a day.
public struct UsageDay: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Strict `YYYY-MM-DD`; anything else is `nil`.
    public init?(rawValue: String) {
        let parts = rawValue.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    public var rawValue: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String { rawValue }

    public static func < (lhs: UsageDay, rhs: UsageDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

extension UsageDay: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let day = UsageDay(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Usage day is not YYYY-MM-DD: \(value)")
        }
        self = day
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Token counts in the Claude shape: `input` is the uncached remainder,
/// cache reads and writes are separate, and `reasoning` is the part of
/// `output` that was thinking (reported separately by Codex, folded into
/// output by Claude). Cache writes split by TTL because Anthropic bills the
/// 1-hour tier at twice the 5-minute rate.
public struct UsageTokens: Codable, Hashable, Sendable {
    public var input: Int64
    public var cacheRead: Int64
    public var cacheWrite5m: Int64
    public var cacheWrite1h: Int64
    public var output: Int64
    public var reasoning: Int64

    public init(
        input: Int64 = 0,
        cacheRead: Int64 = 0,
        cacheWrite5m: Int64 = 0,
        cacheWrite1h: Int64 = 0,
        output: Int64 = 0,
        reasoning: Int64 = 0
    ) {
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.output = output
        self.reasoning = reasoning
    }

    public static let zero = UsageTokens()

    public var cacheWrite: Int64 { cacheWrite5m + cacheWrite1h }

    /// Everything the model processed: input + cache read + cache write + output.
    public var total: Int64 { input + cacheRead + cacheWrite5m + cacheWrite1h + output }

    public mutating func add(_ other: UsageTokens) {
        input += other.input
        cacheRead += other.cacheRead
        cacheWrite5m += other.cacheWrite5m
        cacheWrite1h += other.cacheWrite1h
        output += other.output
        reasoning += other.reasoning
    }

    private enum CodingKeys: String, CodingKey {
        case input
        case cacheRead
        case cacheWrite5m
        case cacheWrite1h
        case output
        case reasoning
    }
}

/// Where the price table in force came from.
public enum UsagePricingSource: Hashable, Sendable {
    /// The snapshot compiled into the daemon (never fetched, or nothing cached).
    case builtin
    /// The on-disk copy of a previous fetch, older than the refresh interval
    /// or kept because the last fetch failed.
    case cached
    /// Fetched within the refresh interval.
    case fresh

    public var rawValue: String {
        switch self {
        case .builtin: "builtin"
        case .cached: "cached"
        case .fresh: "fresh"
        }
    }
}

extension UsagePricingSource: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = switch value {
        case "builtin": .builtin
        case "cached": .cached
        case "fresh": .fresh
        default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown usage pricing source: \(value)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct UsagePricingStatus: Codable, Hashable, Sendable {
    public var source: UsagePricingSource
    /// When the table in force was fetched; `nil` for the built-in snapshot.
    public var fetchedAt: Date?
    public var modelCount: Int

    public init(source: UsagePricingSource, fetchedAt: Date? = nil, modelCount: Int) {
        self.source = source
        self.fetchedAt = fetchedAt
        self.modelCount = modelCount
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case fetchedAt
        case modelCount
    }
}

/// Progress of the daemon's transcript scan, so the page can say
/// "scanning" instead of showing a partial total as the truth.
public struct UsageScanStatus: Codable, Hashable, Sendable {
    /// Files the store holds a cursor for.
    public var scannedFiles: Int
    /// Files found on disk whose cursor is missing or behind (0 once caught up).
    public var pendingFiles: Int
    public var lastScanAt: Date?
    public var isScanning: Bool

    public init(scannedFiles: Int, pendingFiles: Int, lastScanAt: Date? = nil, isScanning: Bool) {
        self.scannedFiles = scannedFiles
        self.pendingFiles = pendingFiles
        self.lastScanAt = lastScanAt
        self.isScanning = isScanning
    }

    private enum CodingKeys: String, CodingKey {
        case scannedFiles
        case pendingFiles
        case lastScanAt
        case isScanning
    }
}

/// One row of a usage table. Which of `agent` / `model` / `workspace` are
/// set says what the row groups by: the totals row sets none, the per-agent
/// rows set `agent`, per-model rows set `agent` + `model`, per-project rows
/// set `workspace`.
///
/// `costUSD` sums the priced part of the row; `unpricedTokens` is the part
/// no published price covers (their cost is missing, not zero). A row with
/// nothing priced and something unpriced carries `costUSD == nil`.
public struct UsageSlice: Codable, Hashable, Sendable {
    public var agent: AgentProvider?
    public var model: String?
    public var workspace: String?
    public var tokens: UsageTokens
    public var costUSD: Double?
    public var unpricedTokens: Int64
    /// Model calls (Claude API messages / Codex token_count events).
    public var calls: Int
    /// Distinct session ids (a subagent shares its parent's).
    public var sessions: Int
    /// Distinct (session, turn) pairs; records ahead of any turn are not counted.
    public var turns: Int
    public var lastDay: UsageDay?

    public init(
        agent: AgentProvider? = nil,
        model: String? = nil,
        workspace: String? = nil,
        tokens: UsageTokens = .zero,
        costUSD: Double? = nil,
        unpricedTokens: Int64 = 0,
        calls: Int = 0,
        sessions: Int = 0,
        turns: Int = 0,
        lastDay: UsageDay? = nil
    ) {
        self.agent = agent
        self.model = model
        self.workspace = workspace
        self.tokens = tokens
        self.costUSD = costUSD
        self.unpricedTokens = unpricedTokens
        self.calls = calls
        self.sessions = sessions
        self.turns = turns
        self.lastDay = lastDay
    }

    private enum CodingKeys: String, CodingKey {
        case agent
        case model
        case workspace
        case tokens
        case costUSD
        case unpricedTokens
        case calls
        case sessions
        case turns
        case lastDay
    }
}

/// The answer to `usage_report {since, until}`: one inclusive day range,
/// already grouped every way the page shows it. Small by construction — a
/// year of usage is a few hundred rows — so it always fits one IPC frame.
public struct UsageReport: Codable, Hashable, Sendable {
    public var since: UsageDay
    public var until: UsageDay
    public var generatedAt: Date
    public var totals: UsageSlice
    /// One row per agent provider, cost descending.
    public var byAgent: [UsageSlice]
    /// One row per working directory, cost descending.
    public var byProject: [UsageSlice]
    /// One row per (agent, model), cost descending; unpriced rows last.
    public var byModel: [UsageSlice]
    public var pricing: UsagePricingStatus
    public var scan: UsageScanStatus

    public init(
        since: UsageDay,
        until: UsageDay,
        generatedAt: Date,
        totals: UsageSlice,
        byAgent: [UsageSlice],
        byProject: [UsageSlice],
        byModel: [UsageSlice],
        pricing: UsagePricingStatus,
        scan: UsageScanStatus
    ) {
        self.since = since
        self.until = until
        self.generatedAt = generatedAt
        self.totals = totals
        self.byAgent = byAgent
        self.byProject = byProject
        self.byModel = byModel
        self.pricing = pricing
        self.scan = scan
    }

    private enum CodingKeys: String, CodingKey {
        case since
        case until
        case generatedAt
        case totals
        case byAgent
        case byProject
        case byModel
        case pricing
        case scan
    }
}
