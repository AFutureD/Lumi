import Diagnostics
import Logging
import Network
import Synchronization
import Transport
import Foundation

private let log = Logger(label: "relay")

/// The local network path, Network.framework edition. The daemon advertises
/// `_lumi-relay._tcp` over Bonjour with its host id in the TXT record and
/// accepts TCP connections; an iPhone that sees a paired Mac on the network
/// connects and speaks the same sealed frames it would send through the
/// Relay, as length-prefixed records:
///
///     u32 big-endian record length ‖ RelayFrameCodec binary frame
///
/// Plain TCP is enough: every frame is sealed and authenticated under the
/// pairing's keys, the advertisement is only an address, and the daemon
/// takes nothing from a connection until a frame opens under a pinned key.
/// What the listener does guard is itself: a record cap, a cap on
/// connections, and an idle deadline before the first frame.
public enum DirectNetwork {
    public static let serviceType = "_lumi-relay._tcp"
    public static let protocolVersionKey = "v"
    public static let hostIDKey = "host"
    public static let maxRecordBytes = 2 * 1024 * 1024
    public static let maxConnections = 16
    /// A connection that sends nothing in this long is closed.
    public static let idleTimeout: Duration = .seconds(90)
    public static let connectTimeout: Duration = .seconds(8)

    /// Encodes one record: the length prefix and the frame.
    static func record(_ frame: RelayRoutingFrame) throws -> Data {
        let body = try RelayFrameCodec.encode(frame)
        var data = Data(capacity: 4 + body.count)
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(body)
        return data
    }
}

/// One TCP connection, either end: writes records, reads them one at a
/// time, and hands the frames up through an `AsyncStream`.
final class DirectConnection: @unchecked Sendable {
    let id: DirectConnectionID
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let framesIn: AsyncStream<Result<RelayRoutingFrame, any Error>>.Continuation
    let frames: AsyncStream<Result<RelayRoutingFrame, any Error>>
    private var ready: CheckedContinuation<Void, any Error>?
    private var started = false

    init(connection: NWConnection, id: DirectConnectionID = DirectConnectionID(), queue: DispatchQueue) {
        self.connection = connection
        self.id = id
        self.queue = queue
        (frames, framesIn) = AsyncStream.makeStream(of: Result<RelayRoutingFrame, any Error>.self)
    }

    /// Starts the connection and resolves once it is ready (or failed, or
    /// `timeout` passed without either — the connection is cancelled then).
    func start(timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard !started else { continuation.resume(); return }
                started = true
                ready = continuation
                connection.stateUpdateHandler = { [weak self] state in
                    self?.stateChanged(state)
                }
                connection.start(queue: queue)
                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    guard let self, let pending = ready else { return }
                    ready = nil
                    pending.resume(throwing: RelayClientError.notConnected)
                    connection.cancel()
                }
            }
        }
    }

    /// The listener's side: the connection is already starting.
    func accept() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            connection.stateUpdateHandler = { [weak self] state in
                self?.stateChanged(state)
            }
            connection.start(queue: queue)
        }
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            ready?.resume()
            ready = nil
            readRecord()
        case let .failed(error):
            ready?.resume(throwing: error)
            ready = nil
            framesIn.yield(.failure(error))
            framesIn.finish()
        case .cancelled:
            ready?.resume(throwing: RelayClientError.notConnected)
            ready = nil
            framesIn.finish()
        case let .waiting(error):
            // Unreachable for now (the Mac left the network): give up rather
            // than sit in `waiting` forever.
            ready?.resume(throwing: error)
            ready = nil
            connection.cancel()
        default:
            break
        }
    }

    private func readRecord() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, complete, error in
            guard let self else { return }
            if let error { framesIn.yield(.failure(error)); framesIn.finish(); return }
            guard let header, header.count == 4 else {
                if complete { framesIn.finish() }
                return
            }
            let length = header.reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= DirectNetwork.maxRecordBytes else {
                framesIn.yield(.failure(RelayFrameCodecError.headerTooLarge(length)))
                framesIn.finish()
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, complete, error in
                guard let self else { return }
                if let error { framesIn.yield(.failure(error)); framesIn.finish(); return }
                guard let body, body.count == length else {
                    if complete { framesIn.finish() }
                    return
                }
                do {
                    framesIn.yield(.success(try RelayFrameCodec.decode(body)))
                } catch {
                    framesIn.yield(.failure(error))
                }
                readRecord()
            }
        }
    }

    func send(_ frame: RelayRoutingFrame) async throws {
        let record = try DirectNetwork.record(frame)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: record, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func cancel() {
        connection.cancel()
    }
}

// MARK: - Daemon: listener

/// The daemon's Bonjour listener: `DirectHostLink` over Network.framework.
public final class BonjourHostListener: DirectHostLink, Sendable {
    private struct State {
        var listener: NWListener?
        var connections: [DirectConnectionID: DirectConnection] = [:]
        var readers: [DirectConnectionID: Task<Void, Never>] = [:]
    }

    private let queue = DispatchQueue(label: "app.huanan.lumi.direct.listener")
    private let eventsIn: AsyncStream<DirectHostEvent>.Continuation
    public let events: AsyncStream<DirectHostEvent>
    private let state = Mutex(State())

    public init() {
        (events, eventsIn) = AsyncStream.makeStream(of: DirectHostEvent.self)
    }

    public func start(hostID: HostID) async throws {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(
            type: DirectNetwork.serviceType,
            txtRecord: NWTXTRecord([
                DirectNetwork.hostIDKey: hostID.rawValue,
                DirectNetwork.protocolVersionKey: "\(ProtocolVersion.current.major).\(ProtocolVersion.current.minor)",
            ])
        )
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let once = OnceResumer(continuation: nil)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            once.arm(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    log.info("direct_listener_ready", metadata: .fields(["port": listener.port?.rawValue, "service": DirectNetwork.serviceType]))
                    once.resume(nil)
                case let .failed(error):
                    log.warning("direct_listener_failed", metadata: .fields(["error": error]))
                    once.resume(error)
                    self?.closeAll()
                case .cancelled:
                    once.resume(RelayClientError.notConnected)
                    self?.closeAll()
                default:
                    break
                }
            }
            self.state.withLock { $0.listener = listener }
            listener.start(queue: queue)
        }
    }

    public func stop() async {
        let listener = state.withLock { state -> NWListener? in
            let listener = state.listener
            state.listener = nil
            return listener
        }
        listener?.cancel()
        closeAll()
    }

    private func accept(_ nwConnection: NWConnection) {
        let count = state.withLock { $0.connections.count }
        guard count < DirectNetwork.maxConnections else {
            log.warning("direct_connection_refused", metadata: .fields(["reason": "too_many", "open": count]))
            nwConnection.cancel()
            return
        }
        let connection = DirectConnection(connection: nwConnection, queue: queue)
        state.withLock { $0.connections[connection.id] = connection }
        log.info("direct_connection_accepted", metadata: .fields(["connection": connection.id.rawValue, "open": count + 1]))
        connection.accept()
        // The tasks below capture only values that are Sendable on their
        // own (the id, the stream, the continuation, a mutex): the
        // connection object stays behind the state lock and is reached by id.
        let id = connection.id
        let frames = connection.frames
        let eventsIn = eventsIn
        let sawFrame = Mutex(false)
        // Idle deadline: a connection that never speaks is closed.
        let idle = Task { [weak self] in
            try? await Task.sleep(for: DirectNetwork.idleTimeout)
            guard !Task.isCancelled, !sawFrame.withLock({ $0 }) else { return }
            self?.cancel(id)
        }
        let reader = Task { [weak self] in
            for await result in frames {
                switch result {
                case let .success(frame):
                    sawFrame.withLock { $0 = true }
                    eventsIn.yield(.frame(id, frame))
                case let .failure(error):
                    log.debug("direct_connection_read_failed", metadata: .fields(["connection": id.rawValue, "error": error]))
                }
            }
            idle.cancel()
            self?.remove(id)
        }
        state.withLock { $0.readers[id] = reader }
    }

    private func cancel(_ id: DirectConnectionID) {
        state.withLock { $0.connections[id] }?.cancel()
    }

    private func remove(_ id: DirectConnectionID) {
        let removed = state.withLock { state -> Bool in
            state.readers[id] = nil
            return state.connections.removeValue(forKey: id) != nil
        }
        guard removed else { return }
        log.info("direct_connection_closed", metadata: .fields(["connection": id.rawValue]))
        eventsIn.yield(.closed(id))
    }

    private func closeAll() {
        let open = state.withLock { Array($0.connections.values) }
        for connection in open { connection.cancel() }
    }

    public func send(_ frame: RelayRoutingFrame, to connection: DirectConnectionID) async throws {
        guard let target = state.withLock({ $0.connections[connection] }) else { throw RelayClientError.notConnected }
        try await target.send(frame)
    }
}

/// Resumes a continuation exactly once, whichever state change comes first.
private final class OnceResumer: Sendable {
    private let slot: Mutex<CheckedContinuation<Void, any Error>?>

    init(continuation: CheckedContinuation<Void, any Error>?) {
        slot = Mutex(continuation)
    }

    func arm(_ continuation: CheckedContinuation<Void, any Error>) {
        slot.withLock { $0 = continuation }
    }

    func resume(_ error: (any Error)?) {
        let continuation = slot.withLock { slot -> CheckedContinuation<Void, any Error>? in
            let value = slot
            slot = nil
            return value
        }
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }
}

// MARK: - iPhone: browser and connection

/// Browses `_lumi-relay._tcp` and reports the Macs it sees by the host id in
/// their TXT record. Starts when first asked, stops when nobody listens.
public final class BonjourPeerBrowser: DirectPeerDiscovery, Sendable {
    private struct State {
        var browser: NWBrowser?
        var watchers: [UUID: AsyncStream<[HostID: DirectEndpoint]>.Continuation] = [:]
        var current: [HostID: DirectEndpoint] = [:]
        var results: [HostID: NWBrowser.Result] = [:]
    }

    private let queue = DispatchQueue(label: "app.huanan.lumi.direct.browser")
    private let state = Mutex(State())

    public init() {}

    public func endpoints() -> AsyncStream<[HostID: DirectEndpoint]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [HostID: DirectEndpoint].self)
        let id = UUID()
        let (snapshot, needsStart) = state.withLock { state -> ([HostID: DirectEndpoint], Bool) in
            state.watchers[id] = continuation
            return (state.current, state.browser == nil)
        }
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in self?.removeWatcher(id) }
        if needsStart { startBrowsing() }
        return stream
    }

    /// The browser result for a host, for the connection to dial.
    func result(for hostID: HostID) -> NWBrowser.Result? {
        state.withLock { $0.results[hostID] }
    }

    private func removeWatcher(_ id: UUID) {
        let browser = state.withLock { state -> NWBrowser? in
            state.watchers[id] = nil
            guard state.watchers.isEmpty else { return nil }
            let browser = state.browser
            state.browser = nil
            return browser
        }
        browser?.cancel()
    }

    private func startBrowsing() {
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: DirectNetwork.serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        browser.stateUpdateHandler = { state in
            switch state {
            case let .failed(error):
                log.warning("direct_browser_failed", metadata: .fields(["error": error]))
            case let .waiting(error):
                // Local Network permission not granted (yet): no results, no retry storm.
                log.info("direct_browser_waiting", metadata: .fields(["error": error]))
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.update(results)
        }
        state.withLock { $0.browser = browser }
        browser.start(queue: queue)
    }

    private func update(_ found: Set<NWBrowser.Result>) {
        var endpoints: [HostID: DirectEndpoint] = [:]
        var byHost: [HostID: NWBrowser.Result] = [:]
        for result in found {
            guard case let .service(name, _, _, _) = result.endpoint,
                  case let .bonjour(txt) = result.metadata,
                  let host = txt[DirectNetwork.hostIDKey], !host.isEmpty else { continue }
            let hostID = HostID(host)
            endpoints[hostID] = DirectEndpoint(hostID: hostID, serviceName: name)
            byHost[hostID] = result
        }
        let (changed, watchers) = state.withLock { state -> (Bool, [AsyncStream<[HostID: DirectEndpoint]>.Continuation]) in
            let changed = endpoints != state.current
            state.current = endpoints
            state.results = byHost
            return (changed, Array(state.watchers.values))
        }
        guard changed else { return }
        log.info("direct_peers_changed", metadata: .fields(["hosts": endpoints.count]))
        for watcher in watchers { watcher.yield(endpoints) }
    }
}

/// Dials one discovered Mac.
public struct BonjourDirectTransportFactory: DirectTransportFactory {
    private let browser: BonjourPeerBrowser

    public init(browser: BonjourPeerBrowser) {
        self.browser = browser
    }

    public func makeTransport(to endpoint: DirectEndpoint) -> any RelayFrameTransport {
        DirectClientTransport(endpoint: endpoint, browser: browser)
    }
}

/// The iPhone's direct connection as a `RelayFrameTransport`. Reports the
/// host online once the TCP connection is up — the daemon itself is the far
/// end — and lost when the connection drops.
public actor DirectClientTransport: RelayFrameTransport {
    private let endpoint: DirectEndpoint
    private let browser: BonjourPeerBrowser
    private let queue = DispatchQueue(label: "app.huanan.lumi.direct.client")
    private var connection: DirectConnection?
    private var reader: Task<Void, Never>?
    private var buffer: [Result<RelayIncomingMessage, any Error>] = []
    private var waiter: CheckedContinuation<Result<RelayIncomingMessage, any Error>, Never>?
    private var finished = false

    init(endpoint: DirectEndpoint, browser: BonjourPeerBrowser) {
        self.endpoint = endpoint
        self.browser = browser
    }

    public func connect(hostID: HostID, role: RelayConnectionRole, token: String) async throws {
        guard let result = browser.result(for: hostID) else { throw RelayClientError.notConnected }
        let connection = DirectConnection(connection: NWConnection(to: result.endpoint, using: .tcp), queue: queue)
        self.connection = connection
        finished = false
        buffer = []
        try await connection.start(timeout: DirectNetwork.connectTimeout)
        // The daemon itself is the far end: it is online while the connection is.
        deliver(.success(.presence(online: true)))
        let frames = connection.frames
        reader = Task { [weak self] in
            for await result in frames {
                switch result {
                case let .success(frame): await self?.deliver(.success(.frame(frame)))
                case let .failure(error): await self?.deliver(.failure(error))
                }
            }
            await self?.finish()
        }
        log.info("direct_connected", metadata: .fields(["host": hostID.rawValue, "service": endpoint.serviceName]))
    }

    public func send(_ frame: RelayRoutingFrame) async throws {
        guard let connection else { throw RelayClientError.notConnected }
        try await connection.send(frame)
    }

    public func next() async throws -> RelayIncomingMessage {
        guard connection != nil else { throw RelayClientError.notConnected }
        if !buffer.isEmpty { return try buffer.removeFirst().get() }
        if finished { throw RelayClientError.notConnected }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<RelayIncomingMessage, any Error>, Never>) in
            waiter = continuation
        }
        return try result.get()
    }

    private func deliver(_ result: Result<RelayIncomingMessage, any Error>) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: result)
        } else {
            buffer.append(result)
        }
    }

    private func finish() {
        finished = true
        deliver(.failure(RelayClientError.notConnected))
    }

    /// TCP has no ping; a connection that is still up answers at once, one
    /// that died surfaces through `next()`. The listener's idle deadline and
    /// the OS keepalive are what notice a silent peer.
    public func ping() async throws {
        guard connection != nil else { throw RelayClientError.notConnected }
    }

    public func disconnect() async {
        connection?.cancel()
        connection = nil
        reader?.cancel()
        reader = nil
        finish()
    }
}
