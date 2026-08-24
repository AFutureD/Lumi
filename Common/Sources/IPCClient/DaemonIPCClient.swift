import Diagnostics
import Logging
import Transport
import Foundation
import Darwin

private let log = Logger(label: "ipc")

public enum DaemonIPCClientError: Error, Sendable {
    case timedOut
    case connectionClosed
    case incompatibleProtocol(ProtocolVersion)
}

/// A socket syscall failure that is neither a timeout nor a clean close.
public struct DaemonIPCSocketError: Error, CustomStringConvertible, Sendable {
    public let operation: String
    public let code: Int32

    public init(operation: String, code: Int32) {
        self.operation = operation
        self.code = code
    }

    public var description: String {
        "\(operation): \(String(cString: strerror(code))) (\(code))"
    }
}

public final class DaemonIPCClient: @unchecked Sendable {
    public init() {}

    public func request(
        _ request: IPCRequest,
        socketPath: String,
        timeout: Duration = .seconds(2)
    ) throws -> IPCResponse {
        let started = ContinuousClock.now
        do {
            let (response, bytesOut) = try send(request, socketPath: socketPath, timeout: timeout)
            let failed = response.status == .error
            log.log(level: failed ? .warning : .debug, "ipc_request", metadata: .fields([
                "op": request.operation.rawValue,
                "session": request.sessionID?.rawValue,
                "events": request.events?.count,
                "bytes_out": bytesOut,
                "status": response.status.rawValue,
                "failure": response.failure?.code,
                "ms": LogClock.milliseconds(since: started),
            ]))
            return response
        } catch {
            log.warning("ipc_request_failed", metadata: .fields([
                "op": request.operation.rawValue,
                "socket": socketPath,
                "ms": LogClock.milliseconds(since: started),
                "error": error,
            ]))
            throw error
        }
    }

    private func send(
        _ request: IPCRequest,
        socketPath: String,
        timeout: Duration
    ) throws -> (IPCResponse, Int) {
        // Inside a traced unit (a helper run, a Mac reconcile pass) the
        // request carries that unit's id, so the daemon's lines join ours.
        let envelope = TransportEnvelope(
            requestID: currentTraceID.map(RequestID.init(rawValue:)) ?? RequestID(),
            payload: request
        )
        let body = try TransportCoding.makeEncoder().encode(envelope)

        // One deadline covers connect, write and the response read.
        let deadline = ContinuousClock.now + timeout
        let connection = try FrameConnection.connect(socketPath: socketPath, deadline: deadline)
        defer { connection.close() }
        try connection.writeFrame(body, deadline: deadline)
        let responseBody = try connection.readFrame(deadline: deadline)

        let responseEnvelope = try TransportCoding.makeDecoder().decode(
            TransportEnvelope<IPCResponse>.self,
            from: responseBody
        )
        guard responseEnvelope.version.isCompatible(with: .current) else {
            throw DaemonIPCClientError.incompatibleProtocol(responseEnvelope.version)
        }
        return (responseEnvelope.payload, body.count)
    }
}

/// One persistent local channel receives daemon invalidation events for the
/// whole Mac. Sessions are multiplexed over this channel.
///
/// A dedicated thread blocks in the frame-read loop. `stop()` only shuts the
/// socket down (which reliably wakes the reader on Darwin); closing the file
/// descriptor is the read loop's job alone, so the descriptor can never be
/// reused out from under a blocked read.
public final class DaemonEventSubscriber: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: FrameConnection?
    private var connecting = false

    public init() {}

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connection != nil || connecting
    }

    public func start(
        socketPath: String,
        onEvent: @escaping @Sendable (AgentIngressEvent) -> Void,
        onSummary: @escaping @Sendable (SessionSummary) -> Void,
        onHealth: @escaping @Sendable (DaemonHealth) -> Void,
        onDisconnect: @escaping @Sendable () -> Void
    ) throws {
        lock.lock()
        guard connection == nil, !connecting else {
            lock.unlock()
            return
        }
        connecting = true
        lock.unlock()

        do {
            let deadline = ContinuousClock.now + .seconds(10)
            let newConnection = try FrameConnection.connect(socketPath: socketPath, deadline: deadline)
            do {
                let body = try TransportCoding.makeEncoder().encode(
                    TransportEnvelope(payload: IPCRequest(operation: .subscribe))
                )
                try newConnection.writeFrame(body, deadline: deadline)
            } catch {
                newConnection.close()
                throw error
            }

            lock.lock()
            connection = newConnection
            connecting = false
            lock.unlock()
            log.info("ipc_stream_connected", metadata: .fields(["socket": socketPath]))

            let thread = Thread { [weak self] in
                Self.readLoop(
                    connection: newConnection,
                    subscriber: self,
                    onEvent: onEvent,
                    onSummary: onSummary,
                    onHealth: onHealth,
                    onDisconnect: onDisconnect
                )
            }
            thread.name = "lumi.ipc-subscriber"
            thread.start()
        } catch {
            lock.lock()
            connecting = false
            lock.unlock()
            log.warning("ipc_stream_connect_failed", metadata: .fields(["socket": socketPath, "error": error]))
            throw error
        }
    }

    public func stop() {
        lock.lock()
        let current = connection
        connection = nil
        connecting = false
        lock.unlock()
        current?.shutdown()
    }

    /// Clears the stored connection only if it is still this loop's own, so a
    /// stop-then-restart never has the old loop clobber the new connection.
    private func markDisconnected(_ connection: FrameConnection) {
        lock.lock()
        if self.connection === connection {
            self.connection = nil
            connecting = false
        }
        lock.unlock()
        log.info("ipc_stream_disconnected")
    }

    private static func readLoop(
        connection: FrameConnection,
        subscriber: DaemonEventSubscriber?,
        onEvent: @Sendable (AgentIngressEvent) -> Void,
        onSummary: @Sendable (SessionSummary) -> Void,
        onHealth: @Sendable (DaemonHealth) -> Void,
        onDisconnect: @Sendable () -> Void
    ) {
        defer {
            connection.close()
            // State resets before the callback: when the store reconnects two
            // seconds later, `isRunning` must already read false.
            subscriber?.markDisconnected(connection)
            onDisconnect()
        }
        while true {
            let body: Data
            do {
                body = try connection.readFrame(deadline: nil)
            } catch DaemonIPCClientError.connectionClosed {
                return
            } catch {
                log.warning("ipc_stream_error", metadata: .fields(["error": error]))
                return
            }

            let envelope: TransportEnvelope<IPCResponse>
            do {
                envelope = try TransportCoding.makeDecoder().decode(TransportEnvelope<IPCResponse>.self, from: body)
            } catch {
                // A frame this build cannot read is dropped, not fatal — but it
                // is the one symptom of a daemon / app version skew worth seeing.
                log.warning("ipc_stream_frame_rejected", metadata: .fields(["bytes": body.count, "error": error]))
                continue
            }
            guard envelope.version.isCompatible(with: .current) else {
                log.warning("ipc_stream_frame_incompatible", metadata: .fields([
                    "bytes": body.count,
                    "major": envelope.version.major,
                ]))
                continue
            }
            if let health = envelope.payload.health {
                log.debug("ipc_stream_health", metadata: .fields([
                    "active": health.activeSessionCount,
                    "retained": health.retainedSessionCount,
                    "relay": health.relayConnected,
                ]))
                onHealth(health)
            }
            if let event = envelope.payload.event {
                log.debug("ipc_stream_event", metadata: .fields([
                    "session": event.sessionID.rawValue,
                    "event": event.eventID.rawValue,
                    "bytes": body.count,
                ]))
                onEvent(event)
            }
            if let summary = envelope.payload.summary {
                log.debug("ipc_stream_summary", metadata: .fields(["session": summary.id.rawValue]))
                onSummary(summary)
            }
        }
    }
}

public enum DaemonEndpoint {
    public static func defaultSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        if let override = environment["LUMI_SOCKET"], !override.isEmpty {
            return override
        }
        return homeDirectory
            .appendingPathComponent("Library/Application Support/Lumi", isDirectory: true)
            .appendingPathComponent("daemon.sock")
            .path
    }
}

/// A length-prefixed-frame connection over a non-blocking Unix socket. Every
/// wait goes through poll(2) against one absolute deadline (`nil` waits
/// forever); partial reads and writes loop until the frame is complete, which
/// also handles frames split across or coalesced within socket reads.
///
/// Shared by both sides of the daemon socket: clients get one via `connect`,
/// the server wraps each accepted descriptor via `adopt`.
public final class FrameConnection: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Takes ownership of an accepted descriptor. The non-blocking and
    /// no-SIGPIPE flags are set explicitly: their inheritance through
    /// accept(2) is not portable.
    public static func adopt(descriptor: Int32) -> FrameConnection {
        configure(descriptor)
        return FrameConnection(descriptor: descriptor)
    }

    public static func connect(socketPath: String, deadline: ContinuousClock.Instant) throws -> FrameConnection {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let path = socketPath.utf8CString
        guard path.count <= capacity else {
            throw DaemonIPCSocketError(operation: "connect \(socketPath)", code: ENAMETOOLONG)
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DaemonIPCSocketError(operation: "socket", code: errno) }
        let connection = FrameConnection(descriptor: descriptor)
        configure(descriptor)

        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withUnsafeBytes { destination.copyBytes(from: $0) }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EINTR else {
                let code = errno
                connection.close()
                throw DaemonIPCSocketError(operation: "connect", code: code)
            }
            do {
                try connection.wait(for: Int16(POLLOUT), deadline: deadline)
                var connectError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                _ = getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &connectError, &length)
                guard connectError == 0 else {
                    throw DaemonIPCSocketError(operation: "connect", code: connectError)
                }
            } catch {
                connection.close()
                throw error
            }
        }
        return connection
    }

    private static func configure(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        var enable: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enable, socklen_t(MemoryLayout<Int32>.size))
    }

    public func writeFrame(_ body: Data, deadline: ContinuousClock.Instant?) throws {
        guard body.count <= LengthPrefixedFrameCodec.maximumFrameLength else {
            throw FrameCodecError.frameTooLarge(body.count)
        }
        var frame = withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) }
        frame.append(body)
        try writeFully(frame, deadline: deadline)
    }

    public func readFrame(deadline: ContinuousClock.Instant?) throws -> Data {
        let header = try readFully(4, deadline: deadline)
        let length = Int(UInt32(bigEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        guard length <= LengthPrefixedFrameCodec.maximumFrameLength else {
            throw FrameCodecError.frameTooLarge(length)
        }
        return try readFully(length, deadline: deadline)
    }

    /// Wakes a reader blocked on this connection; the read loop still owns the
    /// descriptor and closes it itself.
    public func shutdown() {
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    }

    public func close() {
        _ = Darwin.close(descriptor)
    }

    private func writeFully(_ data: Data, deadline: ContinuousClock.Instant?) throws {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var sent = 0
            while sent < bytes.count {
                let result = Darwin.write(descriptor, bytes.baseAddress! + sent, bytes.count - sent)
                if result > 0 {
                    sent += result
                    continue
                }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN, EWOULDBLOCK:
                    try wait(for: Int16(POLLOUT), deadline: deadline)
                case EPIPE, ECONNRESET:
                    throw DaemonIPCClientError.connectionClosed
                default:
                    throw DaemonIPCSocketError(operation: "write", code: errno)
                }
            }
        }
    }

    private func readFully(_ count: Int, deadline: ContinuousClock.Instant?) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let result = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress! + received, count - received)
            }
            if result > 0 {
                received += result
                continue
            }
            if result == 0 { throw DaemonIPCClientError.connectionClosed }
            switch errno {
            case EINTR:
                continue
            case EAGAIN, EWOULDBLOCK:
                try wait(for: Int16(POLLIN), deadline: deadline)
            case ECONNRESET:
                throw DaemonIPCClientError.connectionClosed
            default:
                throw DaemonIPCSocketError(operation: "read", code: errno)
            }
        }
        return Data(buffer)
    }

    private func wait(for events: Int16, deadline: ContinuousClock.Instant?) throws {
        while true {
            var timeoutMilliseconds: Int32 = -1
            if let deadline {
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { throw DaemonIPCClientError.timedOut }
                let milliseconds = remaining.components.seconds * 1000
                    + remaining.components.attoseconds / 1_000_000_000_000_000
                timeoutMilliseconds = Int32(clamping: milliseconds + 1)
            }
            var entry = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&entry, 1, timeoutMilliseconds)
            if result > 0 { return }
            if result == 0 { throw DaemonIPCClientError.timedOut }
            if errno == EINTR { continue }
            throw DaemonIPCSocketError(operation: "poll", code: errno)
        }
    }
}
