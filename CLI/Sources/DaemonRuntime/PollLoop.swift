import ServiceLifecycle
import Foundation

/// The daemon's slow polling services (the usage scanner, the price
/// refresher, plan usage) run one body every `seconds` until graceful
/// shutdown cancels them. Sleep is floored at 250 ms so a test's tiny
/// interval never spins. Session ingest does not poll: see
/// `SourceFileMonitor`.
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
