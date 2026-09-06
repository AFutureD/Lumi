import Foundation
import Testing
import Transport
@testable import Core

private let now = Date(timeIntervalSince1970: 1_800_000_000)

// MARK: Claude

@Test func claudeCredentialsDecodeFromTheSignInFile() throws {
    let file = Data("""
    {"claudeAiOauth":{"accessToken":" sk-ant-oat01-abc ","refreshToken":"r","expiresAt":1800000600000,
     "subscriptionType":"max","rateLimitTier":"claude_max_subscription_20x","scopes":["user:inference","user:profile"]}}
    """.utf8)
    let credentials = try #require(ClaudeCredentials(fileData: file))
    #expect(credentials.accessToken == "sk-ant-oat01-abc")
    #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_800_000_600))
    #expect(credentials.planLabel == "Max 20x")
    #expect(credentials.hasUsageScope)
    // 600 s left is inside the 5-minute margin? No — 600 > 300.
    #expect(!credentials.isExpired(now: now))
    #expect(credentials.isExpired(now: now.addingTimeInterval(301)))

    #expect(ClaudeCredentials(fileData: Data("{\"claudeAiOauth\":{\"accessToken\":\"\"}}".utf8)) == nil)
    #expect(ClaudeCredentials(fileData: Data("not json".utf8)) == nil)
    let noScope = try #require(ClaudeCredentials(fileData: Data(#"{"claudeAiOauth":{"accessToken":"t","scopes":["user:inference"]}}"#.utf8)))
    #expect(!noScope.hasUsageScope)
    #expect(noScope.planLabel == nil)
    #expect(!noScope.isExpired(now: now))
    let noTier = try #require(ClaudeCredentials(fileData: Data(#"{"claudeAiOauth":{"accessToken":"t","subscriptionType":"pro"}}"#.utf8)))
    #expect(noTier.planLabel == "Pro")
}

@Test func claudeIdentityComesFromTheStateFile() throws {
    let file = Data(#"{"oauthAccount":{"accountUuid":"a-1","emailAddress":"me@example.com","organizationUuid":"o-1","organizationName":"Me"}}"#.utf8)
    let identity = try #require(ClaudeAccountIdentity(stateFileData: file))
    #expect(identity.email == "me@example.com")
    #expect(identity.organizationName == "Me")
    #expect(ClaudeAccountIdentity(stateFileData: Data("{}".utf8)) == nil)
}

@Test func claudeUsageRequestLooksLikeClaudeCode() {
    let request = ClaudePlanUsage.usageRequest(token: "tok")
    #expect(request.url == URL(string: "https://api.anthropic.com/api/oauth/usage"))
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == ClaudePlanUsage.userAgent)
    #expect(request.timeoutInterval == 10)
}

@Test func claudeLimitsMapWindowsAndScopedModels() throws {
    let legacy = Data("""
    {
      "five_hour": { "utilization": 10, "resets_at": "2099-01-01T00:00:00.000Z" },
      "seven_day": { "utilization": 20.5, "resets_at": "2099-01-01T00:00:00Z" },
      "seven_day_sonnet": { "utilization": 5, "resets_at": 4102444800 },
      "extra_usage": { "is_enabled": true, "used_credits": 500, "monthly_limit": 1000 }
    }
    """.utf8)
    let outcome = try ClaudePlanUsage.limits(from: legacy)
    #expect(outcome.limits.count == 3)
    #expect(outcome.limits[0] == PlanUsageLimit(window: .session, usedPercent: 10, resetsAt: Date(timeIntervalSince1970: 4_070_908_800)))
    #expect(outcome.limits[1].window == .weekly && outcome.limits[1].usedPercent == 20.5)
    #expect(outcome.limits[1].resetsAt == Date(timeIntervalSince1970: 4_070_908_800))
    #expect(outcome.limits[2] == PlanUsageLimit(window: .weekly, model: "Sonnet", usedPercent: 5, resetsAt: Date(timeIntervalSince1970: 4_102_444_800)))

    let scoped = Data("""
    {
      "five_hour": { "utilization": 142 },
      "seven_day_sonnet": null,
      "limits": [
        { "kind": "weekly_scoped", "group": "weekly", "percent": 7, "resets_at": 4102444800000,
          "scope": { "model": { "display_name": "Fable", "id": null }, "surface": null } },
        { "kind": "daily", "percent": 99, "scope": { "model": { "display_name": "Fable" } } },
        { "kind": "weekly_scoped", "percent": 3, "scope": { "model": { "display_name": "Fable" } } }
      ]
    }
    """.utf8)
    let outcome2 = try ClaudePlanUsage.limits(from: scoped)
    #expect(outcome2.limits.map(\.model) == [nil, "Fable"])
    // Clamped to the drawable range.
    #expect(outcome2.limits[0].usedPercent == 100)
    #expect(outcome2.limits[1].usedPercent == 7)
    // Milliseconds are recognised.
    #expect(outcome2.limits[1].resetsAt == Date(timeIntervalSince1970: 4_102_444_800))

    #expect(throws: PlanUsageParseError.invalidJSON) { try ClaudePlanUsage.limits(from: Data("[]".utf8)) }
    #expect(throws: PlanUsageParseError.noLimits) { try ClaudePlanUsage.limits(from: Data("{\"five_hour\":{\"utilization\":true}}".utf8)) }
}

// MARK: Codex

private func jwt(_ claims: [String: Any]) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: claims)
    let segment = payload.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "eyJhbGciOiJub25lIn0.\(segment).sig"
}

@Test func codexAuthDecodesTokensAndClaims() throws {
    let access = jwt(["exp": 1_800_000_900, "https://api.openai.com/auth": ["chatgpt_account_id": "acct-from-claim"]])
    let id = jwt(["email": "me@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": "acct-from-claim"]])
    let withAccount = Data("""
    {"OPENAI_API_KEY": null, "auth_mode": "chatgpt", "last_refresh": "2026-08-29T12:54:00Z",
     "tokens": {"access_token": "\(access)", "account_id": "acct-1", "id_token": "\(id)", "refresh_token": "r"}}
    """.utf8)
    guard case let .signedIn(auth) = CodexAuth.read(fileData: withAccount) else { Issue.record("expected signedIn"); return }
    #expect(auth.accessToken == access)
    #expect(auth.accountID == "acct-1")
    #expect(auth.email == "me@example.com")
    #expect(auth.expiresAt == Date(timeIntervalSince1970: 1_800_000_900))
    #expect(!auth.isExpired(now: now))
    #expect(auth.isExpired(now: now.addingTimeInterval(601)))

    let claimOnly = Data("{\"tokens\": {\"access_token\": \"opaque\", \"id_token\": \"\(id)\"}}".utf8)
    guard case let .signedIn(auth2) = CodexAuth.read(fileData: claimOnly) else { Issue.record("expected signedIn"); return }
    #expect(auth2.accountID == "acct-from-claim")
    // An opaque token has no `exp`: never treated as expired here; the service answers 401 instead.
    #expect(auth2.expiresAt == nil && !auth2.isExpired(now: now))

    #expect(CodexAuth.read(fileData: Data("{\"OPENAI_API_KEY\": \"sk-x\"}".utf8)) == .apiKeyOnly)
    #expect(CodexAuth.read(fileData: Data("{}".utf8)) == .unusable)
    #expect(CodexAuth.read(fileData: Data("nope".utf8)) == .unusable)
    #expect(JWTPayload(token: "one-part") == nil)
}

@Test func codexUsageRequestCarriesTheAccount() {
    let request = CodexPlanUsage.usageRequest(token: "tok", accountID: "acct-1")
    #expect(request.url == URL(string: "https://chatgpt.com/backend-api/wham/usage"))
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "OpenUsage")
    #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-1")
    #expect(CodexPlanUsage.usageRequest(token: "tok", accountID: nil).value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
}

@Test func codexLimitsClassifyWindowsByDuration() throws {
    let body = Data("""
    {
      "plan_type": "prolite",
      "rate_limit": {
        "primary_window": { "used_percent": 5, "limit_window_seconds": 18000, "reset_after_seconds": 3600, "reset_at": 1800003600 },
        "secondary_window": { "used_percent": 10, "limit_window_seconds": 604800, "reset_after_seconds": 86400 }
      },
      "additional_rate_limits": [{ "limit_name": "GPT-5.3-Codex-Spark", "rate_limit": { "primary_window": { "used_percent": 99 } } }],
      "credits": { "balance": 100 }
    }
    """.utf8)
    let outcome = try CodexPlanUsage.limits(from: body, now: now)
    #expect(outcome.limits == [
        PlanUsageLimit(window: .session, usedPercent: 5, resetsAt: Date(timeIntervalSince1970: 1_800_003_600)),
        PlanUsageLimit(window: .weekly, usedPercent: 10, resetsAt: now.addingTimeInterval(86_400)),
    ])
    #expect(CodexPlanUsage.planLabel(from: body) == "Pro 5x")

    // A lone weekly limit moved into the primary slot is still weekly.
    let swapped = Data(#"{"rate_limit": {"primary_window": {"used_percent": 33, "limit_window_seconds": 604800}}}"#.utf8)
    #expect(try CodexPlanUsage.limits(from: swapped, now: now).limits == [PlanUsageLimit(window: .weekly, usedPercent: 33)])

    // No durations: slot order decides; a missing percent comes from the header.
    let slots = Data(#"{"rate_limit": {"primary_window": {"reset_after_seconds": 10}, "secondary_window": {"used_percent": "12.5"}}}"#.utf8)
    let fromHeaders = try CodexPlanUsage.limits(from: slots, headers: ["X-Codex-Primary-Used-Percent": "7"], now: now)
    #expect(fromHeaders.limits == [
        PlanUsageLimit(window: .session, usedPercent: 7, resetsAt: now.addingTimeInterval(10)),
        PlanUsageLimit(window: .weekly, usedPercent: 12.5),
    ])

    #expect(CodexPlanUsage.planLabel(from: Data(#"{"plan_type": "pro"}"#.utf8)) == "Pro 20x")
    #expect(CodexPlanUsage.planLabel(from: Data(#"{"plan_type": "team_enterprise"}"#.utf8)) == "Team Enterprise")
    #expect(CodexPlanUsage.planLabel(from: Data("{}".utf8)) == nil)
    #expect(throws: PlanUsageParseError.noLimits) { try CodexPlanUsage.limits(from: Data("{}".utf8), now: now) }
}
