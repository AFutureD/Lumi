import IPCClient
import Foundation

public struct DaemonConfiguration: Hashable, Sendable {
    public let supportDirectory: URL
    /// The daemon's own state lives one level below the shared support root
    /// (`Lumi/Lumen/`): the database and the relay host state. The socket and
    /// the installed helper stay at the root — they are shared contracts.
    public let daemonDirectory: URL
    public let socketPath: String
    public let databasePath: String
    public let codexSessionsDirectory: URL
    /// Codex moves finished rollouts here (`codex archive`); their usage
    /// still counts.
    public let codexArchivedSessionsDirectory: URL
    /// `~/.claude/projects` (or `$CLAUDE_CONFIG_DIR/projects`): every
    /// project's transcripts and subagent sidechains.
    public let claudeProjectsDirectory: URL
    public let rolloutPollIntervalSeconds: Double
    /// How often the usage scanner re-lists the transcript roots.
    public let usagePollIntervalSeconds: Double
    /// Cached models.dev `api.json` (`Lumen/models-dev.json`). `LUMI_MODEL_PRICES=0`
    /// keeps the daemon from fetching it (tests, smoke runs, offline).
    public let modelPricesPath: String
    public let modelPricesFetchEnabled: Bool
    /// The Relay the daemon registers with as the host; paired iPhones sync
    /// through it. Override with `LUMI_RELAY_URL`; `LUMI_RELAY=0`
    /// keeps the daemon off the network (tests, smoke runs).
    public let relayURL: URL
    public let relayEnabled: Bool
    /// Per-device send sequences and pinned device keys (`relay-host-state.json`, 0600).
    public let relayStatePath: String
    /// Keychain service of the daemon's Relay host credentials. Override with
    /// `LUMI_RELAY_KEYCHAIN_SERVICE` so an isolated daemon (smoke
    /// runs against a local Relay) never touches the installed one's identity.
    public let relayCredentialService: String
    /// The Mach service this daemon answers wakes on (`DaemonWakeListener`),
    /// `nil` when it is not the registered daemon — `swift run`, smoke runs
    /// and tests. launchd sets `XPC_SERVICE_NAME` to the job's label, and
    /// only that job owns the name. `LUMI_WAKE_SERVICE` overrides it (an
    /// isolated launchd job) or disables it with `0`.
    public let wakeService: String?

    public static let defaultRelayURL = URL(string: "https://relay.lumi.huanan.app")!

    public init(
        supportDirectory: URL,
        socketPath: String,
        databasePath: String,
        codexSessionsDirectory: URL,
        codexArchivedSessionsDirectory: URL? = nil,
        claudeProjectsDirectory: URL? = nil,
        rolloutPollIntervalSeconds: Double = 2,
        usagePollIntervalSeconds: Double = 30,
        modelPricesPath: String? = nil,
        modelPricesFetchEnabled: Bool = true,
        relayURL: URL = DaemonConfiguration.defaultRelayURL,
        relayEnabled: Bool = true,
        relayStatePath: String? = nil,
        relayCredentialService: String = KeychainRelayHostCredentialStore.defaultService,
        wakeService: String? = nil
    ) {
        self.supportDirectory = supportDirectory
        let daemonDirectory = supportDirectory.appendingPathComponent(
            LumiPaths.daemonSubdirectory,
            isDirectory: true
        )
        self.daemonDirectory = daemonDirectory
        self.socketPath = socketPath
        self.databasePath = databasePath
        self.codexSessionsDirectory = codexSessionsDirectory
        self.codexArchivedSessionsDirectory = codexArchivedSessionsDirectory
            ?? codexSessionsDirectory.deletingLastPathComponent().appendingPathComponent("archived_sessions", isDirectory: true)
        self.claudeProjectsDirectory = claudeProjectsDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        self.rolloutPollIntervalSeconds = rolloutPollIntervalSeconds
        self.usagePollIntervalSeconds = usagePollIntervalSeconds
        self.modelPricesPath = modelPricesPath ?? daemonDirectory.appendingPathComponent("models-dev.json").path
        self.modelPricesFetchEnabled = modelPricesFetchEnabled
        self.relayURL = relayURL
        self.relayEnabled = relayEnabled
        self.relayStatePath = relayStatePath ?? daemonDirectory.appendingPathComponent("relay-host-state.json").path
        self.relayCredentialService = relayCredentialService
        self.wakeService = wakeService
    }

    public static func `default`(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationSupportDirectory: URL = LumiPaths.applicationSupportBase()
    ) -> DaemonConfiguration {
        let supportDirectory = LumiPaths.supportDirectory(
            environment: environment,
            applicationSupportDirectory: applicationSupportDirectory
        )
        let databasePath = environment["LUMI_DATABASE"]
            ?? supportDirectory
                .appendingPathComponent(LumiPaths.daemonSubdirectory, isDirectory: true)
                .appendingPathComponent("sessions.sqlite3")
                .path
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let claudeHome = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".claude", isDirectory: true)

        return DaemonConfiguration(
            supportDirectory: supportDirectory,
            socketPath: DaemonEndpoint.defaultSocketPath(
                environment: environment,
                applicationSupportDirectory: applicationSupportDirectory
            ),
            databasePath: databasePath,
            codexSessionsDirectory: codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexArchivedSessionsDirectory: codexHome.appendingPathComponent("archived_sessions", isDirectory: true),
            claudeProjectsDirectory: claudeHome.appendingPathComponent("projects", isDirectory: true),
            modelPricesFetchEnabled: !["0", "false", "no"].contains(
                (environment["LUMI_MODEL_PRICES"] ?? "").lowercased()
            ),
            relayURL: environment["LUMI_RELAY_URL"].flatMap(URL.init(string:)) ?? defaultRelayURL,
            relayEnabled: !["0", "false", "no"].contains(
                (environment["LUMI_RELAY"] ?? "").lowercased()
            ),
            relayStatePath: environment["LUMI_RELAY_STATE"],
            relayCredentialService: environment["LUMI_RELAY_KEYCHAIN_SERVICE"].flatMap { $0.isEmpty ? nil : $0 }
                ?? KeychainRelayHostCredentialStore.defaultService,
            wakeService: wakeService(environment: environment)
        )
    }

    /// The registered daemon answers on the shared name; an isolated one
    /// (socket or support overrides) never claims it, whoever launched it.
    static func wakeService(environment: [String: String]) -> String? {
        if let override = environment["LUMI_WAKE_SERVICE"], !override.isEmpty {
            return ["0", "false", "no"].contains(override.lowercased()) ? nil : override
        }
        guard environment["XPC_SERVICE_NAME"] == DaemonEndpoint.machServiceName else { return nil }
        return DaemonEndpoint.defaultWakeService(environment: environment)
    }

    public func prepareFileSystem() throws {
        for directory in [supportDirectory, daemonDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
    }
}
