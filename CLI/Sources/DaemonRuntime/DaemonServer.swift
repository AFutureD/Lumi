import Diagnostics
import IPCClient
import Logging
import ServiceLifecycle
import Synchronization
import Transport
import Darwin
import Dispatch
import Foundation

private let log = Logger(label: "ipc")

public enum DaemonServerError: Error, Sendable {
    case occupiedSocketPath(String)
}

/// The daemon's Unix socket server, all structured concurrency: an accept
/// stream feeds one child task per connection (connection count is
/// single-digit: the Mac subscriber plus short-lived helper requests), each
/// connection runs concurrent request tasks next to a single writer task.
/// Frames travel over `AsyncFrameChannel`; readiness comes from
/// DispatchSources, never a blocked thread.
public actor DaemonServer: Service {
    private let socketPath: String
    private let service: DaemonService
    private let outboundByteBudget: Int
    private var listener: Int32?

    /// `outboundByteBudget` bounds each connection's outbound queue. The only
    /// way to accumulate this much is a client that stopped reading; such a
    /// connection is dropped, and the Mac side recovers by reconnect +
    /// reconcile.
    public init(socketPath: String, service: DaemonService, outboundByteBudget: Int = 64 << 20) {
        self.socketPath = socketPath
        self.service = service
        self.outboundByteBudget = outboundByteBudget
    }

    /// Eager bind → chmod → listen: nobody can connect while the socket file
    /// is still wider than owner-only, and a bad socket path throws here —
    /// before the ServiceGroup starts — so a misconfigured daemon fails its
    /// launch instead of limping.
    public func listen() throws {
        guard listener == nil else { return }
        try prepareSocketPath()

        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let path = socketPath.utf8CString
        guard path.count <= capacity else {
            throw DaemonIPCSocketError(operation: "bind \(socketPath)", code: ENAMETOOLONG)
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DaemonIPCSocketError(operation: "socket", code: errno) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)

        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw DaemonIPCSocketError(operation: "bind", code: code)
        }
        guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
            Darwin.close(descriptor)
            unlink(socketPath)
            throw POSIXError(.EACCES)
        }
        guard Darwin.listen(descriptor, 128) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            unlink(socketPath)
            throw DaemonIPCSocketError(operation: "listen", code: code)
        }
        listener = descriptor
        log.info("ipc_listening", metadata: .fields(["socket": socketPath]))
    }

    public func run() async throws {
        try listen()
        guard let listener else { return }
        await cancelWhenGracefulShutdown {
            await withDiscardingTaskGroup { group in
                for await descriptor in Self.acceptedDescriptors(listener: listener) {
                    group.addTask { await self.serve(AsyncFrameChannel(adopting: descriptor)) }
                }
            }
            // The discarding group waited for every connection's teardown:
            // no write is in flight past this line.
        }
        self.listener = nil
        removeSocketFile()
        log.info("ipc_closed", metadata: .fields(["socket": socketPath]))
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

    private func removeSocketFile() {
        if (try? FileManager.default.attributesOfItem(atPath: socketPath)[.type] as? FileAttributeType) == .typeSocket {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    /// Accepted client descriptors as a stream: a DispatchSource on the
    /// listener drains accept(2) to EWOULDBLOCK per readiness event. Ending
    /// the consuming `for await` (cancellation) cancels the source, whose
    /// cancel handler closes the listener — the single owner of that close.
    private static func acceptedDescriptors(listener: Int32) -> AsyncStream<Int32> {
        AsyncStream { continuation in
            let source = DispatchSource.makeReadSource(
                fileDescriptor: listener,
                queue: DispatchQueue(label: "lumi.ipc-accept")
            )
            source.setEventHandler {
                while true {
                    let client = accept(listener, nil, nil)
                    if client >= 0 {
                        continuation.yield(client)
                        continue
                    }
                    switch errno {
                    case EINTR, ECONNABORTED:
                        continue
                    case EAGAIN, EWOULDBLOCK:
                        return
                    default:
                        continuation.finish()
                        return
                    }
                }
            }
            source.setCancelHandler {
                Darwin.close(listener)
                continuation.finish()
            }
            continuation.onTermination = { _ in source.cancel() }
            source.activate()
        }
    }

    private func serve(_ channel: AsyncFrameChannel) async {
        log.debug("ipc_client_connected")
        let writer = ConnectionWriter(channel: channel, byteBudget: outboundByteBudget)
        let subscription = ConnectionSubscription()
        await withDiscardingTaskGroup { group in
            group.addTask { await writer.run() }
            while true {
                let body: Data
                do {
                    body = try await channel.readFrame()
                } catch DaemonIPCClientError.connectionClosed {
                    break
                } catch is CancellationError {
                    break
                } catch {
                    log.warning("ipc_client_error", metadata: .fields([
                        "subscribed": subscription.currentID != nil,
                        "error": error,
                    ]))
                    break
                }
                group.addTask { await self.handle(body: body, writer: writer, subscription: subscription) }
            }
            writer.finish()
        }
        // Single teardown path, owner of the close: the writer has finished —
        // the descriptor is not closed while a write is in flight — then
        // unsubscribe, then close.
        let subscriptionID = subscription.takeID()
        if let subscriptionID { service.subscriptions.unsubscribe(subscriptionID) }
        channel.close()
        log.debug("ipc_client_disconnected", metadata: .fields(["subscribed": subscriptionID != nil]))
    }

    private func handle(body: Data, writer: ConnectionWriter, subscription: ConnectionSubscription) async {
        let started = ContinuousClock.now
        let envelope: TransportEnvelope<IPCRequest>
        do {
            envelope = try TransportCoding.makeDecoder().decode(TransportEnvelope<IPCRequest>.self, from: body)
        } catch {
            log.warning("ipc_request_malformed", metadata: .fields(["bytes": body.count, "error": error]))
            writer.send(TransportEnvelope(
                payload: IPCResponse(
                    status: .error,
                    failure: IPCFailure(
                        code: "malformed_request",
                        message: "The request could not be decoded.",
                        retryable: false
                    )
                )
            ))
            return
        }

        if envelope.payload.operation == .subscribe, subscription.currentID == nil {
            let id = service.subscriptions.subscribe { message in
                switch message {
                case let .event(event):
                    writer.send(TransportEnvelope(payload: IPCResponse(status: .accepted, event: event)))
                case let .summary(summary):
                    writer.send(TransportEnvelope(payload: IPCResponse(status: .accepted, summary: summary)))
                }
            }
            if !subscription.claim(id) {
                // A racing subscribe on the same connection won; drop ours.
                service.subscriptions.unsubscribe(id)
            } else {
                log.info("ipc_stream_client_subscribed")
            }
        }

        let bytesIn = body.count
        // One IPC request is one unit of work: the request id (the helper's
        // run id, the Mac's reconcile id) leads every line logged while the
        // service handles it. Requests on one connection run concurrently;
        // the writer serializes their response frames.
        await withTrace(envelope.requestID.rawValue) {
            let response = await service.handle(envelope)
            let bytesOut = writer.send(response)
            let failed = response.payload.status == .error
            log.log(level: failed ? .warning : .debug, "ipc_handled", metadata: .fields([
                "op": envelope.payload.operation.rawValue,
                "session": envelope.payload.sessionID?.rawValue,
                "status": response.payload.status.rawValue,
                "failure": response.payload.failure?.code,
                "bytes_in": bytesIn,
                "bytes_out": bytesOut,
                "ms": LogClock.milliseconds(since: started),
            ]))
        }
    }
}

/// One connection's subscription slot: written by whichever request task
/// carried the subscribe operation, read by `serve`'s teardown.
private final class ConnectionSubscription: Sendable {
    private let id = Mutex<UUID?>(nil)

    var currentID: UUID? { id.withLock { $0 } }

    /// Claims the slot; false when a racing subscribe already holds it.
    func claim(_ new: UUID) -> Bool {
        id.withLock {
            guard $0 == nil else { return false }
            $0 = new
            return true
        }
    }

    func takeID() -> UUID? {
        id.withLock { current in
            defer { current = nil }
            return current
        }
    }
}

/// One bounded outbound queue per connection, drained by a single writer
/// task so every frame is written atomically no matter which task produced
/// it (request tasks, the subscription hub). `send` stays synchronous — the
/// hub's handlers are non-suspending closures — and after `finish()` it
/// silently drops while still returning the encoded byte count for the
/// `ipc_handled` log.
private final class ConnectionWriter: Sendable {
    private let channel: AsyncFrameChannel
    private let byteBudget: Int
    private let frames: AsyncStream<Data>
    private let producer: AsyncStream<Data>.Continuation
    private let state: Mutex<(queuedBytes: Int, closed: Bool)>

    init(channel: AsyncFrameChannel, byteBudget: Int) {
        self.channel = channel
        self.byteBudget = byteBudget
        (frames, producer) = AsyncStream.makeStream(of: Data.self)
        state = Mutex((queuedBytes: 0, closed: false))
    }

    /// Encodes and enqueues one frame; returns the encoded byte count.
    @discardableResult
    func send(_ envelope: TransportEnvelope<IPCResponse>) -> Int {
        do {
            var body = try TransportCoding.makeEncoder().encode(envelope)
            if body.count > LengthPrefixedFrameCodec.maximumFrameLength {
                // The client-side decoder rejects oversized frames and drops
                // the connection; a clean failure keeps the connection usable
                // and tells the caller to page down.
                log.warning("ipc_response_too_large", metadata: .fields([
                    "bytes": body.count,
                    "limit": LengthPrefixedFrameCodec.maximumFrameLength,
                ]))
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
            enqueue(body)
            return body.count
        } catch {
            log.error("ipc_response_encode_failed", metadata: .fields(["error": error]))
            channel.shutdown()
            return 0
        }
    }

    /// Ends the frame stream; the writer task drains what is already queued
    /// and returns.
    func finish() {
        state.withLock { $0.closed = true }
        producer.finish()
    }

    func run() async {
        for await body in frames {
            state.withLock { $0.queuedBytes -= body.count }
            do {
                try await channel.writeFrame(body, deadline: ContinuousClock.now + .seconds(30))
            } catch is CancellationError {
                return
            } catch {
                log.warning("ipc_client_write_failed", metadata: .fields(["error": error]))
                state.withLock { $0.closed = true }
                channel.shutdown()
                return
            }
        }
    }

    private func enqueue(_ body: Data) {
        let action: Action = state.withLock { current in
            if current.closed { return .drop }
            if current.queuedBytes + body.count > byteBudget {
                return .overBudget(queued: current.queuedBytes)
            }
            current.queuedBytes += body.count
            return .enqueue
        }
        switch action {
        case .drop:
            return
        case let .overBudget(queued):
            log.warning("ipc_outbound_over_budget", metadata: .fields([
                "queued": queued,
                "frame": body.count,
                "budget": byteBudget,
            ]))
            channel.shutdown()
        case .enqueue:
            producer.yield(body)
        }
    }

    private enum Action {
        case drop
        case overBudget(queued: Int)
        case enqueue
    }
}
