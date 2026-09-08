import Core
import Diagnostics
import Logging
import ServiceLifecycle
import Transport
import Foundation

private let log = Logger(label: "lifecycle")

/// Keeps one plan-usage snapshot per tracked sign-in: every poll re-reads
/// the agent's own sign-in file (so an external re-login is picked up),
/// asks the provider's usage endpoint with that token when the account is
/// switched on, and remembers the answer. Never refreshes or writes a
/// token: an expired one is reported as such and left to the agent.
///
/// Failures keep the last good limits — the Notch must not blank on a
/// transient error — and are recorded in the account's status and the log.
/// Tokens, emails and response bodies never reach the log.
public actor PlanUsageService: Service {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Reads Claude Code's Keychain item; injected so tests never touch the
    /// login Keychain.
    public typealias KeychainRead = @Sendable () -> ClaudeKeychainCredentials.Outcome

    public static let defaultPollIntervalSeconds: Double = 5 * 60
    /// A 429 without `retry-after` waits this long.
    public static let defaultRateLimitCooldown: TimeInterval = 5 * 60

    public struct Paths: Hashable, Sendable {
        public var claudeCredentials: String
        public var claudeState: String
        /// Keychain services tried when the credentials file is absent, most
        /// specific first (`ClaudeKeychainCredentials.serviceCandidates`).
        public var claudeKeychainServices: [String]
        public var codexAuth: String

        public init(
            claudeCredentials: String,
            claudeState: String,
            claudeKeychainServices: [String] = [ClaudeKeychainCredentials.baseService],
            codexAuth: String
        ) {
            self.claudeCredentials = claudeCredentials
            self.claudeState = claudeState
            self.claudeKeychainServices = claudeKeychainServices
            self.codexAuth = codexAuth
        }
    }

    private let paths: Paths
    private let fetchEnabled: Bool
    private let fetch: Fetch
    private let readKeychain: KeychainRead
    private let pollIntervalSeconds: Double
    /// The switches, from the daemon's settings table (`plan_usage.enabled.*`);
    /// `apply` keeps them current after `set_settings`.
    private var enabledAccounts: Set<PlanUsageAccountID>
    private var accounts: [PlanUsageAccountID: PlanUsageAccount] = [:]
    /// A failed `security` run is not repeated on every ask (the Mac asks
    /// every minute); the next poll tries again.
    private var keychainFailedUntil: (until: Date, message: String)?
    static let keychainFailureCooldown: TimeInterval = 5 * 60
    /// Stable answer order: Claude first, as the Notch draws it.
    private let order: [PlanUsageAccountID] = [.claude, .codex]

    public init(
        paths: Paths,
        settings: PlanUsageSettings,
        fetchEnabled: Bool,
        fetch: Fetch? = nil,
        readKeychain: KeychainRead? = nil,
        pollIntervalSeconds: Double = PlanUsageService.defaultPollIntervalSeconds
    ) {
        self.paths = paths
        self.enabledAccounts = Set(settings.enabledAccounts)
        self.fetchEnabled = fetchEnabled
        let services = paths.claudeKeychainServices
        self.readKeychain = readKeychain ?? { ClaudeKeychainCredentials.read(services: services) }
        self.fetch = fetch ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http)
        }
        self.pollIntervalSeconds = pollIntervalSeconds
        for id in order {
            accounts[id] = PlanUsageAccount(id: id, provider: id == .claude ? .claude : .codex, enabled: enabledAccounts.contains(id), status: .credentialsMissing)
        }
    }

    public func run() async throws {
        await pollUntilShutdown(everySeconds: pollIntervalSeconds) { await self.refreshAll() }
    }

    public func state(now: Date = Date()) -> PlanUsageState {
        PlanUsageState(accounts: order.compactMap { accounts[$0] }, generatedAt: now)
    }

    /// Every id the service knows; `set_settings` rejects any other.
    public var knownAccounts: [PlanUsageAccountID] { order }

    /// The switches changed (`set_settings`). An account switched on is
    /// fetched right away so the caller's answer already carries limits;
    /// one switched off drops them; the rest are left alone.
    public func apply(_ settings: PlanUsageSettings, now: Date = Date()) async throws {
        let wanted = Set(settings.enabledAccounts)
        if let stranger = wanted.first(where: { accounts[$0] == nil }) {
            throw PlanUsageServiceError.unknownAccount(stranger)
        }
        let changed = wanted.symmetricDifference(enabledAccounts)
        enabledAccounts = wanted
        for id in order where changed.contains(id) {
            let enabled = wanted.contains(id)
            accounts[id]?.enabled = enabled
            if enabled {
                await refresh(id, now: now)
            } else {
                accounts[id]?.limits = []
                accounts[id]?.fetchedAt = nil
                accounts[id]?.retryAt = nil
                if accounts[id]?.status != .credentialsMissing { accounts[id]?.status = .ok }
                accounts[id]?.statusDetail = nil
            }
            log.info("plan_usage_account_switched", metadata: .fields(["account": id.rawValue, "enabled": enabled]))
        }
    }

    /// `localOnly`: re-read the sign-in files without asking the providers —
    /// what `plan_usage` does on every request, so a fresh sign-in shows up
    /// as soon as the Mac asks instead of at the next poll. An account whose
    /// file has just appeared is fetched anyway (once): that is the moment
    /// the user is waiting for.
    public func refreshAll(now: Date = Date(), localOnly: Bool = false) async {
        for id in order {
            await refresh(id, now: now, localOnly: localOnly)
        }
    }

    // MARK: - One account

    /// The account's identity always comes from the local files; the
    /// network is only touched for an enabled account with a live token.
    func refresh(_ id: PlanUsageAccountID, now: Date, localOnly: Bool = false) async {
        guard var account = accounts[id] else { return }
        let hadCredentials = account.status != .credentialsMissing
        account.enabled = enabledAccounts.contains(id)
        let credential: Credential
        switch id {
        case .claude: credential = await readClaude(into: &account, now: now)
        case .codex: credential = readCodex(into: &account)
        default: return
        }
        defer { accounts[id] = account }

        switch credential {
        case let .missing(detail):
            account.status = .credentialsMissing
            account.statusDetail = detail
            account.limits = []
            account.fetchedAt = nil
            account.retryAt = nil
            return
        case let .unusable(detail):
            account.status = .failed
            account.statusDetail = detail
            return
        case let .token(token, accountID, expiresAt):
            guard account.enabled else {
                // Off: identity only. Any stale verdict from an earlier
                // enabled period is cleared so the row reads "ready".
                if account.status != .ok { account.status = .ok; account.statusDetail = nil }
                return
            }
            if PlanUsageTokenExpiry.isExpired(expiresAt, now: now) {
                account.status = .signInExpired
                account.statusDetail = nil
                return
            }
            if account.status == .rateLimited, let retryAt = account.retryAt, retryAt > now { return }
            if localOnly, hadCredentials { return }
            if !hadCredentials { account.status = .ok; account.statusDetail = nil }
            guard fetchEnabled else { return }
            let request = id == .claude
                ? ClaudePlanUsage.usageRequest(token: token)
                : CodexPlanUsage.usageRequest(token: token, accountID: accountID)
            await perform(request, for: id, into: &account, now: now)
        }
    }

    private enum Credential {
        case missing(String)
        case unusable(String)
        case token(String, accountID: String?, expiresAt: Date?)
    }

    private func readClaude(into account: inout PlanUsageAccount, now: Date) async -> Credential {
        if let data = FileManager.default.contents(atPath: paths.claudeState),
           let identity = ClaudeAccountIdentity(stateFileData: data) {
            account.email = identity.email
        }
        // The file first (Linux-style and older sign-ins), the Keychain
        // item second (what Claude Code writes on macOS).
        let data: Data
        let source: String
        if let fileData = FileManager.default.contents(atPath: paths.claudeCredentials) {
            data = fileData
            source = abbreviated(paths.claudeCredentials)
        } else {
            switch await keychainOutcome(now: now) {
            case let .found(keychainData):
                data = keychainData
                source = "the Keychain item"
            case .notFound:
                return .missing("No \(abbreviated(paths.claudeCredentials)) and no Keychain sign-in — sign in with Claude Code first.")
            case let .failed(message):
                return .unusable("Claude Code's Keychain item could not be read: \(message)")
            }
        }
        guard let credentials = ClaudeCredentials(fileData: data) else {
            return .missing("\(source) carries no access token.")
        }
        account.plan = credentials.planLabel
        guard credentials.hasUsageScope else {
            return .unusable("The saved sign-in lacks the \(ClaudeCredentials.usageScope) scope; sign in again with Claude Code.")
        }
        return .token(credentials.accessToken, accountID: nil, expiresAt: credentials.expiresAt)
    }

    /// `security` is a subprocess, so it runs off this actor; a failure is
    /// remembered for a while (see `keychainFailedUntil`).
    private func keychainOutcome(now: Date) async -> ClaudeKeychainCredentials.Outcome {
        if let failed = keychainFailedUntil, failed.until > now { return .failed(failed.message) }
        keychainFailedUntil = nil
        let read = readKeychain
        let outcome = await Task.detached(priority: .utility) { read() }.value
        if case let .failed(message) = outcome {
            keychainFailedUntil = (now.addingTimeInterval(Self.keychainFailureCooldown), message)
            log.warning("plan_usage_keychain_read_failed", metadata: .fields(["error": message]))
        }
        return outcome
    }

    private func readCodex(into account: inout PlanUsageAccount) -> Credential {
        guard let data = FileManager.default.contents(atPath: paths.codexAuth) else {
            return .missing("No \(abbreviated(paths.codexAuth)) — sign in with Codex first.")
        }
        switch CodexAuth.read(fileData: data) {
        case let .signedIn(auth):
            account.email = auth.email
            return .token(auth.accessToken, accountID: auth.accountID, expiresAt: auth.expiresAt)
        case .apiKeyOnly:
            return .unusable("Codex is signed in with an API key; plan usage needs a ChatGPT sign-in.")
        case .unusable:
            return .missing("\(abbreviated(paths.codexAuth)) carries no access token.")
        }
    }

    private func perform(_ request: URLRequest, for id: PlanUsageAccountID, into account: inout PlanUsageAccount, now: Date) async {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await fetch(request)
        } catch {
            account.status = .failed
            account.statusDetail = error.localizedDescription
            log.error("plan_usage_fetch_failed", metadata: .fields(["account": id.rawValue, "error": error]))
            return
        }
        switch response.statusCode {
        case 200..<300:
            do {
                let outcome: PlanUsageFetchOutcome
                if id == .claude {
                    outcome = try ClaudePlanUsage.limits(from: data)
                } else {
                    outcome = try CodexPlanUsage.limits(from: data, headers: headerFields(response), now: now)
                    account.plan = CodexPlanUsage.planLabel(from: data) ?? account.plan
                }
                account.limits = outcome.limits
                account.fetchedAt = now
                account.status = .ok
                account.statusDetail = nil
                account.retryAt = nil
                log.info("plan_usage_refreshed", metadata: .fields([
                    "account": id.rawValue, "limits": outcome.limits.count,
                    "windows": outcome.limits.map { limit in
                        limit.model.map { "\(limit.window.rawValue):\($0)" } ?? limit.window.rawValue
                    }.joined(separator: ","),
                ]))
            } catch {
                account.status = .failed
                account.statusDetail = error.localizedDescription
                log.error("plan_usage_fetch_failed", metadata: .fields(["account": id.rawValue, "http": response.statusCode, "error": error]))
            }
        case 401, 403:
            account.status = .signInRejected
            account.statusDetail = "The service rejected the saved sign-in (HTTP \(response.statusCode))."
            log.warning("plan_usage_fetch_failed", metadata: .fields(["account": id.rawValue, "http": response.statusCode]))
        case 429:
            let wait = retryAfter(response) ?? Self.defaultRateLimitCooldown
            account.status = .rateLimited
            account.retryAt = now.addingTimeInterval(wait)
            account.statusDetail = "Rate limited by the service."
            log.warning("plan_usage_fetch_failed", metadata: .fields(["account": id.rawValue, "http": 429, "retry_s": Int(wait)]))
        default:
            account.status = .failed
            account.statusDetail = "HTTP \(response.statusCode)"
            log.error("plan_usage_fetch_failed", metadata: .fields(["account": id.rawValue, "http": response.statusCode]))
        }
    }

    // MARK: - Helpers

    private func headerFields(_ response: HTTPURLResponse) -> [String: String] {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { fields[key] = value }
        }
        return fields
    }

    /// `retry-after` as seconds or an HTTP date.
    private func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "retry-after")?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

public enum PlanUsageServiceError: Error, Hashable, Sendable {
    case unknownAccount(PlanUsageAccountID)
}
