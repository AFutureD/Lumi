import IPCClient
import Synchronization
import Transport
import Darwin
import Dispatch
import Foundation

/// The daemon-side async counterpart of `FrameConnection`: length-prefixed
/// frames over a non-blocking Unix socket, with readiness waits bridged from
/// per-wait `DispatchSource`s into continuations instead of blocking poll(2).
///
/// Concurrency contract: one reader task and one writer task per channel
/// (the server's `serve` loop and its `ConnectionWriter`). `shutdown()` and
/// `close()` may be called from anywhere; every descriptor syscall runs under
/// the state lock, so a descriptor number can never be shut down or waited on
/// after it was closed and reused — the invariant the old `ServerConnection`
/// lock existed for.
final class AsyncFrameChannel: Sendable {
    private enum Direction {
        case read
        case write
    }

    private struct DirectionState {
        var waiter: CheckedContinuation<Void, any Error>?
        var source: DispatchSourceProtocol?
        /// Ties a scheduled timeout to one particular wait: a timer firing
        /// after its wait resumed must not fail a later wait.
        var generation: UInt64 = 0
    }

    private struct State {
        var read = DirectionState()
        var write = DirectionState()
        /// `close()` was called: no new waits, no more shutdown syscalls.
        var closed = false
        /// The descriptor itself was closed (all sources retired).
        var descriptorClosed = false
        /// Live DispatchSources; the descriptor closes when the last retires.
        var outstandingSources = 0
    }

    private let descriptor: Int32
    private let queue: DispatchQueue
    private let state = Mutex(State())

    /// Takes ownership of an accepted descriptor. The non-blocking and
    /// no-SIGPIPE flags are set explicitly: their inheritance through
    /// accept(2) is not portable.
    init(adopting descriptor: Int32) {
        self.descriptor = descriptor
        queue = DispatchQueue(label: "lumi.ipc-channel")
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        var enable: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enable, socklen_t(MemoryLayout<Int32>.size))
    }

    func readFrame() async throws -> Data {
        let header = try await readFully(4)
        let length = Int(UInt32(bigEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        guard length <= LengthPrefixedFrameCodec.maximumFrameLength else {
            throw FrameCodecError.frameTooLarge(length)
        }
        return try await readFully(length)
    }

    func writeFrame(_ body: Data, deadline: ContinuousClock.Instant) async throws {
        guard body.count <= LengthPrefixedFrameCodec.maximumFrameLength else {
            throw FrameCodecError.frameTooLarge(body.count)
        }
        var frame = withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) }
        frame.append(body)
        try await writeFully(frame, deadline: deadline)
    }

    /// Wakes both endpoints of the connection; parked waits resume through
    /// the kernel (EOF on read readiness, EPIPE on the next write).
    func shutdown() {
        state.withLock { current in
            guard !current.closed, !current.descriptorClosed else { return }
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        }
    }

    /// Single teardown entry, called exactly once by the connection's owner
    /// after reader and writer finished. Fails any parked waits, retires
    /// their sources, and closes the descriptor once no source remains.
    func close() {
        let waiters: [CheckedContinuation<Void, any Error>] = state.withLock { current in
            guard !current.closed else { return [] }
            current.closed = true
            var taken: [CheckedContinuation<Void, any Error>] = []
            for direction in [Direction.read, .write] {
                let (waiter, source) = take(direction, in: &current)
                if let waiter { taken.append(waiter) }
                source?.cancel()
            }
            if current.outstandingSources == 0 {
                current.descriptorClosed = true
                _ = Darwin.close(descriptor)
            }
            return taken
        }
        for waiter in waiters { waiter.resume(throwing: DaemonIPCClientError.connectionClosed) }
    }

    private func readFully(_ count: Int) async throws -> Data {
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
                try await wait(for: .read, deadline: nil)
            case ECONNRESET:
                throw DaemonIPCClientError.connectionClosed
            default:
                throw DaemonIPCSocketError(operation: "read", code: errno)
            }
        }
        return Data(buffer)
    }

    private func writeFully(_ data: Data, deadline: ContinuousClock.Instant) async throws {
        // A copy, not `withUnsafeBytes`: the buffer must stay valid across
        // the readiness suspensions, and pointer scopes cannot.
        let bytes = [UInt8](data)
        var sent = 0
        while sent < bytes.count {
            let result = bytes.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress! + sent, bytes.count - sent)
            }
            if result > 0 {
                sent += result
                continue
            }
            switch errno {
            case EINTR:
                continue
            case EAGAIN, EWOULDBLOCK:
                try await wait(for: .write, deadline: deadline)
            case EPIPE, ECONNRESET, EBADF:
                throw DaemonIPCClientError.connectionClosed
            default:
                throw DaemonIPCSocketError(operation: "write", code: errno)
            }
        }
    }

    /// Parks until the descriptor is ready in `direction`. One transient
    /// DispatchSource per wait: sources are never suspended, so there is no
    /// suspend-count balancing, and the cancel handler is the single place a
    /// source retires — the descriptor closes only after the last one has.
    private func wait(for direction: Direction, deadline: ContinuousClock.Instant?) async throws {
        if let deadline, ContinuousClock.now >= deadline {
            throw DaemonIPCClientError.timedOut
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let generation: UInt64? = state.withLock { current in
                    if current.closed || Task.isCancelled { return nil }
                    let source: DispatchSourceProtocol = switch direction {
                    case .read: DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
                    case .write: DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
                    }
                    // Strong captures on purpose: the handlers anchor the
                    // channel until the source retires, so a deferred
                    // descriptor close can never lose its `self` to deinit.
                    // libdispatch releases both handlers once cancellation
                    // completes, which breaks the cycle.
                    source.setEventHandler { self.fire(direction) }
                    source.setCancelHandler { self.sourceRetired() }
                    current.outstandingSources += 1
                    switch direction {
                    case .read:
                        current.read.generation &+= 1
                        current.read.waiter = continuation
                        current.read.source = source
                    case .write:
                        current.write.generation &+= 1
                        current.write.waiter = continuation
                        current.write.source = source
                    }
                    source.activate()
                    return direction == .read ? current.read.generation : current.write.generation
                }
                guard let generation else {
                    continuation.resume(throwing: Task.isCancelled
                        ? CancellationError()
                        : DaemonIPCClientError.connectionClosed)
                    return
                }
                if let deadline {
                    let remaining = ContinuousClock.now.duration(to: deadline)
                    let seconds = Double(remaining.components.seconds)
                        + Double(remaining.components.attoseconds) / 1e18
                    queue.asyncAfter(deadline: .now() + max(0, seconds)) { [weak self] in
                        self?.fail(direction, with: DaemonIPCClientError.timedOut, ifGeneration: generation)
                    }
                }
            }
        } onCancel: {
            self.fail(direction, with: CancellationError(), ifGeneration: nil)
        }
    }

    private func fire(_ direction: Direction) {
        let waiter = state.withLock { current in
            let (waiter, source) = take(direction, in: &current)
            source?.cancel()
            return waiter
        }
        waiter?.resume()
    }

    private func fail(_ direction: Direction, with error: any Error, ifGeneration generation: UInt64?) {
        let waiter = state.withLock { current -> CheckedContinuation<Void, any Error>? in
            if let generation {
                let currentGeneration = direction == .read ? current.read.generation : current.write.generation
                guard currentGeneration == generation else { return nil }
            }
            let (waiter, source) = take(direction, in: &current)
            source?.cancel()
            return waiter
        }
        waiter?.resume(throwing: error)
    }

    private func take(
        _ direction: Direction,
        in current: inout State
    ) -> (CheckedContinuation<Void, any Error>?, DispatchSourceProtocol?) {
        switch direction {
        case .read:
            defer {
                current.read.waiter = nil
                current.read.source = nil
            }
            return (current.read.waiter, current.read.source)
        case .write:
            defer {
                current.write.waiter = nil
                current.write.source = nil
            }
            return (current.write.waiter, current.write.source)
        }
    }

    private func sourceRetired() {
        state.withLock { current in
            current.outstandingSources -= 1
            if current.closed, !current.descriptorClosed, current.outstandingSources == 0 {
                current.descriptorClosed = true
                _ = Darwin.close(descriptor)
            }
        }
    }
}
