import Transport
import Foundation

/// Claude Code's saved sign-in (`~/.claude/.credentials.json`, or under
/// `CLAUDE_CONFIG_DIR`): the OAuth access token the usage endpoint takes,
/// plus the subscription fields the plan label is built from. Read-only;
/// the refresh token is never used — Claude Code refreshes its own sign-in.
public struct ClaudeCredentials: Hashable, Sendable {
    public var accessToken: String
    /// Milliseconds since 1970 in the file; a date here.
    public var expiresAt: Date?
    public var subscriptionType: String?
    public var rateLimitTier: String?
    public var scopes: [String]

    /// The usage endpoint needs this scope; a token without it is rejected.
    public static let usageScope = "user:profile"

    public init(accessToken: String, expiresAt: Date? = nil, subscriptionType: String? = nil, rateLimitTier: String? = nil, scopes: [String] = []) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
        self.scopes = scopes
    }

    /// `nil` when the file is not JSON or carries no access token.
    public init?(fileData: Data) {
        guard let root = PlanUsageJSON.object(fileData),
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = (oauth["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        accessToken = token
        expiresAt = PlanUsageJSON.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1_000) }
        subscriptionType = oauth["subscriptionType"] as? String
        rateLimitTier = oauth["rateLimitTier"] as? String
        scopes = oauth["scopes"] as? [String] ?? []
    }

    public func isExpired(now: Date) -> Bool {
        PlanUsageTokenExpiry.isExpired(expiresAt, now: now)
    }

    /// An empty scope list is an older file that did not record scopes: allowed.
    public var hasUsageScope: Bool {
        scopes.isEmpty || scopes.contains(Self.usageScope)
    }

    /// `max` + `claude_max_subscription_20x` → `Max 20x`.
    public var planLabel: String? {
        guard let raw = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let base = PlanUsageJSON.titleCased(raw, separator: " ", lowercasingTail: true)
        guard let tier = rateLimitTier, let match = tier.range(of: #"\d+x"#, options: .regularExpression) else { return base }
        return "\(base) \(tier[match])"
    }
}

/// Who the sign-in belongs to, from Claude Code's state file (`~/.claude.json`).
/// The usage endpoint does not answer this; the file does, without a request.
public struct ClaudeAccountIdentity: Hashable, Sendable {
    public var email: String?
    public var organizationName: String?
    public var accountUUID: String?
    public var organizationUUID: String?

    public init(email: String? = nil, organizationName: String? = nil, accountUUID: String? = nil, organizationUUID: String? = nil) {
        self.email = email
        self.organizationName = organizationName
        self.accountUUID = accountUUID
        self.organizationUUID = organizationUUID
    }

    public init?(stateFileData: Data) {
        guard let root = PlanUsageJSON.object(stateFileData),
              let account = root["oauthAccount"] as? [String: Any] else { return nil }
        email = account["emailAddress"] as? String
        organizationName = account["organizationName"] as? String
        accountUUID = account["accountUuid"] as? String
        organizationUUID = account["organizationUuid"] as? String
    }
}

public enum ClaudePlanUsage {
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// The endpoint serves Claude Code; this is the client it expects. The
    /// version string drifts with Claude Code releases — bump when the
    /// endpoint starts rejecting it.
    public static let userAgent = "claude-code/2.1.69"
    public static let oauthBeta = "oauth-2025-04-20"
    public static let requestTimeout: TimeInterval = 10

    public static func usageRequest(token: String) -> URLRequest {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(oauthBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The account-wide windows (`five_hour`, `seven_day`), the legacy
    /// per-model key (`seven_day_sonnet`, `null` on current accounts) and the
    /// `limits[]` rows Anthropic moved model-scoped weekly windows into
    /// (`kind: "weekly_scoped"`, `scope.model.display_name`, `percent`).
    public static func limits(from body: Data) throws -> PlanUsageFetchOutcome {
        guard let object = PlanUsageJSON.object(body) else { throw PlanUsageParseError.invalidJSON }
        var limits: [PlanUsageLimit] = []
        if let limit = window(object["five_hour"], as: .session) { limits.append(limit) }
        if let limit = window(object["seven_day"], as: .weekly) { limits.append(limit) }
        if let limit = window(object["seven_day_sonnet"], as: .weekly, model: "Sonnet") { limits.append(limit) }
        for entry in object["limits"] as? [Any] ?? [] {
            guard let row = entry as? [String: Any],
                  row["kind"] as? String == "weekly_scoped",
                  let scope = row["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String, !name.isEmpty,
                  let used = PlanUsageJSON.percent(row["percent"]),
                  !limits.contains(where: { $0.window == .weekly && $0.model == name }) else { continue }
            limits.append(PlanUsageLimit(window: .weekly, model: name, usedPercent: used, resetsAt: PlanUsageJSON.date(row["resets_at"])))
        }
        guard !limits.isEmpty else { throw PlanUsageParseError.noLimits }
        return PlanUsageFetchOutcome(limits: limits)
    }

    private static func window(_ value: Any?, as window: PlanUsageWindow, model: String? = nil) -> PlanUsageLimit? {
        guard let object = value as? [String: Any], let used = PlanUsageJSON.percent(object["utilization"]) else { return nil }
        return PlanUsageLimit(window: window, model: model, usedPercent: used, resetsAt: PlanUsageJSON.date(object["resets_at"]))
    }
}
