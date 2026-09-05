import Transport
import Foundation

/// Which agent's transcript format a file is in — and therefore which
/// parser reads it and which models.dev provider prices it.
public enum UsageSource: String, Codable, Hashable, Sendable, CaseIterable {
    case claude
    case codex

    public var provider: AgentProvider {
        switch self {
        case .claude: .claude
        case .codex: .codex
        }
    }
}

/// One model call's tokens, parsed out of a transcript / rollout line.
/// Independent of Session storage: identity here is whatever the file
/// records (Claude keeps the parent `sessionId` on subagent transcripts).
public struct UsageRecord: Codable, Hashable, Sendable {
    public var agent: AgentKind
    public var sessionID: String
    /// Empty until the file named a turn (a record ahead of the first
    /// prompt / `turn_context`).
    public var turnID: String
    /// The id as the agent reported it; empty when the file did not say.
    public var model: String
    /// Working directory as recorded; empty when the file did not say.
    public var workspace: String
    public var occurredAt: Date
    public var tokens: UsageTokens
    /// Global de-duplication key: Claude repeats one message's usage on
    /// every content block (and forks / resumes copy history), Codex fork
    /// rollouts replay ancestor lines. The store counts a key once, ever.
    public var dedupeKey: String
    /// The cost the source itself reported for this call (Claude Code's
    /// `costUSD`, written by older versions). Preferred over an estimate.
    public var reportedCostUSD: Double?
    /// `false` for a top-up of a call already counted (a later Claude copy
    /// of the same message carrying more output): tokens add, calls do not.
    public var isCall: Bool
    /// The whole call's context (input + cache read + cache write), also on
    /// a top-up whose `tokens` are only the difference — it decides the band.
    public var context: Int64
    /// Long-context band the call is stored under (0 = base); set by the
    /// scanner from the price table in force when the call was read.
    public var tier: Int

    public init(
        agent: AgentKind,
        sessionID: String,
        turnID: String,
        model: String,
        workspace: String,
        occurredAt: Date,
        tokens: UsageTokens,
        dedupeKey: String,
        reportedCostUSD: Double? = nil,
        isCall: Bool = true,
        context: Int64? = nil,
        tier: Int = 0
    ) {
        self.agent = agent
        self.sessionID = sessionID
        self.turnID = turnID
        self.model = model
        self.workspace = workspace
        self.occurredAt = occurredAt
        self.tokens = tokens
        self.dedupeKey = dedupeKey
        self.reportedCostUSD = reportedCostUSD
        self.isCall = isCall
        self.context = context ?? tokens.context
        self.tier = tier
    }

    private enum CodingKeys: String, CodingKey {
        case agent
        case sessionID
        case turnID
        case model
        case workspace
        case occurredAt
        case tokens
        case dedupeKey
        case reportedCostUSD
        case isCall
        case context
        case tier
    }
}

/// Why a transcript line was refused. The reader counts and skips the
/// line; the file's other lines are unaffected.
public enum UsageParseError: Error, Hashable, Sendable {
    case malformedJSON
    /// A token counter that is not a non-negative integer number.
    case invalidCounter(String)
    /// A reported cost that is not a non-negative finite number.
    case invalidCost
}

/// Per-file parser state, persisted with the file's cursor so an
/// incremental read continues where the last one stopped: the open turn,
/// the carried Codex identity, the Codex cumulative baseline, and a call
/// waiting for its context.
public struct UsageScanState: Codable, Hashable, Sendable {
    public var turnID: String?
    /// Newest timestamp seen; a record without its own inherits it.
    public var lastTimestamp: Date?
    /// The last Claude message counted and the usage it was counted with:
    /// Claude Code writes one record per content block while the message
    /// streams, and `output_tokens` grows across them — the largest copy is
    /// the truth, and a later, larger copy tops the count up.
    public var claudeLastKey: String?
    public var claudeLastTokens: UsageTokens?
    public var codexSessionID: String?
    public var codexIsSubagent: Bool
    public var codexWorkspace: String?
    public var codexModel: String?
    /// `total_token_usage` of the last counted Codex event: an event that
    /// repeats it is a re-emission, a lower one is a reset, and a `last`-less
    /// one is priced as the difference from it.
    public var codexCumulative: UsageTokens?
    /// Signature of the last counted `last_token_usage` for rollouts that
    /// report no cumulative at all.
    public var codexLastSignature: String?
    /// Cumulative resets seen (the counters went backwards).
    public var codexResets: Int
    /// A Codex call read before any `turn_context` named its turn / model /
    /// cwd. Held until the next context line (which completes it), the next
    /// call, or the end of the read (which emit it as it is) — so it never
    /// survives in a saved cursor.
    public var codexPending: UsageRecord?
    /// A forked / spawned rollout starts with a copy of its ancestor's
    /// history, re-stamped to the moment of the copy. While the copy is
    /// being read, its calls are the ancestor's and are not counted again;
    /// the copy ends at the child's own meta or at the first call written
    /// more than a second after the previous line.
    public var codexReplaying: Bool
    public var codexReplayAnchor: Date?

    public init(
        turnID: String? = nil,
        lastTimestamp: Date? = nil,
        codexSessionID: String? = nil,
        codexIsSubagent: Bool = false,
        codexWorkspace: String? = nil,
        codexModel: String? = nil,
        codexCumulative: UsageTokens? = nil,
        codexLastSignature: String? = nil,
        codexResets: Int = 0,
        codexPending: UsageRecord? = nil,
        claudeLastKey: String? = nil,
        claudeLastTokens: UsageTokens? = nil,
        codexReplaying: Bool = false,
        codexReplayAnchor: Date? = nil
    ) {
        self.turnID = turnID
        self.lastTimestamp = lastTimestamp
        self.claudeLastKey = claudeLastKey
        self.claudeLastTokens = claudeLastTokens
        self.codexSessionID = codexSessionID
        self.codexIsSubagent = codexIsSubagent
        self.codexWorkspace = codexWorkspace
        self.codexModel = codexModel
        self.codexCumulative = codexCumulative
        self.codexLastSignature = codexLastSignature
        self.codexResets = codexResets
        self.codexPending = codexPending
        self.codexReplaying = codexReplaying
        self.codexReplayAnchor = codexReplayAnchor
    }

    private enum CodingKeys: String, CodingKey {
        case turnID
        case lastTimestamp
        case claudeLastKey
        case claudeLastTokens
        case codexSessionID
        case codexIsSubagent
        case codexWorkspace
        case codexModel
        case codexCumulative
        case codexLastSignature
        case codexResets
        case codexPending
        case codexReplaying
        case codexReplayAnchor
    }
}
