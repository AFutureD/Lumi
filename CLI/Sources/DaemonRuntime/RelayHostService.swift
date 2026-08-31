import Core
import Diagnostics
import Logging
import Remote
import ServiceLifecycle
import Transport
import Foundation

private let log = Logger(label: "relay")
private let convertLog = Logger(label: "convert")
private let pairingLog = Logger(label: "pairing")

/// The daemon's Relay host: registers the Mac with the Relay, keeps the host
/// WebSocket up, answers paired iPhones' sealed requests (index, whole
/// sessions, timeline tails, reviewed marks) from the repository, and pushes
/// what the repository just changed (events, summary-only changes, removals,
/// health) to every device that has synced on this connection.
///
/// One serial send loop does all outbound work — read → prepare once → seal
/// per device → reserve sequences (persisted first) → send — so an answer is
/// always on the wire before any push that follows it.
public actor RelayHostService: Service {
    public typealias HealthProvider = @Sendable () async -> DaemonHealth?
    public typealias ConnectionObserver = @Sendable (Bool) async -> Void

    public static let indexLimit = 10_000
    public static let detailPageSize = 500

    fileprivate enum WorkItem {
        case index(device: DeviceID, requestID: RequestID?)
        case fetch(device: DeviceID, requestID: RequestID?, ids: [SessionID])
        case timeline(device: DeviceID, requestID: RequestID?, id: SessionID, since: Date)
        case events([AgentIngressEvent])
        case summaries([SessionID])
        case removed([SessionID], requestID: RequestID?, device: DeviceID?)
        case health(DaemonHealth, device: DeviceID?)
        /// An iPhone opened sessions: repository writes + local stream, then
        /// `session_info` to the other iPhones — behind pending answers.
        case reviewed([SessionID])
        /// After a sequence heal: fetch fresh health and nudge that device.
        case healthNudge(device: DeviceID)
    }

    private let repository: any SessionRepository
    private let subscriptions: DaemonSubscriptionHub
    private let relayURL: URL
    private let credentialStore: any RelayHostCredentialStoring
    private var state: RelayHostStateStore
    private let transportFactory: any RelayFrameTransportFactory
    private let rest: any RelayHostREST
    private let hostName: @Sendable () -> String?
    private let healthProvider: HealthProvider
    private let onConnectionChange: ConnectionObserver
    private let eventCoalesceInterval: Duration
    private let reconnectDelay: Duration
    private let deviceRefreshInterval: Duration
    private let healthInterval: Duration
    /// How long a pairing code stays claimable.
    private let pairingCodeLifetime: Duration
    /// How long the Mac has to press Match before the daemon declines for it.
    private let pairingDecisionTimeout: Duration
    /// Floor between two on-demand device refreshes (unknown device, stale key).
    private let deviceRefreshOnDemandInterval: TimeInterval = 2
    private var lastOnDemandDeviceRefresh: Date?

    private var credentials: RelayHostCredentials?
    private var registeredThisProcess = false
    private var transport: (any RelayFrameTransport)?
    private var isConnected = false
    private var lastError: String?
    private var devices: [PairedDevice] = []
    /// Devices already logged as unverified, so the 10 s refresh stays quiet.
    private var unverifiedLogged: Set<DeviceID> = []
    /// Devices that asked for the index on this connection: pushes go only to them.
    private var activeDevices: Set<DeviceID> = []
    private var pendingEvents: [AgentIngressEvent] = []
    /// A coalesce job is already sleeping; the next event rides it.
    private var eventFlushScheduled = false
    /// Push cooldown bookkeeping: when each session last alerted. Pruned on
    /// every drain — entries older than the cooldown are dead weight.
    private var lastPushAt: [SessionID: Date] = [:]
    /// Alert-worthy events waiting for the push loop. One loop drains them in
    /// arrival order; overlapping consumers would race the cooldown reads
    /// across suspension points and send duplicates.
    private var pendingPushEvents: [PushNotificationPolicy.NotableEvent] = []
    private var lastHealth: DaemonHealth?
    private var queue: [WorkItem] = []

    // run()'s child loops feed on these; the producer sides are safe to call
    // before run() starts — yields buffer until the loop consumes them.
    private let events: AsyncStream<AgentIngressEvent>
    private let eventsIn: AsyncStream<AgentIngressEvent>.Continuation
    private let sendSignals: AsyncStream<Void>
    private let sendSignalIn: AsyncStream<Void>.Continuation
    private let pushSignals: AsyncStream<Void>
    private let pushSignalIn: AsyncStream<Void>.Continuation
    /// Timer jobs (event coalescing, pairing expiry / decision timeouts) run
    /// as children of run(): shutdown reaps every sleeper. Late fires are
    /// harmless — each job's target re-checks its own guard.
    private let jobs: AsyncStream<@Sendable () async -> Void>
    private let jobsIn: AsyncStream<@Sendable () async -> Void>.Continuation

    /// The one pairing session this Mac has going (code on screen, maybe an
    /// iPhone waiting for Match). The Mac app drives rotation: it starts a
    /// new one when the page opens, on New code, or after an outcome was
    /// shown — never on a timer. An expired code stays here, marked, so the
    /// Mac can show it as expired instead of asking for another one.
    private var pairing: LivePairing?

    private struct LivePairing {
        let sessionID: String
        let code: String
        let expiresAt: Date
        let nonce: Data
        var expiredAt: Date?
        var pending: RelayPairingPending?
        var pendingDevicePublicKey: Data?
        var outcome: RelayPairingOutcome?
    }

    public init(
        repository: any SessionRepository,
        subscriptions: DaemonSubscriptionHub,
        relayURL: URL,
        credentialStore: any RelayHostCredentialStoring,
        statePath: String,
        transportFactory: any RelayFrameTransportFactory,
        rest: any RelayHostREST,
        hostName: @escaping @Sendable () -> String? = { Host.current().localizedName },
        healthProvider: @escaping HealthProvider,
        onConnectionChange: @escaping ConnectionObserver,
        eventCoalesceInterval: Duration = .seconds(1),
        reconnectDelay: Duration = .seconds(2),
        deviceRefreshInterval: Duration = .seconds(10),
        healthInterval: Duration = .seconds(30),
        pairingCodeLifetime: Duration = .seconds(5 * 60),
        pairingDecisionTimeout: Duration = .seconds(60)
    ) {
        self.repository = repository
        self.subscriptions = subscriptions
        self.relayURL = relayURL
        self.credentialStore = credentialStore
        state = RelayHostStateStore(path: statePath)
        self.transportFactory = transportFactory
        self.rest = rest
        self.hostName = hostName
        self.healthProvider = healthProvider
        self.onConnectionChange = onConnectionChange
        self.eventCoalesceInterval = eventCoalesceInterval
        self.reconnectDelay = reconnectDelay
        self.deviceRefreshInterval = deviceRefreshInterval
        self.healthInterval = healthInterval
        self.pairingCodeLifetime = pairingCodeLifetime
        self.pairingDecisionTimeout = pairingDecisionTimeout
        (events, eventsIn) = AsyncStream.makeStream(of: AgentIngressEvent.self)
        (sendSignals, sendSignalIn) = AsyncStream.makeStream(of: Void.self)
        (pushSignals, pushSignalIn) = AsyncStream.makeStream(of: Void.self)
        (jobs, jobsIn) = AsyncStream.makeStream(of: (@Sendable () async -> Void).self)
    }

    // MARK: - Lifecycle

    /// The whole host under one structured root: the connection loop plus the
    /// event/send/push/job consumers, all reaped together on shutdown. One
    /// call per instance — the feeding streams are consumed once.
    public func run() async throws {
        let subscriptionID = subscriptions.subscribe { [eventsIn] message in
            guard case let .event(event) = message else { return }
            eventsIn.yield(event)
        }
        await cancelWhenGracefulShutdown {
            await withDiscardingTaskGroup { group in
                group.addTask { await self.consumeEvents() }
                group.addTask { await self.runSendLoop() }
                group.addTask { await self.runPushLoop() }
                group.addTask { await self.runJobs() }
                // Returning early (a sticky 401/403) leaves the loops serving
                // the local side; the service itself stays alive.
                await self.runConnectionLoop()
            }
        }
        subscriptions.unsubscribe(subscriptionID)
        await cancelLivePairing(notifyRelay: false)
        await tearDownConnection()
        log.info("relay_host_stopped")
    }

    public func status() -> RelayHostStatus {
        RelayHostStatus(
            connected: isConnected,
            hostID: credentials?.hostID,
            relayURL: credentials?.relayURL ?? relayURL,
            lastError: lastError,
            devices: devices
        )
    }

    // MARK: - Pairing (code + Numeric Comparison)

    /// Starts a fresh pairing session: a new nonce, a commitment to (host
    /// key, nonce) published to the Relay, and a code the Relay hands back
    /// for the Mac to show. Any earlier session of this Mac is cancelled —
    /// one live code at a time.
    public func startPairing() async throws -> RelayPairingSession {
        let credentials = try await ensureCredentials()
        await cancelLivePairing(notifyRelay: true)
        let nonce = RelayCryptography.makePairingNonce()
        let commit = RelayCryptography.pairingCommitment(hostPublicKey: credentials.keyPair.publicKey, hostNonce: nonce)
        let created = try await rest.createPairingSession(
            hostID: credentials.hostID,
            commit: commit,
            hostPublicKey: credentials.keyPair.publicKey,
            hostName: hostName(),
            expiresAt: Date().addingTimeInterval(pairingCodeLifetime.timeInterval),
            hostSecret: credentials.hostSecret
        )
        let live = LivePairing(sessionID: created.sessionID, code: created.code, expiresAt: created.expiresAt, nonce: nonce)
        let sessionID = created.sessionID
        // Late fires no-op: `pairingExpired` re-checks the session id and the
        // expired mark, so a job outliving this code cannot expire its successor.
        jobsIn.yield { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, created.expiresAt.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            await self?.pairingExpired(sessionID)
        }
        pairing = live
        // The code itself is never logged: it is the one thing on screen that
        // lets a device reach this Mac.
        pairingLog.info("pairing_started", metadata: .fields(["session": Self.shortPairingID(sessionID), "expires_at": created.expiresAt]))
        return pairingSnapshot(live, relayURL: credentials.relayURL)
    }

    /// The session as the Mac app shows it — live, ended, or expired;
    /// `nil` when there is none (never started, or cancelled).
    public func pairingSession() -> RelayPairingSession? {
        guard let pairing else { return nil }
        return pairingSnapshot(pairing, relayURL: credentials?.relayURL ?? relayURL)
    }

    /// Match (`true`) or Don't match (`false`) for the iPhone waiting on the
    /// live session. Approving pins the device's key — the one the SAS
    /// covered — so the Relay's later device listings are only believed where
    /// they match it.
    public func decidePairing(approved: Bool) async throws -> RelayPairingSession {
        guard var live = pairing, let pending = live.pending, let deviceKey = live.pendingDevicePublicKey,
              let credentials else {
            throw RelayPairingError.noPendingDevice
        }
        try await rest.decidePairing(hostID: credentials.hostID, sessionID: live.sessionID, approved: approved, hostSecret: credentials.hostSecret)
        if approved {
            do {
                try state.setVerifiedKey(deviceKey, for: pending.deviceID)
            } catch {
                pairingLog.error("pairing_key_pin_failed", metadata: .fields(["device": pending.deviceID.rawValue, "error": error]))
            }
        }
        live.pending = nil
        live.pendingDevicePublicKey = nil
        live.outcome = RelayPairingOutcome(kind: approved ? .approved : .rejected, deviceName: pending.deviceName, at: Date())
        pairing = live
        pairingLog.info(approved ? "pairing_approved" : "pairing_rejected", metadata: .fields([
            "session": Self.shortPairingID(live.sessionID),
            "device": pending.deviceID.rawValue,
        ]))
        if approved { await refreshDevices() }
        return pairingSnapshot(live, relayURL: credentials.relayURL)
    }

    /// The Mac left the pairing page: the code stops being claimable.
    public func cancelPairing() async {
        await cancelLivePairing(notifyRelay: true)
    }

    private func pairingSnapshot(_ live: LivePairing, relayURL: URL) -> RelayPairingSession {
        RelayPairingSession(
            sessionID: live.sessionID, code: live.code, relayURL: relayURL,
            expiresAt: live.expiresAt, expiredAt: live.expiredAt, pending: live.pending, outcome: live.outcome
        )
    }

    private func cancelLivePairing(notifyRelay: Bool) async {
        guard let live = pairing else { return }
        pairing = nil
        pairingLog.info("pairing_cancelled", metadata: .fields([
            "session": Self.shortPairingID(live.sessionID),
            "had_outcome": live.outcome != nil,
            "expired": live.expiredAt != nil,
            "notify_relay": notifyRelay,
        ]))
        // A session that already ended (approved / rejected / expired) is
        // terminal at the Relay; only a live one needs cancelling.
        guard notifyRelay, live.outcome == nil, live.expiredAt == nil, let credentials else { return }
        do {
            try await rest.cancelPairing(hostID: credentials.hostID, sessionID: live.sessionID, hostSecret: credentials.hostSecret)
        } catch {
            pairingLog.warning("pairing_cancel_failed", metadata: .fields(["session": Self.shortPairingID(live.sessionID), "error": error]))
        }
    }

    /// The code ran out (our timer, or the Relay said so). The session stays,
    /// marked expired and with no iPhone on it, until the Mac asks for a new
    /// code or leaves the page — the Mac shows "Expired", it never gets a
    /// replacement it did not ask for.
    private func pairingExpired(_ sessionID: String) {
        guard var live = pairing, live.sessionID == sessionID, live.expiredAt == nil else { return }
        let hadPending = live.pending != nil
        live.pending = nil
        live.pendingDevicePublicKey = nil
        live.expiredAt = Date()
        pairing = live
        pairingLog.info("pairing_expired", metadata: .fields(["session": Self.shortPairingID(sessionID), "had_pending": hadPending]))
    }

    /// `pairing_device` from the Relay: an iPhone submitted its identity and
    /// key to the live session. Derive the SAS, show it (the Mac app polls),
    /// and only now reveal the nonce — after the device's key is fixed, so a
    /// Relay in the middle cannot pick a key that matches.
    private func handlePairingDevice(_ notice: RelayPairingDeviceNotice) async {
        guard var live = pairing, live.sessionID == notice.sessionID, live.pending == nil, live.outcome == nil,
              live.expiredAt == nil, let credentials else {
            pairingLog.warning("pairing_device_ignored", metadata: .fields([
                "session": Self.shortPairingID(notice.sessionID),
                "live_session": pairing.map { Self.shortPairingID($0.sessionID) },
                "device": notice.deviceID.rawValue,
            ]))
            return
        }
        let sas = RelayCryptography.pairingSAS(
            hostID: credentials.hostID,
            deviceID: notice.deviceID,
            hostPublicKey: credentials.keyPair.publicKey,
            devicePublicKey: notice.devicePublicKey,
            hostNonce: live.nonce
        )
        live.pending = RelayPairingPending(deviceID: notice.deviceID, deviceName: notice.deviceName, sas: sas, receivedAt: Date())
        live.pendingDevicePublicKey = notice.devicePublicKey
        pairing = live
        pairingLog.info("pairing_device_submitted", metadata: .fields([
            "session": Self.shortPairingID(live.sessionID),
            "device": notice.deviceID.rawValue,
        ]))
        do {
            try await rest.revealPairing(hostID: credentials.hostID, sessionID: live.sessionID, hostNonce: live.nonce, hostSecret: credentials.hostSecret)
        } catch {
            pairingLog.error("pairing_reveal_failed", metadata: .fields(["session": Self.shortPairingID(live.sessionID), "error": error]))
            pairing?.pending = nil
            pairing?.pendingDevicePublicKey = nil
            return
        }
        pairingLog.info("pairing_revealed", metadata: .fields(["session": Self.shortPairingID(live.sessionID)]))
        let sessionID = live.sessionID
        // Guarded like the expiry job: `declineUnanswered` requires the same
        // session with a still-pending device, so an answered or replaced
        // pairing ignores the timeout.
        jobsIn.yield { [weak self, pairingDecisionTimeout] in
            try? await Task.sleep(for: pairingDecisionTimeout)
            guard !Task.isCancelled else { return }
            await self?.declineUnanswered(sessionID)
        }
    }

    /// Nobody pressed Match in time: decline on the Mac's behalf.
    private func declineUnanswered(_ sessionID: String) async {
        guard let live = pairing, live.sessionID == sessionID, live.pending != nil else { return }
        pairingLog.info("pairing_decision_timed_out", metadata: .fields(["session": Self.shortPairingID(sessionID)]))
        do {
            _ = try await decidePairing(approved: false)
        } catch {
            pairingLog.warning("pairing_auto_decline_failed", metadata: .fields(["session": Self.shortPairingID(sessionID), "error": error]))
        }
    }

    /// `pairing_closed` from the Relay. `expired`: the Relay's clock beat our
    /// timer — same outcome, the code stays on screen as expired. Anything
    /// else (the iPhone cancelled): the session is gone, no result card, and
    /// the Mac app starts a fresh code ("任一端取消，另一端回到起点").
    private func handlePairingClosed(sessionID: String, reason: String) {
        pairingLog.info("pairing_closed_by_relay", metadata: .fields(["session": Self.shortPairingID(sessionID), "reason": reason]))
        if reason == "expired" {
            pairingExpired(sessionID)
            return
        }
        guard pairing?.sessionID == sessionID else { return }
        pairing = nil
    }

    public func refreshDevices() async {
        guard let credentials else { return }
        do {
            let listed = try await rest.devices(hostID: credentials.hostID, hostSecret: credentials.hostSecret)
            let previous = devices
            devices = listed.map { verifyKey(of: $0) }
            let trusted = Set(trustedDeviceIDs)
            let dropped = activeDevices.subtracting(trusted)
            activeDevices.formIntersection(trusted)
            lastError = nil
            if devices != previous {
                log.info("devices_refreshed", metadata: .fields([
                    "devices": devices.count,
                    "trusted": trusted.count,
                    "revoked": devices.filter { $0.revokedAt != nil }.count,
                    "unverified": devices.filter { $0.revokedAt == nil && !$0.keyVerified }.count,
                    "deactivated": dropped.isEmpty ? nil : dropped.map(\.rawValue).sorted().joined(separator: ","),
                ]))
            }
        } catch {
            lastError = String(describing: error)
            log.warning("devices_refresh_failed", metadata: .fields(["error": error]))
        }
    }

    /// Believes the public key the Relay lists for a device only where it is
    /// the key this daemon pinned when the Mac approved that device. Anything
    /// else (a row this Mac never approved, or a key the Relay swapped) stays
    /// unverified: no frames go to it and the Mac says so.
    private func verifyKey(of device: PairedDevice) -> PairedDevice {
        guard state.verifiedKey(for: device.id) == device.publicKey else {
            if device.revokedAt == nil, unverifiedLogged.insert(device.id).inserted {
                log.warning("device_key_unverified", metadata: .fields(["device": device.id.rawValue]))
            }
            return device.withKeyVerified(false)
        }
        unverifiedLogged.remove(device.id)
        return device.withKeyVerified(true)
    }

    public func revoke(deviceID: DeviceID) async throws {
        guard let credentials else { throw RelayClientError.notConnected }
        try await rest.revoke(hostID: credentials.hostID, deviceID: deviceID, hostSecret: credentials.hostSecret)
        activeDevices.remove(deviceID)
        log.info("device_revoked", metadata: .fields(["device": deviceID.rawValue]))
        await refreshDevices()
    }

    /// Deletes a (revoked) device's record at the Relay and forgets its
    /// pinned key; the Mac's `Remove` on a Revoked row.
    public func remove(deviceID: DeviceID) async throws {
        guard let credentials else { throw RelayClientError.notConnected }
        try await rest.removeDevice(hostID: credentials.hostID, deviceID: deviceID, hostSecret: credentials.hostSecret)
        activeDevices.remove(deviceID)
        do {
            try state.clearVerifiedKey(for: deviceID)
        } catch {
            log.error("device_key_unpin_failed", metadata: .fields(["device": deviceID.rawValue, "error": error]))
        }
        log.info("device_removed", metadata: .fields(["device": deviceID.rawValue]))
        await refreshDevices()
    }

    // MARK: - Repository change notifications (from DaemonService)

    /// Summaries changed without an event (reviewed, archived): `session_info`.
    public func summariesChanged(_ ids: [SessionID]) {
        guard !ids.isEmpty, !activeDevices.isEmpty else { return }
        enqueue(.summaries(ids))
    }

    /// Sessions the daemon no longer retains: `session_removed`.
    public func sessionsRemoved(_ ids: [SessionID]) {
        guard !ids.isEmpty, !activeDevices.isEmpty else { return }
        enqueue(.removed(ids, requestID: nil, device: nil))
    }

    /// Sessions the daemon wiped and rebuilt (`Refresh session`): every
    /// synced iPhone gets each one whole again (`session_full`, unsolicited),
    /// the way it would after asking for it — instead of waiting for its next
    /// index to notice the rows changed.
    public func sessionsRebuilt(_ ids: [SessionID]) {
        guard !ids.isEmpty, !activeDevices.isEmpty else { return }
        for device in activeDevices {
            enqueue(.fetch(device: device, requestID: nil, ids: ids))
        }
    }

    // MARK: - Connection

    /// One loop owns the connection's whole life: connect → serve until the
    /// receive loop reports the loss → tear down → delay → again. A sticky
    /// identity rejection (401/403) ends the loop instead of retrying it.
    private func runConnectionLoop() async {
        while !Task.isCancelled {
            do {
                let credentials = try await ensureCredentials()
                let transport = transportFactory.makeTransport(baseURL: credentials.relayURL)
                try await transport.connect(hostID: credentials.hostID, role: .host, token: credentials.hostSecret)
                self.transport = transport
                isConnected = true
                lastError = nil
                activeDevices = []
                log.info("relay_connected", metadata: .fields(["relay": credentials.relayURL, "host": credentials.hostID.rawValue]))
                await onConnectionChange(true)
                await refreshDevices()
                let lostError = await serveConnection(transport)
                if Task.isCancelled {
                    // Shutdown, not a loss: run()'s cleanup tears down.
                    return
                }
                isConnected = false
                lastError = lostError.map { String(describing: $0) }
                log.warning("relay_connection_lost", metadata: .fields([
                    "active_devices": activeDevices.count,
                    "reconnect": lostError.map(Self.shouldReconnect(after:)) ?? true,
                    "error": lostError,
                ]))
                await tearDownConnection()
                await onConnectionChange(false)
                if let lostError, !Self.shouldReconnect(after: lostError) { return }
            } catch {
                isConnected = false
                lastError = String(describing: error)
                log.error("relay_connect_failed", metadata: .fields([
                    "relay": relayURL,
                    "reconnect": Self.shouldReconnect(after: error),
                    "error": error,
                ]))
                guard Self.shouldReconnect(after: error) else { return }
            }
            log.debug("relay_reconnect_scheduled", metadata: .fields(["delay_ms": reconnectDelay.milliseconds]))
            try? await Task.sleep(for: reconnectDelay)
        }
    }

    /// Serves one live connection: the receive loop next to the periodic
    /// device-refresh and health timers. Ends when the receive loop does
    /// (connection loss, or cancellation), returning its terminal error.
    private func serveConnection(_ transport: any RelayFrameTransport) async -> (any Error)? {
        await withTaskGroup(of: (any Error)??.self) { group in
            group.addTask { await .some(self.receiveLoop(transport)) }
            group.addTask {
                // `next()` has no native cancellation; this sentinel sleeps
                // until the group is cancelled, then disconnects (idempotent
                // on both transports) so the receive loop unblocks.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3600))
                }
                await transport.disconnect()
                return nil
            }
            group.addTask {
                await self.refreshLoop()
                return nil
            }
            group.addTask {
                await self.healthLoop()
                return nil
            }
            var lost: (any Error)? = nil
            while let finished = await group.next() {
                if case let .some(terminal) = finished {
                    lost = terminal
                    group.cancelAll()
                }
            }
            return lost
        }
    }

    private func ensureCredentials() async throws -> RelayHostCredentials {
        if let credentials, credentials.relayURL == relayURL, registeredThisProcess {
            return credentials
        }
        var current = try credentials ?? credentialStore.load()
        if current?.relayURL != relayURL {
            current = RelayHostCredentials(
                relayURL: relayURL,
                hostID: HostID("host-\(UUID().uuidString.lowercased())"),
                hostSecret: Self.credential(),
                keyPair: RelayCryptography.makeKeyPair()
            )
        }
        guard let current else { throw RelayClientError.notConnected }
        // Idempotent: the Relay keeps the secret's hash and answers 200 to
        // the same secret, 401 to a different one. A 401 here means this
        // host ID is already registered under another secret — the Relay's
        // storage was reset and someone who knew the ID claimed it first, or
        // the Keychain item came from another machine. Retrying never heals
        // it, so the caller stops reconnecting; say so plainly in the log.
        do {
            try await rest.registerHost(hostID: current.hostID, hostSecret: current.hostSecret)
        } catch RelayClientError.unauthorized {
            log.error("relay_host_identity_rejected", metadata: .fields([
                "relay": current.relayURL,
                "host": current.hostID.rawValue,
                "hint": "host ID is registered with a different secret; restore the original daemon relay Keychain item, or delete it to start with a fresh identity and pair again",
            ]))
            throw RelayClientError.unauthorized
        }
        if credentials != current {
            try credentialStore.save(current)
        }
        log.info("host_registered", metadata: .fields([
            "relay": current.relayURL,
            "host": current.hostID.rawValue,
            "fresh_identity": credentials?.hostID != current.hostID,
        ]))
        credentials = current
        registeredThisProcess = true
        return current
    }

    /// Returns the error that ended the connection; `nil` when it ended by
    /// cancellation (shutdown).
    private func receiveLoop(_ transport: any RelayFrameTransport) async -> (any Error)? {
        while !Task.isCancelled {
            do {
                let message = try await transport.next()
                await handle(message)
            } catch {
                return Task.isCancelled ? nil : error
            }
        }
        return nil
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: deviceRefreshInterval)
            guard !Task.isCancelled else { return }
            await refreshDevices()
        }
    }

    private func healthLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: healthInterval)
            guard !Task.isCancelled else { return }
            await pushHealthIfChanged()
        }
    }

    private func tearDownConnection() async {
        activeDevices = []
        let transport = self.transport
        self.transport = nil
        isConnected = false
        await transport?.disconnect()
    }

    private static func shouldReconnect(after error: Error) -> Bool {
        guard let relayError = error as? RelayClientError else { return true }
        switch relayError {
        case .unauthorized:
            return false
        case let .server(status, _):
            return status != 401 && status != 403
        default:
            return true
        }
    }

    // MARK: - Inbound

    private func handle(_ message: RelayIncomingMessage) async {
        switch message {
        case let .frame(frame):
            await handle(frame)
        case let .error(error):
            handleRelayError(error)
        case let .pairingDevice(notice):
            await handlePairingDevice(notice)
        case let .pairingClosed(sessionID, reason):
            handlePairingClosed(sessionID: sessionID, reason: reason)
        case .presence:
            break
        }
    }

    private func handle(_ frame: RelayRoutingFrame) async {
        guard frame.kind == .request, let deviceID = frame.deviceID, let credentials else { return }
        // A just-paired iPhone (or one that re-paired with a new key) sends
        // its first request before the 10 s device refresh has seen it: look
        // the device list up again before giving up on the request.
        var device = activeDevice(deviceID)
        if device == nil, await refreshDevicesOnDemand() {
            device = activeDevice(deviceID)
        }
        guard let device else {
            log.warning("request_from_unknown_device", metadata: .fields(["device": deviceID.rawValue, "sequence": frame.sequence]))
            return
        }
        let payload: RemoteSessionPayload
        do {
            payload = try open(frame, from: device, credentials: credentials)
        } catch {
            guard await refreshDevicesOnDemand(),
                  let refreshed = activeDevice(deviceID),
                  refreshed.publicKey != device.publicKey,
                  let reopened = try? open(frame, from: refreshed, credentials: credentials) else {
                log.warning("request_open_failed", metadata: .fields(["device": deviceID.rawValue, "sequence": frame.sequence, "error": error]))
                return
            }
            log.info("request_reopened_with_refreshed_key", metadata: .fields(["device": deviceID.rawValue]))
            payload = reopened
        }
        withTrace(payload.requestID?.rawValue ?? "") {
            log.info("request_received", metadata: .fields([
                "device": deviceID.rawValue,
                "kind": payload.kind.rawValue,
                "sessions": payload.sessionIDs?.count,
                "since": payload.since,
                "sequence": frame.sequence,
            ]))
        }
        switch payload.kind {
        case .syncIndex:
            enqueue(.index(device: deviceID, requestID: payload.requestID))
        case .fetchSession:
            enqueue(.fetch(device: deviceID, requestID: payload.requestID, ids: payload.sessionIDs ?? []))
        case .fetchTimelineSince:
            guard let id = payload.sessionIDs?.first, let since = payload.since else { return }
            enqueue(.timeline(device: deviceID, requestID: payload.requestID, id: id, since: since))
        case .sessionReviewed:
            // An iPhone opened the session: the Mac window and the Notch turn
            // grey through the local stream, other iPhones through `session_info`.
            enqueue(.reviewed(payload.sessionIDs ?? []))
        default:
            log.warning("request_kind_ignored", metadata: .fields(["device": deviceID.rawValue, "kind": payload.kind.rawValue]))
        }
    }

    /// A device the daemon will talk to: paired, not revoked, key verified.
    private func activeDevice(_ id: DeviceID) -> PairedDevice? {
        devices.first { $0.id == id && $0.revokedAt == nil && $0.keyVerified }
    }

    /// Paired devices whose key this daemon pinned: the only devices frames
    /// or push alerts may reach.
    private var trustedDeviceIDs: [DeviceID] {
        devices.filter { $0.revokedAt == nil && $0.keyVerified }.map(\.id)
    }

    private func open(_ frame: RelayRoutingFrame, from device: PairedDevice, credentials: RelayHostCredentials) throws -> RemoteSessionPayload {
        try RelayCryptography.open(
            frame,
            privateKey: credentials.keyPair.privateKey,
            peerPublicKey: device.publicKey
        )
    }

    /// Refreshes the device list outside the timer, at most once per
    /// `deviceRefreshOnDemandInterval`; false when throttled.
    private func refreshDevicesOnDemand() async -> Bool {
        let now = Date()
        if let last = lastOnDemandDeviceRefresh, now.timeIntervalSince(last) < deviceRefreshOnDemandInterval {
            return false
        }
        lastOnDemandDeviceRefresh = now
        await refreshDevices()
        return true
    }

    private func handleRelayError(_ error: RelayErrorMessage) {
        guard error.code == "non_monotonic_sequence" else {
            log.warning("relay_worker_error", metadata: .fields(["code": error.code, "device": error.deviceID?.rawValue]))
            return
        }
        guard let deviceID = error.deviceID, let lastSequence = error.lastSequence else { return }
        log.warning("sequence_healed", metadata: .fields([
            "device": deviceID.rawValue,
            "sent": error.sequence,
            "relay_last": lastSequence,
        ]))
        do {
            try state.advance(deviceID, past: lastSequence)
        } catch {
            log.error("sequence_state_persist_failed", metadata: .fields(["device": deviceID.rawValue, "error": error]))
        }
        // Whatever that device received is now suspect: it must re-index, and
        // it only notices when a frame arrives with a sequence past the hole.
        // The Relay forwards nothing about the rejection, so nudge it with a
        // health frame on the healed cursor; the gap makes the iPhone index.
        activeDevices.remove(deviceID)
        enqueue(.healthNudge(device: deviceID))
    }

    // MARK: - Events

    /// Single consumer of the hub's event stream: appends in publish order
    /// (the fix for the racy Task-per-event fan-in) and arms one coalesce job.
    private func consumeEvents() async {
        for await event in events {
            pendingEvents.append(event)
            guard !eventFlushScheduled else { continue }
            eventFlushScheduled = true
            jobsIn.yield { [weak self, eventCoalesceInterval] in
                try? await Task.sleep(for: eventCoalesceInterval)
                await self?.flushEvents()
            }
        }
    }

    private func flushEvents() {
        eventFlushScheduled = false
        let events = pendingEvents
        pendingEvents = []
        guard !events.isEmpty else { return }
        // Before the active-device gate: alerts target every key-verified
        // paired device (the Relay does not know which are suspended), so
        // they must not depend on a live socket; foreground devices suppress
        // the banner client-side.
        evaluatePush(events)
        guard !activeDevices.isEmpty else {
            log.debug("relay_events_dropped_no_devices", metadata: .fields(["events": events.count]))
            return
        }
        enqueue(.events(events))
    }

    // MARK: - Push notifications

    /// Turn-level alerts to key-verified paired iPhones, via the Relay's
    /// plaintext notification endpoint (`PushNotificationPolicy` decides which
    /// events qualify). REST, not the serial send loop: an alert has no place
    /// in the frame sequence and must not wait behind a large sync.
    private func evaluatePush(_ events: [AgentIngressEvent]) {
        guard credentials != nil, !trustedDeviceIDs.isEmpty else { return }
        let notable = PushNotificationPolicy.notableEvents(events, now: Date())
        guard !notable.isEmpty else { return }
        pendingPushEvents.append(contentsOf: notable)
        pushSignalIn.yield(())
    }

    private func runPushLoop() async {
        for await _ in pushSignals {
            while !Task.isCancelled, !pendingPushEvents.isEmpty {
                let notable = pendingPushEvents
                pendingPushEvents = []
                await sendPush(for: notable)
            }
        }
    }

    private func sendPush(for notable: [PushNotificationPolicy.NotableEvent]) async {
        // One index read answers both questions: each session's summary, and
        // whether a subagent's parent is still retained.
        let summaries: [SessionID: SessionSummary]
        do {
            let all = try await repository.listSessions(limit: Self.indexLimit)
            summaries = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        } catch {
            // Swallowing this would either drop an expected alert or turn a
            // transient error into a spurious subagent push; say so and send
            // nothing — the next notable event is the retry.
            log.warning("push_summary_lookup_failed", metadata: .fields(["events": notable.count, "error": error]))
            return
        }
        let now = Date()
        lastPushAt = lastPushAt.filter { now.timeIntervalSince($0.value) < PushNotificationPolicy.cooldown }
        let candidates = PushNotificationPolicy.candidates(
            notable: notable,
            summaries: summaries,
            retainedParents: Set(summaries.keys),
            lastPushAt: lastPushAt,
            now: now
        )
        guard !candidates.isEmpty, let credentials else { return }
        // The alert title is the session's title in plaintext, so it honors
        // the same trust boundary as frames: only devices whose key this
        // daemon pinned are addressed. The Relay cannot tell a verified key
        // from a swapped one, so the daemon names the targets explicitly.
        let targets = trustedDeviceIDs
        guard !targets.isEmpty else { return }
        for candidate in candidates {
            lastPushAt[candidate.sessionID] = now
            do {
                let results = try await rest.sendPushNotification(
                    hostID: credentials.hostID,
                    notification: RelayPushNotification(
                        deviceIDs: targets,
                        title: candidate.title,
                        subtitle: candidate.subtitle,
                        sessionID: candidate.sessionID,
                        collapseID: PushNotificationPolicy.collapseID(for: candidate.sessionID)
                    ),
                    hostSecret: credentials.hostSecret
                )
                // The alert text is content and stays out of the log; the
                // per-device outcomes are what a delivery question needs.
                log.info("push_sent", metadata: .fields([
                    "session": candidate.sessionID.rawValue,
                    "results": results.map { "\($0.deviceID.rawValue):\($0.status.rawValue)" }.sorted().joined(separator: ","),
                ]))
            } catch {
                log.warning("push_send_failed", metadata: .fields([
                    "session": candidate.sessionID.rawValue,
                    "error": error,
                ]))
            }
        }
    }

    private func pushHealthIfChanged() async {
        guard !activeDevices.isEmpty, let health = await healthProvider() else { return }
        if let lastHealth, Self.healthUnchanged(lastHealth, health) { return }
        lastHealth = health
        enqueue(.health(health, device: nil))
    }

    private static func healthUnchanged(_ lhs: DaemonHealth, _ rhs: DaemonHealth) -> Bool {
        lhs.daemonVersion == rhs.daemonVersion
            && lhs.executableHash == rhs.executableHash
            && lhs.activeSessionCount == rhs.activeSessionCount
            && lhs.retainedSessionCount == rhs.retainedSessionCount
            && lhs.relayConnected == rhs.relayConnected
    }

    // MARK: - Serial send loop

    private func enqueue(_ item: WorkItem) {
        queue.append(item)
        sendSignalIn.yield(())
    }

    /// The single consumer of the FIFO work queue: an answer is always on the
    /// wire before any push enqueued after it.
    private func runSendLoop() async {
        for await _ in sendSignals {
            while !Task.isCancelled, !queue.isEmpty {
                let item = queue.removeFirst()
                do {
                    try await process(item)
                } catch {
                    lastError = String(describing: error)
                    log.error("relay_send_failed", metadata: .fields(["item": item.logName, "queued": queue.count, "error": error]))
                }
            }
        }
    }

    /// Timer jobs run as children of this loop; group cancellation reaps
    /// every sleeper at shutdown.
    private func runJobs() async {
        await withDiscardingTaskGroup { group in
            for await job in jobs {
                group.addTask { await job() }
            }
        }
    }

    private func process(_ item: WorkItem) async throws {
        // A device's request id (index / fetch / timeline) is the unit of
        // work; pushes have none.
        if let trace = item.traceID {
            try await withTrace(trace) { try await run(item) }
        } else {
            try await run(item)
        }
    }

    /// The transitive filter-hidden set, read fresh per work item. Verdicts
    /// are frozen, so this is cheap and stable; withholding here (index,
    /// fetch, timeline, events, summaries) is what keeps hidden sessions off
    /// iPhones entirely — a hidden id answers like a removed one, and the
    /// device's reconcile prunes any copy it already holds.
    private func filterHiddenIDs() async throws -> Set<SessionID> {
        SessionSummary.filterHiddenIDs(try await repository.listSessions(limit: Self.indexLimit))
    }

    private func run(_ item: WorkItem) async throws {
        let now = Date()
        switch item {
        case let .index(device, requestID):
            let allEntries = try await repository.sessionIndex(limit: Self.indexLimit)
            let hidden = SessionSummary.filterHiddenIDs(allEntries.map(\.summary))
            let entries = allEntries.filter { !hidden.contains($0.summary.id) }
            let parts = try RelayPayloadBatcher.indexParts(entries, requestID: requestID, generatedAt: now)
            convertLog.info("index_prepared", metadata: .fields(["device": device.rawValue, "sessions": entries.count, "parts": parts.count]))
            try await send(parts.map(\.prepared), to: [device])
            activeDevices.insert(device)
            if let health = await healthProvider() {
                lastHealth = health
                let prepared = try RelayCryptography.prepare(RemoteSessionPayload(kind: .health, generatedAt: now, health: health))
                try await send([prepared], to: [device])
            }
        case let .fetch(device, requestID, ids):
            let hidden = try await filterHiddenIDs()
            for id in ids {
                if !hidden.contains(id), let detail = try await fetchFullDetail(id) {
                    let parts = try RelaySessionPartitioner.parts(for: detail, kind: .sessionFull, requestID: requestID, generatedAt: now)
                    convertLog.info("session_prepared", metadata: .fields([
                        "device": device.rawValue,
                        "session": id.rawValue,
                        "kind": "session_full",
                        "timeline": detail.timeline.count,
                        "parts": parts.count,
                    ]))
                    try await send(parts.map(\.prepared), to: [device])
                } else {
                    let prepared = try RelayCryptography.prepare(RemoteSessionPayload(
                        kind: .sessionRemoved, generatedAt: now, requestID: requestID, sessionIDs: [id]
                    ))
                    try await send([prepared], to: [device])
                }
            }
        case let .timeline(device, requestID, id, since):
            if try await !filterHiddenIDs().contains(id), let detail = try await fetchTimelineSince(id, since: since) {
                let parts = try RelaySessionPartitioner.parts(for: detail, kind: .sessionTimeline, requestID: requestID, generatedAt: now)
                convertLog.info("session_prepared", metadata: .fields([
                    "device": device.rawValue,
                    "session": id.rawValue,
                    "kind": "session_timeline",
                    "timeline": detail.timeline.count,
                    "parts": parts.count,
                ]))
                try await send(parts.map(\.prepared), to: [device])
            } else {
                let prepared = try RelayCryptography.prepare(RemoteSessionPayload(
                    kind: .sessionRemoved, generatedAt: now, requestID: requestID, sessionIDs: [id]
                ))
                try await send([prepared], to: [device])
            }
        case let .events(events):
            guard !activeDevices.isEmpty else { return }
            let hidden = try await filterHiddenIDs()
            let events = events.filter { !hidden.contains($0.sessionID) }
            guard !events.isEmpty else { return }
            let batches = try RelayPayloadBatcher.eventBatches(events, generatedAt: now)
            log.info("events_pushed", metadata: .fields(["events": events.count, "batches": batches.count, "devices": activeDevices.count]))
            try await send(batches.map(\.prepared), to: Array(activeDevices))
        case let .summaries(ids):
            guard !activeDevices.isEmpty else { return }
            let hidden = try await filterHiddenIDs()
            var summaries: [SessionSummary] = []
            for id in ids where !hidden.contains(id) {
                if let summary = try await repository.sessionSummary(id: id) {
                    summaries.append(summary)
                }
            }
            guard !summaries.isEmpty else { return }
            let batches = try RelayPayloadBatcher.summaryBatches(summaries, generatedAt: now)
            log.info("summaries_pushed", metadata: .fields(["sessions": summaries.count, "batches": batches.count, "devices": activeDevices.count]))
            try await send(batches.map(\.prepared), to: Array(activeDevices))
        case let .removed(ids, requestID, device):
            let targets = device.map { [$0] } ?? Array(activeDevices)
            guard !targets.isEmpty else { return }
            let prepared = try RelayCryptography.prepare(RemoteSessionPayload(
                kind: .sessionRemoved, generatedAt: now, requestID: requestID, sessionIDs: ids
            ))
            log.info("removals_pushed", metadata: .fields(["sessions": ids.count, "devices": targets.count]))
            try await send([prepared], to: targets)
        case let .health(health, device):
            let targets = device.map { [$0] } ?? Array(activeDevices)
            guard !targets.isEmpty else { return }
            let prepared = try RelayCryptography.prepare(RemoteSessionPayload(kind: .health, generatedAt: now, health: health))
            try await send([prepared], to: targets)
        case let .reviewed(ids):
            for id in ids {
                try? await repository.markSessionReviewed(id)
                if let summary = try? await repository.sessionSummary(id: id) {
                    subscriptions.publish(summary: summary)
                }
            }
            summariesChanged(ids)
        case let .healthNudge(device):
            guard let health = await healthProvider() else { return }
            let prepared = try RelayCryptography.prepare(RemoteSessionPayload(kind: .health, generatedAt: now, health: health))
            try await send([prepared], to: [device])
        }
    }

    /// Seals and sends the prepared payloads to each device, reserving and
    /// persisting that device's sequences BEFORE anything hits the wire.
    private func send(_ prepared: [RelayPreparedPayload], to targets: [DeviceID]) async throws {
        guard !prepared.isEmpty, let credentials, let transport else { return }
        for deviceID in targets {
            guard let device = activeDevice(deviceID) else {
                log.debug("send_skipped_inactive_device", metadata: .fields(["device": deviceID.rawValue, "parts": prepared.count]))
                continue
            }
            let first = try state.reserve(for: deviceID, count: prepared.count)
            var bytes = 0
            for (offset, payload) in prepared.enumerated() {
                let frame = try RelayCryptography.seal(
                    payload,
                    hostID: credentials.hostID,
                    deviceID: deviceID,
                    sequence: first + UInt64(offset),
                    kind: .data,
                    privateKey: credentials.keyPair.privateKey,
                    peerPublicKey: device.publicKey
                )
                bytes += frame.ciphertext?.count ?? 0
                try await transport.send(frame)
            }
            log.debug("frames_sent", metadata: .fields([
                "device": deviceID.rawValue,
                "parts": prepared.count,
                "first_sequence": first,
                "last_sequence": first + UInt64(prepared.count - 1),
                "ciphertext_bytes": bytes,
            ]))
        }
    }

    // MARK: - Repository reads

    private func fetchFullDetail(_ id: SessionID) async throws -> SessionDetail? {
        var cursor: PaginationCursor?
        var turns: [TurnSummary] = []
        var timeline: [TimelineItem] = []
        var summary: SessionSummary?
        repeat {
            guard let page = try await repository.sessionDetail(id: id, cursor: cursor, limit: Self.detailPageSize) else {
                return nil
            }
            summary = page.summary
            if !page.turns.isEmpty { turns = page.turns }
            timeline += page.timeline
            cursor = page.nextCursor
        } while cursor != nil
        guard let summary else { return nil }
        return SessionDetail(summary: summary, turns: turns, timeline: timeline)
    }

    private func fetchTimelineSince(_ id: SessionID, since: Date) async throws -> SessionDetail? {
        var cursor: PaginationCursor?
        var turns: [TurnSummary] = []
        var timeline: [TimelineItem] = []
        var summary: SessionSummary?
        repeat {
            guard let page = try await repository.timelineSince(id: id, since: since, cursor: cursor, limit: Self.detailPageSize) else {
                return nil
            }
            summary = page.summary
            if !page.turns.isEmpty { turns = page.turns }
            timeline += page.timeline
            cursor = page.nextCursor
        } while cursor != nil
        guard let summary else { return nil }
        return SessionDetail(summary: summary, turns: turns, timeline: timeline)
    }

    private static func credential() -> String {
        RelayCryptography.makeKeyPair().privateKey
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A pairing session id doubles as the iPhone's bearer capability for
    /// that session, so logs carry only its first 8 characters.
    private static func shortPairingID(_ sessionID: String) -> String {
        sessionID.count > 8 ? String(sessionID.prefix(8)) + "…" : sessionID
    }
}

private extension RelayHostService.WorkItem {
    var traceID: String? {
        switch self {
        case let .index(_, requestID), let .fetch(_, requestID, _), let .timeline(_, requestID, _, _), let .removed(_, requestID, _):
            requestID?.rawValue
        case .events, .summaries, .health, .reviewed, .healthNudge:
            nil
        }
    }

    var logName: String {
        switch self {
        case .index: "index"
        case .fetch: "fetch"
        case .timeline: "timeline"
        case .events: "events"
        case .summaries: "summaries"
        case .removed: "removed"
        case .health: "health"
        case .reviewed: "reviewed"
        case .healthNudge: "health_nudge"
        }
    }
}

/// Pairing actions the Mac asked for that the live session cannot take.
public enum RelayPairingError: Error, Sendable {
    /// Match / Don't match with no iPhone waiting on the live session.
    case noPendingDevice
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    var milliseconds: Int {
        Int(timeInterval * 1_000)
    }
}
