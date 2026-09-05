import DaemonRuntime
import IPCClient
import Foundation
import Testing

private let label = "app.huanan.lumi.daemon"

@Test func clientsWakeTheInstalledDaemonOnly() {
    // The default endpoint is the registered daemon: wake it.
    #expect(DaemonEndpoint.defaultWakeService(environment: [:]) == label)
    let installed = DaemonEndpoint.defaultSocketPath(environment: [:])
    #expect(DaemonWakePolicy.default(socketPath: installed, environment: [:], timeout: .seconds(1))?.service == label)
    // Any other socket (a test path) is not the installed daemon's: no wake.
    #expect(DaemonWakePolicy.default(socketPath: "/tmp/none.sock", environment: [:], timeout: .seconds(1)) == nil)
    // Isolated daemons are addressed by socket or support overrides — waking
    // the installed one would start the wrong daemon.
    #expect(DaemonEndpoint.defaultWakeService(environment: ["LUMI_SOCKET": "/tmp/x.sock"]) == nil)
    #expect(DaemonEndpoint.defaultWakeService(environment: ["LUMI_SUPPORT_DIRECTORY": "/tmp/lumi"]) == nil)
    #expect(DaemonWakePolicy.default(socketPath: "/tmp/x.sock", environment: ["LUMI_SOCKET": "/tmp/x.sock"], timeout: .seconds(1)) == nil)
    // An explicit service names an isolated launchd job (its socket is the
    // override), `0` disables.
    let isolated = ["LUMI_WAKE_SERVICE": "test.lumi.wake", "LUMI_SOCKET": "/tmp/x.sock"]
    #expect(DaemonEndpoint.defaultWakeService(environment: isolated) == "test.lumi.wake")
    #expect(DaemonWakePolicy.default(socketPath: "/tmp/x.sock", environment: isolated, timeout: .seconds(1))?.service == "test.lumi.wake")
    #expect(DaemonEndpoint.defaultWakeService(environment: ["LUMI_WAKE_SERVICE": "0"]) == nil)
}

@Test func onlyTheRegisteredDaemonAnswersWakes() {
    let support = URL(fileURLWithPath: "/tmp/lumi-wake-test", isDirectory: true)
    func resolved(_ environment: [String: String]) -> String? {
        DaemonConfiguration.default(environment: environment, applicationSupportDirectory: support).wakeService
    }
    // Not under launchd (swift run, tests): no name to claim.
    #expect(resolved([:]) == nil)
    // launchd's job label identifies the registered daemon.
    #expect(resolved(["XPC_SERVICE_NAME": label]) == label)
    #expect(resolved(["XPC_SERVICE_NAME": "some.other.job"]) == nil)
    // Even under launchd, an isolated socket never claims the shared name.
    #expect(resolved(["XPC_SERVICE_NAME": label, "LUMI_SOCKET": "/tmp/x.sock"]) == nil)
    // An isolated launchd job names its own service; `0` opts out.
    #expect(resolved(["LUMI_WAKE_SERVICE": "test.lumi.wake", "LUMI_SOCKET": "/tmp/x.sock"]) == "test.lumi.wake")
    #expect(resolved(["XPC_SERVICE_NAME": label, "LUMI_WAKE_SERVICE": "0"]) == nil)
}

@Test func wakingAnUnregisteredServiceFailsFast() throws {
    // No job owns this name: launchd refuses the lookup outright, which is
    // the "daemon never installed" path — it must not wait for the timeout.
    let started = ContinuousClock.now
    #expect(throws: DaemonWakeError.self) {
        try DaemonWaker.wake(service: "app.huanan.lumi.test.unregistered", timeout: .seconds(5))
    }
    #expect(ContinuousClock.now - started < .seconds(3))
}

@Test func missingSocketWithoutWakePolicyIsAPlainFailure() throws {
    let socketPath = "/tmp/lumi-wake-missing-\(UUID().uuidString.prefix(8)).sock"
    #expect(throws: DaemonIPCSocketError.self) {
        try FrameConnection.connect(socketPath: socketPath, timeout: .seconds(1), wake: nil)
    }
}
