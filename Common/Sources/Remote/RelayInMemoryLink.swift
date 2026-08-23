import Transport
import Foundation

/// A Relay stand-in for tests: one host end and any number of device ends,
/// wired like the worker (host `data` frames go to the addressed device,
/// device `request` frames go to the host, presence flips on host
/// connect/disconnect). No sequence checks — those belong to the worker's
/// own tests.
public actor RelayInMemoryLink {
    private var hostEnd: RelayInMemoryTransport?
    private var deviceEnds: [DeviceID: RelayInMemoryTransport] = [:]
    /// Every frame the host sent, in order (for assertions).
    public private(set) var hostSent: [RelayRoutingFrame] = []
    /// Every frame any device sent, in order.
    public private(set) var deviceSent: [RelayRoutingFrame] = []

    public init() {}

    public nonisolated func makeHostTransport() -> any RelayFrameTransport {
        RelayInMemoryTransport(link: self, end: .host)
    }

    public nonisolated func makeDeviceTransport(_ deviceID: DeviceID) -> any RelayFrameTransport {
        RelayInMemoryTransport(link: self, end: .device(deviceID))
    }

    public var isHostConnected: Bool { hostEnd != nil }

    // MARK: - Wiring

    func attach(_ transport: RelayInMemoryTransport, as end: RelayInMemoryTransport.End) async {
        switch end {
        case .host:
            if let previous = hostEnd { await previous.finish() }
            hostEnd = transport
            for device in deviceEnds.values { await device.deliver(.presence(online: true)) }
        case let .device(deviceID):
            if let previous = deviceEnds[deviceID] { await previous.finish() }
            deviceEnds[deviceID] = transport
            await transport.deliver(.presence(online: hostEnd != nil))
        }
    }

    func detach(_ end: RelayInMemoryTransport.End) async {
        switch end {
        case .host:
            let previous = hostEnd
            hostEnd = nil
            await previous?.finish()
            for device in deviceEnds.values { await device.deliver(.presence(online: false)) }
        case let .device(deviceID):
            let previous = deviceEnds.removeValue(forKey: deviceID)
            await previous?.finish()
        }
    }

    func send(_ frame: RelayRoutingFrame, from end: RelayInMemoryTransport.End) async throws {
        switch end {
        case .host:
            hostSent.append(frame)
            if let deviceID = frame.deviceID {
                await deviceEnds[deviceID]?.deliver(.frame(frame))
            } else {
                for device in deviceEnds.values { await device.deliver(.frame(frame)) }
            }
        case .device:
            deviceSent.append(frame)
            guard let hostEnd else { throw RelayClientError.notConnected }
            await hostEnd.deliver(.frame(frame))
        }
    }

    /// Injects a worker control message into the host's inbox.
    public func sendErrorToHost(_ error: RelayErrorMessage) async {
        await hostEnd?.deliver(.error(error))
    }

    /// The worker telling the host an iPhone submitted itself to the live
    /// pairing session (`pairing_device`).
    public func sendPairingDeviceToHost(_ notice: RelayPairingDeviceNotice) async {
        await hostEnd?.deliver(.pairingDevice(notice))
    }

    /// The worker telling the host the iPhone cancelled (`pairing_closed`).
    public func sendPairingClosedToHost(sessionID: String, reason: String = "cancelled") async {
        await hostEnd?.deliver(.pairingClosed(sessionID: sessionID, reason: reason))
    }

    /// Drops the host socket from the relay side (as a worker restart would).
    public func dropHost() async {
        await detach(.host)
    }
}

/// The link doubles as the host-side transport factory for tests.
extension RelayInMemoryLink: RelayFrameTransportFactory {
    public nonisolated func makeTransport(baseURL: URL) -> any RelayFrameTransport {
        makeHostTransport()
    }
}

public actor RelayInMemoryTransport: RelayFrameTransport {
    enum End: Sendable {
        case host
        case device(DeviceID)
    }

    private let link: RelayInMemoryLink
    private let end: End
    private var connected = false
    private var closed = false
    private var buffer: [RelayIncomingMessage] = []
    private var waiter: CheckedContinuation<RelayIncomingMessage?, Never>?

    init(link: RelayInMemoryLink, end: End) {
        self.link = link
        self.end = end
    }

    public func connect(hostID: HostID, role: RelayConnectionRole, token: String) async throws {
        connected = true
        closed = false
        buffer = []
        await link.attach(self, as: end)
    }

    public func send(_ frame: RelayRoutingFrame) async throws {
        guard connected, !closed else { throw RelayClientError.notConnected }
        try await link.send(frame, from: end)
    }

    public func next() async throws -> RelayIncomingMessage {
        guard connected else { throw RelayClientError.notConnected }
        if !buffer.isEmpty { return buffer.removeFirst() }
        if closed {
            connected = false
            throw RelayClientError.notConnected
        }
        let message = await withCheckedContinuation { (continuation: CheckedContinuation<RelayIncomingMessage?, Never>) in
            waiter = continuation
        }
        guard let message else {
            connected = false
            throw RelayClientError.notConnected
        }
        return message
    }

    public func disconnect() async {
        guard connected else { return }
        connected = false
        closed = true
        waiter?.resume(returning: nil)
        waiter = nil
        await link.detach(end)
    }

    // MARK: - Link side

    func deliver(_ message: RelayIncomingMessage) {
        guard !closed else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
        } else {
            buffer.append(message)
        }
    }

    /// The relay closed this socket.
    func finish() {
        closed = true
        waiter?.resume(returning: nil)
        waiter = nil
    }
}
