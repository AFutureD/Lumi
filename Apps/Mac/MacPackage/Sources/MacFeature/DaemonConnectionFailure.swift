import IPCClient
import Transport
import Foundation

/// Why the daemon is not answering, read off the error the connection or a
/// request threw. The Settings panel picks its words and buttons from these
/// cases; `description` is the one-line form for logs and secondary text.
public enum DaemonConnectionFailure: Equatable, Sendable, CustomStringConvertible {
    /// Nothing listens on the socket and no wake started a daemon: none is
    /// registered, it waits for approval, or the wake was refused.
    case daemonNotRunning(String)
    /// The wake was accepted but no daemon answered within the budget —
    /// launchd is throttling a recent exit, or the daemon is still booting.
    case daemonStarting(String)
    /// Connected, but a request or the subscription ran out of time.
    case daemonNotResponding(String)
    /// The daemon speaks another protocol major; neither side can trust the
    /// other's frames.
    case incompatibleDaemon(major: UInt16)
    /// The stream ended after being up: the daemon exited or restarted.
    case streamClosed
    /// Anything else.
    case other(String)

    public init(_ error: any Error) {
        switch error {
        case let socket as DaemonIPCSocketError
            where socket.operation == "connect" && (socket.code == ENOENT || socket.code == ECONNREFUSED):
            self = .daemonNotRunning(socket.description)
        case let wake as DaemonWakeError:
            switch wake {
            case .unavailable: self = .daemonNotRunning(wake.description)
            case .timedOut: self = .daemonStarting(wake.description)
            }
        case DaemonIPCClientError.timedOut:
            self = .daemonNotResponding("no reply in time")
        case let DaemonIPCClientError.incompatibleProtocol(version):
            self = .incompatibleDaemon(major: version.major)
        case DaemonIPCClientError.connectionClosed:
            self = .streamClosed
        default:
            self = .other(String(describing: error))
        }
    }

    public var description: String {
        switch self {
        case let .daemonNotRunning(detail): "daemon is not running (\(detail))"
        case let .daemonStarting(detail): "daemon is starting (\(detail))"
        case let .daemonNotResponding(detail): "daemon is not responding (\(detail))"
        case let .incompatibleDaemon(major): "daemon speaks protocol v\(major), this app speaks v\(ProtocolVersion.current.major)"
        case .streamClosed: "daemon event stream closed"
        case let .other(detail): detail
        }
    }
}
