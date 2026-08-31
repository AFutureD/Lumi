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
    public let rolloutPollIntervalSeconds: Double
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

    public static let defaultRelayURL = URL(string: "https://relay.lumi.huanan.app")!

    public init(
        supportDirectory: URL,
        socketPath: String,
        databasePath: String,
        codexSessionsDirectory: URL,
        rolloutPollIntervalSeconds: Double = 2,
        relayURL: URL = DaemonConfiguration.defaultRelayURL,
        relayEnabled: Bool = true,
        relayStatePath: String? = nil,
        relayCredentialService: String = KeychainRelayHostCredentialStore.defaultService
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
        self.rolloutPollIntervalSeconds = rolloutPollIntervalSeconds
        self.relayURL = relayURL
        self.relayEnabled = relayEnabled
        self.relayStatePath = relayStatePath ?? daemonDirectory.appendingPathComponent("relay-host-state.json").path
        self.relayCredentialService = relayCredentialService
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

        return DaemonConfiguration(
            supportDirectory: supportDirectory,
            socketPath: DaemonEndpoint.defaultSocketPath(
                environment: environment,
                applicationSupportDirectory: applicationSupportDirectory
            ),
            databasePath: databasePath,
            codexSessionsDirectory: codexHome.appendingPathComponent("sessions", isDirectory: true),
            relayURL: environment["LUMI_RELAY_URL"].flatMap(URL.init(string:)) ?? defaultRelayURL,
            relayEnabled: !["0", "false", "no"].contains(
                (environment["LUMI_RELAY"] ?? "").lowercased()
            ),
            relayStatePath: environment["LUMI_RELAY_STATE"],
            relayCredentialService: environment["LUMI_RELAY_KEYCHAIN_SERVICE"].flatMap { $0.isEmpty ? nil : $0 }
                ?? KeychainRelayHostCredentialStore.defaultService
        )
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
