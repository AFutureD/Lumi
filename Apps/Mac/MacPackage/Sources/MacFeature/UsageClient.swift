import IPCClient
import Diagnostics
import Logging
import Transport
import Foundation

private let log = Logger(label: "ui")

/// The Usage page's line to the daemon: one `usage_report` per range
/// change, refresh or poll tick, carrying the comparison period the
/// Summary's change is measured against. The daemon computes everything;
/// the page only renders.
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

    func report(range: UsageRange, comparison: UsageRange?) async throws -> UsageReport {
        let request = IPCRequest(
            operation: .usageReport,
            since: range.since,
            until: range.until,
            compareSince: comparison?.since,
            compareUntil: comparison?.until
        )
        let response = try await client.send(request, socketPath: socketPath)
        if let failure = response.failure { throw failure }
        guard let usage = response.usage else {
            throw IPCFailure(code: "missing_usage", message: "The daemon answered without a usage report.", retryable: true)
        }
        log.debug("usage_report_received", metadata: .fields([
            "since": range.since.rawValue, "until": range.until.rawValue,
            "projects": usage.byProject.count, "models": usage.byModel.count, "compared": usage.comparison != nil,
        ]))
        return usage
    }
}
