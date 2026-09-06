import Transport
import Foundation
import Testing
@testable import MacFeature

/// A scripted daemon for the plan-usage operations: answers from a queue
/// and records what it was asked.
private final class ScriptedPlanUsageDaemon: MacDaemonClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [IPCResponse]
    private(set) var requests: [IPCRequest] = []

    init(responses: [IPCResponse]) {
        self.responses = responses
    }

    func request(_ request: IPCRequest, socketPath: String, timeoutSeconds: Int64) throws -> IPCResponse {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        if responses.count > 1 { return responses.removeFirst() }
        return responses.first ?? IPCResponse(status: .error, failure: IPCFailure(code: "down", message: "daemon down", retryable: true))
    }
}

private func state(codexEnabled: Bool) -> PlanUsageState {
    PlanUsageState(
        accounts: [
            PlanUsageAccount(id: .claude, provider: .claude, enabled: false, status: .credentialsMissing),
            PlanUsageAccount(id: .codex, provider: .codex, email: "dev@example.com", plan: "Pro 20x", enabled: codexEnabled, status: .ok,
                             limits: codexEnabled ? [PlanUsageLimit(window: .weekly, usedPercent: 12)] : []),
        ],
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
}

@MainActor
@Test func modelLoadsSwitchesAndSurfacesFailures() async throws {
    let daemon = ScriptedPlanUsageDaemon(responses: [
        IPCResponse(status: .ok, planUsage: state(codexEnabled: false)),
        IPCResponse(status: .ok, planUsage: state(codexEnabled: true)),
        IPCResponse(status: .error, failure: IPCFailure(code: "plan_usage_unavailable", message: "The daemon runs without plan usage.", retryable: false)),
    ])
    let suite = "PlanUsageModelTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = PlanUsageModel(
        client: PlanUsageClient(client: daemon, socketPath: "/tmp/lumi-test.sock"),
        preferences: HaloPlanUsagePreferences(defaults: defaults)
    )

    await model.refresh()
    #expect(model.state == state(codexEnabled: false))
    #expect(model.errorMessage == nil)
    #expect(model.account(.codex)?.email == "dev@example.com")

    await model.setEnabled(true, for: .codex)
    #expect(model.state == state(codexEnabled: true))
    #expect(model.updating.isEmpty)
    let switchRequest = try #require(daemon.requests.last)
    #expect(switchRequest.operation == .setPlanUsage && switchRequest.planAccount == .codex && switchRequest.enabled == true)

    // A failed switch keeps the last snapshot and reports the daemon's words.
    await model.setEnabled(false, for: .codex)
    #expect(model.state == state(codexEnabled: true))
    #expect(model.errorMessage == "The daemon runs without plan usage.")
    #expect(daemon.requests.map(\.operation) == [.planUsage, .setPlanUsage, .setPlanUsage])
}
