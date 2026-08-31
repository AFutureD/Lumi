import Foundation

/// Single source of truth for where Lumi keeps its on-disk state.
///
/// Layout under `~/Library/Application Support/Lumi/`:
/// - `daemon.sock` — the daemon's IPC endpoint, the shared rendezvous point.
/// - `bin/Spark` — the installed hook helper; its absolute path is written
///   into external agent configs, so it never moves.
/// - `Lumen/` — the daemon's own state (database, relay host state).
/// - `Storage/` — the Mac app's synchronized session cache.
public enum LumiPaths {
    public static let rootDirectoryName = "Lumi"
    public static let daemonSubdirectory = "Lumen"
    public static let socketFileName = "daemon.sock"

    /// `~/Library/Application Support` (user domain). `urls(for:)` never
    /// returns an empty list for this directory on macOS, but a hand-built
    /// fallback keeps the path deterministic rather than trapping.
    public static func applicationSupportBase(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// The `Lumi` support root. `LUMI_SUPPORT_DIRECTORY` moves the whole
    /// tree — database, relay state, and socket alike — so an isolated
    /// daemon never touches the installed one's state.
    public static func supportDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportDirectory: URL = applicationSupportBase()
    ) -> URL {
        if let override = environment["LUMI_SUPPORT_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return applicationSupportDirectory.appendingPathComponent(rootDirectoryName, isDirectory: true)
    }
}
