import Core
import Persistence
import Remote
import Transport
import Foundation

/// Which link a Mac's channel session runs on right now.
enum MacConnectionPath: Sendable, Equatable {
    case relay
    /// The same network: frames go straight to the Mac, nothing through the Relay.
    case direct
}

/// What one paired Mac looks like to the UI.
struct MacChannelState: Sendable {
    let hostID: HostID
    let displayName: String
    /// The Relay this Mac is reached through (each Mac remembers its own).
    let relayURL: URL
    let pairedAt: Date
    let isConnected: Bool
    let isHostOnline: Bool
    /// The link the current channel session uses; `nil` before one opened.
    var connectionPath: MacConnectionPath? = nil
    /// The Relay refused this iPhone's credentials (the Mac revoked it):
    /// reconnecting stopped; the cache stays readable; pair again to resume.
    let accessRevoked: Bool
    /// The latest index was reconciled and every fetch it needed has landed.
    let hasCompleteSync: Bool
    /// Every session cached for this Mac (loaded from disk at launch, kept
    /// current by the sync), online or not.
    let sessions: [SessionDetail]
    /// When the last complete sync landed (persists across launches).
    let lastSyncAt: Date?
    let lastError: String?
    /// The daemon's last reported health, while connected.
    let health: DaemonHealth?
    /// The cache file has been read into memory (false only during launch).
    let hasLoadedCache: Bool
    /// The Usage tab's History figures for this Mac — memory only, asked
    /// for while the tab is open (`fetch_usage`).
    var usage: UsageSnapshot? = nil
    /// The Usage tab's Plan cards for this Mac — memory only (`fetch_plan_usage`).
    var planUsage: PlanUsageSnapshot? = nil

    var isOnline: Bool { isConnected && isHostOnline }
    /// Sessions the lists show: the cache, always — staleness is shown per
    /// Mac (online dot, "last sync"), never by hiding content.
    var visibleSessions: [SessionDetail] { sessions }
}

/// How a controller builds a channel's cache and Relay socket; tests inject
/// in-memory doubles.
struct RelayDeviceDependencies: Sendable {
    /// The Relay used when a person types a code without a Relay URL; a
    /// scanned link or the Advanced field can name another one. Each paired
    /// Mac remembers its own.
    var defaultRelayURL: URL
    var transportFactory: any RelayFrameTransportFactory
    /// The local network: which paired Macs are reachable, and how to dial
    /// them. `nil` keeps every channel on the Relay (tests, or disabled).
    var directDiscovery: (any DirectPeerDiscovery)? = nil
    var directTransportFactory: (any DirectTransportFactory)? = nil
    var pairingAPI: any RelayPairingAPI = LiveRelayPairingAPI()
    /// How often a pairing attempt asks the Relay where the session is.
    var pairingPollInterval: Duration = .seconds(1)
    var makeRepository: @Sendable (HostID) throws -> any SessionRepository
    var removeRepository: @Sendable (HostID) throws -> Void
    /// Drops cache files of Macs that are no longer paired (launch housekeeping).
    var pruneRepositories: @Sendable (Set<HostID>) throws -> Void = { _ in }
    var requestTimeouts: RelayDeviceChannel.Timeouts
    /// Tests keep credentials out of the Keychain.
    var persistsCredentials = true

    /// Production: `RelayWebSocketClient`, one SQLite file per Mac under
    /// `Application Support/Lumi/Channels/<hostID>.sqlite3`.
    static func live(defaultRelayURL: URL = RelayBuildConfiguration.url) -> RelayDeviceDependencies {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumi", isDirectory: true)
            .appendingPathComponent("Channels", isDirectory: true)
        let browser = BonjourPeerBrowser()
        return RelayDeviceDependencies(
            defaultRelayURL: defaultRelayURL,
            transportFactory: RelayWebSocketTransportFactory(),
            directDiscovery: browser,
            directTransportFactory: BonjourDirectTransportFactory(browser: browser),
            makeRepository: { hostID in
                try SQLiteSessionRepository(path: directory.appendingPathComponent("\(hostID.rawValue).sqlite3").path)
            },
            removeRepository: { hostID in
                let base = directory.appendingPathComponent("\(hostID.rawValue).sqlite3").path
                for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: base + suffix) {
                    try FileManager.default.removeItem(atPath: base + suffix)
                }
            },
            pruneRepositories: { keep in
                let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
                for file in files {
                    guard let stem = file.components(separatedBy: ".sqlite3").first, stem != file else { continue }
                    if !keep.contains(HostID(stem)) {
                        try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
                    }
                }
            },
            requestTimeouts: .init()
        )
    }
}

/// All paired Macs. Credentials live in the Keychain; each Mac's sessions
/// live in that Mac's SQLite cache (the shared repository) and are loaded
/// into memory at launch, then kept current by index reconciles and the
/// daemon's event stream.
@MainActor
final class RelayDeviceController {
    private let secureStore = SecureStore(service: "app.huanan.lumi.ios.relay")
    private let credentialsAccount = "device-channels-v4"
    private let settings: LocalSettings
    private let dependencies: RelayDeviceDependencies
    private var channelOrder: [HostID] = []
    private var channels: [HostID: RelayDeviceChannel] = [:]
    private var observers: [UUID: () -> Void] = [:]
    /// Developer preview (`-LumiPreviewData`): fixed states instead of Relay.
    private var previewStates: [MacChannelState]?
    /// The paired Macs the local network shows right now, kept so a channel
    /// added later learns about its Mac without waiting for the next change.
    private var directEndpoints: [HostID: DirectEndpoint] = [:]
    private var discoveryTask: Task<Void, Never>?

    init(settings: LocalSettings = .shared, dependencies: RelayDeviceDependencies = .live(), loadStoredCredentials: Bool = true) {
        self.settings = settings
        self.dependencies = dependencies
        guard loadStoredCredentials else { return }
        let stored = (try? secureStore.load(RelayDeviceCredentialCollection.self, account: credentialsAccount))?.channels ?? []
        try? dependencies.pruneRepositories(Set(stored.map(\.hostID)))
        for credentials in stored {
            guard let channel = makeChannel(credentials) else { continue }
            channelOrder.append(credentials.hostID)
            channels[credentials.hostID] = channel
        }
    }

    // MARK: - Observation

    @discardableResult
    func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func notify() {
        for handler in observers.values { handler() }
    }

    // MARK: - Reading

    var isPaired: Bool { previewStates != nil || !channels.isEmpty }

    var channelStates: [MacChannelState] {
        if let previewStates { return previewStates }
        return channelOrder.compactMap { channels[$0]?.state }
    }

    func channelState(for hostID: HostID) -> MacChannelState? {
        channelStates.first { $0.hostID == hostID }
    }

    func session(hostID: HostID, id: SessionID) -> SessionDetail? {
        channelState(for: hostID)?.sessions.first { $0.summary.id == id }
    }

    // MARK: - Lifecycle

    func start() {
        for channel in channels.values { channel.start() }
        reportPushToken()
        startDiscovery()
    }

    /// Watches the local network for paired Macs and hands each channel its
    /// Mac's endpoint (or its disappearance).
    private func startDiscovery() {
        guard discoveryTask == nil, let discovery = dependencies.directDiscovery, dependencies.directTransportFactory != nil else { return }
        discoveryTask = Task { [weak self] in
            for await endpoints in discovery.endpoints() {
                guard let self else { return }
                self.directEndpoints = endpoints
                for (hostID, channel) in self.channels { channel.updateDirectEndpoint(endpoints[hostID]) }
            }
        }
    }

    // MARK: - Push token

    /// The APNs token this launch registered, hex-encoded. Reported to every
    /// paired Mac's Relay so the daemon can alert this iPhone while the app
    /// is suspended.
    private var apnsToken: String?
    /// One chain per Mac: push-token PUTs and the unpair DELETE run in
    /// arrival order. Without this a DELETE could land before an in-flight
    /// PUT and leave the Relay holding a token for an unpaired device — or
    /// two PUTs after a token rotation could land out of order.
    private var pushTokenTasks: [HostID: Task<Void, Never>] = [:]

    func updatePushToken(_ token: String) {
        apnsToken = token
        reportPushToken()
    }

    /// Re-reports the token to every paired Mac, unconditionally: the PUT is
    /// idempotent and cheap, and the Relay may have dropped the token on its
    /// own (revocation, APNs said the token is dead) — an "already reported"
    /// cache would never notice that and leave pushes silently dead.
    private func reportPushToken() {
        for hostID in channelOrder { reportPushToken(to: hostID) }
    }

    private func reportPushToken(to hostID: HostID) {
        guard let token = apnsToken, let credentials = channels[hostID]?.credentials else { return }
        enqueuePushTokenOperation(for: hostID) {
            // Failures are logged by the REST client; the next foreground
            // start() is the retry.
            try? await RelayRESTClient(baseURL: credentials.relayURL).updatePushToken(
                hostID: credentials.hostID,
                deviceID: credentials.deviceID,
                apnsToken: token,
                environment: RelayBuildConfiguration.apnsEnvironment,
                deviceToken: credentials.deviceToken
            )
        }
    }

    private func enqueuePushTokenOperation(for hostID: HostID, _ operation: @escaping @Sendable () async -> Void) {
        let previous = pushTokenTasks[hostID]
        pushTokenTasks[hostID] = Task {
            await previous?.value
            await operation()
        }
    }

    /// Ask every Mac for its index again (pull-to-refresh, `Refresh list`).
    func refreshAll() {
        for channel in channels.values { channel.refresh() }
        notify()
    }

    func refresh(hostID: HostID) {
        channels[hostID]?.refresh()
        notify()
    }

    /// Take one session whole again (`Refresh session` in the detail).
    func refreshSession(hostID: HostID, id: SessionID) {
        channels[hostID]?.refreshSession(id)
        notify()
    }

    /// The detail screen opened a session: its content is fetched now
    /// (whole, or the tail the held copy lacks) and kept live until closed.
    func openSession(hostID: HostID, id: SessionID) {
        channels[hostID]?.openSession(id)
        notify()
    }

    func closeSession(hostID: HostID, id: SessionID) {
        channels[hostID]?.closeSession(id)
    }

    /// The session's content is on its way (the detail shows a loading row).
    func isFetchingSession(hostID: HostID, id: SessionID) -> Bool {
        channels[hostID]?.isFetching(id) ?? false
    }

    /// The detail screen reached the top of what it holds: one page of
    /// older rows is taken.
    func loadOlder(hostID: HostID, id: SessionID) {
        channels[hostID]?.loadOlder(id)
        notify()
    }

    /// The Mac holds rows older than the ones this iPhone shows.
    func canLoadOlder(hostID: HostID, id: SessionID) -> Bool {
        channels[hostID]?.canLoadOlder(id) ?? false
    }

    func isLoadingOlder(hostID: HostID, id: SessionID) -> Bool {
        channels[hostID]?.isLoadingOlder(id) ?? false
    }

    /// The whole copies of rows the Relay carried trimmed.
    func fetchTimelineItems(hostID: HostID, id: SessionID, itemIDs: [TimelineItemID]) {
        channels[hostID]?.fetchItems(id, itemIDs: itemIDs)
        notify()
    }

    func isFetchingTimelineItems(hostID: HostID, id: SessionID, itemIDs: [TimelineItemID]) -> Bool {
        channels[hostID]?.isFetchingItems(id, itemIDs: itemIDs) ?? false
    }

    /// The app left the foreground: probes stop until `start()`.
    func pause() {
        for channel in channels.values { channel.pause() }
    }

    func usePreview(_ states: [MacChannelState]) {
        previewStates = states
        notify()
    }

    /// Usage › History: ask every Mac for the preset (each expands it with
    /// its own calendar). The preview keeps its fixture.
    func requestUsage(_ preset: UsageRangePreset) {
        guard previewStates == nil else { return }
        for channel in channels.values { channel.requestUsage(preset) }
        notify()
    }

    /// Usage › Plan: ask every Mac for its accounts and settings.
    func requestPlanUsage() {
        guard previewStates == nil else { return }
        for channel in channels.values { channel.requestPlanUsage() }
        notify()
    }

    // MARK: - Pairing

    var defaultRelayURL: URL { dependencies.defaultRelayURL }

    /// A pairing attempt against `relayURL` with `code`. Start it, watch
    /// `progress`, cancel it if the person leaves. Failures are
    /// `PairingFailure`; nothing touches the Keychain before `.paired`.
    func makePairingAttempt(relayURL: URL, code: String) -> RelayPairingAttempt {
        RelayPairingAttempt(controller: self, relayURL: relayURL, code: code)
    }

    /// Pairing the same Mac again keeps this iPhone's device id, so the Relay
    /// and the Mac update the one record (new key, new token, revocation
    /// lifted) instead of listing a second "Active" iPhone.
    func deviceID(forPairingWith hostID: HostID) -> DeviceID {
        channels[hostID]?.credentials.deviceID ?? DeviceID("device-\(UUID().uuidString.lowercased())")
    }

    var pairingAPI: any RelayPairingAPI { dependencies.pairingAPI }
    var pairingPollInterval: Duration { dependencies.pairingPollInterval }
    var pairingDeviceName: String { settings.deviceName }

    /// Installs a paired channel (also the test seam around `pair`).
    func addChannel(_ credentials: RelayDeviceCredentials) async throws {
        if let existing = channels[credentials.hostID] { await existing.stop(removeLocalData: false) }
        channelOrder.removeAll { $0 == credentials.hostID }
        channelOrder.append(credentials.hostID)
        guard let channel = makeChannel(credentials) else { throw ChannelCacheError.unavailable }
        channels[credentials.hostID] = channel
        settings.setLastSync(nil, for: credentials.hostID)
        try saveCredentials()
        channel.start()
        reportPushToken(to: credentials.hostID)
        notify()
    }

    /// Removes one Mac: its channel, credentials and cache file. The Mac's
    /// own pairing record stays until revoked there.
    func unpair(hostID: HostID) {
        if previewStates != nil {
            previewStates?.removeAll { $0.hostID == hostID }
            notify()
            return
        }
        guard let channel = channels.removeValue(forKey: hostID) else { return }
        channelOrder.removeAll { $0 == hostID }
        channel.cancelTasks()
        // Best-effort: ask the Relay to forget the APNs token. Queued behind
        // any in-flight PUT for this host so the delete is what lands last;
        // revoking on the Mac clears it server-side anyway.
        let credentials = channel.credentials
        enqueuePushTokenOperation(for: hostID) {
            try? await RelayRESTClient(baseURL: credentials.relayURL).deletePushToken(
                hostID: credentials.hostID,
                deviceID: credentials.deviceID,
                deviceToken: credentials.deviceToken
            )
        }
        Task { await channel.stop(removeLocalData: true) }
        settings.setLastSync(nil, for: hostID)
        try? saveCredentials()
        notify()
    }

    // MARK: - Review

    /// Opening a session on the iPhone counts as reviewing it everywhere:
    /// the row turns grey here at once, and the daemon is told so the Mac,
    /// the Notch and other iPhones follow.
    func markReviewed(hostID: HostID, id: SessionID) {
        if previewStates != nil {
            previewStates = previewStates?.map { state in
                guard state.hostID == hostID else { return state }
                return state.replacingSessions(state.sessions.map { detail in
                    guard detail.summary.id == id, detail.summary.needsReview else { return detail }
                    return SessionDetail(summary: detail.summary.reviewed, turns: detail.turns, timeline: detail.timeline)
                })
            }
            notify()
            return
        }
        guard let channel = channels[hostID], channel.markReviewed(id) else { return }
        notify()
    }

    // MARK: - Local data

    /// Hides one session on this iPhone until the daemon sends a newer
    /// version of it. The Mac keeps the session; the iPhone is read-only.
    func dismissSession(hostID: HostID, id: SessionID) {
        if previewStates != nil {
            previewStates = previewStates?.map { state in
                guard state.hostID == hostID else { return state }
                return state.replacingSessions(state.sessions.filter { $0.summary.id != id })
            }
            notify()
            return
        }
        channels[hostID]?.dismiss(id)
        notify()
    }

    /// Drops every cached session; each Mac is asked for its index again so
    /// the caches refill from the daemons.
    func clearReceivedData() {
        if previewStates != nil {
            previewStates = previewStates?.map { $0.replacingSessions([]) }
            notify()
            return
        }
        for channel in channels.values { channel.clear() }
        notify()
    }

    // MARK: - Private

    private func makeChannel(_ credentials: RelayDeviceCredentials) -> RelayDeviceChannel? {
        guard let cache = try? dependencies.makeRepository(credentials.hostID) else { return nil }
        let channel = RelayDeviceChannel(
            credentials: credentials,
            cache: cache,
            removeCache: dependencies.removeRepository,
            transportFactory: dependencies.transportFactory,
            directFactory: dependencies.directTransportFactory,
            timeouts: dependencies.requestTimeouts,
            settings: settings
        ) { [weak self] in
            self?.notify()
        }
        channel.updateDirectEndpoint(directEndpoints[credentials.hostID])
        return channel
    }

    private func saveCredentials() throws {
        guard dependencies.persistsCredentials else { return }
        let collection = RelayDeviceCredentialCollection(
            channels: channelOrder.compactMap { channels[$0]?.credentials }
        )
        if collection.channels.isEmpty {
            try secureStore.delete(account: credentialsAccount)
        } else {
            try secureStore.save(collection, account: credentialsAccount)
        }
    }
}

extension MacChannelState {
    func replacingSessions(_ sessions: [SessionDetail]) -> MacChannelState {
        MacChannelState(
            hostID: hostID,
            displayName: displayName,
            relayURL: relayURL,
            pairedAt: pairedAt,
            isConnected: isConnected,
            isHostOnline: isHostOnline,
            connectionPath: connectionPath,
            accessRevoked: accessRevoked,
            hasCompleteSync: hasCompleteSync,
            sessions: sessions,
            lastSyncAt: lastSyncAt,
            lastError: lastError,
            health: health,
            hasLoadedCache: hasLoadedCache,
            usage: usage,
            planUsage: planUsage
        )
    }
}

/// One Mac's answer to `fetch_usage`: the report for the preset last asked
/// for, when it landed, and what went wrong if it did not. A newer ask keeps
/// the previous report on screen until the answer arrives (`isLoading`).
struct UsageSnapshot: Equatable, Sendable {
    var report: UsageReport?
    var preset: UsageRangePreset?
    var fetchedAt: Date?
    var isLoading = false
    /// The last ask failed (timed out, or the daemon answered without a report).
    var error: String?
}

/// One Mac's answer to `fetch_plan_usage`: its accounts and the settings the
/// numbers follow (percent style), plus when they landed.
struct PlanUsageSnapshot: Equatable, Sendable {
    var state: PlanUsageState?
    var settings: DaemonSettings?
    var fetchedAt: Date?
    var isLoading = false
    var error: String?
}

/// One Mac-to-iPhone channel: this Mac's SQLite cache, the in-memory copy
/// the screens read, and the one Relay socket every session of that Mac is
/// multiplexed through.
///
/// The Relay only carries frames; it decides nothing here. Every
/// `sync_index` opens a channel session: both ends add a one-time key and
/// derive a session key that exists only in memory. A frame counts only
/// when it authenticates under the current session and its sequence moved
/// forward — so a frame the Relay repeats, reorders or keeps from an
/// earlier session changes nothing, and neither does a presence flag.
///
/// Sync is index-first and lazy, and a session's rows are read from the
/// newest end. Every connect (and pull-to-refresh, and any sequence gap)
/// asks the daemon for `session_index`; `SyncReconcilePlan.lazy` turns the
/// difference against the cache and the per-session `SessionSyncMark` into
/// prunes, summary writes, since-tails for held sessions that grew and
/// rebuilds for held sessions the daemon changed underneath. Opening a
/// session takes its tail (`fetch_session`, the newest rows) and shows each
/// part as it lands; scrolling back pages older rows (`fetch_session_before`);
/// a trimmed row is completed on demand (`fetch_timeline_items`). Nothing a
/// part carries ever erases rows — erasing is this end's own decision
/// (rebuild, `Refresh session`) and happens before the tail is asked for.
///
/// A request that gets no part for `Timeouts.fetch` is asked once more (the
/// daemon drops the earlier answer); a second miss drops that request alone
/// and tells the daemon so (`cancel_request`). Leaving a detail screen
/// cancels its page and row requests. The socket is probed every
/// `heartbeat.interval`; a probe unanswered for `heartbeat.timeout` is a
/// lost connection, and reconnects back off from 2 s to 30 s.
@MainActor
final class RelayDeviceChannel {
    /// As many sessions as the daemon's `list_sessions` serves.
    static let indexLimit = 10_000
    /// Rows a tail or an older page asks for.
    static let pageLimit = 80

    struct Timeouts: Sendable {
        var index: Duration = .seconds(20)
        /// Measured from the last part received, not from the ask.
        var fetch: Duration = .seconds(30)
        /// `fetch_usage` / `fetch_plan_usage`: one try, then the tab shows
        /// the failure and the next poll asks again.
        var usage: Duration = .seconds(20)
        var tick: Duration = .seconds(1)
        var retryDelay: Duration = .seconds(10)
        var heartbeat = RelayHeartbeat()
        var backoff = RelayBackoff()
        /// Screens are told about a change at most this often while parts land.
        var changeCoalesce: Duration = .milliseconds(80)
    }

    /// A Usage-tab request in flight. Kept apart from `pending`: those gate
    /// `hasCompleteSync`, and a usage answer is not part of the sync.
    private enum UsageRequest {
        case usage(UsageRangePreset)
        case planUsage
    }

    private enum PendingKind: Hashable {
        case index
        /// The newest rows of one session (`erase`: wipe the loaded rows
        /// before the first part lands — a rebuild or `Refresh session`).
        case tail(SessionID, erase: Bool)
        /// Rows from the mark's `lastItemAt` on.
        case since(SessionID)
        /// One page older than the loaded window.
        case history(SessionID)
        /// Whole copies of trimmed rows.
        case items(SessionID)

        var sessionID: SessionID? {
            switch self {
            case .index: nil
            case let .tail(id, _), let .since(id), let .history(id), let .items(id): id
            }
        }

        /// The content the detail screen waits for before it has anything to show.
        var loadsContent: Bool {
            switch self {
            case .tail, .since: true
            case .index, .history, .items: false
            }
        }
    }

    private struct PendingRequest {
        var kind: PendingKind
        var payload: RemoteSessionPayload
        var sentAt: Date
        /// When the last part of the answer landed; the timeout runs from here.
        var lastProgressAt: Date
        var attempts: Int
        var partsReceived: Set<Int> = []
        /// The first part has landed (the erase, if any, is done).
        var started = false
    }

    /// The two links a channel can run on. A channel session belongs to the
    /// link its `sync_index` went out on; its frames travel nowhere else.
    /// Moving to the other link is a new session.
    private enum LinkPath: Equatable {
        case relay
        case direct
    }

    private let onChange: () -> Void
    private let settings: LocalSettings
    private let cache: any SessionRepository
    private let removeCache: @Sendable (HostID) throws -> Void
    private let transportFactory: any RelayFrameTransportFactory
    private let directFactory: (any DirectTransportFactory)?
    private let timeouts: Timeouts
    private var transport: (any RelayFrameTransport)?
    /// The Mac as the local network last showed it; `nil` = not on this network.
    private var directEndpoint: DirectEndpoint?
    private var directTransport: (any RelayFrameTransport)?
    private var directConnectTask: Task<Void, Never>?
    private var directReceiveTask: Task<Void, Never>?
    private var directHeartbeatTask: Task<Void, Never>?
    private var directBackoff: RelayBackoff
    private var isDirectConnected = false
    private var startTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private var marksWriteTask: Task<Void, Never>?
    private var backoff: RelayBackoff

    private(set) var credentials: RelayDeviceCredentials
    /// Latest activity first, mirroring `cache.listSessions`.
    private var sessions: [SessionDetail] = []
    private var cacheLoaded = false
    /// The Relay's word on the daemon; a live direct link is the other.
    private var relayHostOnline = false
    private var isHostOnline: Bool { relayHostOnline || isDirectConnected }
    /// The Relay socket is up. Requests do not need it while the direct
    /// link carries the session: see `isLinked`.
    private var isConnected = false
    /// Some link to the Mac is up — the Relay socket or the direct connection.
    private var isLinked: Bool { isConnected || isDirectConnected }
    private var accessRevoked = false
    private var hasCompleteSync = false
    private var lastError: String?
    private var health: DaemonHealth?
    /// The daemon history revision this cache was taken from
    /// (`HistoryRevision`); `nil` until one is recorded.
    private var cacheHistoryRevision: Int?
    /// The channel session this connection syncs under. Memory only: gone
    /// with the connection or the Mac going offline, replaced by the next
    /// `sync_index`.
    private var channelSession: ChannelSession?
    /// A `sync_index` on its way: this end's one-time key, waiting for the
    /// daemon's `channel_opened`.
    private var channelOpening: ChannelOpening?
    /// Requests made while a session is opening; sent, in order, once it is.
    private var outbox: [RemoteSessionPayload] = []
    /// Sequence of device → host `request` frames on this connection. The
    /// daemon takes a session's requests only in rising order.
    private var requestSequence: UInt64 = 0
    /// Sealed requests leave in the order they were sealed.
    private var sendQueue: Task<Void, Never>?
    private var pending: [RequestID: PendingRequest] = [:]
    private var usageRequests: [RequestID: (kind: UsageRequest, sentAt: Date)] = [:]
    /// `nil` until the Usage tab first asks — the UI's "never loaded" state.
    private var usage: UsageSnapshot?
    private var planUsage: PlanUsageSnapshot?
    /// The index is the one answer that is applied whole: reconciling against
    /// half of it would prune what the other half lists.
    private var indexParts: [RequestID: [RemoteSessionPayload]] = [:]
    /// `generatedAt` of the index whose fetches are still landing.
    private var indexGeneratedAt: Date?
    /// Sessions a detail screen is showing: their timeline is kept current
    /// even before the first fetch landed.
    private var openSessions: Set<SessionID> = []
    /// The daemon's timeline facts from the latest index, so opening a
    /// session held from an earlier run knows whether its copy is behind.
    private var remoteFacts: [SessionID: SessionIndexEntry] = [:]
    /// What this iPhone holds of each session: the daemon's facts at the
    /// last completed sync and the loaded window. Persisted (`LocalSettings`)
    /// so a relaunch knows what it has without taking every tail again.
    private var marks: [SessionID: SessionSyncMark] {
        didSet { scheduleMarksWrite() }
    }
    /// Sessions hidden on this iPhone (`Delete`), kept out of `sessions` but
    /// still in the cache and still fed by the daemon; one rule on every
    /// path — event, summary, whole session, index — shows a hidden session
    /// again: its `lastActivityAt` moved past the moment it was hidden
    /// (real agent activity, not a metadata touch).
    private var hidden: [SessionID: HiddenSession] = [:]
    /// Serialises cache writes against each other (applies, merges, prunes).
    private var applyQueue: Task<Void, Never>?

    private struct HiddenSession {
        let hiddenAt: Date
        var detail: SessionDetail
    }

    private struct ChannelSession {
        let key: RelayChannelKey
        /// The link this session runs on.
        let path: LinkPath
        /// Highest frame sequence that authenticated in this session: the
        /// replay floor and the gap detector.
        var lastReceivedSequence: UInt64
    }

    private struct ChannelOpening {
        /// The `sync_index` that asked; `channel_opened` must echo it.
        let requestID: RequestID
        let ephemeral: RelayEphemeralKey
        let path: LinkPath
    }

    init(
        credentials: RelayDeviceCredentials,
        cache: any SessionRepository,
        removeCache: @escaping @Sendable (HostID) throws -> Void,
        transportFactory: any RelayFrameTransportFactory,
        directFactory: (any DirectTransportFactory)? = nil,
        timeouts: Timeouts,
        settings: LocalSettings,
        onChange: @escaping () -> Void
    ) {
        self.credentials = credentials
        self.cache = cache
        self.removeCache = removeCache
        self.transportFactory = transportFactory
        self.directFactory = directFactory
        self.timeouts = timeouts
        self.settings = settings
        self.onChange = onChange
        backoff = timeouts.backoff
        directBackoff = timeouts.backoff
        marks = settings.syncMarks(for: credentials.hostID)
    }

    /// The link the current (or opening) session runs on, for the Macs row.
    private var connectionPath: MacConnectionPath? {
        switch channelSession?.path ?? channelOpening?.path {
        case .direct?: .direct
        case .relay?: .relay
        case nil: nil
        }
    }

    var state: MacChannelState {
        MacChannelState(
            hostID: credentials.hostID,
            displayName: credentials.displayName,
            relayURL: credentials.relayURL,
            pairedAt: credentials.pairedAt,
            isConnected: isLinked,
            isHostOnline: isHostOnline,
            connectionPath: connectionPath,
            accessRevoked: accessRevoked,
            hasCompleteSync: hasCompleteSync,
            sessions: sessions,
            lastSyncAt: settings.lastSync(for: credentials.hostID),
            lastError: lastError,
            health: health,
            hasLoadedCache: cacheLoaded,
            usage: usage,
            planUsage: planUsage
        )
    }

    // MARK: - Lifecycle

    /// Loads the cache (first run only), then connects. Idempotent. Called
    /// again when the app comes to the foreground.
    func start() {
        guard startTask == nil else { return }
        if isConnected {
            // Foreground again: the socket may have been suspended; ask for
            // the index so whatever was dropped meanwhile is healed, and
            // probe the links now instead of at the next heartbeat.
            startHeartbeat()
            if isDirectConnected { startDirectHeartbeat() }
            startTicker()
            requestIndex()
            return
        }
        startTask = Task { [weak self] in
            guard let self else { return }
            if !self.cacheLoaded { await self.loadCache() }
            await self.connect()
            self.startTask = nil
        }
    }

    /// The app left the foreground: the socket will be suspended with it, so
    /// the probes stop (a probe that cannot run is not a lost link).
    func pause() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        directHeartbeatTask?.cancel()
        directHeartbeatTask = nil
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Direct link

    /// The local network showed (or stopped showing) this Mac. A Mac that
    /// appears is dialled; one that vanishes from the advertisement keeps a
    /// live connection — Bonjour flickers, TCP tells the truth.
    func updateDirectEndpoint(_ endpoint: DirectEndpoint?) {
        guard directFactory != nil else { return }
        let appeared = endpoint != nil && directEndpoint == nil
        directEndpoint = endpoint
        if endpoint == nil {
            directConnectTask?.cancel()
            directConnectTask = nil
        } else if appeared || (!isDirectConnected && directConnectTask == nil) {
            connectDirect()
        }
    }

    private func connectDirect() {
        guard let directFactory, let endpoint = directEndpoint, !isDirectConnected, directConnectTask == nil, cacheLoaded else { return }
        directConnectTask = Task { [weak self] in
            guard let self else { return }
            let transport = directFactory.makeTransport(to: endpoint)
            do {
                try await transport.connect(hostID: credentials.hostID, role: .device(credentials.deviceID), token: credentials.deviceToken)
            } catch {
                self.directConnectTask = nil
                guard !Task.isCancelled, self.directEndpoint != nil else { return }
                // Still advertised but not answering: try again later.
                let delay = self.directBackoff.next()
                self.directConnectTask = Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled, let self else { return }
                    self.directConnectTask = nil
                    self.connectDirect()
                }
                return
            }
            guard !Task.isCancelled else { await transport.disconnect(); return }
            self.directTransport = transport
            self.isDirectConnected = true
            self.directBackoff.reset()
            self.directConnectTask = nil
            self.directReceiveTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        let message = try await transport.next()
                        await self?.handle(message, from: .direct)
                    } catch {
                        guard !Task.isCancelled else { return }
                        self?.directLinkLost()
                        return
                    }
                }
            }
            self.startDirectHeartbeat()
            // Move the channel session onto the direct link: the Relay
            // carries nothing for this Mac until the link goes.
            self.requestIndex(superseding: true, path: .direct)
            self.onChange()
        }
    }

    private func startDirectHeartbeat() {
        directHeartbeatTask?.cancel()
        guard let transport = directTransport else { return }
        directHeartbeatTask = Task { [weak self, timeouts] in
            await timeouts.heartbeat.run(on: transport)
            guard !Task.isCancelled, let self, self.directTransport === transport else { return }
            await transport.disconnect()
            self.directLinkLost()
        }
    }

    /// The direct connection ended: the session on it is over, and the Relay
    /// (if the daemon is online there) takes the channel back with a new
    /// opening. Dialling resumes while the Mac stays on the network.
    private func directLinkLost() {
        guard isDirectConnected else { return }
        isDirectConnected = false
        directReceiveTask?.cancel()
        directReceiveTask = nil
        directHeartbeatTask?.cancel()
        directHeartbeatTask = nil
        let transport = directTransport
        directTransport = nil
        Task { await transport?.disconnect() }
        if channelSession?.path == .direct || channelOpening?.path == .direct {
            channelSession = nil
            channelOpening = nil
            indexParts = [:]
            if isConnected, relayHostOnline {
                requestIndex(superseding: true, path: .relay)
            } else {
                for (id, request) in pending where request.kind == .index { pending[id] = nil }
            }
        }
        onChange()
        if directEndpoint != nil { connectDirect() }
    }

    private func disconnectDirect() async {
        directConnectTask?.cancel()
        directConnectTask = nil
        directReceiveTask?.cancel()
        directReceiveTask = nil
        directHeartbeatTask?.cancel()
        directHeartbeatTask = nil
        let transport = directTransport
        directTransport = nil
        isDirectConnected = false
        await transport?.disconnect()
    }

    /// Connected: ask for the index. Otherwise: connect (which asks).
    func refresh() {
        if isLinked {
            requestIndex()
        } else {
            start()
        }
    }

    /// `Refresh session`: the loaded rows are wiped and the tail taken again.
    func refreshSession(_ id: SessionID) {
        guard isLinked, isHostOnline else { return }
        cancelRequests(for: id) { _ in true }
        requestTail(id, erase: true)
    }

    /// A detail screen opened the session: take its newest rows now — or,
    /// when a loaded copy is held, whatever the daemon's index says it lacks
    /// — and keep it current while the screen is up.
    func openSession(_ id: SessionID) {
        openSessions.insert(id)
        guard isLinked, isHostOnline, !isFetching(id), detail(id) != nil else { return }
        guard let mark = marks[id], mark.isLoaded else {
            requestTail(id, erase: false)
            return
        }
        guard let remote = remoteFacts[id] else { return }
        switch SyncReconcilePlan.classify(remote: remote, mark: mark) {
        case .rebuild:
            requestTail(id, erase: true)
        case let .fetchSince(since):
            send(kind: .since(id), payload: RemoteSessionPayload(kind: .fetchTimelineSince, sessionIDs: [id], since: since, limit: Self.pageLimit))
        case .upToDate:
            break
        }
    }

    /// The detail screen left: its page and row requests are cancelled on
    /// both ends; a tail or since-tail still in flight lands in the cache.
    func closeSession(_ id: SessionID) {
        openSessions.remove(id)
        cancelRequests(for: id) { kind in
            if case .history = kind { return true }
            if case .items = kind { return true }
            return false
        }
    }

    /// One page of rows older than the loaded window.
    func loadOlder(_ id: SessionID) {
        guard isLinked, isHostOnline, canLoadOlder(id), !isLoadingOlder(id),
              let mark = marks[id], let oldest = mark.oldest else { return }
        send(kind: .history(id), payload: RemoteSessionPayload(kind: .fetchSessionBefore, sessionIDs: [id], limit: Self.pageLimit, before: oldest))
    }

    /// Rows older than the loaded window exist on the Mac.
    func canLoadOlder(_ id: SessionID) -> Bool {
        guard let mark = marks[id], mark.isLoaded else { return false }
        return mark.hasOlder
    }

    func isLoadingOlder(_ id: SessionID) -> Bool {
        pending.values.contains { if case .history(id) = $0.kind { true } else { false } }
    }

    /// The whole copies of trimmed rows (`TimelineItem.truncated`).
    func fetchItems(_ id: SessionID, itemIDs: [TimelineItemID]) {
        guard isLinked, isHostOnline, !itemIDs.isEmpty else { return }
        let wanted = Set(itemIDs)
        let alreadyAsked = pending.values.contains { request in
            guard case .items(id) = request.kind else { return false }
            return Set(request.payload.itemIDs ?? []) == wanted
        }
        guard !alreadyAsked else { return }
        send(kind: .items(id), payload: RemoteSessionPayload(kind: .fetchTimelineItems, sessionIDs: [id], itemIDs: itemIDs))
    }

    func isFetchingItems(_ id: SessionID, itemIDs: [TimelineItemID]) -> Bool {
        let wanted = Set(itemIDs)
        return pending.values.contains { request in
            guard case .items(id) = request.kind else { return false }
            return !wanted.isDisjoint(with: request.payload.itemIDs ?? [])
        }
    }

    /// The session's rows are on their way (the detail shows a loading row).
    func isFetching(_ id: SessionID) -> Bool {
        pending.values.contains { $0.kind.loadsContent && $0.kind.sessionID == id }
    }

    private func detail(_ id: SessionID) -> SessionDetail? {
        sessions.first { $0.summary.id == id } ?? hidden[id]?.detail
    }

    /// Sessions whose rows this iPhone holds (a loaded window) or shows: the
    /// ones live events are applied to in full.
    private var heldIDs: Set<SessionID> {
        var ids = openSessions
        for (id, mark) in marks where mark.isLoaded { ids.insert(id) }
        return ids
    }

    /// Ask for the History report of a preset. Offline: the last report
    /// stays, marked with the error, so the tab can say how old it is.
    func requestUsage(_ preset: UsageRangePreset) {
        var snapshot = usage ?? UsageSnapshot()
        defer { usage = snapshot }
        guard isLinked, isHostOnline else {
            snapshot.isLoading = false
            snapshot.error = "offline"
            return
        }
        // One ask per preset in flight; a different preset supersedes it.
        for (id, request) in usageRequests {
            if case .usage = request.kind { usageRequests[id] = nil }
        }
        snapshot.isLoading = true
        snapshot.error = nil
        let requestID = RequestID()
        usageRequests[requestID] = (.usage(preset), Date())
        sendRequest(RemoteSessionPayload(kind: .fetchUsage, generatedAt: Date(), requestID: requestID, usageRange: preset))
    }

    func requestPlanUsage() {
        var snapshot = planUsage ?? PlanUsageSnapshot()
        defer { planUsage = snapshot }
        guard isLinked, isHostOnline else {
            snapshot.isLoading = false
            snapshot.error = "offline"
            return
        }
        guard !usageRequests.values.contains(where: { if case .planUsage = $0.kind { true } else { false } }) else { return }
        snapshot.isLoading = true
        snapshot.error = nil
        let requestID = RequestID()
        usageRequests[requestID] = (.planUsage, Date())
        sendRequest(RemoteSessionPayload(kind: .fetchPlanUsage, generatedAt: Date(), requestID: requestID))
    }

    func stop(removeLocalData: Bool) async {
        cancelTasks()
        await disconnectDirect()
        let transport = self.transport
        self.transport = nil
        await transport?.disconnect()
        isConnected = false
        relayHostOnline = false
        endChannelSession()
        pending = [:]
        indexParts = [:]
        if removeLocalData {
            sessions = []
            marks = [:]
            try? removeCache(credentials.hostID)
        }
        onChange()
    }

    func cancelTasks() {
        startTask?.cancel()
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        reconnectTask?.cancel()
        tickTask?.cancel()
        retryTask?.cancel()
        changeTask?.cancel()
        directConnectTask?.cancel()
        directReceiveTask?.cancel()
        directHeartbeatTask?.cancel()
        startTask = nil
        receiveTask = nil
        heartbeatTask = nil
        reconnectTask = nil
        tickTask = nil
        retryTask = nil
        changeTask = nil
        directConnectTask = nil
        directReceiveTask = nil
        directHeartbeatTask = nil
    }

    /// Clears the review flag locally and tells the daemon. Returns false
    /// when the session is unknown or already reviewed.
    func markReviewed(_ id: SessionID) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.summary.id == id }),
              sessions[index].summary.needsReview else { return false }
        let detail = sessions[index]
        sessions[index] = SessionDetail(summary: detail.summary.reviewed, turns: detail.turns, timeline: detail.timeline)
        enqueueCacheWrite { [cache] in try await cache.markSessionReviewed(id) }
        if isLinked {
            sendRequest(RemoteSessionPayload(kind: .sessionReviewed, sessionIDs: [id]))
        }
        return true
    }

    func dismiss(_ id: SessionID) {
        guard let detail = sessions.first(where: { $0.summary.id == id }) else { return }
        hidden[id] = HiddenSession(hiddenAt: detail.summary.lastActivityAt, detail: detail)
        sessions.removeAll { $0.summary.id == id }
    }

    /// The Mac's daemon rewrote rows it already held (`HistoryRevision`): no
    /// summary and no clock moved, so the index diff cannot see it. A copy
    /// taken from another revision is dropped and taken again.
    private func adoptHistoryRevision() {
        guard let health else { return }
        let revision = health.historyRevision ?? HistoryRevision.first
        // A cache from before revisions were recorded was taken from a
        // daemon at the first one.
        guard revision != cacheHistoryRevision ?? HistoryRevision.first else { return }
        let isFirstCopy = sessions.isEmpty && hidden.isEmpty
        cacheHistoryRevision = revision
        enqueueCacheWrite { [cache] in try await cache.setHistoryRevision(revision) }
        if !isFirstCopy { clear() }
    }

    /// Empties the cache (no tombstones, no dedupe reset) and re-indexes.
    func clear() {
        sessions = []
        hidden = [:]
        marks = [:]
        hasCompleteSync = false
        enqueueCacheWrite { [cache] in _ = try await cache.pruneSessions(keeping: []) }
        if isLinked { requestIndex() }
        onChange()
    }

    // MARK: - Cache

    private func loadCache() async {
        do {
            var loaded: [SessionDetail] = []
            for summary in try await cache.listSessions(limit: Self.indexLimit) {
                if let detail = try await Self.loadFullDetail(cache, id: summary.id) {
                    loaded.append(detail)
                }
            }
            sessions = loaded
            // A mark for a session the cache no longer has is stale.
            let cached = Set(loaded.map(\.summary.id))
            marks = marks.filter { cached.contains($0.key) }
            cacheHistoryRevision = try await cache.historyRevision()
            cacheLoaded = true
            // A health frame that came before the cache was read.
            adoptHistoryRevision()
        } catch {
            lastError = "Unable to read the session cache: \(error)"
        }
        onChange()
        // A Mac seen on the network before the cache was ready can be dialled now.
        connectDirect()
    }

    private static func loadFullDetail(_ cache: any SessionRepository, id: SessionID) async throws -> SessionDetail? {
        var cursor: PaginationCursor?
        var turns: [TurnSummary] = []
        var timeline: [TimelineItem] = []
        var summary: SessionSummary?
        repeat {
            guard let page = try await cache.sessionDetail(id: id, cursor: cursor, limit: 500) else { return nil }
            summary = page.summary
            if !page.turns.isEmpty { turns = page.turns }
            timeline += page.timeline
            cursor = page.nextCursor
        } while cursor != nil
        guard let summary else { return nil }
        return SessionDetail(summary: summary, turns: turns, timeline: timeline)
    }

    /// Cache writes run one after another, in order, off the frame handler.
    private func enqueueCacheWrite(_ body: @escaping @Sendable () async throws -> Void) {
        let previous = applyQueue
        applyQueue = Task { [weak self] in
            await previous?.value
            do {
                try await body()
            } catch {
                self?.lastError = "Unable to write the session cache: \(error)"
            }
        }
    }

    /// A cache operation whose result the caller needs, run in queue order
    /// (after every write enqueued before it, before every write after it).
    private func cacheWrite<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = applyQueue
        let task = Task<T, Error> {
            await previous?.value
            return try await body()
        }
        applyQueue = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Marks go to disk a moment after they changed, once per burst.
    private func scheduleMarksWrite() {
        guard marksWriteTask == nil else { return }
        marksWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self else { return }
            self.marksWriteTask = nil
            self.settings.setSyncMarks(self.marks, for: self.credentials.hostID)
        }
    }

    /// Screens hear about a burst of parts once, not per part.
    private func scheduleChange() {
        guard changeTask == nil else { return }
        changeTask = Task { [weak self, timeouts] in
            try? await Task.sleep(for: timeouts.changeCoalesce)
            guard let self else { return }
            self.changeTask = nil
            self.onChange()
        }
    }

    // MARK: - Connection

    private func connect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        await transport?.disconnect()
        let transport = transportFactory.makeTransport(baseURL: credentials.relayURL)
        self.transport = transport
        isConnected = false
        relayHostOnline = false
        hasCompleteSync = false
        if channelSession?.path != .direct && channelOpening?.path != .direct {
            endChannelSession()
            pending = [:]
            indexParts = [:]
        }
        requestSequence = 0
        sendQueue = nil
        do {
            try await transport.connect(
                hostID: credentials.hostID,
                role: .device(credentials.deviceID),
                token: credentials.deviceToken
            )
            isConnected = true
            accessRevoked = false
            lastError = nil
            backoff.reset()
            receiveTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        let message = try await transport.next()
                        await self?.handle(message)
                    } catch {
                        guard !Task.isCancelled else { return }
                        self?.connectionFailed(error)
                        return
                    }
                }
            }
            startHeartbeat()
            startTicker()
            // The worker answers the connect with presence; the index request
            // goes out as soon as the host is known to be online (`handle`).
        } catch {
            connectionFailed(error)
        }
        onChange()
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        guard let transport else { return }
        heartbeatTask = Task { [weak self, timeouts] in
            await timeouts.heartbeat.run(on: transport)
            guard !Task.isCancelled, let self, self.transport === transport else { return }
            // The link stopped answering: tear it down so the receive loop
            // ends, and reconnect like any other loss.
            await transport.disconnect()
            self.connectionFailed(RelayClientError.notConnected)
        }
    }

    private func connectionFailed(_ error: Error) {
        guard isConnected || reconnectTask == nil else { return }
        isConnected = false
        relayHostOnline = false
        hasCompleteSync = false
        // A session on the direct link outlives the Relay socket.
        if channelSession?.path != .direct && channelOpening?.path != .direct {
            endChannelSession()
            pending = [:]
            indexParts = [:]
        }
        tickTask?.cancel()
        tickTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if case RelayClientError.unauthorized = error {
            // The Mac revoked this iPhone (or the pairing record is gone):
            // no retry loop — the Macs screen says so and offers re-pairing.
            accessRevoked = true
            lastError = "This iPhone was revoked on the Mac. Pair again to reconnect."
        } else if case RelayClientError.upgradeRequired = error {
            lastError = "Update Lumi on this iPhone to keep syncing with this Mac."
        } else {
            lastError = String(describing: error)
        }
        onChange()
        scheduleReconnect(after: error)
    }

    private func scheduleReconnect(after error: Error) {
        guard Self.shouldReconnect(after: error), reconnectTask == nil else { return }
        let delay = backoff.next()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.connect()
        }
    }

    private static func shouldReconnect(after error: Error) -> Bool {
        guard let relayError = error as? RelayClientError else { return true }
        switch relayError {
        case .unauthorized, .upgradeRequired:
            return false
        case let .server(status, _):
            return status != 401 && status != 403
        default:
            return true
        }
    }

    // MARK: - Requests

    /// Asks for the index — and with it opens a new channel session: this
    /// end's one-time key goes out in a `sync_index` sealed with the
    /// handshake key, and the daemon's `channel_opened` completes the
    /// session key (`receiveOpening`). Until then the previous session, if
    /// any, keeps taking frames, and requests wait in the outbox.
    ///
    /// One at a time, unless `superseding`: the daemon just (re)appeared
    /// behind the Relay and cannot know an opening sent before that.
    private func requestIndex(superseding: Bool = false, attempts: Int = 1, path: LinkPath? = nil) {
        let path = path ?? preferredPath
        switch path {
        case .relay: guard isConnected, relayHostOnline else { return }
        case .direct: guard isDirectConnected else { return }
        }
        guard superseding || !pending.values.contains(where: { if case .index = $0.kind { true } else { false } }) else { return }
        let ephemeral = RelayEphemeralKey()
        let requestID = RequestID()
        let opening: RemoteSessionPayload
        let handshakeKey: RelayChannelKey
        do {
            handshakeKey = try self.handshakeKey()
            opening = RemoteSessionPayload(kind: .syncIndex, generatedAt: Date(), requestID: requestID, ephemeralKey: try ephemeral.publicKey)
        } catch {
            lastError = "Unable to start syncing: \(error)"
            return
        }
        // The daemon answers a request only in the session it arrived in:
        // whatever is still unanswered is asked again once this one opens.
        // An earlier index is void — its answer belongs to its own session.
        requeueUnansweredRequests()
        channelOpening = ChannelOpening(requestID: requestID, ephemeral: ephemeral, path: path)
        let now = Date()
        pending[requestID] = PendingRequest(kind: .index, payload: opening, sentAt: now, lastProgressAt: now, attempts: attempts)
        transmit(opening, key: handshakeKey, path: path)
    }

    /// Direct when the Mac is on this network and answering, the Relay otherwise.
    private var preferredPath: LinkPath { isDirectConnected ? .direct : .relay }

    private func link(for path: LinkPath) -> (any RelayFrameTransport)? {
        switch path {
        case .relay: transport
        case .direct: directTransport
        }
    }

    private func requeueUnansweredRequests() {
        var queued = Set(outbox.compactMap(\.requestID))
        for (id, request) in pending {
            if case .index = request.kind {
                pending[id] = nil
                indexParts[id] = nil
            } else if queued.insert(id).inserted {
                outbox.append(request.payload)
            }
        }
        for (id, request) in usageRequests where queued.insert(id).inserted {
            switch request.kind {
            case let .usage(preset):
                outbox.append(RemoteSessionPayload(kind: .fetchUsage, generatedAt: Date(), requestID: id, usageRange: preset))
            case .planUsage:
                outbox.append(RemoteSessionPayload(kind: .fetchPlanUsage, generatedAt: Date(), requestID: id))
            }
        }
    }

    /// The key the two long-term keys of this pairing derive. It seals only
    /// the `sync_index` / `channel_opened` exchange.
    private func handshakeKey() throws -> RelayChannelKey {
        try RelayCryptography.handshakeKey(
            privateKey: credentials.keyPair.privateKey,
            peerPublicKey: credentials.hostPublicKey,
            hostID: credentials.hostID,
            deviceID: credentials.deviceID
        )
    }

    private func endChannelSession() {
        channelSession = nil
        channelOpening = nil
        outbox = []
    }

    private func requestTail(_ id: SessionID, erase: Bool) {
        send(kind: .tail(id, erase: erase), payload: RemoteSessionPayload(kind: .fetchSession, sessionIDs: [id], limit: Self.pageLimit))
    }

    private func send(kind: PendingKind, payload: RemoteSessionPayload, attempts: Int = 1) {
        let requestID = RequestID()
        let now = Date()
        let stamped = RemoteSessionPayload(
            kind: payload.kind,
            generatedAt: now,
            requestID: requestID,
            sessionIDs: payload.sessionIDs,
            since: payload.since,
            limit: payload.limit,
            before: payload.before,
            itemIDs: payload.itemIDs
        )
        pending[requestID] = PendingRequest(kind: kind, payload: stamped, sentAt: now, lastProgressAt: now, attempts: attempts)
        sendRequest(stamped)
    }

    /// Drops the pending requests for `id` that `matching` selects and tells
    /// the daemon to stop answering them.
    private func cancelRequests(for id: SessionID, matching: (PendingKind) -> Bool) {
        for (requestID, request) in pending where request.kind.sessionID == id && matching(request.kind) {
            pending[requestID] = nil
            outbox.removeAll { $0.requestID == requestID }
            sendRequest(RemoteSessionPayload(kind: .cancelRequest, generatedAt: Date(), requestID: RequestID(), cancels: requestID))
        }
    }

    /// Sends a request inside the open channel session. While a session is
    /// opening the request waits for it; with none at all there is nobody
    /// to hear it and the caller's own timeout or next sync covers it.
    private func sendRequest(_ payload: RemoteSessionPayload) {
        if channelOpening != nil {
            outbox.append(payload)
        } else if let session = channelSession {
            transmit(payload, key: session.key, path: session.path)
        }
    }

    private func flushOutbox() {
        guard let session = channelSession else { return }
        let waiting = outbox
        outbox = []
        for payload in waiting { transmit(payload, key: session.key, path: session.path) }
    }

    /// Seals now, on the next request sequence, and sends behind every
    /// request sealed before it — the daemon drops a request whose sequence
    /// is not past the previous one's. Every request of a session travels
    /// the session's own link.
    private func transmit(_ payload: RemoteSessionPayload, key: RelayChannelKey, path: LinkPath) {
        guard let transport = link(for: path) else { return }
        requestSequence += 1
        let frame: RelayRoutingFrame
        do {
            frame = try RelayCryptography.seal(
                payload,
                hostID: credentials.hostID,
                deviceID: credentials.deviceID,
                sequence: requestSequence,
                kind: .request,
                key: key
            )
        } catch {
            lastError = "Unable to send request: \(error)"
            onChange()
            return
        }
        let previous = sendQueue
        sendQueue = Task { [weak self] in
            await previous?.value
            do {
                try await transport.send(frame)
            } catch {
                self?.lastError = "Unable to send request: \(error)"
                self?.onChange()
            }
        }
    }

    private func startTicker() {
        tickTask?.cancel()
        tickTask = Task { [weak self, timeouts] in
            while !Task.isCancelled {
                try? await Task.sleep(for: timeouts.tick)
                guard !Task.isCancelled else { return }
                self?.expirePendingRequests()
            }
        }
    }

    /// A request whose answer made no progress for its timeout is asked once
    /// more under a new id (the daemon drops the earlier answer for the same
    /// session). A second miss gives that request up — alone: what else is
    /// in flight keeps going, and whatever parts already landed stay — and
    /// tells the daemon to stop. The index keeps its own rule: a second
    /// miss pauses, then opens a fresh session.
    private func expirePendingRequests() {
        let now = Date()
        let lateUsage = usageRequests.filter { Duration.seconds(now.timeIntervalSince($0.value.sentAt)) > timeouts.usage }
        if !lateUsage.isEmpty {
            for (id, request) in lateUsage {
                usageRequests[id] = nil
                switch request.kind {
                case .usage:
                    usage?.isLoading = false
                    usage?.error = "timed out"
                case .planUsage:
                    planUsage?.isLoading = false
                    planUsage?.error = "timed out"
                }
            }
            onChange()
        }
        var expired: [(RequestID, PendingRequest)] = []
        for (id, request) in pending {
            let limit: Duration = if case .index = request.kind { timeouts.index } else { timeouts.fetch }
            if Duration.seconds(now.timeIntervalSince(request.lastProgressAt)) > limit { expired.append((id, request)) }
        }
        guard !expired.isEmpty else { return }
        var indexGaveUp = false
        for (id, request) in expired {
            pending[id] = nil
            indexParts[id] = nil
            outbox.removeAll { $0.requestID == id }
            if case .index = request.kind {
                if request.attempts >= 2 {
                    indexGaveUp = true
                } else {
                    // Never the same opening twice: a fresh one-time key.
                    requestIndex(superseding: true, attempts: request.attempts + 1)
                }
            } else if request.attempts >= 2 {
                sendRequest(RemoteSessionPayload(kind: .cancelRequest, generatedAt: now, requestID: RequestID(), cancels: id))
                lastError = "The Mac did not answer; try again."
            } else {
                // A tail that was to erase first already did on its first part.
                var kind = request.kind
                if case let .tail(sessionID, erase) = kind, erase, request.started { kind = .tail(sessionID, erase: false) }
                send(kind: kind, payload: request.payload, attempts: request.attempts + 1)
            }
        }
        onChange()
        if indexGaveUp {
            channelOpening = nil
            outbox = []
            lastError = "The Mac did not answer; retrying."
            retryTask?.cancel()
            retryTask = Task { [weak self, timeouts] in
                try? await Task.sleep(for: timeouts.retryDelay)
                guard !Task.isCancelled else { return }
                self?.requestIndex()
            }
        }
    }

    // MARK: - Inbound

    private func handle(_ message: RelayIncomingMessage, from path: LinkPath = .relay) async {
        switch message {
        case let .presence(online):
            if path == .direct {
                // The direct link says what it is: up. Its loss comes as an error.
                return
            }
            // Presence is the Relay's word, not the daemon's: it starts or
            // stops asking, and never touches what a session has received.
            relayHostOnline = online
            if channelSession?.path == .direct || channelOpening?.path == .direct {
                // The channel lives on the direct link; the Relay's view of
                // the daemon changes nothing here.
                break
            }
            hasCompleteSync = false
            if online {
                // First sight of the daemon — or the daemon reconnected behind
                // the Relay (which repeats `online`) and forgot every session,
                // so nothing reaches us until we open one again.
                requestIndex(superseding: true, path: .relay)
            } else {
                endChannelSession()
                pending = [:]
                indexParts = [:]
                failUsageRequests("offline")
            }
        case let .frame(frame):
            guard frame.hostID == credentials.hostID,
                  frame.deviceID == credentials.deviceID,
                  frame.kind == .data else { return }
            if receiveOpening(frame, from: path) { break }
            // Authenticate first: a frame that does not open under this
            // session's key is not the daemon's for this session and moves
            // nothing. A frame on the other link is not this session's either.
            guard let session = channelSession, session.path == path, frame.sequence > session.lastReceivedSequence else { return }
            let payload: RemoteSessionPayload
            do {
                payload = try RelayCryptography.open(frame, key: session.key)
            } catch {
                lastError = "Unable to decrypt relay update: \(error)"
                break
            }
            let gap = frame.sequence > session.lastReceivedSequence + 1
            channelSession?.lastReceivedSequence = frame.sequence
            if path == .relay { relayHostOnline = true }
            await apply(payload)
            lastError = nil
            if gap {
                // Dropped frames: whatever they carried is healed by the index.
                hasCompleteSync = false
                requestIndex()
            }
            scheduleChange()
            return
        case let .error(error):
            lastError = "Relay: \(error.code)"
        case .pairingDevice, .pairingClosed, .devicesChanged:
            // Host-socket control messages; a device socket never gets them.
            return
        }
        onChange()
    }

    /// While a `sync_index` is pending: a frame sealed with the handshake
    /// key is the daemon's answer to an opening. `channel_opened` echoing
    /// this one carries the daemon's one-time key; the session key both
    /// ends derive takes over from the frame after it. Returns false for a
    /// frame that is not sealed with the handshake key (the current
    /// session's, usually).
    private func receiveOpening(_ frame: RelayRoutingFrame, from path: LinkPath) -> Bool {
        guard let opening = channelOpening, opening.path == path,
              let handshakeKey = try? handshakeKey(),
              let payload = try? RelayCryptography.open(frame, key: handshakeKey) else { return false }
        // The answer to an opening this iPhone has since replaced is void.
        guard payload.kind == .channelOpened, payload.requestID == opening.requestID,
              let hostEphemeralKey = payload.ephemeralKey else { return true }
        do {
            let key = try RelayCryptography.sessionKey(
                as: .device,
                ephemeral: opening.ephemeral,
                peerEphemeralPublicKey: hostEphemeralKey,
                privateKey: credentials.keyPair.privateKey,
                peerPublicKey: credentials.hostPublicKey,
                hostID: credentials.hostID,
                deviceID: credentials.deviceID
            )
            channelSession = ChannelSession(key: key, path: opening.path, lastReceivedSequence: frame.sequence)
            channelOpening = nil
            if path == .relay { relayHostOnline = true }
            lastError = nil
            pending[opening.requestID]?.lastProgressAt = Date()
            flushOutbox()
        } catch {
            lastError = "Unable to start syncing: \(error)"
        }
        return true
    }

    private func apply(_ payload: RemoteSessionPayload) async {
        switch payload.kind {
        case .sessionIndex:
            guard let requestID = payload.requestID, pending[requestID] != nil else { return }
            pending[requestID]?.lastProgressAt = Date()
            indexParts[requestID, default: []].append(payload)
            guard let entries = RelayFrameReduction.assembleIndex(parts: indexParts[requestID] ?? []) else { return }
            indexParts[requestID] = nil
            pending[requestID] = nil
            await reconcile(entries, generatedAt: payload.generatedAt)
        case .sessionTail, .sessionHistory, .sessionTimeline, .sessionItems:
            await applySessionPart(payload)
        case .sessionMessage:
            await applyEvents(payload.events ?? [])
        case .sessionInfo:
            for summary in payload.summaries ?? [] {
                if updateSummary(summary) {
                    enqueueCacheWrite { [cache] in try await cache.updateSummary(summary) }
                } else {
                    insertSummaryOnly(summary)
                }
            }
            sortSessions()
        case .sessionRemoved:
            let ids = payload.sessionIDs ?? []
            for id in ids {
                sessions.removeAll { $0.summary.id == id }
                hidden[id] = nil
                marks[id] = nil
                enqueueCacheWrite { [cache] in _ = try await cache.deleteSession(id: id) }
                if let requestID = payload.requestID { pending[requestID] = nil }
            }
            completeSyncIfSettled()
        case .health:
            health = payload.health
            if cacheLoaded { adoptHistoryRevision() }
        case .usageReport:
            guard let requestID = payload.requestID, let request = usageRequests[requestID], case let .usage(preset) = request.kind else { return }
            usageRequests[requestID] = nil
            var snapshot = usage ?? UsageSnapshot()
            snapshot.isLoading = false
            if let report = payload.usage {
                snapshot.report = report
                snapshot.preset = preset
                snapshot.fetchedAt = payload.generatedAt
                snapshot.error = nil
            } else {
                snapshot.error = "The Mac could not build the report."
            }
            usage = snapshot
        case .planUsage:
            guard let requestID = payload.requestID, let request = usageRequests[requestID], case .planUsage = request.kind else { return }
            usageRequests[requestID] = nil
            var snapshot = planUsage ?? PlanUsageSnapshot()
            snapshot.isLoading = false
            if let state = payload.planUsage {
                snapshot.state = state
                snapshot.settings = payload.settings
                snapshot.fetchedAt = payload.generatedAt
                snapshot.error = nil
            } else {
                snapshot.error = "The Mac could not read its plan usage."
            }
            planUsage = snapshot
        case .syncIndex, .fetchSession, .fetchSessionBefore, .fetchTimelineSince, .fetchTimelineItems, .cancelRequest,
             .sessionReviewed, .fetchUsage, .fetchPlanUsage:
            // Device → host only; never expected from the daemon.
            return
        case .channelOpened:
            // Only ever sealed with the handshake key (`receiveOpening`); inside
            // a session it means nothing.
            return
        }
    }

    /// One part of a session page. Each part is merged as it lands; the
    /// request completes when its last part is in and no part is missing.
    /// A part of a request this iPhone no longer waits for is ignored — the
    /// one exception is a tail with no request id at all, the daemon's own
    /// word that it rebuilt the session (`Refresh session` on the Mac).
    private func applySessionPart(_ payload: RemoteSessionPayload) async {
        guard let page = payload.session else { return }
        let id = page.summary.id
        let part = payload.part ?? 0
        let isLast = page.nextCursor == nil

        guard let requestID = payload.requestID else {
            guard payload.kind == .sessionTail, heldIDs.contains(id) || detail(id) != nil else { return }
            if part == 0 { eraseRows(of: id, summary: page.summary) }
            install(page)
            if isLast, heldIDs.contains(id) {
                marks[id] = SessionSyncMark(
                    timelineItemCount: remoteFacts[id]?.timelineItemCount,
                    lastItemAt: page.timeline.last?.occurredAt ?? remoteFacts[id]?.lastItemAt,
                    oldest: payload.oldest,
                    hasOlder: payload.hasOlder ?? false
                )
            }
            return
        }
        guard var request = pending[requestID], request.kind.sessionID == id else { return }

        if !request.started {
            request.started = true
            switch request.kind {
            case let .tail(_, erase) where erase:
                eraseRows(of: id, summary: page.summary)
            case .since where payload.kind == .sessionTail:
                // More rows arrived than a since-tail could patch: the daemon
                // sent a fresh tail, which replaces the loaded window.
                eraseRows(of: id, summary: page.summary)
            default:
                break
            }
        }
        request.lastProgressAt = Date()
        request.partsReceived.insert(part)
        pending[requestID] = request
        install(page)

        guard isLast, request.partsReceived.count == part + 1 else { return }
        pending[requestID] = nil
        let remote = remoteFacts[id]
        switch request.kind {
        case .tail, .since where payload.kind == .sessionTail:
            marks[id] = SessionSyncMark(
                timelineItemCount: remote?.timelineItemCount,
                lastItemAt: remote?.lastItemAt ?? page.timeline.last?.occurredAt,
                oldest: payload.oldest,
                hasOlder: payload.hasOlder ?? false
            )
        case .since:
            var mark = marks[id] ?? SessionSyncMark()
            mark.timelineItemCount = remote?.timelineItemCount
            mark.lastItemAt = remote?.lastItemAt ?? page.timeline.last?.occurredAt ?? mark.lastItemAt
            marks[id] = mark
        case .history:
            var mark = marks[id] ?? SessionSyncMark()
            if let oldest = payload.oldest { mark.oldest = oldest }
            mark.hasOlder = payload.hasOlder ?? false
            marks[id] = mark
        case .items, .index:
            break
        }
        completeSyncIfSettled()
    }

    /// Wipes the loaded rows of a session before a tail replaces them —
    /// memory and cache — keeping the summary.
    private func eraseRows(of id: SessionID, summary: SessionSummary) {
        let empty = SessionDetail(summary: summary, turns: [], timeline: [])
        enqueueCacheWrite { [cache] in try await cache.replaceSession(empty) }
        if var entry = hidden[id] {
            entry.detail = empty
            hidden[id] = entry
        } else if let index = sessions.firstIndex(where: { $0.summary.id == id }) {
            sessions[index] = empty
        }
        marks[id] = nil
    }

    /// Every Usage-tab ask in flight fails with one reason (offline, timed out).
    private func failUsageRequests(_ reason: String) {
        for (_, request) in usageRequests {
            switch request.kind {
            case .usage:
                usage?.isLoading = false
                usage?.error = reason
            case .planUsage:
                planUsage?.isLoading = false
                planUsage?.error = reason
            }
        }
        usageRequests = [:]
    }

    private func applyEvents(_ events: [AgentIngressEvent]) async {
        let held = heldIDs
        for event in events {
            let id = event.sessionID
            if event.disposition == .discard {
                sessions.removeAll { $0.summary.id == id }
                hidden[id] = nil
                marks[id] = nil
                enqueueCacheWrite { [cache] in _ = try await cache.apply(event) }
                continue
            }
            guard let current = detail(id) else {
                // A session this iPhone never saw: it exists from now on as
                // a summary, reduced from the event; the next index carries
                // the daemon's own summary, its timeline waits for a tap.
                insertSummaryOnly(SessionReduction.summary(applying: event, to: nil))
                continue
            }
            if held.contains(id) {
                let applied: Bool
                do {
                    // Through the write queue: a tail merged a moment ago
                    // must land before this event, or it would erase it.
                    applied = try await cacheWrite { [cache] in try await cache.apply(event) }
                } catch {
                    lastError = "Unable to apply an update: \(error)"
                    continue
                }
                guard applied else { continue }
                if let index = sessions.firstIndex(where: { $0.summary.id == id }) {
                    sessions[index] = SessionDetailReduction.applying(event, to: sessions[index])
                } else if var entry = hidden[id] {
                    entry.detail = SessionDetailReduction.applying(event, to: entry.detail)
                    hidden[id] = entry
                    revealIfNewer(id)
                }
                // The copy moved on without an index: the mark follows the
                // newest row and forgets the count until the next index.
                if let item = event.timelineItem, var mark = marks[id], mark.isLoaded {
                    mark.lastItemAt = max(mark.lastItemAt ?? .distantPast, item.occurredAt)
                    mark.timelineItemCount = nil
                    marks[id] = mark
                }
            } else {
                // Not held: the summary follows the event (status, phase,
                // title), the timeline stays away until the session is opened.
                let summary = SessionReduction.summary(applying: event, to: current.summary)
                guard summary != current.summary else { continue }
                _ = updateSummary(summary)
                enqueueCacheWrite { [cache] in try await cache.updateSummary(summary) }
            }
        }
        sortSessions()
    }

    /// A session known only by its summary: shown in the list, cached as a
    /// row with no timeline, fetched whole when opened.
    private func insertSummaryOnly(_ summary: SessionSummary) {
        let id = summary.id
        guard detail(id) == nil else { return }
        let detail = SessionDetail(summary: summary, turns: [], timeline: [])
        sessions.append(detail)
        enqueueCacheWrite { [cache] in try await cache.replaceSession(detail) }
    }

    /// Summary-only change (reviewed, archived, index reconcile): updates the
    /// visible or hidden copy; false when this Mac's session is not cached.
    private func updateSummary(_ summary: SessionSummary) -> Bool {
        let id = summary.id
        if let index = sessions.firstIndex(where: { $0.summary.id == id }) {
            let detail = sessions[index]
            sessions[index] = SessionDetail(summary: summary, turns: detail.turns, timeline: detail.timeline)
            return true
        }
        if var entry = hidden[id] {
            entry.detail = SessionDetail(summary: summary, turns: entry.detail.turns, timeline: entry.detail.timeline)
            hidden[id] = entry
            revealIfNewer(id)
            return true
        }
        return false
    }

    /// IOS-R-012: a hidden session comes back once the daemon's copy saw
    /// agent activity after the moment the user hid it.
    private func revealIfNewer(_ id: SessionID) {
        guard let entry = hidden[id], entry.detail.summary.lastActivityAt > entry.hiddenAt else { return }
        hidden[id] = nil
        sessions.removeAll { $0.summary.id == id }
        sessions.append(entry.detail)
    }

    private func sortSessions() {
        sessions.sort { $0.summary.lastActivityAt > $1.summary.lastActivityAt }
    }

    /// Merges one part — summary, turns when it carries them, rows — into
    /// cache and memory. Nothing is erased here.
    private func install(_ page: SessionDetail) {
        let id = page.summary.id
        enqueueCacheWrite { [cache] in try await cache.mergeSession(page) }
        if var entry = hidden[id] {
            entry.detail = SessionDetailReduction.merging(page, into: entry.detail)
            hidden[id] = entry
            revealIfNewer(id)
        } else if let index = sessions.firstIndex(where: { $0.summary.id == id }) {
            sessions[index] = SessionDetailReduction.merging(page, into: sessions[index])
        } else {
            sessions.append(page)
        }
        sortSessions()
    }

    private func completeSyncIfSettled() {
        guard pending.isEmpty, let generatedAt = indexGeneratedAt else { return }
        indexGeneratedAt = nil
        hasCompleteSync = true
        settings.setLastSync(generatedAt, for: credentials.hostID)
    }

    // MARK: - Reconcile

    private func reconcile(_ remote: [SessionIndexEntry], generatedAt: Date) async {
        let local: [SessionIndexEntry]
        do {
            // Let queued writes land first so the local index is current.
            await applyQueue?.value
            local = try await cache.sessionIndex(limit: Self.indexLimit)
        } catch {
            lastError = "Unable to read the session cache: \(error)"
            return
        }
        remoteFacts = Dictionary(remote.map { ($0.summary.id, $0) }, uniquingKeysWith: { first, _ in first })
        let plan = SyncReconcilePlan.lazy(local: local, remote: remote, marks: marks)
        let remoteIDs = Set(remote.map(\.summary.id))
        if !plan.prune.isEmpty {
            sessions.removeAll { plan.prune.contains($0.summary.id) }
            hidden = hidden.filter { !plan.prune.contains($0.key) }
            marks = marks.filter { !plan.prune.contains($0.key) }
            enqueueCacheWrite { [cache] in _ = try await cache.pruneSessions(keeping: remoteIDs) }
        }
        for summary in plan.infoOnly {
            _ = updateSummary(summary)
            enqueueCacheWrite { [cache] in try await cache.updateSummary(summary) }
        }
        for summary in plan.insert {
            insertSummaryOnly(summary)
        }
        // A held copy that is current again learns the daemon's count back.
        for (id, mark) in marks where mark.isLoaded && mark.timelineItemCount == nil {
            if let entry = remoteFacts[id], SyncReconcilePlan.classify(remote: entry, mark: mark) == .upToDate {
                marks[id]?.timelineItemCount = entry.timelineItemCount
            }
        }
        sortSessions()

        indexGeneratedAt = generatedAt
        // A hidden session is rebuilt only when the daemon's copy is newer
        // (then `install` shows it); otherwise it stays as it is.
        for id in plan.rebuild {
            if let entry = hidden[id], let remoteEntry = remoteFacts[id], remoteEntry.summary.lastActivityAt <= entry.hiddenAt { continue }
            requestTail(id, erase: true)
        }
        for request in plan.fetchSince {
            send(
                kind: .since(request.sessionID),
                payload: RemoteSessionPayload(kind: .fetchTimelineSince, sessionIDs: [request.sessionID], since: request.since, limit: Self.pageLimit)
            )
        }
        // A screen opened while no index had arrived yet: now it can ask.
        for id in openSessions where !isFetching(id) && detail(id) != nil {
            guard let mark = marks[id], mark.isLoaded else {
                requestTail(id, erase: false)
                continue
            }
        }
        // "Synced" means the cache says so too: the summary writes above
        // land before the sync is declared complete.
        await applyQueue?.value
        completeSyncIfSettled()
    }
}

/// One pairing attempt, iPhone side: claim the code → submit our identity
/// and key → poll → verify the commitment and show the SAS → poll → on
/// `approved`, install the channel. Cancel at any point tells the Relay.
@MainActor
final class RelayPairingAttempt {
    private weak var controller: RelayDeviceController?
    let relayURL: URL
    let code: String
    private let api: any RelayPairingAPI
    private let pollInterval: Duration
    private var task: Task<Void, Never>?
    /// Set once the code was spent; `Try again` after `hostOffline` resumes here.
    private var claim: RelayPairingClaim?
    private var deviceID: DeviceID?
    private var keyPair: RelayKeyPair?

    private(set) var progress: PairingProgress?
    private(set) var failure: PairingFailure?
    var onChange: (() -> Void)?

    init(controller: RelayDeviceController, relayURL: URL, code: String) {
        self.controller = controller
        self.relayURL = relayURL
        self.code = code
        api = controller.pairingAPI
        pollInterval = controller.pairingPollInterval
    }

    var relayHost: String { RelayURLValidation.displayHost(relayURL) }
    var isRunning: Bool { task != nil }

    /// Runs (or, after `hostOffline`, resumes) the attempt.
    func start() {
        guard task == nil else { return }
        failure = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run()
            } catch let failure as PairingFailure {
                self.failure = failure
            } catch is CancellationError {
                // Told the Relay in `cancel()`.
            } catch {
                self.failure = Self.failure(for: error, claiming: false)
            }
            self.task = nil
            self.onChange?()
        }
    }

    /// Stops polling and releases the session at the Relay (best effort).
    func cancel() {
        task?.cancel()
        task = nil
        if let claim {
            let api = api, relayURL = relayURL
            Task { try? await api.cancel(relayURL: relayURL, hostID: claim.hostID, sessionID: claim.sessionID) }
        }
        claim = nil
    }

    private func set(_ progress: PairingProgress) {
        self.progress = progress
        onChange?()
    }

    private func run() async throws {
        guard let controller else { return }
        if claim == nil {
            set(.claiming)
            do {
                claim = try await api.claim(relayURL: relayURL, code: code)
            } catch {
                throw Self.failure(for: error, claiming: true)
            }
        }
        guard let claim else { return }
        let deviceID = self.deviceID ?? controller.deviceID(forPairingWith: claim.hostID)
        let keyPair = self.keyPair ?? RelayCryptography.makeKeyPair()
        self.deviceID = deviceID
        self.keyPair = keyPair
        set(.waitingForMac(hostName: claim.hostName, relayHost: relayHost))
        do {
            try await api.submit(
                relayURL: relayURL, hostID: claim.hostID, sessionID: claim.sessionID,
                deviceID: deviceID, deviceName: controller.pairingDeviceName, devicePublicKey: keyPair.publicKey
            )
        } catch let error as RelayClientError {
            // Already submitted (a resume after a network blip): just poll.
            if case let .relay(_, code) = error, code == "invalid_state" {
                // Fall through to polling; the state tells us where we are.
            } else {
                throw Self.failure(for: error, claiming: false)
            }
        } catch {
            throw Self.failure(for: error, claiming: false)
        }

        var hostPublicKey: Data?
        while true {
            try Task.checkCancellation()
            let status: RelayPairingSessionStatus
            do {
                status = try await api.status(relayURL: relayURL, hostID: claim.hostID, sessionID: claim.sessionID)
            } catch {
                throw Self.failure(for: error, claiming: false)
            }
            switch status.state {
            case .offered, .claimed, .submitted:
                break
            case .revealed, .approved:
                if hostPublicKey == nil, let key = status.hostPublicKey, let nonce = status.hostNonce {
                    // The key and nonce the Relay hands us must be the ones the
                    // Mac committed to before it ever saw our key — otherwise
                    // someone in the middle is choosing keys.
                    guard RelayCryptography.verifyPairingCommitment(claim.commit, hostPublicKey: key, hostNonce: nonce) else {
                        let api = api, relayURL = relayURL
                        Task { try? await api.cancel(relayURL: relayURL, hostID: claim.hostID, sessionID: claim.sessionID) }
                        throw PairingFailure.commitMismatch
                    }
                    hostPublicKey = key
                    let sas = RelayCryptography.pairingSAS(
                        hostID: claim.hostID, deviceID: deviceID,
                        hostPublicKey: key, devicePublicKey: keyPair.publicKey, hostNonce: nonce
                    )
                    set(.comparing(sas: sas, hostName: status.hostName ?? claim.hostName, relayHost: relayHost))
                }
                if status.state == .approved, let token = status.deviceToken, let hostPublicKey {
                    let credentials = RelayDeviceCredentials(
                        relayURL: relayURL,
                        hostID: claim.hostID,
                        hostName: status.hostName ?? claim.hostName,
                        deviceID: deviceID,
                        deviceToken: token,
                        keyPair: keyPair,
                        hostPublicKey: hostPublicKey,
                        pairedAt: status.pairedAt ?? Date()
                    )
                    try await controller.addChannel(credentials)
                    self.claim = nil
                    set(.paired(hostID: claim.hostID, hostName: credentials.hostName, relayHost: relayHost))
                    return
                }
            case .rejected:
                self.claim = nil
                throw PairingFailure.rejected
            case .cancelled, .expired:
                // The Mac rotated or dropped the code under us: same as a
                // spent code — back to the entry screen.
                self.claim = nil
                throw PairingFailure.badCode
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// Folds whatever ended the attempt into one of the four designed states.
    private static func failure(for error: Error, claiming: Bool) -> PairingFailure {
        if let failure = error as? PairingFailure { return failure }
        guard let relayError = error as? RelayClientError else {
            // Unreachable Relay, a cache file that would not open, …:
            // retryable, and `Try again` resumes where we were.
            return .hostOffline
        }
        switch relayError {
        case let .relay(_, code):
            switch code {
            case "invalid_or_expired_code": return .badCode
            case "host_offline": return .hostOffline
            // The session is gone at the Relay (rotated, expired, never
            // there): the code is no good any more.
            case "invalid_state", "expired", "not_found": return .badCode
            default: return .hostOffline
            }
        case .unauthorized:
            return .badCode
        case .server, .invalidResponse, .notConnected, .unsupportedMessage, .upgradeRequired:
            return .hostOffline
        }
    }
}

/// The per-Mac cache file could not be created (disk / sandbox); the pairing
/// attempt reports it as a retryable failure.
enum ChannelCacheError: Error {
    case unavailable
}
