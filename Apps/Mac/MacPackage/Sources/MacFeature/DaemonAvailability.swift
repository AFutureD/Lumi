import Core
import ServiceManagement
import Transport
import Foundation

/// The one reading of "how is the daemon" that the Settings pill, the Status
/// row and the action buttons all share. Inputs: what launchd says about the
/// registration, what the store last heard on the socket, and — while it
/// runs — whose daemon it is.
enum DaemonAvailability: Equatable {
    /// Health arrives. `ownership` says whether this app may replace it.
    case running(DaemonOwnership)
    /// No LaunchAgent is registered under the daemon's label.
    case notInstalled
    /// Registered, but macOS waits for the user to allow it in Login Items.
    case requiresApproval
    /// This app bundle ships no LaunchAgent plist — a broken build.
    case serviceMissing
    /// Registered and allowed, but nothing listens and no wake started it.
    case notRunning(detail: String)
    /// Registered; the daemon is coming up — a wake was accepted, or the
    /// stream is reconnecting after a drop.
    case starting
    /// Connected, but the daemon does not answer in time.
    case notResponding(detail: String)
    /// The daemon speaks another protocol major.
    case incompatible(major: UInt16)
    /// A failure outside the daemon's reach: the Mac's sync database, an
    /// unexpected socket error.
    case failed(detail: String)

    /// The registration state answers first: a daemon that is not
    /// registered has no connection error worth explaining. Health, when
    /// present, overrides everything — the daemon is plainly running. An
    /// isolated daemon (`isolated`) has no registration of its own, so only
    /// the socket speaks for it.
    static func resolve(
        service: SMAppService.Status,
        health: DaemonHealth?,
        failure: DaemonConnectionFailure?,
        ownership: DaemonOwnership,
        isolated: Bool = false
    ) -> DaemonAvailability {
        if health != nil { return .running(ownership) }
        if !isolated {
            switch service {
            case .notRegistered: return .notInstalled
            case .requiresApproval: return .requiresApproval
            case .notFound: return .serviceMissing
            case .enabled: break
            @unknown default: return .failed(detail: "unknown service status")
            }
        }
        switch failure {
        case nil, .streamClosed, .daemonStarting:
            return .starting
        case let .daemonNotRunning(detail):
            return .notRunning(detail: detail)
        case let .daemonNotResponding(detail):
            return .notResponding(detail: detail)
        case let .incompatibleDaemon(major):
            return .incompatible(major: major)
        case let .other(detail):
            return .failed(detail: detail)
        }
    }

    /// The Status row.
    var statusText: String {
        switch self {
        case .running: "Running"
        case .notInstalled: "Not installed"
        case .requiresApproval: "Waiting for approval in Login Items"
        case .serviceMissing: "No daemon service in this app"
        case .notRunning: "Not running"
        case .starting: "Starting…"
        case .notResponding: "Not responding"
        case let .incompatible(major): "Incompatible daemon · protocol v\(major)"
        case .failed: "Error"
        }
    }

    /// The technical cause shown under the card, when there is one.
    var detailText: String? {
        switch self {
        case let .notRunning(detail), let .notResponding(detail), let .failed(detail): detail
        case .incompatible: "Update Lumi and the daemon together; this app speaks protocol v\(ProtocolVersion.current.major)."
        case .serviceMissing: "The LaunchAgent is missing from the app bundle. Reinstall Lumi."
        case .running, .notInstalled, .requiresApproval, .starting: nil
        }
    }

    /// The subheader pill.
    var pill: (tone: SessionStatusTone, text: String) {
        switch self {
        case .running: (.green, "Running")
        case .starting: (.orange, "Starting")
        case .notInstalled: (.gray, "Not installed")
        case .requiresApproval: (.gray, "Needs approval")
        case .notRunning: (.gray, "Not running")
        case .serviceMissing, .notResponding, .incompatible, .failed: (.red, "Error")
        }
    }

    enum Action: Hashable {
        case install
        case openLoginItems
        case reinstall
        case uninstall
    }

    /// The buttons under the Local service card, in order.
    var actions: [Action] {
        switch self {
        case .notInstalled: [.install]
        case .requiresApproval: [.openLoginItems, .uninstall]
        case .serviceMissing: []
        case .running, .notRunning, .starting, .notResponding, .incompatible, .failed: [.reinstall, .uninstall]
        }
    }
}
