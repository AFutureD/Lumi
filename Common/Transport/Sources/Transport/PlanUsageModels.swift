import Foundation

// Plan usage: how much of a subscription's rate-limit windows a sign-in on
// this Mac has used. The daemon reads each agent's own sign-in file
// (Claude Code `~/.claude/.credentials.json`, Codex `~/.codex/auth.json`),
// asks the provider's usage endpoint with that token, and keeps one
// in-memory snapshot per account. Nothing here is Session or token-cost
// data; it is the provider's own answer, refreshed every few minutes.
//
// These types cross the daemon ↔ Mac IPC boundary (`plan_usage`) and the
// Relay (`fetch_plan_usage` → `plan_usage`), so they live in Transport.
// Which accounts are polled is a setting (`PlanUsageSettings`); each
// account's `enabled` mirrors it for display.

/// One sign-in the daemon tracks. Today there is one per provider and the id
/// is the provider's name (`claude`, `codex`); a second sign-in of the same
/// provider would get a suffixed id, so nothing keys on the provider alone.
public struct PlanUsageAccountID: TypedIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let claude = PlanUsageAccountID(rawValue: "claude")
    public static let codex = PlanUsageAccountID(rawValue: "codex")
}

/// Which rolling window a limit describes.
public enum PlanUsageWindow: String, Codable, Hashable, Sendable {
    /// The short window (five hours for both providers).
    case session
    /// The seven-day window.
    case weekly
}

/// One rate-limit window as the provider reports it. `model` names a
/// model-scoped window (Claude's weekly `Fable` limit); `nil` is the
/// account-wide window.
public struct PlanUsageLimit: Codable, Hashable, Sendable {
    public var window: PlanUsageWindow
    public var model: String?
    /// 0…100, the provider's own figure (used, never remaining).
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(window: PlanUsageWindow, model: String? = nil, usedPercent: Double, resetsAt: Date? = nil) {
        self.window = window
        self.model = model
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    private enum CodingKeys: String, CodingKey {
        case window
        case model
        case usedPercent
        case resetsAt
    }
}

/// Why an account has, or has not, current limits.
public enum PlanUsageAccountStatus: String, Codable, Hashable, Sendable {
    /// The last fetch succeeded; `limits` are current.
    case ok
    /// The sign-in file is missing or carries no access token.
    case credentialsMissing
    /// The saved access token is past its expiry; no request was sent.
    /// The daemon never refreshes tokens — the agent's own sign-in does.
    case signInExpired
    /// The provider answered 401 / 403 to the saved token.
    case signInRejected
    /// The provider answered 429; `retryAt` says when the daemon asks again.
    case rateLimited
    /// Any other failure (network, 5xx, unparseable body); `statusDetail` says what.
    case failed
}

public struct PlanUsageAccount: Codable, Hashable, Sendable {
    public var id: PlanUsageAccountID
    public var provider: AgentProvider
    /// From the agent's local files, present without any network call.
    public var email: String?
    /// The subscription as the provider names it (`Max 20x`, `Pro 5x`).
    public var plan: String?
    /// Mirrors `PlanUsageSettings.enabledAccounts`; only enabled accounts
    /// are fetched. Change it through `set_settings`, never here.
    public var enabled: Bool
    public var status: PlanUsageAccountStatus
    /// Human-readable cause for `failed` / `signInRejected` / `rateLimited`.
    public var statusDetail: String?
    /// `rateLimited`: the daemon skips the account until this passes.
    public var retryAt: Date?
    /// The last successful answer; kept through a failed refresh so the
    /// Notch does not blank out on a transient error.
    public var limits: [PlanUsageLimit]
    public var fetchedAt: Date?

    public init(
        id: PlanUsageAccountID,
        provider: AgentProvider,
        email: String? = nil,
        plan: String? = nil,
        enabled: Bool,
        status: PlanUsageAccountStatus,
        statusDetail: String? = nil,
        retryAt: Date? = nil,
        limits: [PlanUsageLimit] = [],
        fetchedAt: Date? = nil
    ) {
        self.id = id
        self.provider = provider
        self.email = email
        self.plan = plan
        self.enabled = enabled
        self.status = status
        self.statusDetail = statusDetail
        self.retryAt = retryAt
        self.limits = limits
        self.fetchedAt = fetchedAt
    }

    /// The account-wide (or model-scoped) limit for a window, if reported.
    public func limit(_ window: PlanUsageWindow, model: String? = nil) -> PlanUsageLimit? {
        limits.first { $0.window == window && $0.model == model }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case email
        case plan
        case enabled
        case status
        case statusDetail
        case retryAt
        case limits
        case fetchedAt
    }
}

/// The daemon's whole answer to `plan_usage`: every known account, in a
/// stable order (Claude first), plus when the snapshot was assembled.
public struct PlanUsageState: Codable, Hashable, Sendable {
    public var accounts: [PlanUsageAccount]
    public var generatedAt: Date

    public init(accounts: [PlanUsageAccount], generatedAt: Date) {
        self.accounts = accounts
        self.generatedAt = generatedAt
    }

    public func account(_ id: PlanUsageAccountID) -> PlanUsageAccount? {
        accounts.first { $0.id == id }
    }

    private enum CodingKeys: String, CodingKey {
        case accounts
        case generatedAt
    }
}
