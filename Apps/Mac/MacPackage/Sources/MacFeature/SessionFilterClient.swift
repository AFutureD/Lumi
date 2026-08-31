import IPCClient
import Diagnostics
import Logging
import Transport
import Foundation

private let log = Logger(label: "ui")

/// The Settings panel's line to the daemon's stored filter rules. The daemon
/// is the source of truth: `load` pulls the list on panel appear, `save`
/// replaces it wholesale (the editor's write model). No polling — rules only
/// change through this panel.
@MainActor
final class SessionFilterClient {
    private let client: any MacDaemonClient
    private let socketPath: String

    init(
        client: any MacDaemonClient = DaemonIPCClient(),
        socketPath: String = DaemonEndpoint.defaultSocketPath()
    ) {
        self.client = client
        self.socketPath = socketPath
    }

    func load() async throws -> [SessionFilterRule] {
        let response = try await request(IPCRequest(operation: .getSessionFilters))
        if let failure = response.failure { throw failure }
        return response.filters ?? []
    }

    /// Returns the list as stored, so the caller can settle on it.
    @discardableResult
    func save(_ rules: [SessionFilterRule]) async throws -> [SessionFilterRule] {
        let response = try await request(IPCRequest(operation: .setSessionFilters, filters: rules))
        if let failure = response.failure { throw failure }
        log.info("session_filters_saved", metadata: .fields(["rules": rules.count]))
        return response.filters ?? rules
    }

    private func request(_ request: IPCRequest) async throws -> IPCResponse {
        let client = client
        let socketPath = socketPath
        return try await Task.detached {
            try client.request(request, socketPath: socketPath, timeoutSeconds: 15)
        }.value
    }
}
