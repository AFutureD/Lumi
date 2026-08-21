import AgentStatusTransport
import Darwin
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOFoundationCompat
@preconcurrency import NIOPosix

public enum DaemonServerError: Error, Sendable {
    case occupiedSocketPath(String)
}

public final class DaemonServer: @unchecked Sendable {
    private let socketPath: String
    private let service: DaemonService
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    public init(socketPath: String, service: DaemonService) {
        self.socketPath = socketPath
        self.service = service
        // One event loop is sufficient for the local daemon channel. Sessions
        // are multiplexed inside the protocol and never allocate NIO loops.
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    public func start() throws {
        try prepareSocketPath()

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .childChannelInitializer { [service] channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(ServerFrameDecoder()))
                    try channel.pipeline.syncOperations.addHandler(ServerRequestHandler(
                        service: service,
                        subscriptions: service.subscriptions
                    ))
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        channel = try bootstrap.bind(unixDomainSocketPath: socketPath).wait()
        guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
            try? channel?.close().wait()
            throw POSIXError(.EACCES)
        }
    }

    public func wait() throws {
        try channel?.closeFuture.wait()
    }

    public func shutdown() {
        try? channel?.close().wait()
        channel = nil
        try? group.syncShutdownGracefully()
        if (try? FileManager.default.attributesOfItem(atPath: socketPath)[.type] as? FileAttributeType) == .typeSocket {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    private func prepareSocketPath() throws {
        let url = URL(fileURLWithPath: socketPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard FileManager.default.fileExists(atPath: socketPath) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        guard attributes[.type] as? FileAttributeType == .typeSocket else {
            throw DaemonServerError.occupiedSocketPath(socketPath)
        }
        try FileManager.default.removeItem(atPath: socketPath)
    }
}

private struct ServerFrameDecoder: ByteToMessageDecoder {
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

private final class ChannelResponseWriter: @unchecked Sendable {
    private let channel: Channel

    init(channel: Channel) {
        self.channel = channel
    }

    func send(_ envelope: TransportEnvelope<IPCResponse>) {
        do {
            var body = try TransportCoding.makeEncoder().encode(envelope)
            if body.count > LengthPrefixedFrameCodec.maximumFrameLength {
                // The client-side decoder rejects oversized frames and drops
                // the connection; a clean failure keeps the channel usable and
                // tells the caller to page down.
                body = try TransportCoding.makeEncoder().encode(TransportEnvelope(
                    requestID: envelope.requestID,
                    payload: IPCResponse(
                        status: .error,
                        failure: IPCFailure(
                            code: "response_too_large",
                            message: "The response exceeds the IPC frame limit; request a smaller page.",
                            retryable: false
                        )
                    )
                ))
            }
            let frame = body
            channel.eventLoop.execute { [channel] in
                var buffer = channel.allocator.buffer(capacity: frame.count + 4)
                buffer.writeInteger(UInt32(frame.count), endianness: .big)
                buffer.writeBytes(frame)
                channel.writeAndFlush(buffer, promise: nil)
            }
        } catch {
            channel.close(promise: nil)
        }
    }
}

private final class ServerRequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let service: DaemonService
    private let subscriptions: DaemonSubscriptionHub
    private var subscriptionID: UUID?

    init(service: DaemonService, subscriptions: DaemonSubscriptionHub) {
        self.service = service
        self.subscriptions = subscriptions
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var frame = unwrapInboundIn(data)
        guard let body = frame.readData(length: frame.readableBytes) else { return }
        let writer = ChannelResponseWriter(channel: context.channel)

        do {
            let envelope = try TransportCoding.makeDecoder().decode(
                TransportEnvelope<IPCRequest>.self,
                from: body
            )
            if envelope.payload.operation == .subscribe, subscriptionID == nil {
                subscriptionID = subscriptions.subscribe { message in
                    switch message {
                    case let .event(event):
                        writer.send(TransportEnvelope(payload: IPCResponse(status: .accepted, event: event)))
                    case let .summary(summary):
                        writer.send(TransportEnvelope(payload: IPCResponse(status: .accepted, summary: summary)))
                    }
                }
            }
            Task { [service] in
                let response = await service.handle(envelope)
                writer.send(response)
            }
        } catch {
            let response = TransportEnvelope(
                payload: IPCResponse(
                    status: .error,
                    failure: IPCFailure(
                        code: "malformed_request",
                        message: "The request could not be decoded.",
                        retryable: false
                    )
                )
            )
            writer.send(response)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        unsubscribe()
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        unsubscribe()
        context.fireChannelInactive()
    }

    private func unsubscribe() {
        guard let subscriptionID else { return }
        subscriptions.unsubscribe(subscriptionID)
        self.subscriptionID = nil
    }
}
