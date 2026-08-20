import AgentStatusIPCClient
import Foundation

public struct AgentStatusConfiguration: Hashable, Sendable {
    public let supportDirectory: URL
    public let socketPath: String
    public let databasePath: String
    public let codexSessionsDirectory: URL
    public let rolloutPollIntervalSeconds: Double
    /// The in-daemon rollout tailer is a fallback; the helper now reads the
    /// transcript on every hook. Enable with `AGENT_STATUS_ROLLOUT_WATCHER=1`.
    public let rolloutWatcherEnabled: Bool
    /// Polls active Claude sessions' transcripts for records no hook delivers
    /// (a user interrupt fires no hook). On by default; disable with
    /// `AGENT_STATUS_CLAUDE_WATCHER=0`.
    public let claudeWatcherEnabled: Bool

    public init(
        supportDirectory: URL,
        socketPath: String,
        databasePath: String,
        codexSessionsDirectory: URL,
        rolloutPollIntervalSeconds: Double = 2,
        rolloutWatcherEnabled: Bool = false,
        claudeWatcherEnabled: Bool = true
    ) {
        self.supportDirectory = supportDirectory
        self.socketPath = socketPath
        self.databasePath = databasePath
        self.codexSessionsDirectory = codexSessionsDirectory
        self.rolloutPollIntervalSeconds = rolloutPollIntervalSeconds
        self.rolloutWatcherEnabled = rolloutWatcherEnabled
        self.claudeWatcherEnabled = claudeWatcherEnabled
    }

    public static func `default`(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AgentStatusConfiguration {
        let supportDirectory = environment["AGENT_STATUS_SUPPORT_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent("Library/Application Support/Agent Status", isDirectory: true)
        let databasePath = environment["AGENT_STATUS_DATABASE"]
            ?? supportDirectory.appendingPathComponent("sessions.sqlite3").path
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)

        return AgentStatusConfiguration(
            supportDirectory: supportDirectory,
            socketPath: DaemonEndpoint.defaultSocketPath(
                environment: environment,
                homeDirectory: homeDirectory
            ),
            databasePath: databasePath,
            codexSessionsDirectory: codexHome.appendingPathComponent("sessions", isDirectory: true),
            rolloutWatcherEnabled: ["1", "true", "yes"].contains(
                (environment["AGENT_STATUS_ROLLOUT_WATCHER"] ?? "").lowercased()
            ),
            claudeWatcherEnabled: !["0", "false", "no"].contains(
                (environment["AGENT_STATUS_CLAUDE_WATCHER"] ?? "").lowercased()
            )
        )
    }

    public func prepareFileSystem() throws {
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: supportDirectory.path
        )
    }
}
