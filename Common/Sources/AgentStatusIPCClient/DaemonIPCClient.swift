import AgentStatusTransport
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOFoundationCompat
@preconcurrency import NIOPosix

public enum DaemonIPCClientError: Error, Sendable {
    case timedOut
    case connectionClosed
    case incompatibleProtocol(ProtocolVersion)
}

public final class DaemonIPCClient: @unchecked Sendable {
    public init() {}

    public func request(
        _ request: IPCRequest,
        socketPath: String,
        timeout: TimeAmount = .seconds(2)
    ) throws -> IPCResponse {
        let group = MultiThreadedEventLoopGroup.singleton
        let eventLoop = group.next()
        let responsePromise = eventLoop.makePromise(of: IPCResponse.self)
        defer {
            responsePromise.fail(DaemonIPCClientError.connectionClosed)
            _ = try? responsePromise.futureResult.wait()
        }
        let handler = ClientResponseHandler(responsePromise: responsePromise)
        let channel = try ClientBootstrap(group: group)
            .channelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(ClientFrameDecoder()))
                    try channel.pipeline.syncOperations.addHandler(handler)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .connect(unixDomainSocketPath: socketPath)
            .wait()

        let envelope = TransportEnvelope(payload: request)
        let body = try TransportCoding.makeEncoder().encode(envelope)
        guard body.count <= LengthPrefixedFrameCodec.maximumFrameLength else {
            throw FrameCodecError.frameTooLarge(body.count)
        }

        var buffer = channel.allocator.buffer(capacity: body.count + 4)
        buffer.writeInteger(UInt32(body.count), endianness: .big)
        buffer.writeBytes(body)
        try channel.writeAndFlush(buffer).wait()

        let timeoutTask = eventLoop.scheduleTask(in: timeout) {
            responsePromise.fail(DaemonIPCClientError.timedOut)
            channel.close(promise: nil)
        }
        defer {
            timeoutTask.cancel()
            try? channel.close().wait()
        }

        let responseEnvelope = try responsePromise.futureResult.wait()
        return responseEnvelope
    }
}

/// One persistent local channel receives daemon invalidation events for the
/// whole Mac. Sessions are multiplexed over this channel.
public final class DaemonEventSubscriber: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: Channel?
    private var connecting = false

    public init() {}

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return channel?.isActive == true || connecting
    }

    public func start(
        socketPath: String,
        onEvent: @escaping @Sendable (AgentIngressEvent) -> Void,
        onSummary: @escaping @Sendable (SessionSummary) -> Void,
        onHealth: @escaping @Sendable (DaemonHealth) -> Void,
        onDisconnect: @escaping @Sendable () -> Void
    ) throws {
        lock.lock()
        guard channel == nil, !connecting else {
            lock.unlock()
            return
        }
        connecting = true
        lock.unlock()

        do {
            let group = MultiThreadedEventLoopGroup.singleton
            let handler = ClientSubscriptionHandler(
                onEvent: onEvent,
                onSummary: onSummary,
                onHealth: onHealth,
                onDisconnect: { [weak self] in
                    self?.markDisconnected()
                    onDisconnect()
                }
            )
            let newChannel = try ClientBootstrap(group: group)
                .channelInitializer { channel in
                    do {
                        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(ClientFrameDecoder()))
                        try channel.pipeline.syncOperations.addHandler(handler)
                        return channel.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                .connect(unixDomainSocketPath: socketPath)
                .wait()

            let body = try TransportCoding.makeEncoder().encode(
                TransportEnvelope(payload: IPCRequest(operation: .subscribe))
            )
            var buffer = newChannel.allocator.buffer(capacity: body.count + 4)
            buffer.writeInteger(UInt32(body.count), endianness: .big)
            buffer.writeBytes(body)
            try newChannel.writeAndFlush(buffer).wait()

            lock.lock()
            channel = newChannel
            connecting = false
            lock.unlock()
        } catch {
            lock.lock()
            connecting = false
            lock.unlock()
            throw error
        }
    }

    public func stop() {
        lock.lock()
        let current = channel
        channel = nil
        connecting = false
        lock.unlock()
        try? current?.close().wait()
    }

    private func markDisconnected() {
        lock.lock()
        channel = nil
        connecting = false
        lock.unlock()
    }
}

public enum DaemonEndpoint {
    public static func defaultSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        if let override = environment["AGENT_STATUS_SOCKET"], !override.isEmpty {
            return override
        }
        return homeDirectory
            .appendingPathComponent("Library/Application Support/Agent Status", isDirectory: true)
            .appendingPathComponent("daemon.sock")
            .path
    }
}

private struct ClientFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let length = buffer.getInteger(
            at: buffer.readerIndex,
            endianness: .big,
            as: UInt32.self
        ) else { return .needMoreData }
        guard length <= LengthPrefixedFrameCodec.maximumFrameLength else {
            throw FrameCodecError.frameTooLarge(Int(length))
        }
        let totalLength = 4 + Int(length)
        guard buffer.readableBytes >= totalLength else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 4)
        guard let frame = buffer.readSlice(length: Int(length)) else { return .needMoreData }
        context.fireChannelRead(wrapInboundOut(frame))
        return .continue
    }

    mutating func decodeLast(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer,
        seenEOF: Bool
    ) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }
}

private final class ClientResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let responsePromise: EventLoopPromise<IPCResponse>

    init(responsePromise: EventLoopPromise<IPCResponse>) {
        self.responsePromise = responsePromise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let body = buffer.readData(length: buffer.readableBytes) else {
            responsePromise.fail(DaemonIPCClientError.connectionClosed)
            return
        }
        do {
            let envelope = try TransportCoding.makeDecoder().decode(
                TransportEnvelope<IPCResponse>.self,
                from: body
            )
            guard envelope.version.isCompatible(with: .current) else {
                throw DaemonIPCClientError.incompatibleProtocol(envelope.version)
            }
            responsePromise.succeed(envelope.payload)
        } catch {
            responsePromise.fail(error)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        responsePromise.fail(DaemonIPCClientError.connectionClosed)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        responsePromise.fail(error)
        context.close(promise: nil)
    }
}

private final class ClientSubscriptionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let onEvent: @Sendable (AgentIngressEvent) -> Void
    private let onSummary: @Sendable (SessionSummary) -> Void
    private let onHealth: @Sendable (DaemonHealth) -> Void
    private let onDisconnect: @Sendable () -> Void

    init(
        onEvent: @escaping @Sendable (AgentIngressEvent) -> Void,
        onSummary: @escaping @Sendable (SessionSummary) -> Void,
        onHealth: @escaping @Sendable (DaemonHealth) -> Void,
        onDisconnect: @escaping @Sendable () -> Void
    ) {
        self.onEvent = onEvent
        self.onSummary = onSummary
        self.onHealth = onHealth
        self.onDisconnect = onDisconnect
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let body = buffer.readData(length: buffer.readableBytes),
              let envelope = try? TransportCoding.makeDecoder().decode(
                TransportEnvelope<IPCResponse>.self,
                from: body
              ),
              envelope.version.isCompatible(with: .current) else { return }
        if let health = envelope.payload.health { onHealth(health) }
        if let event = envelope.payload.event { onEvent(event) }
        if let summary = envelope.payload.summary { onSummary(summary) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        onDisconnect()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
