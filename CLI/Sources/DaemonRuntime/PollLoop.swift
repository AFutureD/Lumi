import ServiceLifecycle
import Foundation

/// The daemon's polling services (transcript and rollout watchers, the usage
/// scanner, the price refresher) all run one body every `seconds` until
/// graceful shutdown cancels them. Sleep is floored at 250 ms so a test's
/// tiny interval never spins.
func pollUntilShutdown(everySeconds seconds: Double, _ body: @escaping @Sendable () async -> Void) async {
    await cancelWhenGracefulShutdown {
        while !Task.isCancelled {
            await body()
            do {
                try await Task.sleep(for: .milliseconds(Int64(max(250, seconds * 1_000))))
            } catch {
                break
            }
        }
    }
}

/// Every regular `.jsonl` under `root`, recursively, hidden entries skipped,
/// as the relative path plus the attributes the path-based enumerator
/// already fetched. Path-based on purpose: the URL enumerator resolves
/// symlinks (`/var` → `/private/var`) and would key cursors differently
/// from the hook path that derives them from the same root. A missing root
/// is an agent that was never used here, not an error.
func jsonlFiles(under root: URL) -> [(relativePath: String, attributes: [FileAttributeKey: Any])] {
    guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
    var files: [(relativePath: String, attributes: [FileAttributeKey: Any])] = []
    while let relative = enumerator.nextObject() as? String {
        guard relative.hasSuffix(".jsonl"),
              !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
              let attributes = enumerator.fileAttributes,
              attributes[.type] as? FileAttributeType == .typeRegular else { continue }
        files.append((relative, attributes))
    }
    return files
}
