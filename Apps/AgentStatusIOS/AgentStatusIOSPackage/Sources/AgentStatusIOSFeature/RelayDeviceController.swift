import AgentStatusRemote
import AgentStatusCore
import AgentStatusTransport
import Foundation
import UIKit

struct RelayDeviceChannelState: Sendable {
    let hostID: HostID
    let displayName: String
    let sessions: [SessionDetail]
    let isHostOnline: Bool
    let isConnected: Bool
    let lastError: String?
}

@MainActor
final class RelayDeviceController {
    private let secureStore = SecureStore(service: "com.huanan.AgentStatusIOS.relay")
    private let credentialsAccount = "device-channels-v2"
    private let legacyCredentialsAccount = "device-credentials-v1"
    private var channelOrder: [HostID] = []
    private var channels: [HostID: RelayDeviceChannel] = [:]

    var onChange: (() -> Void)?

    init() {
        let stored: [RelayDeviceCredentials]
        if let collection = try? secureStore.load(
            RelayDeviceCredentialCollection.self,
            account: credentialsAccount
        ) {
            stored = collection.channels
        } else if let legacy = try? secureStore.load(
            RelayDeviceCredentials.self,
            account: legacyCredentialsAccount
        ) {
            stored = [legacy]
        } else {
            stored = []
        }

        for credentials in stored {
            if let channel = try? makeChannel(credentials) {
                channelOrder.append(credentials.hostID)
                channels[credentials.hostID] = channel
            }
        }
    }

    var isPaired: Bool { !channels.isEmpty }

    var channelStates: [RelayDeviceChannelState] {
        channelOrder.compactMap { channels[$0]?.state }
    }

    func start() {
        for channel in channels.values { channel.start() }
    }

    func pair(using offer: PairingOffer) async throws {
        guard offer.version.isCompatible(with: .current), offer.expiresAt > Date() else {
            throw PairingError.expiredOrIncompatible
        }
        guard offer.relayURL == RelayBuildConfiguration.url else {
            throw PairingError.unexpectedRelay
        }
        let keyPair = RelayCryptography.makeKeyPair()
        let deviceID = DeviceID("device-\(UUID().uuidString.lowercased())")
        let relayURL = RelayBuildConfiguration.url
        let result = try await RelayRESTClient(baseURL: relayURL).pair(PairingRequest(
            hostID: offer.hostID,
            deviceID: deviceID,
            challenge: offer.challenge,
            deviceName: UIDevice.current.name,
            devicePublicKey: keyPair.publicKey
        ))
        let credentials = RelayDeviceCredentials(
            relayURL: relayURL,
            hostID: offer.hostID,
            hostName: offer.hostName,
            deviceID: deviceID,
            deviceToken: result.deviceToken,
            keyPair: keyPair,
            hostPublicKey: result.hostPublicKey,
            lastAcknowledgedSequence: 0
        )

        if let existing = channels[offer.hostID] { await existing.stop() }
        channelOrder.removeAll { $0 == offer.hostID }
        channelOrder.append(offer.hostID)
        let channel = try makeChannel(credentials)
        channels[offer.hostID] = channel
        try saveCredentials()
        await channel.connect()
        onChange?()
    }

    func unpair(hostID: HostID) {
        guard let channel = channels.removeValue(forKey: hostID) else { return }
        channelOrder.removeAll { $0 == hostID }
        channel.cancelTasks()
        Task { await channel.stop(removeLocalData: true) }
        try? saveCredentials()
        onChange?()
    }

    private func makeChannel(_ credentials: RelayDeviceCredentials) throws -> RelayDeviceChannel {
        let credentials = RelayDeviceCredentials(
            relayURL: RelayBuildConfiguration.url,
            hostID: credentials.hostID,
            hostName: credentials.hostName,
            deviceID: credentials.deviceID,
            deviceToken: credentials.deviceToken,
            keyPair: credentials.keyPair,
            hostPublicKey: credentials.hostPublicKey,
            lastAcknowledgedSequence: credentials.lastAcknowledgedSequence
        )
        let databasePath = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("Agent Status", isDirectory: true)
            .appendingPathComponent("Channels", isDirectory: true)
            .appendingPathComponent("\(credentials.hostID.rawValue).sqlite3")
            .path
        let cache = try SQLiteSessionRepository(path: databasePath)
        return RelayDeviceChannel(credentials: credentials, cache: cache) { [weak self] in
            guard let self else { return }
            try? self.saveCredentials()
            self.onChange?()
        }
    }

    private func saveCredentials() throws {
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

/// One instance is one Mac-to-iOS channel. Every session for that Mac is
/// multiplexed through this single WebSocket; no session creates a connection.
@MainActor
private final class RelayDeviceChannel {
    private let onChange: () -> Void
    private let cache: SQLiteSessionRepository
    private var socket: RelayWebSocketClient?
    private var connectTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private(set) var credentials: RelayDeviceCredentials
    private var sessions: [SessionDetail] = []
    private var isHostOnline = false
    private var isConnected = false
    /// The visible id set promised by the latest `.index` frame; `nil` until
    /// one arrives on this connection.
    private var indexIDs: Set<SessionID>?
    /// Parts of sessions still in flight, keyed by session.
    private var partBuffers: [SessionID: [RemoteSessionPayload]] = [:]
    /// Highest frame sequence seen on this connection, for gap detection.
    private var lastReceivedSequence: UInt64 = 0
    private var needsResync = false
    private var lastError: String?

    /// The sync is current when the latest index has arrived and every
    /// session it references was fully received.
    private var hasCompleteSync: Bool {
        guard let indexIDs else { return false }
        return RelayFrameReduction.missingIDs(index: indexIDs, sessions: sessions).isEmpty
    }

    init(
        credentials: RelayDeviceCredentials,
        cache: SQLiteSessionRepository,
        onChange: @escaping () -> Void
    ) {
        self.credentials = credentials
        self.cache = cache
        self.onChange = onChange
    }

    var state: RelayDeviceChannelState {
        RelayDeviceChannelState(
            hostID: credentials.hostID,
            displayName: credentials.displayName,
            sessions: isConnected && isHostOnline && hasCompleteSync ? sessions : [],
            isHostOnline: isHostOnline,
            isConnected: isConnected,
            lastError: lastError
        )
    }

    func start() {
        guard !isConnected, connectTask == nil else { return }
        connectTask = Task { [weak self] in
            guard let self else { return }
            await self.loadCachedSessions()
            await self.connect()
            self.connectTask = nil
        }
    }

    func connect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        await socket?.disconnect()
        let socket = RelayWebSocketClient(baseURL: credentials.relayURL)
        self.socket = socket
        isConnected = false
        isHostOnline = false
        indexIDs = nil
        partBuffers = [:]
        lastReceivedSequence = 0
        needsResync = false
        do {
            try await socket.connect(
                hostID: credentials.hostID,
                role: .device(credentials.deviceID),
                token: credentials.deviceToken
            )
            isConnected = true
            lastError = nil
            try await socket.send(RelayRoutingFrame(
                hostID: credentials.hostID,
                deviceID: credentials.deviceID,
                sequence: credentials.lastAcknowledgedSequence,
                kind: .hello,
                acknowledgedSequence: credentials.lastAcknowledgedSequence
            ))
            receiveTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await socket.next()
                        await self?.handle(message, socket: socket)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.connectionFailed(error)
                }
            }
        } catch {
            connectionFailed(error)
        }
        onChange()
    }

    func stop(removeLocalData: Bool = false) async {
        cancelTasks()
        await socket?.disconnect()
        socket = nil
        if removeLocalData {
            _ = try? await cache.deleteAllSessions()
            sessions = []
        }
        isConnected = false
        isHostOnline = false
        indexIDs = nil
        partBuffers = [:]
        onChange()
    }

    func cancelTasks() {
        connectTask?.cancel()
        receiveTask?.cancel()
        reconnectTask?.cancel()
        connectTask = nil
        receiveTask = nil
        reconnectTask = nil
    }

    private func connectionFailed(_ error: Error) {
        isConnected = false
        isHostOnline = false
        indexIDs = nil
        partBuffers = [:]
        lastError = String(describing: error)
        onChange()
        scheduleReconnect(after: error)
    }

    private func scheduleReconnect(after error: Error) {
        guard Self.shouldReconnect(after: error), reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await self.connect()
        }
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

    private func handle(_ message: RelayIncomingMessage, socket: RelayWebSocketClient) async {
        switch message {
        case let .presence(online):
            isHostOnline = online
            if !online { indexIDs = nil }
        case let .frame(frame):
            guard frame.hostID == credentials.hostID,
                  frame.deviceID == credentials.deviceID,
                  frame.sequence > credentials.lastAcknowledgedSequence else { return }
            do {
                let payload = try RelayCryptography.open(
                    frame,
                    privateKey: credentials.keyPair.privateKey,
                    peerPublicKey: credentials.hostPublicKey
                )
                // A hole in the sequence means dropped frames: finish this
                // batch, then ask the host for a full resend at the index.
                if lastReceivedSequence != 0, frame.sequence > lastReceivedSequence + 1 {
                    needsResync = true
                }
                lastReceivedSequence = frame.sequence
                try await apply(payload, socket: socket)
                credentials.lastAcknowledgedSequence = frame.sequence
                try await socket.send(RelayRoutingFrame(
                    hostID: credentials.hostID,
                    deviceID: credentials.deviceID,
                    sequence: frame.sequence,
                    kind: .acknowledgement,
                    acknowledgedSequence: frame.sequence
                ))
                lastError = nil
            } catch {
                lastError = "Unable to decrypt relay update: \(error)"
            }
        }
        onChange()
    }

    private func apply(_ payload: RemoteSessionPayload, socket: RelayWebSocketClient) async throws {
        switch payload.kind {
        case .session:
            guard let page = payload.session else { return }
            let id = page.summary.id
            if (payload.part ?? 0) == 0 { partBuffers[id] = [] }
            partBuffers[id, default: []].append(payload)
            guard page.nextCursor == nil,
                  let detail = RelayFrameReduction.assemble(parts: partBuffers[id] ?? []) else { return }
            partBuffers[id] = nil
            try await cache.replaceSession(detail)
            sessions = RelayFrameReduction.upsert(detail, into: sessions)
            isHostOnline = true
        case .index:
            let ids = Set(payload.sessionIDs ?? [])
            try await cache.pruneSessions(keeping: ids)
            sessions = RelayFrameReduction.prune(sessions, keeping: ids)
            partBuffers = partBuffers.filter { ids.contains($0.key) }
            indexIDs = ids
            isHostOnline = true
            // The index closes a batch. Anything still missing (partial
            // delivery, dropped frames) is healed by a full resend. This
            // hello goes out before the index frame's own ack lands in
            // `credentials`, so the host still sees the device as behind.
            if needsResync || !RelayFrameReduction.missingIDs(index: ids, sessions: sessions).isEmpty {
                needsResync = false
                try await socket.send(RelayRoutingFrame(
                    hostID: credentials.hostID,
                    deviceID: credentials.deviceID,
                    sequence: credentials.lastAcknowledgedSequence,
                    kind: .hello,
                    acknowledgedSequence: credentials.lastAcknowledgedSequence
                ))
            }
        case .unavailable:
            isHostOnline = false
            indexIDs = nil
        case .unknown:
            // A newer host build; fail safe into the syncing state.
            isHostOnline = false
            indexIDs = nil
        }
    }

    private func loadCachedSessions() async {
        do {
            let summaries = try await cache.listSessions(limit: 10_000)
            var details: [SessionDetail] = []
            details.reserveCapacity(summaries.count)
            for summary in summaries {
                var cursor: PaginationCursor?
                var turns: [TurnSummary] = []
                var timeline: [TimelineItem] = []
                repeat {
                    guard let page = try await cache.sessionDetail(
                        id: summary.id,
                        cursor: cursor,
                        limit: 500
                    ) else { break }
                    turns = page.turns
                    timeline.append(contentsOf: page.timeline)
                    cursor = page.nextCursor
                } while cursor != nil
                details.append(SessionDetail(summary: summary, turns: turns, timeline: timeline))
            }
            sessions = details
        } catch {
            lastError = "Unable to read the iOS sync database: \(error)"
        }
        onChange()
    }
}

private enum PairingError: LocalizedError {
    case expiredOrIncompatible
    case unexpectedRelay

    var errorDescription: String? {
        switch self {
        case .expiredOrIncompatible:
            "The pairing code has expired or uses an incompatible protocol."
        case .unexpectedRelay:
            "The pairing code was created for a different Relay build configuration."
        }
    }
}
