import AgentStatusCodex
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
        let executableHash: String
        do {
            executableHash = try ExecutableFingerprint.currentExecutable()
        } catch {
            // An empty hash never matches the bundled binary, so the Mac app's
            // auto-update restarts this process — self-healing over crashing.
            executableHash = ""
            FileHandle.standardError.write(Data(
                "agent-status-daemon: executable fingerprint failed: \(error)\n".utf8
            ))
        }
        let service = DaemonService(
            repository: repository,
            socketPath: configuration.socketPath,
            executableHash: executableHash,
            subscriptions: subscriptions,
            reingester: SessionReingester(
                repository: repository,
                codexSessionsDirectory: configuration.codexSessionsDirectory
            )
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
        let claudeWatcher: ClaudeTranscriptWatcher? = configuration.claudeWatcherEnabled
            ? ClaudeTranscriptWatcher(
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
        claudeWatcher?.start()
        FileHandle.standardError.write(Data(
            "agent-status-daemon: listening at \(configuration.socketPath) rollout_watcher=\(watcher == nil ? "off" : "on") claude_watcher=\(claudeWatcher == nil ? "off" : "on")\n".utf8
        ))
        defer {
            claudeWatcher?.stop()
            watcher?.stop()
            server.shutdown()
        }
        try server.wait()
    }
}
