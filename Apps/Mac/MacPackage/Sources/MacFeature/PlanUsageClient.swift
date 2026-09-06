import IPCClient
import Diagnostics
import Logging
import Transport
import Foundation

private let log = Logger(label: "ui")

/// The Mac's line to the daemon's plan-usage poller: `plan_usage` for the
/// current snapshot, `set_plan_usage` to switch one sign-in. The daemon
/// reads the sign-in files and calls the providers; the Mac only renders.
@MainActor
final class PlanUsageClient {
    private let client: any MacDaemonClient
    private let socketPath: String

    init(
        client: any MacDaemonClient = DaemonIPCClient(),
        socketPath: String = DaemonEndpoint.defaultSocketPath()
    ) {
        self.client = client
        self.socketPath = socketPath
    }

    func state() async throws -> PlanUsageState {
        try await unwrap(client.send(IPCRequest(operation: .planUsage), socketPath: socketPath))
    }

    func setEnabled(_ enabled: Bool, for account: PlanUsageAccountID) async throws -> PlanUsageState {
        let state = try await unwrap(client.send(
            IPCRequest(operation: .setPlanUsage, planAccount: account, enabled: enabled),
            socketPath: socketPath
        ))
        log.info("plan_usage_account_switched", metadata: .fields([
            "account": account.rawValue, "enabled": enabled, "status": state.account(account)?.status.rawValue,
        ]))
        return state
    }

    private func unwrap(_ response: IPCResponse) throws -> PlanUsageState {
        if let failure = response.failure { throw failure }
        guard let state = response.planUsage else {
            throw IPCFailure(code: "missing_plan_usage", message: "The daemon answered without plan usage.", retryable: true)
        }
        return state
    }
}
