import Adapters
import Core
import DaemonRuntime
import Diagnostics
import Logging
import Persistence
import Remote
import Foundation

private let log = Logger(label: "lifecycle")
private let dbLog = Logger(label: "db")

@main
enum LumenMain {
    static func main() async throws {
        let configuration = DaemonConfiguration.default()
        // Logging first: everything after this line, including a failing
        // start, lands in `daemon.log` (and `errors.log`) as well as stderr.
        let logConfiguration = LogConfiguration.fromEnvironment(
            subsystem: "daemon",
            standardErrorPrefix: "Lumen:"
        )
        Diagnostics.bootstrap(logConfiguration)
        do {
            try configuration.prepareFileSystem()
        } catch {
            log.error("support_directory_unavailable", metadata: .fields(["path": configuration.supportDirectory, "error": error]))
            throw error
        }
        let repository: SQLiteSessionRepository
        do {
            repository = try SQLiteSessionRepository(path: configuration.databasePath)
        } catch {
            dbLog.error("database_open_failed", metadata: .fields(["path": configuration.databasePath, "error": error]))
            throw error
        }
        let subscriptions = DaemonSubscriptionHub()
        let executableHash: String
        do {
            executableHash = try ExecutableFingerprint.currentExecutable()
        } catch {
            // An empty hash never matches the bundled binary, so the Mac app's
            // auto-update restarts this process — self-healing over crashing.
            executableHash = ""
            log.error("executable_fingerprint_failed", metadata: .fields(["error": error]))
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
                onEvent: { subscriptions.publish($0) }
            )
            : nil
        let claudeWatcher: ClaudeTranscriptWatcher? = configuration.claudeWatcherEnabled
            ? ClaudeTranscriptWatcher(
                repository: repository,
                pollIntervalSeconds: configuration.rolloutPollIntervalSeconds,
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
                onConnectionChange: { connected in await service.setRelayConnected(connected) }
            )
            : nil
        if let relay { await service.attachRelay(relay) }
        // Histories the helper refuses to replay inside a hook land here.
        let backfill = TranscriptBackfillQueue(
            repository: repository,
            onEvent: { subscriptions.publish($0) }
        )
        await service.attachBackfill(backfill)

        do {
            try await watcher?.prepareInitialBaseline()
            try server.start()
        } catch {
            log.error("daemon_start_failed", metadata: .fields(["socket": configuration.socketPath, "error": error]))
            throw error
        }
        watcher?.start()
        claudeWatcher?.start()
        // Announced before the Relay connects: the socket is already
        // serving, and the first Relay round-trip can take a while.
        log.info("daemon_started", metadata: .fields([
            "version": DaemonService.version,
            "fingerprint": executableHash.isEmpty ? nil : String(executableHash.prefix(12)),
            "socket": configuration.socketPath,
            "database": configuration.databasePath,
            "rollout_watcher": watcher != nil,
            "claude_watcher": claudeWatcher != nil,
            "relay": relay == nil ? "off" : configuration.relayURL.absoluteString,
            "log_level": logConfiguration.minimumLevel.label.lowercased(),
            "log_directory": logConfiguration.directory,
        ]))
        await relay?.start()
        defer {
            claudeWatcher?.stop()
            watcher?.stop()
            server.shutdown()
            log.info("daemon_stopped")
        }
        try server.wait()
        await relay?.stop()
    }
}
