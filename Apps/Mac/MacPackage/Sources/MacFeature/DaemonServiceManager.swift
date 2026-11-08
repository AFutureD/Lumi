import Foundation
import ServiceManagement

/// The daemon's `SMAppService` registration, behind a seam so the lifecycle
/// controller can be exercised against a fake launchd.
@MainActor
protocol DaemonServiceManaging: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
    func reinstall() async throws
    /// System Settings › General › Login Items, where a `requiresApproval`
    /// registration waits for the user.
    func openLoginItems()
}

/// Single owner of the daemon's `SMAppService` registration. Only
/// `DaemonLifecycleController` drives it, so every restart — automatic or
/// from Settings — goes the same way.
@MainActor
final class DaemonServiceManager: DaemonServiceManaging {
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
    /// exists. Whether launchd then spawns the daemon is not assumed: the
    /// caller verifies with a fresh health probe.
    func reinstall() async throws {
        if service.status == .enabled {
            try await service.unregister()
            try await waitUntilUnregistered()
        }
        try service.register()
    }

    /// Insurance on top of the awaited unregister, not a guarantee: polls
    /// for up to two seconds so the register rarely lands on a job launchd
    /// still holds. Apple's contract is that the awaited `unregister()`
    /// alone suffices; this covers the "already in progress" refusals seen
    /// in practice.
    private func waitUntilUnregistered() async throws {
        for _ in 0..<40 where service.status == .enabled {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
