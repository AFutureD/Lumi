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
/// The Relay is a carrier, never an authority. Which iPhones are trusted is
/// this daemon's own persisted state (`RelayHostStateStore`), read at every
/// point of use — the Relay's device list is only what the Mac shows; every frame
/// but a channel-session opening is sealed with a key the two ends derive
/// per session from one-time keys, and a request counts only when it
/// authenticates under the device's current session and its sequence moved
/// forward — so nothing the Relay lists, replays or reorders changes what
/// the daemon does.
///
/// One serial send loop does all outbound work — read → prepare once → seal
/// per device → reserve sequences (persisted first) → send — so an answer is
/// always on the wire before any push that follows it.
public actor RelayHostService: Service {
    public typealias HealthProvider = @Sendable () async -> DaemonHealth?
    /// `fetch_usage`: a preset, expanded and folded by the daemon.
    public typealias UsageProvider = @Sendable (UsageRangePreset) async throws -> UsageReport
    /// `fetch_plan_usage`: the snapshot and the settings it follows.
    public typealias PlanUsageProvider = @Sendable () async throws -> (state: PlanUsageState, settings: DaemonSettings)
    public typealias ConnectionObserver = @Sendable (Bool) async -> Void

    public static let indexLimit = 10_000
    public static let detailPageSize = 500

    fileprivate enum WorkItem {
        /// Announce the channel session `requestID` opened, then its index.
        case index(device: DeviceID, requestID: RequestID)
        case fetch(device: DeviceID, requestID: RequestID?, ids: [SessionID])
        case timeline(device: DeviceID, requestID: RequestID?, id: SessionID, since: Date)
        case events([AgentIngressEvent])
        case summaries([SessionID])
        case removed([SessionID], requestID: RequestID?, device: DeviceID?)
        case health(DaemonHealth, device: DeviceID?)
        /// An iPhone opened sessions: repository writes + local stream, then
        /// `session_info` to the other iPhones — behind pending answers.
        case reviewed([SessionID])
        /// `fetch_usage`: the report for a preset in this Mac's own days.
        case usage(device: DeviceID, requestID: RequestID?, preset: UsageRangePreset)
        /// `fetch_plan_usage`: the snapshot plus the settings it follows.
        case planUsage(device: DeviceID, requestID: RequestID?)
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
    private let usageProvider: UsageProvider
    private let planUsageProvider: PlanUsageProvider
    private let onConnectionChange: ConnectionObserver
    private let eventCoalesceInterval: Duration
    private let reconnectDelay: Duration
    private let deviceRefreshInterval: Duration
    private let healthInterval: Duration
    /// How long a pairing code stays claimable.
    private let pairingCodeLifetime: Duration
    /// How long the Mac has to press Match before the daemon declines for it.
    private let pairingDecisionTimeout: Duration

    private var credentials: RelayHostCredentials?
    private var registeredThisProcess = false
    private var transport: (any RelayFrameTransport)?
    private var isConnected = false
    private var lastError: String?
    private var devices: [PairedDevice] = []
    /// Devices already logged as unverified, so the 10 s refresh stays quiet.
    private var unverifiedLogged: Set<DeviceID> = []
    /// Revoked devices already logged as still active at the Relay.
    private var unappliedRevocationLogged: Set<DeviceID> = []
    /// The channel session each trusted iPhone opened on this connection.
    /// Memory only: a reconnect, a revocation or a newer `sync_index` ends
    /// one, and its key is gone with it.
    private var channelSessions: [DeviceID: ChannelSession] = [:]

    private struct ChannelSession {
        /// The `sync_index` that opened it; `channel_opened` echoes it.
        let requestID: RequestID
        let key: RelayChannelKey
        /// The daemon's one-time public key, announced in `channel_opened`.
        let hostEphemeralKey: Data
        /// Highest request sequence that authenticated in this session.
        var lastRequestSequence: UInt64
        /// `channel_opened` and the index went out: the iPhone has the key,
        /// so answers and pushes may be sealed with it. Until then nothing is.
        var isOpen = false
    }

    /// Devices with an open channel session: pushes go only to them. A
    /// push is still queued while a session is opening — its index item is
    /// ahead in the same lane, so the session is open by the time the push
    /// is sent, and nothing that happened after the index was read is lost.
    private var syncedDevices: [DeviceID] {
        channelSessions.filter { $0.value.isOpen }.map(\.key)
    }

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
        var phase: Phase

        /// One way only: `offered` → `revealing` → `comparing` → `decided`,
        /// with `expired` reachable from the first three. Nothing leads back
        /// to `offered`, the one phase that takes a device: once the nonce
        /// may have left this process, the device it was revealed for is the
        /// only one this session ever shows an SAS for. A session that
        /// cannot go on is dropped whole; the next one starts with a fresh
        /// nonce.
        enum Phase {
            /// The code is on screen and the nonce is still secret.
            case offered
            /// An iPhone's identity and key are bound to the session and the
            /// nonce is on its way to the Relay. Nothing is shown yet.
            case revealing(RelayPairingPending, devicePublicKey: Data)
            /// The Relay took the nonce: the SAS is on screen, waiting for Match.
            case comparing(RelayPairingPending, devicePublicKey: Data)
            case decided(RelayPairingOutcome)
            case expired(Date)

            var logName: String {
                switch self {
                case .offered: "offered"
                case .revealing: "revealing"
                case .comparing: "comparing"
                case .decided: "decided"
                case .expired: "expired"
                }
            }
        }

        /// The iPhone the Mac may decide on.
        var pending: RelayPairingPending? {
            if case let .comparing(pending, _) = phase { pending } else { nil }
        }

        var outcome: RelayPairingOutcome? {
            if case let .decided(outcome) = phase { outcome } else { nil }
        }

        var expiredAt: Date? {
            if case let .expired(date) = phase { date } else { nil }
        }

        /// Still claimable or waiting for Match: the Relay holds it open too.
        var isLive: Bool {
            switch phase {
            case .offered, .revealing, .comparing: true
            case .decided, .expired: false
            }
        }
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
        usageProvider: @escaping UsageProvider,
        planUsageProvider: @escaping PlanUsageProvider,
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
        self.usageProvider = usageProvider
        self.planUsageProvider = planUsageProvider
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
        let live = LivePairing(sessionID: created.sessionID, code: created.code, expiresAt: created.expiresAt, nonce: nonce, phase: .offered)
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
    /// covered — on this Mac first, lifting an earlier revocation of the
    /// same iPhone, and only then tells the Relay: trust is this Mac's own
    /// record. A pin that cannot be written stops the Match before the
    /// Relay hears of it; a decision the Relay refuses puts the record back.
    public func decidePairing(approved: Bool) async throws -> RelayPairingSession {
        guard var live = pairing, case let .comparing(pending, deviceKey) = live.phase, let credentials else {
            throw RelayPairingError.noPendingDevice
        }
        let earlier = state
        if approved {
            do {
                try state.setVerifiedKey(deviceKey, for: pending.deviceID)
            } catch {
                pairingLog.error("pairing_key_pin_failed", metadata: .fields(["device": pending.deviceID.rawValue, "error": error]))
                throw error
            }
            // Whatever session the device had ran under its previous key.
            channelSessions[pending.deviceID] = nil
        }
        do {
            try await rest.decidePairing(hostID: credentials.hostID, sessionID: live.sessionID, approved: approved, hostSecret: credentials.hostSecret)
        } catch {
            // Put the record back only if it is still the one this Match
            // wrote: a revocation made while the Relay was answering stands.
            if approved, state.verifiedKey(for: pending.deviceID) == deviceKey {
                do {
                    try state.restoreTrust(of: pending.deviceID, from: earlier)
                } catch let restoreError {
                    pairingLog.error("pairing_key_restore_failed", metadata: .fields(["device": pending.deviceID.rawValue, "error": restoreError]))
                }
                channelSessions[pending.deviceID] = nil
            }
            pairingLog.warning("pairing_decision_failed", metadata: .fields([
                "session": Self.shortPairingID(live.sessionID),
                "device": pending.deviceID.rawValue,
                "approved": approved,
                "error": error,
            ]))
            throw error
        }
        live.phase = .decided(RelayPairingOutcome(kind: approved ? .approved : .rejected, deviceName: pending.deviceName, at: Date()))
        // The page may have left or rotated the code while the Relay
        // answered: the decision stands, the newer session is not replaced.
        if pairing?.sessionID == live.sessionID { pairing = live }
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
        guard notifyRelay, live.isLive, let credentials else { return }
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
        guard var live = pairing, live.sessionID == sessionID, live.isLive else { return }
        let hadPending: Bool = if case .offered = live.phase { false } else { true }
        live.phase = .expired(Date())
        pairing = live
        pairingLog.info("pairing_expired", metadata: .fields(["session": Self.shortPairingID(sessionID), "had_pending": hadPending]))
    }

    /// `pairing_device` from the Relay: an iPhone submitted its identity and
    /// key to the live session. Bind them to the session, derive the SAS,
    /// and only now reveal the nonce — after the device's key is fixed, so a
    /// Relay in the middle cannot pick a key that matches.
    ///
    /// The binding is final: no later `pairing_device` is taken, whatever
    /// happens to the reveal. The reveal runs as a job so a slow Relay does
    /// not hold up the frames of every paired iPhone.
    private func handlePairingDevice(_ notice: RelayPairingDeviceNotice) {
        guard var live = pairing, live.sessionID == notice.sessionID, case .offered = live.phase, let credentials else {
            pairingLog.warning("pairing_device_ignored", metadata: .fields([
                "session": Self.shortPairingID(notice.sessionID),
                "live_session": pairing.map { Self.shortPairingID($0.sessionID) },
                "phase": pairing?.phase.logName,
                "device": notice.deviceID.rawValue,
            ]))
            return
        }
        let sessionID = live.sessionID
        let sas = RelayCryptography.pairingSAS(
            hostID: credentials.hostID,
            deviceID: notice.deviceID,
            hostPublicKey: credentials.keyPair.publicKey,
            devicePublicKey: notice.devicePublicKey,
            hostNonce: live.nonce
        )
        let pending = RelayPairingPending(deviceID: notice.deviceID, deviceName: notice.deviceName, sas: sas, receivedAt: Date())
        live.phase = .revealing(pending, devicePublicKey: notice.devicePublicKey)
        pairing = live
        pairingLog.info("pairing_device_submitted", metadata: .fields([
            "session": Self.shortPairingID(sessionID),
            "device": notice.deviceID.rawValue,
        ]))
        jobsIn.yield { [weak self] in
            await self?.revealNonce(sessionID)
        }
    }

    /// Hands the nonce to the Relay for the device the session is bound to;
    /// once the Relay took it, the SAS goes on screen and Match has 60 s.
    ///
    /// A reveal that fails says nothing about whether the nonce reached the
    /// Relay, so the session cannot go back to taking a device: it is
    /// dropped whole, and the Mac shows a fresh code with a fresh nonce.
    private func revealNonce(_ sessionID: String) async {
        guard let live = pairing, live.sessionID == sessionID, case .revealing = live.phase, let credentials else { return }
        do {
            try await rest.revealPairing(hostID: credentials.hostID, sessionID: sessionID, hostNonce: live.nonce, hostSecret: credentials.hostSecret)
        } catch {
            pairingLog.error("pairing_reveal_failed", metadata: .fields(["session": Self.shortPairingID(sessionID), "error": error]))
            if let current = pairing, current.sessionID == sessionID, current.isLive {
                await cancelLivePairing(notifyRelay: true)
            }
            return
        }
        // Expired, cancelled or replaced while the reveal was in flight.
        guard var current = pairing, current.sessionID == sessionID,
              case let .revealing(pending, devicePublicKey) = current.phase else { return }
        let shown = RelayPairingPending(deviceID: pending.deviceID, deviceName: pending.deviceName, sas: pending.sas, receivedAt: Date())
        current.phase = .comparing(shown, devicePublicKey: devicePublicKey)
        pairing = current
        pairingLog.info("pairing_revealed", metadata: .fields(["session": Self.shortPairingID(sessionID)]))
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

    /// Reads the Relay's device list for the Mac to show, and settles what
    /// the two sides disagree on about revocations. Trust is not read from
    /// here: frames and alerts go by the keys pinned in the state file.
    public func refreshDevices() async {
        guard let credentials else { return }
        let listed: [PairedDevice]
        do {
            listed = try await rest.devices(hostID: credentials.hostID, hostSecret: credentials.hostSecret)
        } catch {
            lastError = String(describing: error)
            log.warning("devices_refresh_failed", metadata: .fields(["error": error]))
            return
        }
        adoptRevocations(listed)
        let previous = devices
        devices = listed.map { verdict(on: $0) }
        lastError = nil
        if devices != previous {
            log.info("devices_refreshed", metadata: .fields([
                "devices": devices.count,
                "trusted": devices.filter { $0.revokedAt == nil && $0.keyVerified }.count,
                "revoked": devices.filter { $0.revokedAt != nil }.count,
                "unverified": devices.filter { $0.revokedAt == nil && !$0.keyVerified }.count,
            ]))
        }
        await resendRevocations(listed)
    }

    /// The Relay's row for a device as this Mac judges it, for display:
    /// - a device this Mac revoked is revoked, whatever the Relay lists;
    /// - otherwise the row is verified only where its public key is the one
    ///   this daemon pinned when the Mac approved that device. Anything else
    ///   (a row this Mac never approved, or a key the Relay swapped) is
    ///   unverified: the daemon never uses a key from this list, so that
    ///   row gets nothing, and the Mac says so.
    private func verdict(on device: PairedDevice) -> PairedDevice {
        if let revokedAt = state.revokedAt(for: device.id) {
            return device.revoked(at: revokedAt)
        }
        guard state.verifiedKey(for: device.id) == device.publicKey else {
            if device.revokedAt == nil, unverifiedLogged.insert(device.id).inserted {
                log.warning("device_key_unverified", metadata: .fields(["device": device.id.rawValue]))
            }
            return device.withKeyVerified(false)
        }
        unverifiedLogged.remove(device.id)
        return device.withKeyVerified(true)
    }

    /// A revocation the Relay lists for a key this daemon still pins becomes
    /// this Mac's own (a device revoked before revocations were recorded
    /// here): from then on only pairing again trusts it. The Relay can take
    /// trust away this way, never give it back.
    private func adoptRevocations(_ listed: [PairedDevice]) {
        for device in listed {
            guard let revokedAt = device.revokedAt, state.revokedAt(for: device.id) == nil,
                  state.verifiedKey(for: device.id) == device.publicKey else { continue }
            do {
                try state.revoke(device.id, at: revokedAt)
                channelSessions[device.id] = nil
                log.info("device_revocation_adopted", metadata: .fields(["device": device.id.rawValue]))
            } catch {
                log.error("device_revocation_persist_failed", metadata: .fields(["device": device.id.rawValue, "error": error]))
            }
        }
    }

    /// The Relay follows this Mac's revocations: a device revoked here that
    /// the Relay still lists as active (the revoke never reached it, or it
    /// did not apply it) is revoked there again on every refresh.
    private func resendRevocations(_ listed: [PairedDevice]) async {
        for device in listed where device.revokedAt == nil && state.revokedAt(for: device.id) != nil {
            // Said once per device: a Relay that keeps refusing would
            // otherwise repeat itself on every 10 s refresh.
            let firstSighting = unappliedRevocationLogged.insert(device.id).inserted
            if firstSighting {
                log.warning("device_revocation_unapplied", metadata: .fields(["device": device.id.rawValue]))
            }
            if await sendRevocation(of: device.id, logsFailure: firstSighting) {
                unappliedRevocationLogged.remove(device.id)
            }
        }
    }

    /// Tells the Relay a device is revoked (it closes the device's socket
    /// and drops its push token). False when the Relay did not take it; the
    /// next refresh tries again.
    private func sendRevocation(of deviceID: DeviceID, logsFailure: Bool = true) async -> Bool {
        guard let credentials else { return false }
        do {
            try await rest.revoke(hostID: credentials.hostID, deviceID: deviceID, hostSecret: credentials.hostSecret)
            log.info("device_revocation_sent", metadata: .fields(["device": deviceID.rawValue]))
            return true
        } catch {
            lastError = "The Relay has not applied a revocation: \(error)"
            if logsFailure {
                log.warning("device_revocation_send_failed", metadata: .fields(["device": deviceID.rawValue, "error": error]))
            }
            return false
        }
    }

    /// Revokes an iPhone on this Mac first — written to the state file, so
    /// neither a restart nor anything the Relay answers brings it back —
    /// then tells the Relay. A revocation that cannot be written throws and
    /// changes nothing; one the Relay does not take stays in force here and
    /// is sent again on every refresh. Only pairing again trusts the device.
    public func revoke(deviceID: DeviceID) async throws {
        do {
            try state.revoke(deviceID, at: Date())
        } catch {
            log.error("device_revocation_persist_failed", metadata: .fields(["device": deviceID.rawValue, "error": error]))
            throw error
        }
        channelSessions[deviceID] = nil
        devices = devices.map { verdict(on: $0) }
        log.info("device_revoked", metadata: .fields(["device": deviceID.rawValue]))
        _ = await sendRevocation(of: deviceID)
        await refreshDevices()
    }

    /// Deletes a (revoked) device's record at the Relay and forgets its
    /// pinned key and revocation; the Mac's `Remove` on a Revoked row.
    public func remove(deviceID: DeviceID) async throws {
        guard let credentials else { throw RelayClientError.notConnected }
        try await rest.removeDevice(hostID: credentials.hostID, deviceID: deviceID, hostSecret: credentials.hostSecret)
        channelSessions[deviceID] = nil
        do {
            try state.forget(deviceID)
        } catch {
            log.error("device_key_unpin_failed", metadata: .fields(["device": deviceID.rawValue, "error": error]))
        }
        log.info("device_removed", metadata: .fields(["device": deviceID.rawValue]))
        await refreshDevices()
    }

    // MARK: - Repository change notifications (from DaemonService)

    /// Summaries changed without an event (reviewed, archived): `session_info`.
    public func summariesChanged(_ ids: [SessionID]) {
        guard !ids.isEmpty, !channelSessions.isEmpty else { return }
        enqueue(.summaries(ids))
    }

    /// Sessions the daemon no longer retains: `session_removed`.
    public func sessionsRemoved(_ ids: [SessionID]) {
        guard !ids.isEmpty, !channelSessions.isEmpty else { return }
        enqueue(.removed(ids, requestID: nil, device: nil))
    }

    /// Sessions the daemon wiped and rebuilt (`Refresh session`): every
    /// synced iPhone gets each one whole again (`session_full`, unsolicited),
    /// the way it would after asking for it — instead of waiting for its next
    /// index to notice the rows changed.
    public func sessionsRebuilt(_ ids: [SessionID]) {
        let devices = syncedDevices
        guard !ids.isEmpty, !devices.isEmpty else { return }
        for device in devices {
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
                channelSessions = [:]
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
                    "channel_sessions": channelSessions.count,
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
        channelSessions = [:]
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
            handlePairingDevice(notice)
        case let .pairingClosed(sessionID, reason):
            handlePairingClosed(sessionID: sessionID, reason: reason)
        case .presence:
            break
        }
    }

    /// A sealed `request` from an iPhone. Two things can authenticate:
    /// - a request inside the device's channel session (sealed with the
    ///   session's key), accepted only when its sequence is past every
    ///   request this session already took — a repeated or reordered frame
    ///   is dropped, a frame of any other session does not open at all;
    /// - a `sync_index` sealed with the handshake key, which opens a new
    ///   session and replaces the old one.
    /// Nothing else changes state.
    private func handle(_ frame: RelayRoutingFrame) async {
        guard frame.kind == .request, let deviceID = frame.deviceID, let credentials else { return }
        guard let devicePublicKey = state.verifiedKey(for: deviceID) else {
            log.warning("request_from_untrusted_device", metadata: .fields(["device": deviceID.rawValue, "sequence": frame.sequence]))
            return
        }
        if let session = channelSessions[deviceID], let payload = try? RelayCryptography.open(frame, key: session.key) {
            guard frame.sequence > session.lastRequestSequence else {
                log.warning("request_replayed", metadata: .fields([
                    "device": deviceID.rawValue,
                    "sequence": frame.sequence,
                    "last_sequence": session.lastRequestSequence,
                ]))
                return
            }
            channelSessions[deviceID]?.lastRequestSequence = frame.sequence
            accept(payload, from: deviceID, sequence: frame.sequence)
            return
        }
        let opening: RemoteSessionPayload
        do {
            let handshakeKey = try RelayCryptography.handshakeKey(
                privateKey: credentials.keyPair.privateKey,
                peerPublicKey: devicePublicKey,
                hostID: credentials.hostID,
                deviceID: deviceID
            )
            opening = try RelayCryptography.open(frame, key: handshakeKey)
        } catch {
            // Neither the device's session nor an opening: a frame of a
            // session this daemon no longer holds, a replay, or an iPhone
            // app from before channel sessions.
            log.warning("request_open_failed", metadata: .fields([
                "device": deviceID.rawValue,
                "sequence": frame.sequence,
                "channel_session": channelSessions[deviceID] != nil,
                "error": error,
            ]))
            return
        }
        openChannelSession(opening, sequence: frame.sequence, deviceID: deviceID, devicePublicKey: devicePublicKey, credentials: credentials)
    }

    /// A `sync_index` sealed with the handshake key: the iPhone's one-time
    /// key arrives, the daemon makes its own, and the session key both ends
    /// derive replaces whatever session the device had. Nothing is sealed
    /// with it until the queued index item has sent `channel_opened`.
    private func openChannelSession(
        _ payload: RemoteSessionPayload,
        sequence: UInt64,
        deviceID: DeviceID,
        devicePublicKey: Data,
        credentials: RelayHostCredentials
    ) {
        guard payload.kind == .syncIndex, let requestID = payload.requestID, let deviceEphemeralKey = payload.ephemeralKey else {
            log.warning("request_outside_channel_session", metadata: .fields([
                "device": deviceID.rawValue,
                "kind": payload.kind.rawValue,
                "sequence": sequence,
            ]))
            return
        }
        // The iPhone never sends an opening twice: the one this session
        // came from, seen again, is a repeat and must not replace it.
        guard channelSessions[deviceID]?.requestID != requestID else {
            log.warning("channel_opening_repeated", metadata: .fields(["device": deviceID.rawValue, "sequence": sequence]))
            return
        }
        withTrace(requestID.rawValue) {
            do {
                let ephemeral = RelayEphemeralKey()
                let key = try RelayCryptography.sessionKey(
                    as: .host,
                    ephemeral: ephemeral,
                    peerEphemeralPublicKey: deviceEphemeralKey,
                    privateKey: credentials.keyPair.privateKey,
                    peerPublicKey: devicePublicKey,
                    hostID: credentials.hostID,
                    deviceID: deviceID
                )
                let replaced = channelSessions[deviceID] != nil
                channelSessions[deviceID] = ChannelSession(
                    requestID: requestID,
                    key: key,
                    hostEphemeralKey: try ephemeral.publicKey,
                    lastRequestSequence: sequence
                )
                log.info("channel_session_accepted", metadata: .fields([
                    "device": deviceID.rawValue,
                    "sequence": sequence,
                    "replaced": replaced,
                ]))
                enqueue(.index(device: deviceID, requestID: requestID))
            } catch {
                log.warning("channel_session_rejected", metadata: .fields(["device": deviceID.rawValue, "sequence": sequence, "error": error]))
            }
        }
    }

    /// A request that authenticated inside the device's channel session.
    private func accept(_ payload: RemoteSessionPayload, from deviceID: DeviceID, sequence: UInt64) {
        withTrace(payload.requestID?.rawValue ?? "") {
            log.info("request_received", metadata: .fields([
                "device": deviceID.rawValue,
                "kind": payload.kind.rawValue,
                "sessions": payload.sessionIDs?.count,
                "since": payload.since,
                "sequence": sequence,
            ]))
        }
        switch payload.kind {
        case .fetchSession:
            enqueue(.fetch(device: deviceID, requestID: payload.requestID, ids: payload.sessionIDs ?? []))
        case .fetchTimelineSince:
            guard let id = payload.sessionIDs?.first, let since = payload.since else { return }
            enqueue(.timeline(device: deviceID, requestID: payload.requestID, id: id, since: since))
        case .sessionReviewed:
            // An iPhone opened the session: the Mac window and the Notch turn
            // grey through the local stream, other iPhones through `session_info`.
            enqueue(.reviewed(payload.sessionIDs ?? []))
        case .fetchUsage:
            guard let preset = payload.usageRange else {
                log.warning("request_missing_usage_range", metadata: .fields(["device": deviceID.rawValue]))
                return
            }
            enqueue(.usage(device: deviceID, requestID: payload.requestID, preset: preset))
        case .fetchPlanUsage:
            enqueue(.planUsage(device: deviceID, requestID: payload.requestID))
        default:
            // `sync_index` included: it only ever opens a session.
            log.warning("request_kind_ignored", metadata: .fields(["device": deviceID.rawValue, "kind": payload.kind.rawValue]))
        }
    }

    /// Devices whose key this daemon pinned: the only devices frames or push
    /// alerts may reach.
    private var trustedDeviceIDs: [DeviceID] {
        state.verifiedDeviceIDs
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
        } catch RelayHostStateError.sequenceOutOfRange {
            // Not a cursor the Relay could hold: following it would use up
            // the channel's sequences for good. Keep ours.
            log.error("sequence_heal_refused", metadata: .fields(["device": deviceID.rawValue, "relay_last": lastSequence]))
            return
        } catch {
            log.error("sequence_state_persist_failed", metadata: .fields(["device": deviceID.rawValue, "error": error]))
        }
        // Whatever that device received is now suspect — the rejected frame
        // may have been `channel_opened` itself, and the Relay tells the
        // iPhone nothing. Open the session again on the healed cursor:
        // an iPhone still waiting gets its key and index, one that already
        // had them sees the sequence gap and indexes again. Pushes wait.
        guard let session = channelSessions[deviceID] else { return }
        channelSessions[deviceID]?.isOpen = false
        enqueue(.index(device: deviceID, requestID: session.requestID))
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
        // Before the channel-session gate: alerts target every key-verified
        // paired device (the Relay does not know which are suspended), so
        // they must not depend on a live socket; foreground devices suppress
        // the banner client-side.
        evaluatePush(events)
        guard !channelSessions.isEmpty else {
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
        for candidate in candidates {
            // Read per alert: a device revoked while an earlier alert was
            // on its way gets none of the later ones.
            let targets = trustedDeviceIDs
            guard !targets.isEmpty else { return }
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
        guard !channelSessions.isEmpty, let health = await healthProvider() else { return }
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

    /// Two lanes, one consumer. Bulk items (whole sessions, timeline tails)
    /// can take seconds each on a slow link, so they alternate with the
    /// small lane (answers, pushes, health, usage) instead of queueing
    /// ahead of it — one device catching up on a day of history no longer
    /// stalls another device's index or a Usage tab's ask. Within a lane
    /// the order is FIFO, so an answer still precedes a push enqueued after
    /// it. A whole-session request for many ids becomes one item per id so
    /// the lanes can interleave between sessions.
    ///
    /// Repeats collapse: a device that asks for the index (or usage, or plan
    /// usage) again has given up on its earlier ask, so the earlier queued
    /// answer is dropped and only the newest request id is answered.
    private func enqueue(_ item: WorkItem) {
        if case let .fetch(device, requestID, ids) = item, ids.count > 1 {
            for id in ids { queue.append(.fetch(device: device, requestID: requestID, ids: [id])) }
        } else {
            if let key = item.dedupeKey {
                let dropped = queue.count
                queue.removeAll { $0.dedupeKey == key }
                if queue.count < dropped {
                    log.debug("request_superseded", metadata: .fields(["item": item.logName, "dropped": dropped - queue.count]))
                }
            }
            queue.append(item)
        }
        sendSignalIn.yield(())
    }

    /// The lane whose turn it is next; a bulk item only when a small one
    /// went out before it (or nothing small is waiting).
    private var bulkTurn = false

    private func dequeue() -> WorkItem? {
        guard !queue.isEmpty else { return nil }
        let bulkIndex = queue.firstIndex { $0.isBulk }
        let smallIndex = queue.firstIndex { !$0.isBulk }
        let chosen: Int
        switch (bulkTurn, bulkIndex, smallIndex) {
        case let (true, .some(bulk), _): chosen = bulk
        case let (_, _, .some(small)): chosen = small
        case let (_, .some(bulk), nil): chosen = bulk
        default: return nil
        }
        bulkTurn = !queue[chosen].isBulk
        return queue.remove(at: chosen)
    }

    private func runSendLoop() async {
        for await _ in sendSignals {
            while !Task.isCancelled, let item = dequeue() {
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
            guard try await announceChannelSession(requestID, to: device, index: parts.map(\.prepared)) else {
                log.debug("index_skipped_superseded", metadata: .fields(["device": device.rawValue]))
                return
            }
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
            let targets = syncedDevices
            guard !targets.isEmpty else { return }
            let hidden = try await filterHiddenIDs()
            let events = events.filter { !hidden.contains($0.sessionID) }
            guard !events.isEmpty else { return }
            let batches = try RelayPayloadBatcher.eventBatches(events, generatedAt: now)
            log.info("events_pushed", metadata: .fields(["events": events.count, "batches": batches.count, "devices": targets.count]))
            try await send(batches.map(\.prepared), to: targets)
        case let .summaries(ids):
            let targets = syncedDevices
            guard !targets.isEmpty else { return }
            let hidden = try await filterHiddenIDs()
            var summaries: [SessionSummary] = []
            for id in ids where !hidden.contains(id) {
                if let summary = try await repository.sessionSummary(id: id) {
                    summaries.append(summary)
                }
            }
            guard !summaries.isEmpty else { return }
            let batches = try RelayPayloadBatcher.summaryBatches(summaries, generatedAt: now)
            log.info("summaries_pushed", metadata: .fields(["sessions": summaries.count, "batches": batches.count, "devices": targets.count]))
            try await send(batches.map(\.prepared), to: targets)
        case let .removed(ids, requestID, device):
            let targets = device.map { [$0] } ?? syncedDevices
            guard !targets.isEmpty else { return }
            let prepared = try RelayCryptography.prepare(RemoteSessionPayload(
                kind: .sessionRemoved, generatedAt: now, requestID: requestID, sessionIDs: ids
            ))
            log.info("removals_pushed", metadata: .fields(["sessions": ids.count, "devices": targets.count]))
            try await send([prepared], to: targets)
        case let .health(health, device):
            let targets = device.map { [$0] } ?? syncedDevices
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
        case let .usage(device, requestID, preset):
            // A failed build answers with an empty report so the iPhone can
            // say "can't reach" instead of waiting out a timeout. A month is
            // a few hundred rows; a report that would not fit one frame is a
            // bug worth an error line, not a silent stall.
            var answer = RemoteSessionPayload(kind: .usageReport, generatedAt: now, requestID: requestID)
            do {
                let report = try await usageProvider(preset)
                let full = RemoteSessionPayload(kind: .usageReport, generatedAt: now, requestID: requestID, usage: report)
                if try RelayPayloadBatcher.fits(full) {
                    answer = full
                    convertLog.info("usage_relay_sent", metadata: .fields([
                        "device": device.rawValue, "preset": preset.rawValue,
                        "days": report.byDay.count, "trend": report.trend.count, "models": report.byModel.count,
                    ]))
                } else {
                    log.error("usage_relay_too_large", metadata: .fields(["device": device.rawValue, "preset": preset.rawValue, "trend": report.trend.count]))
                }
            } catch {
                log.error("usage_relay_failed", metadata: .fields(["device": device.rawValue, "preset": preset.rawValue, "error": error]))
            }
            try await send([try RelayCryptography.prepare(answer)], to: [device])
        case let .planUsage(device, requestID):
            var answer = RemoteSessionPayload(kind: .planUsage, generatedAt: now, requestID: requestID)
            do {
                let snapshot = try await planUsageProvider()
                answer = RemoteSessionPayload(kind: .planUsage, generatedAt: now, requestID: requestID, planUsage: snapshot.state, settings: snapshot.settings)
            } catch {
                log.error("plan_usage_relay_failed", metadata: .fields(["device": device.rawValue, "error": error]))
            }
            try await send([try RelayCryptography.prepare(answer)], to: [device])
        }
    }

    /// Seals the prepared payloads with each device's channel-session key
    /// and sends them. A device without an open session gets nothing: it
    /// could not read the frames, and its next `sync_index` starts over.
    private func send(_ prepared: [RelayPreparedPayload], to targets: [DeviceID]) async throws {
        guard !prepared.isEmpty else { return }
        for deviceID in targets {
            guard let session = channelSessions[deviceID], session.isOpen else {
                log.debug("send_skipped_no_channel_session", metadata: .fields(["device": deviceID.rawValue, "parts": prepared.count]))
                continue
            }
            try await sendFrames(prepared.map { ($0, session.key) }, to: deviceID)
        }
    }

    /// Opens the session `requestID` asked for, in one run of sequences:
    /// `channel_opened` sealed with the handshake key — the one frame the
    /// iPhone can read before it has the session key — then the index
    /// sealed with the session key. Only after both are on the wire do
    /// answers and pushes follow. False when a newer `sync_index` (or the
    /// device losing trust) made this one moot.
    private func announceChannelSession(_ requestID: RequestID, to deviceID: DeviceID, index: [RelayPreparedPayload]) async throws -> Bool {
        guard let session = channelSessions[deviceID], session.requestID == requestID,
              let credentials, let devicePublicKey = state.verifiedKey(for: deviceID) else { return false }
        let handshakeKey = try RelayCryptography.handshakeKey(
            privateKey: credentials.keyPair.privateKey,
            peerPublicKey: devicePublicKey,
            hostID: credentials.hostID,
            deviceID: deviceID
        )
        let opened = try RelayCryptography.prepare(RemoteSessionPayload(
            kind: .channelOpened,
            requestID: requestID,
            ephemeralKey: session.hostEphemeralKey
        ))
        try await sendFrames([(opened, handshakeKey)] + index.map { ($0, session.key) }, to: deviceID)
        // Replaced while the frames went out: the newer session's own item opens that one.
        guard channelSessions[deviceID]?.requestID == requestID else { return false }
        channelSessions[deviceID]?.isOpen = true
        log.info("channel_session_opened", metadata: .fields(["device": deviceID.rawValue, "index_parts": index.count]))
        return true
    }

    /// Reserves and persists the device's sequences BEFORE anything hits the
    /// wire, then seals and sends each payload with its key.
    private func sendFrames(_ frames: [(payload: RelayPreparedPayload, key: RelayChannelKey)], to deviceID: DeviceID) async throws {
        guard !frames.isEmpty, let credentials, let transport else { return }
        let first = try state.reserve(for: deviceID, count: frames.count)
        var bytes = 0
        for (offset, entry) in frames.enumerated() {
            // Revoked while the earlier frames went out: the rest stay here.
            guard state.verifiedKey(for: deviceID) != nil else {
                log.info("send_stopped_device_untrusted", metadata: .fields(["device": deviceID.rawValue, "unsent": frames.count - offset]))
                return
            }
            let frame = try RelayCryptography.seal(
                entry.payload,
                hostID: credentials.hostID,
                deviceID: deviceID,
                sequence: first + UInt64(offset),
                kind: .data,
                key: entry.key
            )
            bytes += frame.ciphertext?.count ?? 0
            try await transport.send(frame)
        }
        log.debug("frames_sent", metadata: .fields([
            "device": deviceID.rawValue,
            "parts": frames.count,
            "first_sequence": first,
            "last_sequence": first + UInt64(frames.count - 1),
            "ciphertext_bytes": bytes,
        ]))
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
        case let .index(_, requestID):
            requestID.rawValue
        case let .fetch(_, requestID, _), let .timeline(_, requestID, _, _), let .removed(_, requestID, _),
             let .usage(_, requestID, _), let .planUsage(_, requestID):
            requestID?.rawValue
        case .events, .summaries, .health, .reviewed:
            nil
        }
    }

    /// Requests a device repeats only after giving up on the earlier one:
    /// the same key means the earlier queued answer can go.
    var dedupeKey: String? {
        switch self {
        case let .index(device, _): "index:\(device.rawValue)"
        case let .usage(device, _, _): "usage:\(device.rawValue)"
        case let .planUsage(device, _): "plan_usage:\(device.rawValue)"
        default: nil
        }
    }

    /// Whole sessions and timeline tails: seconds each on a slow link.
    var isBulk: Bool {
        switch self {
        case .fetch, .timeline: true
        default: false
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
        case .usage: "usage"
        case .planUsage: "plan_usage"
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
