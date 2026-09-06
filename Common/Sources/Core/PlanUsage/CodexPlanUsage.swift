import Transport
import Foundation

/// Codex's saved sign-in (`$CODEX_HOME/auth.json`, default `~/.codex/auth.json`).
/// A ChatGPT sign-in carries `tokens.{access_token, account_id, id_token}`;
/// an API-key-only file has no plan usage at all. Read-only; the refresh
/// token is never used.
public struct CodexAuth: Hashable, Sendable {
    public var accessToken: String
    public var accountID: String?
    public var email: String?
    /// From the access token's `exp` claim.
    public var expiresAt: Date?

    public init(accessToken: String, accountID: String? = nil, email: String? = nil, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.email = email
        self.expiresAt = expiresAt
    }

    public enum FileContent: Hashable, Sendable {
        case signedIn(CodexAuth)
        /// Only `OPENAI_API_KEY`: the usage endpoint is a ChatGPT-account service.
        case apiKeyOnly
        /// Not JSON, or JSON with neither a token nor an API key.
        case unusable
    }

    /// The identity claims live in the ID token (`email`,
    /// `https://api.openai.com/auth.chatgpt_account_id`); the expiry in the
    /// access token. `tokens.account_id` wins over the claim when both exist.
    public static func read(fileData: Data) -> FileContent {
        guard let root = PlanUsageJSON.object(fileData) else { return .unusable }
        let tokens = root["tokens"] as? [String: Any] ?? [:]
        guard let token = (tokens["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            if let key = root["OPENAI_API_KEY"] as? String, !key.isEmpty { return .apiKeyOnly }
            return .unusable
        }
        let identity = (tokens["id_token"] as? String).flatMap(JWTPayload.init(token:))
        let authClaims = identity?.claims["https://api.openai.com/auth"] as? [String: Any]
        let accountID = (tokens["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (authClaims?["chatgpt_account_id"] as? String)
            ?? identity?.string("chatgpt_account_id")
        return .signedIn(CodexAuth(
            accessToken: token,
            accountID: accountID,
            email: identity?.string("email"),
            expiresAt: JWTPayload(token: token)?.expiresAt
        ))
    }

    public func isExpired(now: Date) -> Bool {
        PlanUsageTokenExpiry.isExpired(expiresAt, now: now)
    }
}

public enum CodexPlanUsage {
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static let userAgent = "OpenUsage"
    public static let requestTimeout: TimeInterval = 10
    static let sessionWindowSeconds: Double = 5 * 60 * 60
    static let weeklyWindowSeconds: Double = 7 * 24 * 60 * 60

    public static func usageRequest(token: String, accountID: String?) -> URLRequest {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return request
    }

    /// `rate_limit.primary_window` / `secondary_window`, classified by their
    /// `limit_window_seconds` (5 h → session, 7 d → weekly) because Codex has
    /// moved a lone weekly limit into the primary slot before; the slot order
    /// is only the fallback for windows without a duration. A window missing
    /// `used_percent` takes the `x-codex-*-used-percent` response header.
    public static func limits(from body: Data, headers: [String: String] = [:], now: Date) throws -> PlanUsageFetchOutcome {
        guard let object = PlanUsageJSON.object(body) else { throw PlanUsageParseError.invalidJSON }
        let rateLimit = object["rate_limit"] as? [String: Any] ?? [:]
        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        let candidates = [
            candidate(rateLimit["primary_window"], header: lowered["x-codex-primary-used-percent"], fallback: .session),
            candidate(rateLimit["secondary_window"], header: lowered["x-codex-secondary-used-percent"], fallback: .weekly),
        ].compactMap { $0 }
        var limits: [PlanUsageLimit] = []
        for window in [PlanUsageWindow.session, .weekly] {
            let exact = candidates.first { $0.exactWindow == window }
            let fallback = candidates.first { $0.exactWindow == nil && $0.fallback == window }
            guard let chosen = exact ?? fallback, let used = chosen.usedPercent else { continue }
            limits.append(PlanUsageLimit(window: window, usedPercent: used, resetsAt: resetDate(chosen.object, now: now)))
        }
        guard !limits.isEmpty else { throw PlanUsageParseError.noLimits }
        return PlanUsageFetchOutcome(limits: limits)
    }

    /// `prolite` → `Pro 5x`, `pro` → `Pro 20x`; anything else title-cased.
    public static func planLabel(from body: Data) -> String? {
        guard let object = PlanUsageJSON.object(body),
              let raw = (object["plan_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "prolite": return "Pro 5x"
        case "pro": return "Pro 20x"
        case "self_serve_business_prolite": return "Business Premium"
        default: return PlanUsageJSON.titleCased(raw, separator: "_")
        }
    }

    private struct Candidate {
        var object: [String: Any]
        var usedPercent: Double?
        var exactWindow: PlanUsageWindow?
        var fallback: PlanUsageWindow
    }

    private static func candidate(_ value: Any?, header: String?, fallback: PlanUsageWindow) -> Candidate? {
        let headerPercent = PlanUsageJSON.percent(header)
        guard let object = value as? [String: Any] ?? (headerPercent == nil ? nil : [:]) else { return nil }
        let exact: PlanUsageWindow? = switch PlanUsageJSON.number(object["limit_window_seconds"]) {
        case sessionWindowSeconds?: .session
        case weeklyWindowSeconds?: .weekly
        default: nil
        }
        return Candidate(
            object: object,
            usedPercent: PlanUsageJSON.percent(object["used_percent"]) ?? headerPercent,
            exactWindow: exact,
            fallback: fallback
        )
    }

    private static func resetDate(_ window: [String: Any], now: Date) -> Date? {
        if let at = PlanUsageJSON.number(window["reset_at"]) { return Date(timeIntervalSince1970: at) }
        if let after = PlanUsageJSON.number(window["reset_after_seconds"]) { return now.addingTimeInterval(after) }
        return nil
    }
}
