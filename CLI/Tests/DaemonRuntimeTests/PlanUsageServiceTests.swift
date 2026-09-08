import Core
import Foundation
import Synchronization
import Testing
import Transport
@testable import DaemonRuntime

private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// Temp files standing in for the agents' sign-ins, plus a scripted HTTP
/// layer that records every request and answers from a queue.
private final class Harness: Sendable {
    let home: URL
    let paths: PlanUsageService.Paths
    let requests = Mutex<[URLRequest]>([])
    let answers = Mutex<[(Int, [String: String], Data)]>([])
    let keychain = Mutex<ClaudeKeychainCredentials.Outcome>(.notFound)

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("plan-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        paths = PlanUsageService.Paths(
            claudeCredentials: home.appendingPathComponent(".claude/.credentials.json").path,
            claudeState: home.appendingPathComponent(".claude.json").path,
            codexAuth: home.appendingPathComponent(".codex/auth.json").path
        )
    }

    func write(_ path: String, _ text: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func answer(_ status: Int, headers: [String: String] = [:], _ body: String) {
        answers.withLock { $0.append((status, headers, Data(body.utf8))) }
    }

    /// The switches a service starts with — what the daemon reads from its
    /// settings table before constructing the poller.
    let enabled = Mutex<[PlanUsageAccountID]>([])

    func service(fetchEnabled: Bool = true) -> PlanUsageService {
        PlanUsageService(paths: paths, settings: PlanUsageSettings(enabledAccounts: enabled.withLock { $0 }, percentStyle: .used), fetchEnabled: fetchEnabled, fetch: { request in
            self.requests.withLock { $0.append(request) }
            guard let next = self.answers.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else { throw URLError(.notConnectedToInternet) }
            let response = HTTPURLResponse(url: request.url!, statusCode: next.0, httpVersion: nil, headerFields: next.1)!
            return (next.2, response)
        }, readKeychain: { self.keychain.withLock { $0 } }, pollIntervalSeconds: 3_600)
    }

    func signInClaude(expiresAt: Date = now.addingTimeInterval(3_600)) throws {
        try write(paths.claudeCredentials, """
        {"claudeAiOauth":{"accessToken":"claude-token","expiresAt":\(Int(expiresAt.timeIntervalSince1970 * 1_000)),
         "subscriptionType":"max","rateLimitTier":"claude_max_subscription_20x","scopes":["user:profile"]}}
        """)
        try write(paths.claudeState, #"{"oauthAccount":{"emailAddress":"me@example.com"}}"#)
    }

    func signInCodex() throws {
        let claims = Data(#"{"email":"dev@example.com","exp":1800003600}"#.utf8).base64EncodedString()
        let token = "h.\(claims).s"
        try write(paths.codexAuth, #"{"tokens":{"access_token":"\#(token)","account_id":"acct-1","id_token":"\#(token)"}}"#)
    }

    static let claudeBody = """
    {"five_hour":{"utilization":42,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":18},
     "limits":[{"kind":"weekly_scoped","percent":7,"scope":{"model":{"display_name":"Fable"}}}]}
    """
    static let codexBody = """
    {"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000},
     "secondary_window":{"used_percent":3,"limit_window_seconds":604800}}}
    """
}

private func account(_ id: PlanUsageAccountID, in service: PlanUsageService) async throws -> PlanUsageAccount {
    let state = await service.state()
    return try #require(state.account(id))
}


/// `set_settings` as the daemon applies it: the new switch set, then the snapshot.
private func apply(_ enabled: [PlanUsageAccountID], to service: PlanUsageService, harness: Harness, now: Date) async throws -> PlanUsageState {
    harness.enabled.withLock { $0 = enabled }
    try await service.apply(PlanUsageSettings(enabledAccounts: enabled, percentStyle: .used), now: now)
    return await service.state(now: now)
}

@Test func accountsStartFromTheFilesAndOnlyEnabledOnesFetch() async throws {
    let harness = try Harness()
    let service = harness.service()

    // Nothing signed in: both accounts say so, no request goes out.
    await service.refreshAll(now: now)
    var state = await service.state(now: now)
    #expect(state.accounts.map(\.id) == [.claude, .codex])
    #expect(state.accounts.allSatisfy { $0.status == .credentialsMissing && !$0.enabled })
    #expect(state.account(.claude)?.statusDetail?.contains(".credentials.json") == true)
    #expect(harness.requests.withLock { $0.count } == 0)

    // Signed in but switched off: identity and plan, still no request.
    try harness.signInClaude()
    try harness.signInCodex()
    await service.refreshAll(now: now)
    state = await service.state(now: now)
    #expect(state.account(.claude) == PlanUsageAccount(id: .claude, provider: .claude, email: "me@example.com", plan: "Max 20x", enabled: false, status: .ok))
    #expect(state.account(.codex)?.email == "dev@example.com")
    #expect(state.account(.codex)?.status == .ok)
    #expect(harness.requests.withLock { $0.count } == 0)

    // Switching on fetches at once, with the provider's own headers.
    harness.answer(200, Harness.claudeBody)
    state = try await apply([.claude], to: service, harness: harness, now: now)
    let claude = try #require(state.account(.claude))
    #expect(claude.enabled && claude.status == .ok && claude.fetchedAt == now)
    #expect(claude.limits.map(\.usedPercent) == [42, 18, 7])
    #expect(claude.limit(.weekly, model: "Fable")?.usedPercent == 7)
    let request = try #require(harness.requests.withLock { $0.first })
    #expect(request.url == ClaudePlanUsage.usageURL)
    #expect(request.value(forHTTPHeaderField: "User-Agent") == ClaudePlanUsage.userAgent)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer claude-token")

    harness.answer(200, Harness.codexBody)
    state = try await apply([.claude, .codex], to: service, harness: harness, now: now)
    let codex = try #require(state.account(.codex))
    #expect(codex.plan == "Pro 20x")
    #expect(codex.limits == [PlanUsageLimit(window: .session, usedPercent: 12), PlanUsageLimit(window: .weekly, usedPercent: 3)])
    #expect(harness.requests.withLock { $0.last?.value(forHTTPHeaderField: "ChatGPT-Account-Id") } == "acct-1")

    // Switching off drops the limits and stops fetching; a service built
    // from the same switches (the daemon's next start) agrees.
    state = try await apply([.claude], to: service, harness: harness, now: now)
    #expect(state.account(.codex)?.limits.isEmpty == true)
    #expect(state.account(.codex)?.status == .ok)
    let reloaded = harness.service()
    harness.answer(200, Harness.claudeBody)
    await reloaded.refreshAll(now: now)
    let reloadedState = await reloaded.state(now: now)
    #expect(reloadedState.account(.claude)?.enabled == true)
    #expect(reloadedState.account(.codex)?.enabled == false)
    #expect(harness.requests.withLock { $0.count } == 3)

    await #expect(throws: PlanUsageServiceError.unknownAccount(PlanUsageAccountID("gemini"))) {
        try await service.apply(PlanUsageSettings(enabledAccounts: [.claude, PlanUsageAccountID("gemini")], percentStyle: .used), now: now)
    }
    // A rejected set leaves the switches as they were.
    #expect(await service.state(now: now).account(.claude)?.enabled == true)
}

@Test func failuresKeepTheLastLimitsAndSayWhy() async throws {
    let harness = try Harness()
    try harness.signInClaude()
    let service = harness.service()
    harness.answer(200, Harness.claudeBody)
    _ = try await apply([.claude], to: service, harness: harness, now: now)

    // 5xx: limits stay, status says failed.
    harness.answer(503, "down")
    await service.refreshAll(now: now.addingTimeInterval(300))
    var claude = try await account(.claude, in: service)
    #expect(claude.status == .failed && claude.statusDetail == "HTTP 503")
    #expect(claude.limits.count == 3 && claude.fetchedAt == now)

    // 429 with retry-after: a cooldown during which no request is sent.
    harness.answer(429, headers: ["Retry-After": "120"], "")
    let limited = now.addingTimeInterval(600)
    await service.refreshAll(now: limited)
    claude = try await account(.claude, in: service)
    #expect(claude.status == .rateLimited && claude.retryAt == limited.addingTimeInterval(120))
    let requestsBefore = harness.requests.withLock { $0.count }
    await service.refreshAll(now: limited.addingTimeInterval(60))
    #expect(harness.requests.withLock { $0.count } == requestsBefore)
    harness.answer(200, Harness.claudeBody)
    await service.refreshAll(now: limited.addingTimeInterval(121))
    claude = try await account(.claude, in: service)
    #expect(claude.status == .ok && claude.retryAt == nil)

    // 401: the saved sign-in is rejected; a transport error is `failed`.
    harness.answer(401, "")
    await service.refreshAll(now: now)
    #expect(try await account(.claude, in: service).status == .signInRejected)
    await service.refreshAll(now: now)
    claude = try await account(.claude, in: service)
    #expect(claude.status == .failed && claude.limits.count == 3)

    // An expired token is reported without a request; an unparsable body too.
    let before = harness.requests.withLock { $0.count }
    try harness.signInClaude(expiresAt: now.addingTimeInterval(60))
    await service.refreshAll(now: now)
    #expect(try await account(.claude, in: service).status == .signInExpired)
    #expect(harness.requests.withLock { $0.count } == before)
    try harness.signInClaude()
    harness.answer(200, "{}")
    await service.refreshAll(now: now)
    claude = try await account(.claude, in: service)
    #expect(claude.status == .failed && claude.statusDetail == PlanUsageParseError.noLimits.errorDescription)

    // Removing the file while enabled: credentials missing, limits gone.
    try FileManager.default.removeItem(atPath: harness.paths.claudeCredentials)
    await service.refreshAll(now: now)
    claude = try await account(.claude, in: service)
    #expect(claude.status == .credentialsMissing && claude.limits.isEmpty && claude.enabled)
}

@Test func aFreshSignInShowsUpOnTheNextAskWithoutPolling() async throws {
    let harness = try Harness()
    let service = harness.service()
    await service.refreshAll(now: now)
    #expect(await service.state().account(.codex)?.status == .credentialsMissing)

    // Off: the ask re-reads the file, reports the identity, sends nothing.
    try harness.signInCodex()
    await service.refreshAll(now: now, localOnly: true)
    var codex = try await account(.codex, in: service)
    #expect(codex.status == .ok && codex.email == "dev@example.com" && codex.limits.isEmpty)
    #expect(harness.requests.withLock { $0.count } == 0)

    // On, file removed then restored: the local ask notices the file and fetches once.
    harness.answer(200, Harness.codexBody)
    _ = try await apply([.codex], to: service, harness: harness, now: now)
    try FileManager.default.removeItem(atPath: harness.paths.codexAuth)
    await service.refreshAll(now: now, localOnly: true)
    #expect(try await account(.codex, in: service).status == .credentialsMissing)
    try harness.signInCodex()
    harness.answer(200, Harness.codexBody)
    await service.refreshAll(now: now, localOnly: true)
    codex = try await account(.codex, in: service)
    #expect(codex.status == .ok && codex.limits.count == 2)
    #expect(harness.requests.withLock { $0.count } == 2)
    // A plain local ask while signed in and on stays off the network.
    await service.refreshAll(now: now, localOnly: true)
    #expect(harness.requests.withLock { $0.count } == 2)
}

@Test func claudeFallsBackToTheKeychainItem() async throws {
    let harness = try Harness()
    let service = harness.service()
    let item = Data(#"{"claudeAiOauth":{"accessToken":"kc-token","expiresAt":1800003600000,"subscriptionType":"pro","scopes":["user:profile"]}}"#.utf8)

    harness.keychain.withLock { $0 = .found(item) }
    harness.answer(200, Harness.claudeBody)
    var state = try await apply([.claude], to: service, harness: harness, now: now)
    #expect(state.account(.claude)?.status == .ok)
    #expect(state.account(.claude)?.plan == "Pro")
    #expect(harness.requests.withLock { $0.first?.value(forHTTPHeaderField: "Authorization") } == "Bearer kc-token")

    // The file wins when both exist.
    try harness.signInClaude()
    harness.answer(200, Harness.claudeBody)
    await service.refreshAll(now: now)
    #expect(harness.requests.withLock { $0.last?.value(forHTTPHeaderField: "Authorization") } == "Bearer claude-token")
    try FileManager.default.removeItem(atPath: harness.paths.claudeCredentials)

    // A `security` failure is reported, not read as "not signed in".
    harness.keychain.withLock { $0 = .failed("security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.") }
    await service.refreshAll(now: now)
    state = await service.state()
    #expect(state.account(.claude)?.status == .failed)
    #expect(state.account(.claude)?.statusDetail?.hasPrefix("Claude Code's Keychain item could not be read") == true)
    #expect(state.account(.claude)?.limits.count == 3)

    // Inside the failure cooldown `security` is not run again.
    harness.keychain.withLock { $0 = .notFound }
    await service.refreshAll(now: now.addingTimeInterval(60))
    #expect(try await account(.claude, in: service).status == .failed)
    await service.refreshAll(now: now.addingTimeInterval(PlanUsageService.keychainFailureCooldown + 1))
    #expect(try await account(.claude, in: service).status == .credentialsMissing)

    // `security -w` output: JSON as-is, hex when it will not print the value.
    let json = #"{"claudeAiOauth":{"accessToken":"t"}}"#
    #expect(ClaudeKeychainCredentials.decodeSecurityOutput(Data((json + "\n").utf8)) == Data(json.utf8))
    let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
    #expect(ClaudeKeychainCredentials.decodeSecurityOutput(Data((hex + "\n").utf8)) == Data(json.utf8))
    #expect(ClaudeKeychainCredentials.decodeSecurityOutput(Data("\n".utf8)) == nil)

    #expect(ClaudeKeychainCredentials.serviceCandidates(configDirectory: nil) == ["Claude Code-credentials"])
    let custom = ClaudeKeychainCredentials.serviceCandidates(configDirectory: "/Users/me/.claude-work")
    #expect(custom.count == 2 && custom[0].hasPrefix("Claude Code-credentials-") && custom[0].count == "Claude Code-credentials-".count + 8 && custom[1] == "Claude Code-credentials")
}

@Test func fetchingCanBeSwitchedOffForSmokeRuns() async throws {
    let harness = try Harness()
    try harness.signInCodex()
    let service = harness.service(fetchEnabled: false)
    let state = try await apply([.codex], to: service, harness: harness, now: now)
    #expect(state.account(.codex)?.enabled == true)
    #expect(state.account(.codex)?.limits.isEmpty == true)
    #expect(harness.requests.withLock { $0.count } == 0)
}

@Test func serviceAnswersPlanUsageAndSettingsOverIPC() async throws {
    let harness = try Harness()
    try harness.signInCodex()
    let planUsage = harness.service()
    let repository = InMemorySessionRepository()
    let settings = InMemorySettingsStore()
    let service = DaemonService(repository: repository, socketPath: "/tmp/lumi.sock", executableHash: "test-hash")
    await service.attachPlanUsage(planUsage)
    await service.attachSettings(store: settings)

    let initial = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .planUsage)))
    #expect(initial.payload.status == .ok)
    #expect(initial.payload.planUsage?.accounts.map(\.id) == [.claude, .codex])
    let defaults = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .getSettings)))
    #expect(defaults.payload.settings == .defaults)

    // Switching Codex on through settings fetches at once; the answer is what was stored.
    harness.answer(200, Harness.codexBody)
    let wanted = DaemonSettings(planUsage: PlanUsageSettings(enabledAccounts: [.codex], percentStyle: .remaining))
    let switched = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .setSettings, settings: wanted)))
    #expect(switched.payload.settings == wanted)
    #expect(try await settings.settings() == wanted)
    let after = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .planUsage)))
    #expect(after.payload.planUsage?.account(.codex)?.limits.count == 2)
    #expect(after.payload.planUsage?.account(.codex)?.enabled == true)

    let missing = await service.handle(TransportEnvelope(payload: IPCRequest(operation: .setSettings)))
    #expect(missing.payload.failure?.code == "missing_settings")
    let unknown = await service.handle(TransportEnvelope(payload: IPCRequest(
        operation: .setSettings,
        settings: DaemonSettings(planUsage: PlanUsageSettings(enabledAccounts: [PlanUsageAccountID("x")], percentStyle: .used))
    )))
    #expect(unknown.payload.failure?.code == "invalid_settings")
    #expect(try await settings.settings() == wanted)

    // The Relay snapshot re-reads the files and carries the settings.
    let snapshot = try await service.planUsageSnapshot()
    #expect(snapshot.settings == wanted && snapshot.state.account(.codex)?.limits.count == 2)

    let bare = DaemonService(repository: repository, socketPath: "/tmp/lumi.sock", executableHash: "test-hash")
    let unavailable = await bare.handle(TransportEnvelope(payload: IPCRequest(operation: .planUsage)))
    #expect(unavailable.payload.failure?.code == "plan_usage_unavailable")
    #expect(await bare.handle(TransportEnvelope(payload: IPCRequest(operation: .getSettings))).payload.failure?.code == "settings_unavailable")
}

@Test func legacySettingsFileIsImportedOnceThenRemoved() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-plan-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("plan-usage-settings.json").path
    try Data(#"{"enabled":{"claude":true,"codex":false}}"#.utf8).write(to: URL(fileURLWithPath: path))
    let store = InMemorySettingsStore()
    try await LegacyPlanUsageSettingsImport.run(path: path, into: store)
    #expect(try await store.settings().planUsage.enabledAccounts == [.claude])
    #expect(!FileManager.default.fileExists(atPath: path))

    // A file left behind after the table already holds switches is stale: removed, not applied.
    try Data(#"{"enabled":{"codex":true}}"#.utf8).write(to: URL(fileURLWithPath: path))
    try await LegacyPlanUsageSettingsImport.run(path: path, into: store)
    #expect(try await store.settings().planUsage.enabledAccounts == [.claude])
    #expect(!FileManager.default.fileExists(atPath: path))
    // No file: nothing to do.
    try await LegacyPlanUsageSettingsImport.run(path: path, into: store)
}
