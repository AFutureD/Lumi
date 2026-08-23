import Transport
import Foundation

/// One Relay WebSocket as the host and device controllers see it. The
/// production transport is `RelayWebSocketClient`; tests pair two in-memory
/// ends so the daemon and the iPhone can be driven without a network.
public protocol RelayFrameTransport: Sendable {
    func connect(hostID: HostID, role: RelayConnectionRole, token: String) async throws
    func send(_ frame: RelayRoutingFrame) async throws
    func next() async throws -> RelayIncomingMessage
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
