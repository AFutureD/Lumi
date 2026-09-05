import Foundation
import ServiceManagement

/// Single owner of the daemon's `SMAppService` registration, shared by the
/// Settings panel and the launch-time auto-updater so both restart the daemon
/// the same way.
@MainActor
final class DaemonServiceManager {
    private let service = SMAppService.agent(plistName: "app.huanan.lumi.daemon.plist")

    var status: SMAppService.Status { service.status }

    func register() throws {
        try service.register()
    }

    func unregister() async throws {
        try await service.unregister()
    }

    /// launchd keeps a running daemon on the pre-update binary even after the
    /// app bundle is replaced; unregister + register is what actually swaps in
    /// the new build. The removal is awaited: the synchronous `unregister()`
    /// returns once smd accepted it while launchd removes the job on its own
    /// time, and a register racing that removal is refused ("Operation
    /// already in progress") and leaves smd watching a job that no longer
    /// exists. Whether launchd then spawns the daemon is not assumed — the
    /// app's stream reconnect wakes it.
    func reinstall() async throws {
        if service.status == .enabled {
            try await service.unregister()
            try await waitUntilUnregistered()
        }
        try service.register()
    }

    /// Insurance on top of the awaited unregister: polls for up to two
    /// seconds so the register never lands on a job launchd still holds.
    private func waitUntilUnregistered() async throws {
        for _ in 0..<40 where service.status == .enabled {
            try await Task.sleep(for: .milliseconds(50))
        }
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
