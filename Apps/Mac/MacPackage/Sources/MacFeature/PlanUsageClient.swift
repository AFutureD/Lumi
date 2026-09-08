import IPCClient
import Diagnostics
import Logging
import Transport
import Foundation

private let log = Logger(label: "ui")

/// The Mac's line to the daemon's plan-usage poller: `plan_usage` for the
/// current snapshot, `get_settings` / `set_settings` for the switches and
/// the percent style that live in the daemon's settings table. The daemon
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

    func settings() async throws -> DaemonSettings {
        try await unwrapSettings(client.send(IPCRequest(operation: .getSettings), socketPath: socketPath))
    }

    /// Replaces every daemon-owned setting; the answer is what the daemon stored.
    func save(_ settings: DaemonSettings) async throws -> DaemonSettings {
        let stored = try await unwrapSettings(client.send(IPCRequest(operation: .setSettings, settings: settings), socketPath: socketPath))
        log.info("settings_saved", metadata: .fields([
            "plan_usage_enabled": stored.planUsage.enabledAccounts.map(\.rawValue).joined(separator: ","),
            "percent_style": stored.planUsage.percentStyle.rawValue,
        ]))
        return stored
    }

    private func unwrapSettings(_ response: IPCResponse) throws -> DaemonSettings {
        if let failure = response.failure { throw failure }
        guard let settings = response.settings else {
            throw IPCFailure(code: "missing_settings", message: "The daemon answered without settings.", retryable: true)
        }
        return settings
    }

    private func unwrap(_ response: IPCResponse) throws -> PlanUsageState {
        if let failure = response.failure { throw failure }
        guard let state = response.planUsage else {
            throw IPCFailure(code: "missing_plan_usage", message: "The daemon answered without plan usage.", retryable: true)
        }
        return state
    }
}
