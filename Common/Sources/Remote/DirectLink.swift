import Transport
import Foundation

/// Where a Mac's daemon can be reached on the local network, as discovery
/// reports it: the Bonjour service name and the host it says it is. The
/// name is only an address — trust comes from the sealed frames, never from
/// what the advertisement claims.
public struct DirectEndpoint: Hashable, Sendable {
    public let hostID: HostID
    public let serviceName: String

    public init(hostID: HostID, serviceName: String) {
        self.hostID = hostID
        self.serviceName = serviceName
    }
}

/// One accepted connection on the daemon's local listener.
public struct DirectConnectionID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String = UUID().uuidString.lowercased()) {
        self.rawValue = rawValue
    }
}

/// What the daemon hears from its local listener: a frame on a connection,
/// or a connection going away (its channel sessions die with it).
public enum DirectHostEvent: Sendable {
    case frame(DirectConnectionID, RelayRoutingFrame)
    case closed(DirectConnectionID)
}

/// The daemon's end of the local network path: it advertises the Mac and
/// accepts iPhones' connections. Production is Bonjour + TCP
/// (`BonjourHostListener`); tests pair it with an in-memory device link.
public protocol DirectHostLink: Sendable {
    /// Starts advertising `hostID` and accepting connections; `events`
    /// delivers everything that arrives until `stop()`.
    func start(hostID: HostID) async throws
    func stop() async
    var events: AsyncStream<DirectHostEvent> { get }
    func send(_ frame: RelayRoutingFrame, to connection: DirectConnectionID) async throws
}

/// The iPhone's view of the local network: which paired Macs are reachable
/// right now. Production browses Bonjour (`BonjourPeerBrowser`).
public protocol DirectPeerDiscovery: Sendable {
    /// The reachable Macs, whole, every time the set changes.
    func endpoints() -> AsyncStream<[HostID: DirectEndpoint]>
}

/// Opens a frame link to one discovered Mac.
public protocol DirectTransportFactory: Sendable {
    func makeTransport(to endpoint: DirectEndpoint) -> any RelayFrameTransport
}

// MARK: - In-memory stand-in (tests)

/// A local network in memory: one daemon listener and any number of
/// iPhones. Device transports made from it connect to the listener; the
/// discovery stream says which hosts are "on the network".
public actor InMemoryDirectLink: DirectHostLink, DirectPeerDiscovery, DirectTransportFactory {
    private var hostID: HostID?
    private var running = false
    private let eventsIn: AsyncStream<DirectHostEvent>.Continuation
    public nonisolated let events: AsyncStream<DirectHostEvent>
    private var connections: [DirectConnectionID: InMemoryDirectTransport] = [:]
    private var discoveryWatchers: [UUID: AsyncStream<[HostID: DirectEndpoint]>.Continuation] = [:]
    private var advertised: [HostID: DirectEndpoint] = [:]
    /// Every frame the host sent over direct connections, in order.
    public private(set) var hostSent: [RelayRoutingFrame] = []
    /// Every frame any device sent over direct connections, in order.
    public private(set) var deviceSent: [RelayRoutingFrame] = []

    public init() {
        (events, eventsIn) = AsyncStream.makeStream(of: DirectHostEvent.self)
    }

    // MARK: DirectHostLink

    public func start(hostID: HostID) async throws {
        self.hostID = hostID
        running = true
        advertised[hostID] = DirectEndpoint(hostID: hostID, serviceName: "memory-\(hostID.rawValue)")
        publishDiscovery()
    }

    public func stop() async {
        running = false
        if let hostID { advertised[hostID] = nil }
        publishDiscovery()
        for (id, connection) in connections {
            await connection.finish()
            eventsIn.yield(.closed(id))
        }
        connections = [:]
    }

    public func send(_ frame: RelayRoutingFrame, to connection: DirectConnectionID) async throws {
        guard let target = connections[connection] else { throw RelayClientError.notConnected }
        hostSent.append(frame)
        await target.deliver(.frame(frame))
    }

    /// Tests: the Mac leaves the network without closing cleanly (Wi‑Fi gone).
    public func dropAllConnections() async {
        for (id, connection) in connections {
            await connection.finish()
            eventsIn.yield(.closed(id))
        }
        connections = [:]
    }

    /// Tests: the daemon's advertisement disappears (or appears) without
    /// touching live connections.
    public func setAdvertised(_ visible: Bool) {
        guard let hostID else { return }
        advertised[hostID] = visible ? DirectEndpoint(hostID: hostID, serviceName: "memory-\(hostID.rawValue)") : nil
        publishDiscovery()
    }

    public var connectionCount: Int { connections.count }

    // MARK: DirectPeerDiscovery

    public nonisolated func endpoints() -> AsyncStream<[HostID: DirectEndpoint]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [HostID: DirectEndpoint].self)
        let id = UUID()
        Task { await self.addWatcher(id, continuation) }
        continuation.onTermination = { _ in Task { await self.removeWatcher(id) } }
        return stream
    }

    private func addWatcher(_ id: UUID, _ continuation: AsyncStream<[HostID: DirectEndpoint]>.Continuation) {
        discoveryWatchers[id] = continuation
        continuation.yield(advertised)
    }

    private func removeWatcher(_ id: UUID) {
        discoveryWatchers[id] = nil
    }

    private func publishDiscovery() {
        for watcher in discoveryWatchers.values { watcher.yield(advertised) }
    }

    // MARK: DirectTransportFactory

    public nonisolated func makeTransport(to endpoint: DirectEndpoint) -> any RelayFrameTransport {
        InMemoryDirectTransport(link: self, endpoint: endpoint)
    }

    // MARK: Device side wiring

    func attach(_ transport: InMemoryDirectTransport, to endpoint: DirectEndpoint) throws -> DirectConnectionID {
        guard running, advertised[endpoint.hostID] != nil else { throw RelayClientError.notConnected }
        let id = DirectConnectionID()
        connections[id] = transport
        return id
    }

    func detach(_ id: DirectConnectionID) {
        guard connections.removeValue(forKey: id) != nil else { return }
        eventsIn.yield(.closed(id))
    }

    func receive(_ frame: RelayRoutingFrame, on id: DirectConnectionID) throws {
        guard connections[id] != nil else { throw RelayClientError.notConnected }
        deviceSent.append(frame)
        eventsIn.yield(.frame(id, frame))
    }
}

/// The iPhone's end of an in-memory direct connection. Like the real link it
/// reports the host online the moment the connection is up: there is no
/// Relay in between to say otherwise.
public actor InMemoryDirectTransport: RelayFrameTransport {
    private let link: InMemoryDirectLink
    private let endpoint: DirectEndpoint
    private var connectionID: DirectConnectionID?
    private var closed = false
    private var buffer: [RelayIncomingMessage] = []
    private var waiter: CheckedContinuation<RelayIncomingMessage?, Never>?

    init(link: InMemoryDirectLink, endpoint: DirectEndpoint) {
        self.link = link
        self.endpoint = endpoint
    }

    public func connect(hostID: HostID, role: RelayConnectionRole, token: String) async throws {
        connectionID = try await link.attach(self, to: endpoint)
        closed = false
        buffer = [.presence(online: true)]
    }

    public func send(_ frame: RelayRoutingFrame) async throws {
        guard let connectionID, !closed else { throw RelayClientError.notConnected }
        try await link.receive(frame, on: connectionID)
    }

    public func next() async throws -> RelayIncomingMessage {
        guard connectionID != nil else { throw RelayClientError.notConnected }
        if !buffer.isEmpty { return buffer.removeFirst() }
        if closed { throw RelayClientError.notConnected }
        let message = await withCheckedContinuation { (continuation: CheckedContinuation<RelayIncomingMessage?, Never>) in
            waiter = continuation
        }
        guard let message else { throw RelayClientError.notConnected }
        return message
    }

    public func ping() async throws {
        guard connectionID != nil, !closed else { throw RelayClientError.notConnected }
    }

    public func disconnect() async {
        guard let connectionID, !closed else { return }
        closed = true
        waiter?.resume(returning: nil)
        waiter = nil
        await link.detach(connectionID)
    }

    func deliver(_ message: RelayIncomingMessage) {
        guard !closed else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
        } else {
            buffer.append(message)
        }
    }

    func finish() {
        closed = true
        waiter?.resume(returning: nil)
        waiter = nil
    }
}
