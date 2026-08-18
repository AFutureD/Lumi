import AgentStatusCore
import AgentStatusDaemonRuntime
import Foundation

@main
enum AgentStatusDaemonMain {
    static func main() async throws {
        let configuration = AgentStatusConfiguration.default()
        try configuration.prepareFileSystem()
        let repository = try SQLiteSessionRepository(path: configuration.databasePath)
        let subscriptions = DaemonSubscriptionHub()
        let service = DaemonService(
            repository: repository,
            socketPath: configuration.socketPath,
            subscriptions: subscriptions
        )
        let watcher: CodexRolloutWatcher? = configuration.rolloutWatcherEnabled
            ? CodexRolloutWatcher(
                rootDirectory: configuration.codexSessionsDirectory,
                repository: repository,
                pollIntervalSeconds: configuration.rolloutPollIntervalSeconds,
                logger: { message in
                    FileHandle.standardError.write(Data("agent-status-daemon: \(message)\n".utf8))
                },
                onEvent: { subscriptions.publish($0) }
            )
            : nil
        let server = DaemonServer(socketPath: configuration.socketPath, service: service)

        try await watcher?.prepareInitialBaseline()
        try server.start()
        watcher?.start()
        FileHandle.standardError.write(Data(
            "agent-status-daemon: listening at \(configuration.socketPath) rollout_watcher=\(watcher == nil ? "off" : "on")\n".utf8
        ))
        defer {
            watcher?.stop()
            server.shutdown()
        }
        try server.wait()
    }
}
