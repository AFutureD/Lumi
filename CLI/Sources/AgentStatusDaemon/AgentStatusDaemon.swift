import AgentStatusCodex
import AgentStatusCore
import AgentStatusDaemonRuntime
import AgentStatusRemote
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
        // The Relay host lives here, not in the Mac app: paired iPhones keep
        // syncing while the app is closed. Credentials are the daemon's own
        // Keychain item; per-device sequences sit next to the database.
        let relay: RelayHostService? = configuration.relayEnabled
            ? RelayHostService(
                repository: repository,
                subscriptions: subscriptions,
                relayURL: configuration.relayURL,
                credentialStore: KeychainRelayHostCredentialStore(service: configuration.relayCredentialService),
                statePath: configuration.relayStatePath,
                transportFactory: RelayWebSocketTransportFactory(),
                rest: LiveRelayHostREST(baseURL: configuration.relayURL),
                healthProvider: { await service.currentHealth() },
                onConnectionChange: { connected in await service.setRelayConnected(connected) },
                logger: { message in
                    FileHandle.standardError.write(Data("agent-status-daemon: \(message)\n".utf8))
                }
            )
            : nil
        if let relay { await service.attachRelay(relay) }

        try await watcher?.prepareInitialBaseline()
        try server.start()
        watcher?.start()
        claudeWatcher?.start()
        await relay?.start()
        FileHandle.standardError.write(Data(
            "agent-status-daemon: listening at \(configuration.socketPath) rollout_watcher=\(watcher == nil ? "off" : "on") claude_watcher=\(claudeWatcher == nil ? "off" : "on") relay=\(relay == nil ? "off" : configuration.relayURL.absoluteString)\n".utf8
        ))
        defer {
            claudeWatcher?.stop()
            watcher?.stop()
            server.shutdown()
        }
        try server.wait()
        await relay?.stop()
    }
}
