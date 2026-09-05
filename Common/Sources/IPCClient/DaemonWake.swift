import Diagnostics
import Logging
import Synchronization
import Foundation
import Darwin
#if os(macOS)
import XPC
#endif

private let log = Logger(label: "ipc")

/// The only message a client sends to the daemon's Mach service. Its effect
/// is launchd's: a daemon that is not running gets spawned to receive it. No
/// session data travels here — the Unix socket stays the single data channel.
public struct DaemonWakeRequest: Codable, Sendable {
    public let clientProcessID: Int32

    public init(clientProcessID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.clientProcessID = clientProcessID
    }
}

/// The daemon's answer, sent only once its Unix socket is listening: the
/// client can connect now.
public struct DaemonWakeReply: Codable, Sendable {
    public let socketPath: String
    public let processID: Int32
    public let version: String

    public init(socketPath: String, processID: Int32, version: String) {
        self.socketPath = socketPath
        self.processID = processID
        self.version = version
    }
}

/// Whether and how a client wakes the daemon whose socket it could not
/// reach. No policy keeps a failed `connect(2)` a plain failure — what an
/// isolated daemon (`LUMI_SOCKET`) and the tests want.
public struct DaemonWakePolicy: Sendable {
    public let service: String
    /// Bounds the wake alone: launchd's spawn, the database open and the
    /// initial transcript baseline, plus up to launchd's `ThrottleInterval`
    /// when the daemon exited within the last few seconds.
    public let timeout: Duration

    public init(service: String, timeout: Duration) {
        self.service = service
        self.timeout = timeout
    }

    /// The policy for a client of `socketPath`: the installed daemon's
    /// service when that is the installed daemon's socket, `nil` for any
    /// other path (a test socket, an isolated daemon under `LUMI_SOCKET` /
    /// `LUMI_SUPPORT_DIRECTORY`) — waking the installed daemon would start
    /// the wrong one. `DaemonEndpoint.defaultWakeService` names the service.
    public static func `default`(
        socketPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: Duration
    ) -> DaemonWakePolicy? {
        guard let service = DaemonEndpoint.defaultWakeService(environment: environment),
              socketPath == DaemonEndpoint.defaultSocketPath(environment: environment)
        else { return nil }
        return DaemonWakePolicy(service: service, timeout: timeout)
    }
}

public enum DaemonWakeError: Error, CustomStringConvertible, Sendable {
    /// The service refused in a way that will not clear by itself: the
    /// daemon is not registered (never installed, uninstalled, or waiting
    /// for the user's approval in System Settings).
    case unavailable(service: String, reason: String)
    /// The message was accepted but no reply arrived in time: launchd is
    /// throttling a recent spawn, or the daemon is still starting.
    case timedOut(service: String)

    public var description: String {
        switch self {
        case let .unavailable(service, reason): "wake \(service): \(reason)"
        case let .timedOut(service): "wake \(service): no reply in time"
        }
    }
}

extension FrameConnection {
    /// Connects within `timeout`. When the socket is absent (`ENOENT`: the
    /// daemon never started, or unlinked its socket on exit) or refuses
    /// (`ECONNREFUSED`: a stale socket file) and a wake policy is given,
    /// wakes the daemon through its Mach service and connects again with a
    /// fresh budget. Every other failure propagates untouched.
    public static func connect(
        socketPath: String,
        timeout: Duration,
        wake: DaemonWakePolicy?
    ) throws -> FrameConnection {
        do {
            return try connect(socketPath: socketPath, deadline: ContinuousClock.now + timeout)
        } catch let error as DaemonIPCSocketError
            where error.operation == "connect" && (error.code == ENOENT || error.code == ECONNREFUSED)
        {
            guard let wake else { throw error }
            #if os(macOS)
            let started = ContinuousClock.now
            let reply: DaemonWakeReply
            do {
                reply = try DaemonWaker.wake(service: wake.service, timeout: wake.timeout)
            } catch {
                log.warning("ipc_wake_failed", metadata: .fields([
                    "service": wake.service,
                    "socket": socketPath,
                    "ms": LogClock.milliseconds(since: started),
                    "error": error,
                ]))
                throw error
            }
            log.info("ipc_wake", metadata: .fields([
                "service": wake.service,
                "daemon_pid": reply.processID,
                "daemon_version": reply.version,
                "ms": LogClock.milliseconds(since: started),
            ]))
            return try connect(socketPath: socketPath, deadline: ContinuousClock.now + timeout)
            #else
            throw error
            #endif
        }
    }
}

#if os(macOS)
/// One wake per call over a fresh `XPCSession`. launchd holds the Mach port,
/// so the message waits for the daemon it spawns, and one daemon answers
/// however many clients woke it at once — there is nothing to coordinate
/// between concurrent hook helpers. A transport interruption (the daemon
/// died mid-wake) earns one retry; a refusal never does.
public enum DaemonWaker {
    public static func wake(service: String, timeout: Duration) throws -> DaemonWakeReply {
        let deadline = ContinuousClock.now + timeout
        var retried = false
        while true {
            switch send(service: service, deadline: deadline) {
            case let .reply(reply):
                return reply
            case let .interrupted(reason) where !retried:
                retried = true
                log.info("ipc_wake_interrupted", metadata: .fields(["service": service, "error": reason]))
                Thread.sleep(forTimeInterval: 0.25)
            case let .interrupted(reason), let .refused(reason):
                throw DaemonWakeError.unavailable(service: service, reason: reason)
            case .timedOut:
                throw DaemonWakeError.timedOut(service: service)
            }
        }
    }

    private enum Outcome: Sendable {
        case reply(DaemonWakeReply)
        case interrupted(String)
        case refused(String)
        case timedOut
    }

    private static func send(service: String, deadline: ContinuousClock.Instant) -> Outcome {
        let session: XPCSession
        do {
            // No job owns the name: launchd refuses the lookup here, at once.
            session = try XPCSession(machService: service)
        } catch {
            return .refused(describe(error))
        }
        defer { session.cancel(reason: "wake complete") }
        let outcome = Mutex<Outcome?>(nil)
        let arrived = DispatchSemaphore(value: 0)
        do {
            try session.send(DaemonWakeRequest()) { (result: Result<XPCReceivedMessage, XPCRichError>) in
                let value: Outcome
                switch result {
                case let .success(message):
                    do {
                        value = .reply(try message.decode(as: DaemonWakeReply.self))
                    } catch {
                        value = .refused("undecodable reply: \(error)")
                    }
                case let .failure(error):
                    value = error.canRetry ? .interrupted(error.debugDescription) : .refused(error.debugDescription)
                }
                outcome.withLock { $0 = value }
                arrived.signal()
            }
        } catch let error as XPCRichError where error.canRetry {
            return .interrupted(error.debugDescription)
        } catch {
            return .refused(describe(error))
        }
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { return .timedOut }
        let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
        guard arrived.wait(timeout: .now() + seconds) == .success else { return .timedOut }
        return outcome.withLock { $0 } ?? .timedOut
    }

    private static func describe(_ error: any Error) -> String {
        (error as? XPCRichError)?.debugDescription ?? String(describing: error)
    }
}
#endif
