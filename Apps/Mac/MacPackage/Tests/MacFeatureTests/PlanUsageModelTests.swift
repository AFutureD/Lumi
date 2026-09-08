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
    let codexOn = DaemonSettings(planUsage: PlanUsageSettings(enabledAccounts: [.codex], percentStyle: .used))
    let daemon = ScriptedPlanUsageDaemon(responses: [
        IPCResponse(status: .ok, planUsage: state(codexEnabled: false)),   // plan_usage
        IPCResponse(status: .ok, settings: .defaults),                       // get_settings
        IPCResponse(status: .ok, settings: codexOn),                         // set_settings (switch)
        IPCResponse(status: .ok, planUsage: state(codexEnabled: true)),    // plan_usage after the switch
        IPCResponse(status: .error, failure: IPCFailure(code: "settings_unavailable", message: "The daemon runs without a settings store.", retryable: false)),
    ])
    let suite = "PlanUsageModelTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = PlanUsageModel(
        client: PlanUsageClient(client: daemon, socketPath: "/tmp/lumi-test.sock"),
        preferences: HaloPlanUsagePreferences(defaults: defaults),
        legacyDefaults: defaults
    )

    // Nothing is written before the daemon's settings were read.
    await model.setEnabled(true, for: .codex)
    #expect(daemon.requests.isEmpty && model.errorMessage != nil)

    await model.refresh()
    #expect(model.state == state(codexEnabled: false))
    #expect(model.settings == .defaults && model.settingsLoaded)
    #expect(model.errorMessage == nil)
    #expect(model.account(.codex)?.email == "dev@example.com")

    await model.setEnabled(true, for: .codex)
    #expect(model.settings == codexOn)
    #expect(model.state == state(codexEnabled: true))
    #expect(model.updating.isEmpty)
    let switchRequest = try #require(daemon.requests[2])
    #expect(switchRequest.operation == .setSettings && switchRequest.settings == codexOn)

    // A failed write keeps the last settings and reports the daemon's words.
    await model.setPercentStyle(.remaining)
    #expect(model.settings == codexOn)
    #expect(model.errorMessage == "The daemon runs without a settings store.")
    #expect(daemon.requests.map(\.operation) == [.planUsage, .getSettings, .setSettings, .planUsage, .setSettings])
}

@MainActor
@Test func legacyPercentStyleKeyIsCarriedToTheDaemonOnce() async throws {
    let remaining = DaemonSettings(planUsage: PlanUsageSettings(enabledAccounts: [], percentStyle: .remaining))
    let daemon = ScriptedPlanUsageDaemon(responses: [
        IPCResponse(status: .ok, planUsage: state(codexEnabled: false)),
        IPCResponse(status: .ok, settings: .defaults),
        IPCResponse(status: .ok, settings: remaining),
        IPCResponse(status: .ok, planUsage: state(codexEnabled: false)),
        IPCResponse(status: .ok, settings: remaining),
    ])
    let suite = "PlanUsageModelTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("remaining", forKey: PlanUsageModel.legacyPercentStyleKey)
    let model = PlanUsageModel(
        client: PlanUsageClient(client: daemon, socketPath: "/tmp/lumi-test.sock"),
        preferences: HaloPlanUsagePreferences(defaults: defaults),
        legacyDefaults: defaults
    )
    await model.refresh()
    #expect(model.percentStyle == .remaining)
    #expect(defaults.string(forKey: PlanUsageModel.legacyPercentStyleKey) == nil)
    #expect(daemon.requests.map(\.operation) == [.planUsage, .getSettings, .setSettings])
    // The next refresh finds no key and writes nothing.
    await model.refresh()
    #expect(daemon.requests.map(\.operation) == [.planUsage, .getSettings, .setSettings, .planUsage, .getSettings])
}
