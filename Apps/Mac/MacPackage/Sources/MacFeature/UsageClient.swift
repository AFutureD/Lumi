import IPCClient
import Diagnostics
import Logging
import Transport
import Foundation

private let log = Logger(label: "ui")

/// The Usage page's line to the daemon: one `usage_report` per range
/// change, refresh or poll tick. The daemon computes everything; the page
/// only renders.
@MainActor
final class UsageClient {
    private let client: any MacDaemonClient
    private let socketPath: String

    init(
        client: any MacDaemonClient = DaemonIPCClient(),
        socketPath: String = DaemonEndpoint.defaultSocketPath()
    ) {
        self.client = client
        self.socketPath = socketPath
    }

    func report(since: UsageDay, until: UsageDay) async throws -> UsageReport {
        let client = client
        let socketPath = socketPath
        let request = IPCRequest(operation: .usageReport, since: since, until: until)
        let response = try await Task.detached {
            try client.request(request, socketPath: socketPath, timeoutSeconds: 15)
        }.value
        if let failure = response.failure { throw failure }
        guard let usage = response.usage else {
            throw IPCFailure(code: "missing_usage", message: "The daemon answered without a usage report.", retryable: true)
        }
        log.debug("usage_report_received", metadata: .fields([
            "since": since.rawValue, "until": until.rawValue,
            "projects": usage.byProject.count, "models": usage.byModel.count,
        ]))
        return usage
    }
}
