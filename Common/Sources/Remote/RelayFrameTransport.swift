import Transport
import Foundation

/// One link the host and device controllers send frames over: the Relay
/// WebSocket in production (`RelayWebSocketClient`), a direct LAN record
/// stream, or the in-memory pair tests wire the daemon and the iPhone with.
public protocol RelayFrameTransport: AnyObject, Sendable {
    func connect(hostID: HostID, role: RelayConnectionRole, token: String) async throws
    func send(_ frame: RelayRoutingFrame) async throws
    func next() async throws -> RelayIncomingMessage
    /// A liveness probe that completes when the far end answered. Throws
    /// when the link is gone; the caller decides how long to wait.
    func ping() async throws
    func disconnect() async
}

public protocol RelayFrameTransportFactory: Sendable {
    func makeTransport(baseURL: URL) -> any RelayFrameTransport
}

public struct RelayWebSocketTransportFactory: RelayFrameTransportFactory {
    public init() {}

    public func makeTransport(baseURL: URL) -> any RelayFrameTransport {
        RelayWebSocketClient(baseURL: baseURL)
    }
}

extension RelayWebSocketClient: RelayFrameTransport {}

/// How a link is kept alive: a probe every `interval`, declared lost when
/// one goes unanswered for `timeout`. Shared by both ends and both links.
public struct RelayHeartbeat: Sendable {
    public var interval: Duration
    public var timeout: Duration

    public init(interval: Duration = .seconds(10), timeout: Duration = .seconds(30)) {
        self.interval = interval
        self.timeout = timeout
    }

    /// Probes the link until one probe fails or goes unanswered. Returns
    /// (never throws) once the link should be considered lost; cancellation
    /// ends it quietly.
    public func run(on transport: any RelayFrameTransport) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            let answered = await withTaskGroup(of: Bool.self) { group in
                group.addTask { (try? await transport.ping()) != nil }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if !answered, !Task.isCancelled { return }
        }
    }
}

/// Reconnect delays that double from `base` up to `cap`, reset by the caller
/// on a successful connection.
public struct RelayBackoff: Sendable {
    public let base: Duration
    public let cap: Duration
    private var attempt = 0

    public init(base: Duration = .seconds(2), cap: Duration = .seconds(30)) {
        self.base = base
        self.cap = cap
    }

    /// The delay before the next attempt, then advances.
    public mutating func next() -> Duration {
        let factor = Double(1 << min(attempt, 10))
        attempt += 1
        return min(base * factor, cap)
    }

    public mutating func reset() {
        attempt = 0
    }
}
