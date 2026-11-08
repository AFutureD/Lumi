import Transport
import Foundation

/// Where the running daemon's executable lives, relative to this app. The
/// LaunchAgent runs `Lumen` in place from an app bundle, so a daemon whose
/// executable is this app's bundled `Lumen` is this app's to restart and
/// replace; one running from another bundle — the `/Applications` copy as
/// seen by a DerivedData build, or a copy the user keeps elsewhere — is
/// only observed. The path says where the process came from, not who
/// registered the LaunchAgent; the lifecycle controller treats it as a
/// reason to stop short, never as proof.
enum DaemonOwnership: Equatable {
    /// Launched from this app's bundled `Lumen`.
    case owned
    /// Launched from another bundle, or from a bare executable outside any.
    case foreign(executablePath: String)
    /// The daemon did not say: no health yet, a daemon from before identity
    /// reporting, or a daemon that could not resolve its own path.
    case unknown

    /// Compares the daemon's executable path (already symlink-resolved on
    /// its side) with this app's bundled `Lumen`, given as `resolvedPath(of:)`
    /// so a `/var` vs `/private/var` spelling never splits one bundle in two.
    static func resolve(process: DaemonProcessIdentity?, bundledExecutablePath: String?) -> DaemonOwnership {
        guard let process, !process.executablePath.isEmpty else { return .unknown }
        guard let bundledExecutablePath else { return .foreign(executablePath: process.executablePath) }
        let theirs = URL(fileURLWithPath: process.executablePath).standardizedFileURL.path
        return bundledExecutablePath == theirs ? .owned : .foreign(executablePath: process.executablePath)
    }

    /// The comparable form of a bundled executable's URL; computed once per
    /// app launch, not per health frame — it walks the filesystem.
    static func resolvedPath(of url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The `.app` bundle an executable path lives in, for display; the path
    /// itself when it is not inside a bundle.
    static func bundlePath(containing executablePath: String) -> String {
        var url = URL(fileURLWithPath: executablePath)
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app" { return url.path }
            url.deleteLastPathComponent()
        }
        return executablePath
    }
}
