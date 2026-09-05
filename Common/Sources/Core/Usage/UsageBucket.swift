import Transport
import Foundation

/// One persisted usage bucket: every model call of one model within one
/// turn on one local day, summed. The daemon's `usage_buckets` row.
public struct UsageBucket: Hashable, Sendable {
    public var agent: AgentKind
    public var sessionID: String
    public var turnID: String
    public var model: String
    public var day: UsageDay
    /// Long-context band (0 = base) the calls were classified into.
    public var tier: Int
    /// Working directory of the bucket's first record.
    public var workspace: String
    public var firstAt: Date
    public var lastAt: Date
    public var tokens: UsageTokens
    public var calls: Int
    /// Sum of the costs the source reported; `nil` when no call carried one.
    public var reportedCostUSD: Double?
    /// How many of `calls` carried a reported cost.
    public var reportedCalls: Int

    public init(
        agent: AgentKind,
        sessionID: String,
        turnID: String,
        model: String,
        day: UsageDay,
        tier: Int = 0,
        workspace: String,
        firstAt: Date,
        lastAt: Date,
        tokens: UsageTokens,
        calls: Int,
        reportedCostUSD: Double? = nil,
        reportedCalls: Int = 0
    ) {
        self.agent = agent
        self.sessionID = sessionID
        self.turnID = turnID
        self.model = model
        self.day = day
        self.tier = tier
        self.workspace = workspace
        self.firstAt = firstAt
        self.lastAt = lastAt
        self.tokens = tokens
        self.calls = calls
        self.reportedCostUSD = reportedCostUSD
        self.reportedCalls = reportedCalls
    }
}

/// Where the usage scan stopped in one file, plus the parser state it
/// needs to continue. The file is known by `identity` (its inode, see
/// `UsageFileIdentity`), so a moved file continues where it left off;
/// `prefixHash` tells a rewritten file from an appended one; `fileSize` /
/// `modifiedAt` let the scanner skip unchanged files without opening them.
public struct UsageCursor: Hashable, Sendable {
    public var identity: String
    public var path: String
    public var source: UsageSource
    public var byteOffset: UInt64
    public var fileSize: UInt64
    public var modifiedAt: Date
    /// How many leading bytes `prefixHash` covers (up to `UsageFileIdentity.prefixLimit`).
    public var prefixLength: Int
    public var prefixHash: String
    public var state: UsageScanState

    public init(
        identity: String,
        path: String,
        source: UsageSource,
        byteOffset: UInt64,
        fileSize: UInt64,
        modifiedAt: Date,
        prefixLength: Int,
        prefixHash: String,
        state: UsageScanState
    ) {
        self.identity = identity
        self.path = path
        self.source = source
        self.byteOffset = byteOffset
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.prefixLength = prefixLength
        self.prefixHash = prefixHash
        self.state = state
    }
}

/// Persistence contract for usage: what the scanner writes and the report
/// reads. Kept apart from `SessionRepository` on purpose — usage is not
/// Session history and survives every Session deletion.
public protocol UsageStore: Sendable {
    /// Counts each record whose dedupe key is new into its bucket, then
    /// saves the cursor — one transaction. Returns how many records were new.
    @discardableResult
    func apply(records: [UsageRecord], cursor: UsageCursor) async throws -> Int
    func cursor(identity: String) async throws -> UsageCursor?
    /// Every cursor, for the scanner's change detection.
    func cursors() async throws -> [UsageCursor]
    /// Buckets whose day falls in the inclusive range.
    func buckets(since: UsageDay, until: UsageDay) async throws -> [UsageBucket]
}
