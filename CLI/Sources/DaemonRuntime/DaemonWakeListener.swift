import Diagnostics
import IPCClient
import Logging
import ServiceLifecycle
import XPC
import Foundation

private let log = Logger(label: "lifecycle")

/// The daemon's launchd Mach service (`DaemonEndpoint.machServiceName`). Its
/// one job is demand launch: a client whose `connect(2)` found no socket
/// sends a wake message, launchd spawns this daemon to deliver it, and the
/// reply — sent only once the Unix socket listens — tells the client to
/// connect. No session data crosses this channel.
///
/// Activated after `DaemonServer.listen()` and shut down first, so a daemon
/// on its way out never acknowledges a wake.
public actor DaemonWakeListener: Service {
    private let service: String
    private let socketPath: String
    private let version: String
    private var listener: XPCListener?

    public init(service: String, socketPath: String, version: String) {
        self.service = service
        self.socketPath = socketPath
        self.version = version
    }

    /// Messages launchd queued before this point are delivered on
    /// activation, so from here on a reply always means "connect now".
    public func activate() throws {
        guard listener == nil else { return }
        let socketPath = socketPath
        let version = version
        let listener = try XPCListener(service: service, options: .inactive) { request in
            request.accept { (message: XPCReceivedMessage) -> (any Encodable)? in
                let wake = try? message.decode(as: DaemonWakeRequest.self)
                log.info("wake_received", metadata: .fields(["client_pid": wake?.clientProcessID]))
                return DaemonWakeReply(socketPath: socketPath, processID: getpid(), version: version)
            }
        }
        // Logged before activation: a wake launchd queued while this daemon
        // was starting is delivered inside `activate()`, so its
        // `wake_received` line follows this one rather than preceding it.
        log.info("wake_listener_started", metadata: .fields(["service": service]))
        try listener.activate()
        self.listener = listener
    }

    public func run() async throws {
        try? await gracefulShutdown()
        listener?.cancel()
        listener = nil
        log.info("wake_listener_stopped")
    }
}
