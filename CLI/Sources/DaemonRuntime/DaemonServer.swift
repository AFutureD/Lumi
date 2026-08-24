import Diagnostics
import IPCClient
import Logging
import Transport
import Darwin
import Foundation

private let log = Logger(label: "ipc")

public enum DaemonServerError: Error, Sendable {
    case occupiedSocketPath(String)
}

/// The daemon's Unix socket server on plain POSIX primitives: one accept
/// thread, then a reader and a writer thread per connection (connection count
/// is single-digit: the Mac subscriber plus short-lived helper requests).
/// Frames reuse the same `FrameConnection` the clients are built on.
public final class DaemonServer: @unchecked Sendable {
    private let socketPath: String
    private let service: DaemonService
    private let outboundByteBudget: Int

    private let state = NSCondition()
    private var running = false
    private var wakeWriteDescriptor: Int32 = -1
    private let acceptFinished = DispatchSemaphore(value: 0)

    private let connectionsLock = NSLock()
    private var connections: [ObjectIdentifier: ServerConnection] = [:]

    /// `outboundByteBudget` bounds each connection's outbound queue. The only
    /// way to accumulate this much is a client that stopped reading; such a
    /// connection is dropped, and the Mac side recovers by reconnect +
    /// reconcile. (NIO buffered without bound here.)
    public init(socketPath: String, service: DaemonService, outboundByteBudget: Int = 64 << 20) {
        self.socketPath = socketPath
        self.service = service
        self.outboundByteBudget = outboundByteBudget
    }

    public func start() throws {
        try prepareSocketPath()

        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let path = socketPath.utf8CString
        guard path.count <= capacity else {
            throw DaemonIPCSocketError(operation: "bind \(socketPath)", code: ENAMETOOLONG)
        }

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw DaemonIPCSocketError(operation: "socket", code: errno) }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        _ = fcntl(listener, F_SETFL, O_NONBLOCK)

        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(listener)
            throw DaemonIPCSocketError(operation: "bind", code: code)
        }
        // bind → chmod → listen: nobody can connect while the file is still
        // wider than owner-only. (NIO's combined bind+listen left a window.)
        guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
            Darwin.close(listener)
            unlink(socketPath)
            throw POSIXError(.EACCES)
        }
        guard listen(listener, 128) == 0 else {
            let code = errno
            Darwin.close(listener)
            unlink(socketPath)
            throw DaemonIPCSocketError(operation: "listen", code: code)
        }

        var pipeDescriptors: [Int32] = [-1, -1]
        guard pipe(&pipeDescriptors) == 0 else {
            let code = errno
            Darwin.close(listener)
            unlink(socketPath)
            throw DaemonIPCSocketError(operation: "pipe", code: code)
        }
        _ = fcntl(pipeDescriptors[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(pipeDescriptors[1], F_SETFD, FD_CLOEXEC)

        state.lock()
        running = true
        wakeWriteDescriptor = pipeDescriptors[1]
        state.unlock()

        let wakeRead = pipeDescriptors[0]
        let thread = Thread { self.acceptLoop(listener: listener, wake: wakeRead) }
        thread.name = "lumi.ipc-accept"
        thread.start()
        log.info("ipc_listening", metadata: .fields(["socket": socketPath]))
    }

    public func wait() throws {
        state.lock()
        while running { state.wait() }
        state.unlock()
    }

    public func shutdown() {
        state.lock()
        guard running else {
            state.unlock()
            return
        }
        running = false
        let wakeWrite = wakeWriteDescriptor
        wakeWriteDescriptor = -1
        state.unlock()

        var byte: UInt8 = 0
        _ = write(wakeWrite, &byte, 1)
        connectionsLock.lock()
        let current = Array(connections.values)
        connectionsLock.unlock()
        for connection in current { connection.shutdownIfOpen() }
        acceptFinished.wait()
        Darwin.close(wakeWrite)

        if (try? FileManager.default.attributesOfItem(atPath: socketPath)[.type] as? FileAttributeType) == .typeSocket {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        state.lock()
        state.broadcast()
        state.unlock()
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

    private func acceptLoop(listener: Int32, wake: Int32) {
        defer {
            Darwin.close(listener)
            Darwin.close(wake)
            acceptFinished.signal()
        }
        while true {
            var entries = [
                pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wake, events: Int16(POLLIN), revents: 0),
            ]
            let ready = entries.withUnsafeMutableBufferPointer { Darwin.poll($0.baseAddress, 2, -1) }
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if entries[1].revents != 0 { return }
            if entries[0].revents == 0 { continue }

            let client = accept(listener, nil, nil)
            if client < 0 {
                switch errno {
                case EINTR, EWOULDBLOCK, ECONNABORTED: continue
                default: return
                }
            }
            let connection = ServerConnection(frames: .adopt(descriptor: client))
            connectionsLock.lock()
            connections[ObjectIdentifier(connection)] = connection
            connectionsLock.unlock()
            let thread = Thread { self.serve(connection) }
            thread.name = "lumi.ipc-conn"
            thread.start()
        }
    }

    private func serve(_ connection: ServerConnection) {
        log.debug("ipc_client_connected")
        let writer = ConnectionWriter(connection: connection, byteBudget: outboundByteBudget)
        let writerFinished = DispatchSemaphore(value: 0)
        let writerThread = Thread {
            writer.run()
            writerFinished.signal()
        }
        writerThread.name = "lumi.ipc-writer"
        writerThread.start()

        var subscriptionID: UUID?
        defer {
            // Single teardown path, reader-owned: close the queue (wakes the
            // writer), wait for it — the descriptor must not be closed while a
            // write is in flight — then unsubscribe, unregister and close.
            writer.close()
            writerFinished.wait()
            if let subscriptionID { service.subscriptions.unsubscribe(subscriptionID) }
            connectionsLock.lock()
            connections[ObjectIdentifier(connection)] = nil
            connectionsLock.unlock()
            connection.closeOnce()
            log.debug("ipc_client_disconnected", metadata: .fields(["subscribed": subscriptionID != nil]))
        }

        while true {
            let body: Data
            do {
                body = try connection.frames.readFrame(deadline: nil)
            } catch DaemonIPCClientError.connectionClosed {
                return
            } catch {
                log.warning("ipc_client_error", metadata: .fields([
                    "subscribed": subscriptionID != nil,
                    "error": error,
                ]))
                return
            }
            handle(body: body, writer: writer, subscriptionID: &subscriptionID)
        }
    }

    private func handle(body: Data, writer: ConnectionWriter, subscriptionID: inout UUID?) {
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

        if envelope.payload.operation == .subscribe, subscriptionID == nil {
            subscriptionID = service.subscriptions.subscribe { message in
                switch message {
                case let .event(event):
                    writer.send(TransportEnvelope(payload: IPCResponse(status: .accepted, event: event)))
                case let .summary(summary):
                    writer.send(TransportEnvelope(payload: IPCResponse(status: .accepted, summary: summary)))
                }
            }
            log.info("ipc_stream_client_subscribed")
        }

        let bytesIn = body.count
        // One IPC request is one unit of work: the request id (the helper's
        // run id, the Mac's reconcile id) leads every line logged while the
        // service handles it. Requests on one connection run concurrently;
        // the writer serializes their response frames.
        Task { [service] in
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
}

/// Guards the descriptor against the shutdown/close race: `shutdownIfOpen`
/// (any thread) and `closeOnce` (the reader's teardown, exactly once) share
/// one lock, so a descriptor number can never be shut down after the reader
/// closed it and the number was reused.
private final class ServerConnection: @unchecked Sendable {
    let frames: FrameConnection
    private let lock = NSLock()
    private var isClosed = false

    init(frames: FrameConnection) {
        self.frames = frames
    }

    func shutdownIfOpen() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        frames.shutdown()
    }

    func closeOnce() {
        lock.lock()
        let shouldClose = !isClosed
        isClosed = true
        lock.unlock()
        if shouldClose { frames.close() }
    }
}

/// One bounded outbound queue per connection, drained by a dedicated writer
/// thread so every frame is written atomically no matter which thread
/// produced it (request tasks, the subscription hub). After `close()`,
/// `send` silently drops — matching NIO's write-to-closed-channel behavior —
/// while still returning the encoded byte count for the `ipc_handled` log.
private final class ConnectionWriter: @unchecked Sendable {
    private let connection: ServerConnection
    private let byteBudget: Int
    private let condition = NSCondition()
    private var queue: [Data] = []
    private var queuedBytes = 0
    private var closed = false

    init(connection: ServerConnection, byteBudget: Int) {
        self.connection = connection
        self.byteBudget = byteBudget
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
            connection.shutdownIfOpen()
            return 0
        }
    }

    private func enqueue(_ body: Data) {
        condition.lock()
        if closed {
            condition.unlock()
            return
        }
        if queuedBytes + body.count > byteBudget {
            condition.unlock()
            log.warning("ipc_outbound_over_budget", metadata: .fields([
                "queued": queuedBytes,
                "frame": body.count,
                "budget": byteBudget,
            ]))
            connection.shutdownIfOpen()
            return
        }
        queue.append(body)
        queuedBytes += body.count
        condition.signal()
        condition.unlock()
    }

    func close() {
        condition.lock()
        closed = true
        queue.removeAll()
        queuedBytes = 0
        condition.broadcast()
        condition.unlock()
    }

    func run() {
        while true {
            condition.lock()
            while queue.isEmpty, !closed { condition.wait() }
            if closed {
                condition.unlock()
                return
            }
            let body = queue.removeFirst()
            queuedBytes -= body.count
            condition.unlock()

            do {
                try connection.frames.writeFrame(body, deadline: ContinuousClock.now + .seconds(30))
            } catch {
                log.warning("ipc_client_write_failed", metadata: .fields(["error": error]))
                connection.shutdownIfOpen()
                close()
                return
            }
        }
    }
}
