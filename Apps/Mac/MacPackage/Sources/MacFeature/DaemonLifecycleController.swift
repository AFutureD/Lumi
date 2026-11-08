import Core
import Diagnostics
import Logging
import ServiceManagement
import Transport
import Foundation

private let log = Logger(label: "lifecycle")

/// The one owner of what happens to the installed daemon: the launch-time
/// check that replaces a stale or unreachable daemon, and the Settings
/// panel's Install / Reinstall / Stop.
///
/// Three rules, from the daemon lifecycle model (docs/research):
/// - Nothing automatic from a development build or against an isolated
///   daemon (`DaemonManagementPolicy`): the registration and the installed
///   helper are shared by every copy of Lumi on this Mac.
/// - Only a daemon running from this app's own bundled `Lumen` is replaced
///   on sight; one running from another bundle is reported, not touched.
/// - A restart is judged on a fresh `health` probe, never on the store's
///   last reading (a slow reconcile may still be writing the old one), and
///   it counts as done only when a different process answers with the
///   bundled fingerprint.
///
/// One operation runs at a time; a manual action ends the automatic flow.
@MainActor
final class DaemonLifecycleController {
    typealias HealthProbe = @MainActor (_ wake: Bool) async throws -> DaemonHealth
    typealias Sleep = @MainActor (Duration) async -> Void

    /// How long after launch a registered daemon may stay silent before it
    /// counts as unreachable. A healthy daemon connects within a second.
    nonisolated static let unreachableGrace: Duration = .seconds(10)
    /// How long a (re)registered daemon gets to answer: a launchd spawn, the
    /// database open and the transcript baseline, plus launchd's 5 s
    /// `ThrottleInterval` when the previous process exited moments ago.
    nonisolated static let restartWindow: Duration = .seconds(20)
    nonisolated static let probeInterval: Duration = .milliseconds(500)

    /// What the launch-time check concludes from the current health.
    enum Decision: Equatable {
        /// No health yet and the grace has not run out.
        case wait
        /// The running daemon is this app's bundled build.
        case upToDate
        /// Stale, fingerprint-less, or silent past the grace: reinstall.
        case restart(reason: String)
        /// Running from another bundle: observe, never replace.
        case foreign(executablePath: String)
    }

    /// What a fresh probe said after a (re)install.
    enum RestartOutcome: Equatable {
        /// A different process answers with the bundled fingerprint.
        case replaced(DaemonProcessIdentity?)
        /// A process answers, but not with the bundled fingerprint.
        case stillStale(reportedHash: String?)
        /// The window closed with the pre-restart process still answering:
        /// launchd did not swap it.
        case restartNotObserved(previous: DaemonProcessIdentity)
        /// The window closed with no answer at all; `lastError` is what the
        /// final probe ran into.
        case noResponse(within: Duration, lastError: String?)
        /// The daemon that answered runs from another bundle.
        case foreign(executablePath: String)
        /// macOS wants the user's approval in Login Items before it runs the
        /// daemon; probing would only wait on a person.
        case awaitingApproval
        /// This app's bundled `Lumen` could not be fingerprinted, so no
        /// answer could be judged.
        case cannotVerify(String)
    }

    /// What Settings shows under the Local service card.
    enum Notice: Equatable {
        case automaticManagementOff(DaemonManagementPolicy.Reason)
        case observedForeign(bundlePath: String)
        case restartNotObserved(pid: Int32)
        case noResponse(seconds: Int64, detail: String?)
        case stillStale
        case operationFailed(String)

        var text: String {
            switch self {
            case .automaticManagementOff(.developmentBuild):
                "Development build: the installed daemon and helper are not updated automatically."
            case .automaticManagementOff(.isolatedDaemon):
                "Isolated daemon (LUMI_SOCKET / LUMI_SUPPORT_DIRECTORY): the registered daemon is not managed from here."
            case let .observedForeign(bundlePath):
                "The running daemon comes from another copy of Lumi at \(bundlePath). It is left alone; Reinstall replaces it with this one."
            case let .restartNotObserved(pid):
                "After reinstall the previous daemon (pid \(pid)) kept answering for \(restartWindowSeconds) s; the system did not swap it. Try Reinstall again or check daemon.log."
            case let .noResponse(seconds, detail):
                "No daemon answered within \(seconds) s of the (re)install\(detail.map { " (\($0))" } ?? ""). Check daemon.log, or Reinstall again."
            case .stillStale:
                "The daemon that came back is not this app's build. Check which Lumi the system runs it from."
            case let .operationFailed(detail):
                detail
            }
        }

        private var restartWindowSeconds: Int64 { DaemonLifecycleController.restartWindow.components.seconds }
    }

    enum OperationError: Error, CustomStringConvertible {
        case busy
        case notAllowed(DaemonManagementPolicy.Reason)
        case daemonChanged(now: DaemonProcessIdentity?)

        var description: String {
            switch self {
            case .busy: "Another daemon operation is still running."
            case .notAllowed(.isolatedDaemon): "This Lumi observes an isolated daemon; the registered one cannot be managed from here."
            case .notAllowed(.developmentBuild): "Automatic management is off in development builds."
            case let .daemonChanged(now):
                "The daemon changed since the confirmation (now pid \(now.map { String($0.processID) } ?? "none")); check it and try again."
            }
        }
    }

    nonisolated static func decide(
        bundledHash: String,
        health: DaemonHealth?,
        ownership: DaemonOwnership,
        graceElapsed: Bool
    ) -> Decision {
        guard let health else {
            // A registered service that never produced health is dead-looping
            // in launchd (or its binary is gone). One reinstall re-registers
            // it on this app's bundle.
            return graceElapsed ? .restart(reason: "registered daemon is unreachable") : .wait
        }
        if case let .foreign(path) = ownership { return .foreign(executablePath: path) }
        guard let reported = health.executableHash, !reported.isEmpty else {
            return .restart(reason: "running daemon reports no executable fingerprint")
        }
        if reported == bundledHash { return .upToDate }
        return .restart(reason: "running \(reported.prefix(12)) ≠ bundled \(bundledHash.prefix(12))")
    }

    /// One probe's verdict during the restart window; `nil` keeps waiting
    /// (the pre-restart process is still the one answering).
    nonisolated static func judge(
        health: DaemonHealth,
        bundledHash: String,
        previous: DaemonProcessIdentity?,
        ownership: DaemonOwnership
    ) -> RestartOutcome? {
        if case let .foreign(path) = ownership { return .foreign(executablePath: path) }
        if let previous, let current = health.process, current.instanceID == previous.instanceID {
            return nil
        }
        guard let reported = health.executableHash, reported == bundledHash else {
            return .stillStale(reportedHash: health.executableHash)
        }
        return .replaced(health.process)
    }

    let policy: DaemonManagementPolicy
    private(set) var notice: Notice?
    private(set) var isBusy = false
    /// launchd's view of the registration, read when the panel appears and
    /// after every operation — an XPC round trip, so never per event.
    private(set) var serviceStatus: SMAppService.Status

    private let store: MacSessionStore
    private let manager: any DaemonServiceManaging
    private let bundledExecutableURL: URL?
    /// The comparable path of the bundled `Lumen`, resolved once.
    private let bundledExecutablePath: String?
    private let probe: HealthProbe
    private let sleep: Sleep
    private var bundledHash: String?
    private var graceElapsed = false
    /// Set once the launch-time check has concluded or a manual action ran:
    /// the automatic flow acts at most once per launch.
    private var automaticFlowEnded = false
    private var observers = ObserverRegistry()

    init(
        store: MacSessionStore,
        manager: (any DaemonServiceManaging)? = nil,
        policy: DaemonManagementPolicy? = nil,
        bundledExecutableURL: URL? = Bundle.main.url(forResource: "Lumen", withExtension: nil),
        probe: HealthProbe? = nil,
        sleep: Sleep? = nil
    ) {
        let manager = manager ?? DaemonServiceManager()
        self.store = store
        self.manager = manager
        self.serviceStatus = manager.status
        self.policy = policy ?? DaemonManagementPolicy.resolve(
            isDevelopmentBuild: DaemonManagementPolicy.isDevelopmentBuild,
            talksToInstalledDaemon: store.talksToInstalledDaemon
        )
        self.bundledExecutableURL = bundledExecutableURL
        self.bundledExecutablePath = bundledExecutableURL.map(DaemonOwnership.resolvedPath)
        self.probe = probe ?? { wake in try await store.probeHealth(wake: wake, quietly: true) }
        self.sleep = sleep ?? { duration in try? await Task.sleep(for: duration) }
    }

    @discardableResult
    func observe(_ observer: @escaping () -> Void) -> UUID {
        observers.add(observer)
    }

    /// Whose daemon the given health describes.
    func ownership(of health: DaemonHealth?) -> DaemonOwnership {
        DaemonOwnership.resolve(process: health?.process, bundledExecutablePath: bundledExecutablePath)
    }

    /// Re-reads launchd's registration state (one XPC round trip).
    func refreshServiceStatus() {
        let status = manager.status
        guard status != serviceStatus else { return }
        serviceStatus = status
        observers.notify()
    }

    // MARK: Launch-time check

    func start() {
        guard case .automatic = policy else {
            let reason = policy.reason
            notice = reason.map(Notice.automaticManagementOff)
            log.info("daemon_auto_update_skipped", metadata: .fields(["reason": reason.map { String(describing: $0) }]))
            observers.notify()
            return
        }
        Task { [weak self] in
            guard let self, await self.resolveBundledHash() != nil else { return }
            self.store.observe { [weak self] in self?.evaluate() }
            self.evaluate()
        }
        Task { [weak self] in
            await self?.sleep(Self.unreachableGrace)
            guard let self, !self.automaticFlowEnded else { return }
            self.graceElapsed = true
            self.evaluate()
        }
    }

    private func evaluate() {
        guard !automaticFlowEnded, !isBusy, let bundledHash else { return }
        let health = store.health
        switch Self.decide(
            bundledHash: bundledHash,
            health: health,
            ownership: ownership(of: health),
            graceElapsed: graceElapsed
        ) {
        case .wait:
            return
        case .upToDate:
            automaticFlowEnded = true
            log.info("daemon_up_to_date", metadata: .fields([
                "fingerprint": bundledHash.prefix(12),
                "pid": health?.process?.processID,
            ]))
        case let .foreign(executablePath):
            automaticFlowEnded = true
            notice = .observedForeign(bundlePath: DaemonOwnership.bundlePath(containing: executablePath))
            log.warning("daemon_foreign_observed", metadata: .fields([
                "executable": executablePath,
                "pid": health?.process?.processID,
                "detail": "running from another bundle; not replaced",
            ]))
        case let .restart(reason):
            automaticFlowEnded = true
            refreshServiceStatus()
            guard serviceStatus == .enabled else {
                log.info("daemon_auto_update_skipped", metadata: .fields(["reason": reason, "service": String(describing: serviceStatus)]))
                return
            }
            log.info("daemon_auto_update_restarting", metadata: .fields(["reason": reason, "previous_pid": health?.process?.processID]))
            let previous = health?.process
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.run("auto_reinstall") { try await self.reinstallAndVerify(previous: previous) }
                } catch {
                    // Already logged and shown by `run`.
                }
            }
        }
        observers.notify()
    }

    // MARK: Manual actions (Settings)

    /// Registers the LaunchAgent and waits for the daemon to answer.
    func install() async throws {
        try await run("install") {
            try self.manager.register()
            self.apply(await self.verifyRestart(previous: nil))
        }
    }

    /// `confirmed` is the process shown in the confirmation; the action is
    /// refused when a different process answers now.
    @discardableResult
    func reinstall(confirmed: DaemonProcessIdentity?) async throws -> RestartOutcome {
        try await run("reinstall") {
            try await self.assertUnchanged(confirmed)
            return try await self.reinstallAndVerify(previous: confirmed ?? self.store.health?.process)
        }
    }

    func uninstall(confirmed: DaemonProcessIdentity?) async throws {
        try await run("uninstall") {
            try await self.assertUnchanged(confirmed)
            try await self.manager.unregister()
            log.info("daemon_unregistered", metadata: .fields(["pid": confirmed?.processID]))
        }
    }

    func openLoginItems() {
        manager.openLoginItems()
    }

    // MARK: Operations

    /// Every operation, automatic or manual, passes here: one at a time,
    /// the automatic flow ends, the registration state and the store are
    /// re-read afterwards, and a failure becomes the notice.
    private func run<T>(_ name: String, _ body: @MainActor () async throws -> T) async throws -> T {
        if case let .manualOnly(reason) = policy, !policy.allowsManualActions {
            throw OperationError.notAllowed(reason)
        }
        guard !isBusy else { throw OperationError.busy }
        isBusy = true
        automaticFlowEnded = true
        notice = nil
        observers.notify()
        defer {
            isBusy = false
            serviceStatus = manager.status
            store.refresh()
            observers.notify()
        }
        do {
            return try await body()
        } catch {
            notice = .operationFailed(String(describing: error))
            log.error("daemon_operation_failed", metadata: .fields(["operation": name, "error": error]))
            throw error
        }
    }

    private func reinstallAndVerify(previous: DaemonProcessIdentity?) async throws -> RestartOutcome {
        try await manager.reinstall()
        let outcome = await verifyRestart(previous: previous)
        apply(outcome)
        return outcome
    }

    /// Probes the socket until a verdict or the window closes. The probe may
    /// wake the daemon: launchd holds back `RunAtLoad` in an on-demand-only
    /// session, and the Mach service is what makes it spawn.
    private func verifyRestart(previous: DaemonProcessIdentity?) async -> RestartOutcome {
        serviceStatus = manager.status
        if serviceStatus == .requiresApproval { return .awaitingApproval }
        guard let bundledHash = await resolveBundledHash() else {
            return .cannotVerify("this app's bundled Lumen could not be fingerprinted")
        }
        // The window is counted in sleeps as well as on the clock: a slow
        // probe (a wake can take several seconds) must not stretch it, and
        // a test with an instant sleep must still run out of it.
        let deadline = ContinuousClock.now + Self.restartWindow
        var slept: Duration = .zero
        var previousStillAnswering = false
        var lastError: String?
        while slept < Self.restartWindow, ContinuousClock.now < deadline {
            do {
                let health = try await probe(true)
                if let verdict = Self.judge(
                    health: health,
                    bundledHash: bundledHash,
                    previous: previous,
                    ownership: ownership(of: health)
                ) {
                    return verdict
                }
                previousStillAnswering = true
            } catch {
                lastError = String(describing: DaemonConnectionFailure(error))
            }
            await sleep(Self.probeInterval)
            slept += Self.probeInterval
        }
        if previousStillAnswering, let previous { return .restartNotObserved(previous: previous) }
        return .noResponse(within: Self.restartWindow, lastError: lastError)
    }

    /// The fingerprint of this app's bundled `Lumen`, hashed once; a failure
    /// is logged here and reported by whoever needed it.
    private func resolveBundledHash() async -> String? {
        if let bundledHash { return bundledHash }
        guard let bundledExecutableURL else {
            log.error("daemon_bundled_executable_missing")
            return nil
        }
        let hash: String? = await Task.detached(priority: .utility) {
            do {
                return try ExecutableFingerprint.sha256Hex(fileAt: bundledExecutableURL.resolvingSymlinksInPath())
            } catch {
                log.error("daemon_auto_update_hash_failed", metadata: .fields(["path": bundledExecutableURL, "error": error]))
                return nil
            }
        }.value
        bundledHash = hash
        return hash
    }

    private func apply(_ outcome: RestartOutcome) {
        switch outcome {
        case let .replaced(process):
            notice = nil
            log.info("daemon_restart_verified", metadata: .fields(["pid": process?.processID]))
        case let .stillStale(reportedHash):
            notice = .stillStale
            log.warning("daemon_still_stale_after_restart", metadata: .fields([
                "running": reportedHash?.prefix(12),
                "bundled": bundledHash?.prefix(12),
            ]))
        case let .restartNotObserved(previous):
            notice = .restartNotObserved(pid: previous.processID)
            log.error("daemon_restart_not_observed", metadata: .fields([
                "pid": previous.processID,
                "window_s": Self.restartWindow.components.seconds,
            ]))
        case let .noResponse(window, lastError):
            notice = .noResponse(seconds: window.components.seconds, detail: lastError)
            log.error("daemon_restart_no_response", metadata: .fields([
                "window_s": window.components.seconds,
                "error": lastError,
            ]))
        case let .foreign(executablePath):
            notice = .observedForeign(bundlePath: DaemonOwnership.bundlePath(containing: executablePath))
            log.warning("daemon_foreign_observed", metadata: .fields(["executable": executablePath, "detail": "answered after reinstall"]))
        case .awaitingApproval:
            // The Status row already says so; nothing to add.
            notice = nil
            log.info("daemon_restart_awaiting_approval")
        case let .cannotVerify(reason):
            notice = .operationFailed("Could not verify the daemon: \(reason).")
            log.error("daemon_restart_cannot_verify", metadata: .fields(["reason": reason]))
        }
    }

    /// Between the confirmation sheet and the click the daemon may have
    /// been replaced; a different process answering now refuses the action.
    /// No answer does not: a daemon that just died is still the one the
    /// user meant.
    private func assertUnchanged(_ confirmed: DaemonProcessIdentity?) async throws {
        guard let confirmed else { return }
        let current = try? await probe(false)
        if let now = current?.process, now.instanceID != confirmed.instanceID {
            throw OperationError.daemonChanged(now: now)
        }
    }
}
