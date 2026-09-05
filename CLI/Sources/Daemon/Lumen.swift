import Adapters
import Core
import DaemonRuntime
import Diagnostics
import Logging
import Persistence
import Remote
import ServiceLifecycle
import Transport
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
        // Legacy layout (state at the support root) moves into `Lumen/`
        // before the database opens; a no-op on every start after the first.
        DaemonStorageMigration.run(configuration: configuration)
        // The filter engine is the repository's filter evaluator (consulted
        // on each session's first user message), so it exists first (empty)
        // and gets the stored rules right after the database opens — before
        // anything listens or watches.
        let filterEngine = SessionFilterEngine()
        let repository: SQLiteSessionRepository
        do {
            repository = try SQLiteSessionRepository(
                path: configuration.databasePath,
                sessionFilter: filterEngine
            )
            filterEngine.update(rules: try await repository.sessionFilterRules())
        } catch {
            dbLog.error("database_open_failed", metadata: .fields(["path": configuration.databasePath, "error": error]))
            throw error
        }
        let subscriptions = DaemonSubscriptionHub()
        // Every ingest path publishes through this closure so a session
        // hidden on its first user message follows the triggering event with
        // the stamped summary frame — mirrors apply the event first (their
        // own reduction knows nothing of the rules), then the verdict.
        let publish: @Sendable (AgentIngressEvent) -> Void = { event in
            subscriptions.publish(event)
            if let verdict = filterEngine.takeVerdict(for: event.sessionID) {
                subscriptions.publish(summary: verdict)
            }
        }
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
        // Histories too large for one capped read land here: hook-path cold
        // starts and watcher offline gaps alike.
        let backfill = TranscriptBackfillQueue(
            repository: repository,
            onEvent: publish
        )
        // Both watchers are load-bearing correctness, not options: hook-less
        // tail writes (a Codex `turn_aborted` after an interrupt, a Claude
        // Esc marker) only reach the store through them.
        let watcher = CodexRolloutWatcher(
            rootDirectory: configuration.codexSessionsDirectory,
            repository: repository,
            pollIntervalSeconds: configuration.rolloutPollIntervalSeconds,
            backfill: backfill,
            onEvent: publish
        )
        let claudeWatcher = ClaudeTranscriptWatcher(
            repository: repository,
            pollIntervalSeconds: configuration.rolloutPollIntervalSeconds,
            backfill: backfill,
            onEvent: publish
        )
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
        // Forwarded hook frames: the daemon-side pipeline that reads the rich
        // increment, reduces the hook, and asserts the AaaS wrapper title.
        let hookIngest = HookIngestService(
            repository: repository,
            backfill: backfill,
            codexSessionsDirectory: configuration.codexSessionsDirectory,
            onEvent: publish
        )
        await service.attachHookIngest(hookIngest)
        await service.attachSessionFilters(filterEngine)
        // Usage: independent of Session ingest. The scanner walks the
        // agents' transcript roots into the usage tables of the same
        // database; the price refresher keeps the models.dev table current.
        let usageStore = repository.makeUsageStore()
        let modelPrices = ModelPriceRefresher(
            cachePath: configuration.modelPricesPath,
            fetchEnabled: configuration.modelPricesFetchEnabled
        )
        // The cached table must be in force before the first scan classifies
        // a call's long-context band.
        await modelPrices.loadCache()
        let usageScanner = UsageScanService(
            roots: UsageScanService.roots(
                claudeProjectsDirectory: configuration.claudeProjectsDirectory,
                codexSessionsDirectory: configuration.codexSessionsDirectory,
                codexArchivedSessionsDirectory: configuration.codexArchivedSessionsDirectory
            ),
            store: usageStore,
            priceTable: { await modelPrices.current().table },
            pollIntervalSeconds: configuration.usagePollIntervalSeconds
        )
        await service.attachUsage(store: usageStore, scanner: usageScanner, prices: modelPrices)

        // Ordered, before anything serves: the baseline must exist before a
        // hook frame or the poll loop can touch rollout cursors, and the
        // eager listen means a bad socket path fails the launch outright.
        do {
            try await watcher.prepareInitialBaseline()
            try await server.listen()
        } catch {
            log.error("daemon_start_failed", metadata: .fields(["socket": configuration.socketPath, "error": error]))
            throw error
        }
        // Demand launch: the Mach service answers wakes only once the socket
        // listens, so a reply always means "connect now". Not load-bearing —
        // without it the daemon serves as before; it just cannot be started
        // by a client while launchd holds back non-demand spawns.
        let wakeListener = await activateWakeListener(configuration: configuration)
        // Announced before the Relay connects: the socket is already
        // listening, and the first Relay round-trip can take a while.
        log.info("daemon_started", metadata: .fields([
            "version": DaemonService.version,
            "fingerprint": executableHash.isEmpty ? nil : String(executableHash.prefix(12)),
            "socket": configuration.socketPath,
            "wake": wakeListener == nil ? "off" : configuration.wakeService,
            "database": configuration.databasePath,
            "relay": relay == nil ? "off" : configuration.relayURL.absoluteString,
            "log_level": logConfiguration.minimumLevel.label.lowercased(),
            "log_directory": logConfiguration.directory,
        ]))

        // Shutdown runs in reverse: the wake listener stops answering first
        // (a daemon on its way out must not promise a socket), the Relay
        // detaches, the watchers stop producing, the server drains its
        // connections, and the backfill queue — last — flushes whatever the
        // others enqueued on the way out. SIGTERM (launchd unregister)
        // therefore exits 0 and stays down (KeepAlive.SuccessfulExit=false)
        // until a client wakes it; a service failure exits non-zero and
        // launchd relaunches.
        var services: [any Service] = [backfill, server, watcher, claudeWatcher, usageScanner, modelPrices]
        if let relay { services.append(relay) }
        if let wakeListener { services.append(wakeListener) }
        let group = ServiceGroup(configuration: .init(
            services: services.map { ServiceGroupConfiguration.ServiceConfiguration(service: $0) },
            gracefulShutdownSignals: [.sigterm, .sigint],
            logger: Logger(label: "lifecycle")
        ))
        try await group.run()
        log.info("daemon_stopped")
    }

    private static func activateWakeListener(configuration: DaemonConfiguration) async -> DaemonWakeListener? {
        guard let service = configuration.wakeService else {
            log.info("wake_listener_skipped", metadata: .fields([
                "launchd_label": ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"],
                "socket": configuration.socketPath,
            ]))
            return nil
        }
        let listener = DaemonWakeListener(
            service: service,
            socketPath: configuration.socketPath,
            version: DaemonService.version
        )
        do {
            try await listener.activate()
            return listener
        } catch {
            log.error("wake_listener_failed", metadata: .fields(["service": service, "error": error]))
            return nil
        }
    }
}
