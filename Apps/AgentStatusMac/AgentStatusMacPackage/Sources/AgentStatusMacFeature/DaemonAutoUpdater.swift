import AgentStatusCore
import AgentStatusTransport
import Foundation

/// launchd keeps a registered daemon running on the binary it launched, so an
/// app update leaves a stale process behind until something re-registers the
/// service. This restarts the daemon once per app launch when the hash the
/// running daemon reports no longer matches the binary bundled in this app.
@MainActor
final class DaemonAutoUpdater {
    enum Decision: Equatable {
        /// No health yet — keep observing.
        case wait
        /// Hashes match — nothing to do, stop observing.
        case upToDate
        /// Stale daemon and no restart attempted yet this launch.
        case restart(reason: String)
        /// Already restarted once and the fresh daemon still mismatches
        /// (e.g. a DerivedData build talking to the registered /Applications
        /// copy) — log once, never loop.
        case stillStale
    }

    nonisolated static func decide(bundledHash: String, health: DaemonHealth?, alreadyAttempted: Bool) -> Decision {
        guard let health else { return .wait }
        guard let reported = health.executableHash, !reported.isEmpty else {
            return alreadyAttempted
                ? .stillStale
                : .restart(reason: "running daemon reports no executable fingerprint")
        }
        if reported == bundledHash { return .upToDate }
        return alreadyAttempted
            ? .stillStale
            : .restart(reason: "running \(reported.prefix(12)) ≠ bundled \(bundledHash.prefix(12))")
    }

    private let store: MacSessionStore
    private let manager: DaemonServiceManager
    private let restart: () throws -> Void

    private var bundledHash: String?
    private var attempted = false
    /// After a restart, the pre-restart health is still in the store until the
    /// connection drops; ignore it until we have seen the `nil` from the
    /// disconnect, so `stillStale` only ever judges post-restart health.
    private var awaitingDisconnect = false
    private var finished = false

    init(
        store: MacSessionStore,
        manager: DaemonServiceManager = DaemonServiceManager(),
        restart: (() throws -> Void)? = nil
    ) {
        self.store = store
        self.manager = manager
        self.restart = restart ?? { try manager.reinstall() }
    }

    func start() {
        guard let bundled = Bundle.main.url(forResource: "agent-status-daemon", withExtension: nil) else {
            return
        }
        Task { [weak self] in
            let hash: String? = await Task.detached(priority: .utility) {
                do {
                    return try ExecutableFingerprint.sha256Hex(fileAt: bundled.resolvingSymlinksInPath())
                } catch {
                    NSLog("agent-status daemon auto-update: hashing bundled daemon failed: %@", String(describing: error))
                    return nil
                }
            }.value
            guard let self, let hash else { return }
            self.bundledHash = hash
            self.store.observe { [weak self] in self?.evaluate() }
            self.evaluate()
        }
    }

    private func evaluate() {
        guard !finished, let bundledHash else { return }
        if awaitingDisconnect {
            guard store.health == nil else { return }
            awaitingDisconnect = false
        }
        switch Self.decide(bundledHash: bundledHash, health: store.health, alreadyAttempted: attempted) {
        case .wait:
            break
        case .upToDate:
            finished = true
        case .restart(let reason):
            attempted = true
            guard manager.status == .enabled else {
                finished = true
                return
            }
            NSLog("agent-status daemon auto-update: restarting daemon (%@)", reason)
            do {
                awaitingDisconnect = true
                try restart()
                store.refresh()
            } catch {
                finished = true
                NSLog("agent-status daemon auto-update: restart failed: %@", String(describing: error))
            }
        case .stillStale:
            finished = true
            NSLog("agent-status daemon auto-update: daemon is still stale after one restart; not retrying")
        }
    }
}
