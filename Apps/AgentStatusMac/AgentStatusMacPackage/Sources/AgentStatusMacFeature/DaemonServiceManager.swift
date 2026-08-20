import Foundation
import ServiceManagement

/// Single owner of the daemon's `SMAppService` registration, shared by the
/// Settings panel and the launch-time auto-updater so both restart the daemon
/// the same way.
@MainActor
final class DaemonServiceManager {
    private let service = SMAppService.agent(plistName: "com.huanan.AgentStatusDaemon.plist")

    var status: SMAppService.Status { service.status }

    func register() throws {
        try service.register()
    }

    func unregister() async throws {
        try await service.unregister()
    }

    /// launchd keeps a running daemon on the pre-update binary even after the
    /// app bundle is replaced; unregister + register is what actually swaps in
    /// the new build.
    func reinstall() throws {
        if service.status == .enabled {
            try service.unregister()
        }
        try service.register()
    }

    func describeStatus() -> String {
        switch service.status {
        case .notRegistered: "daemon is not installed"
        case .enabled: "daemon is registered but unavailable"
        case .requiresApproval: "approval is required in System Settings"
        case .notFound: "embedded daemon service was not found"
        @unknown default: "daemon status is unknown"
        }
    }
}
