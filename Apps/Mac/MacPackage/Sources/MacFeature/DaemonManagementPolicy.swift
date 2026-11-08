import Foundation

/// What this app may do to the installed daemon and helper without being
/// asked. The installed resources — the LaunchAgent registration and the
/// helper copy in Application Support — are shared by every copy of Lumi on
/// the Mac, so only the release build talking to the installed daemon
/// touches them on its own.
enum DaemonManagementPolicy: Equatable {
    /// Fix a stale or unreachable daemon at launch; refresh the installed
    /// helper and Codex trust at launch.
    case automatic
    /// Observe, and act only when the user asks.
    case manualOnly(Reason)

    enum Reason: Equatable {
        /// A development build (DerivedData) never replaces the installed
        /// copy's daemon or helper on its own.
        case developmentBuild
        /// `LUMI_SOCKET` / `LUMI_SUPPORT_DIRECTORY`: the daemon on this
        /// socket is some other process; the registered one is not the one
        /// being observed, so neither may be touched.
        case isolatedDaemon
    }

    /// Isolation wins over the build kind: a development build on an
    /// isolated socket must not even offer the buttons, which would act on
    /// the registered daemon rather than the one it observes.
    static func resolve(isDevelopmentBuild: Bool, talksToInstalledDaemon: Bool) -> DaemonManagementPolicy {
        if !talksToInstalledDaemon { return .manualOnly(.isolatedDaemon) }
        if isDevelopmentBuild { return .manualOnly(.developmentBuild) }
        return .automatic
    }

    static var isDevelopmentBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Install / Reinstall / Stop act on the registered daemon; they are
    /// offered only while that is the daemon being observed.
    var allowsManualActions: Bool {
        self != .manualOnly(.isolatedDaemon)
    }

    var reason: Reason? {
        if case let .manualOnly(reason) = self { return reason }
        return nil
    }
}
