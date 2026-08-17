import AgentStatusIPCClient
import Foundation

public struct AgentStatusConfiguration: Hashable, Sendable {
    public let supportDirectory: URL
    public let socketPath: String
    public let databasePath: String
    public let codexSessionsDirectory: URL
    public let rolloutPollIntervalSeconds: Double

    public init(
        supportDirectory: URL,
        socketPath: String,
        databasePath: String,
        codexSessionsDirectory: URL,
        rolloutPollIntervalSeconds: Double = 2
    ) {
        self.supportDirectory = supportDirectory
        self.socketPath = socketPath
        self.databasePath = databasePath
        self.codexSessionsDirectory = codexSessionsDirectory
        self.rolloutPollIntervalSeconds = rolloutPollIntervalSeconds
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
            codexSessionsDirectory: codexHome.appendingPathComponent("sessions", isDirectory: true)
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
