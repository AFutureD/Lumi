import Core
import ServiceManagement
import Transport
import Foundation
import Testing
@testable import MacFeature

private let bundledLumen = URL(fileURLWithPath: "/Applications/Lumi.app/Contents/Resources/Lumen")
private let foreignLumen = "/Users/dev/DerivedData/Lumi-abc/Build/Products/Debug/Lumi.app/Contents/Resources/Lumen"

private func identity(_ id: String, path: String = bundledLumen.path, pid: Int32 = 100) -> DaemonProcessIdentity {
    DaemonProcessIdentity(instanceID: id, processID: pid, startedAt: Date(timeIntervalSince1970: 1_000), executablePath: path)
}

private func health(hash: String?, process: DaemonProcessIdentity?) -> DaemonHealth {
    DaemonHealth(
        daemonVersion: "test", executableHash: hash, process: process, uptimeSeconds: 1,
        activeSessionCount: 0, retainedSessionCount: 0, socketPath: "/tmp/lumi.sock", relayConnected: false
    )
}

private func ownership(_ process: DaemonProcessIdentity?) -> DaemonOwnership {
    DaemonOwnership.resolve(process: process, bundledExecutablePath: bundledLumen.path)
}

// MARK: - decide

@Test func lifecycleWaitsWhileHealthIsUnknownUntilTheGraceRunsOut() {
    typealias C = DaemonLifecycleController
    #expect(C.decide(bundledHash: "a", health: nil, ownership: .unknown, graceElapsed: false) == .wait)
    guard case .restart = C.decide(bundledHash: "a", health: nil, ownership: .unknown, graceElapsed: true) else {
        Issue.record("a registered daemon silent past the grace earns a reinstall")
        return
    }
}

@Test func lifecycleIsDoneWhenTheOwnDaemonMatches() {
    let ours = identity("i1")
    #expect(DaemonLifecycleController.decide(
        bundledHash: "a", health: health(hash: "a", process: ours), ownership: ownership(ours), graceElapsed: false
    ) == .upToDate)
}

@Test func lifecycleRestartsStaleOrFingerprintlessOwnDaemons() {
    let ours = identity("i1")
    for stale in [health(hash: "b", process: ours), health(hash: nil, process: ours), health(hash: "", process: ours)] {
        guard case .restart = DaemonLifecycleController.decide(
            bundledHash: "a", health: stale, ownership: ownership(ours), graceElapsed: false
        ) else {
            Issue.record("expected restart for \(String(describing: stale.executableHash))")
            continue
        }
    }
    // A daemon from before identity reporting is stale by definition.
    guard case .restart = DaemonLifecycleController.decide(
        bundledHash: "a", health: health(hash: "b", process: nil), ownership: .unknown, graceElapsed: false
    ) else {
        Issue.record("a pre-identity daemon with another fingerprint is replaced")
        return
    }
}

@Test func lifecycleLeavesAForeignDaemonAloneEvenWhenStale() {
    let theirs = identity("i9", path: foreignLumen)
    #expect(DaemonLifecycleController.decide(
        bundledHash: "a", health: health(hash: "b", process: theirs), ownership: ownership(theirs), graceElapsed: true
    ) == .foreign(executablePath: foreignLumen))
}

// MARK: - judge

@Test func lifecycleJudgesARestartOnlyByAFreshDifferentProcess() {
    typealias C = DaemonLifecycleController
    let before = identity("old")
    let after = identity("new", pid: 101)
    // The old process still answering is not a verdict — keep probing.
    #expect(C.judge(health: health(hash: "a", process: before), bundledHash: "a", previous: before, ownership: .owned) == nil)
    // A new process with the bundled fingerprint: done.
    #expect(C.judge(health: health(hash: "a", process: after), bundledHash: "a", previous: before, ownership: .owned) == .replaced(after))
    // A new process with another fingerprint: launchd runs something else.
    #expect(C.judge(health: health(hash: "b", process: after), bundledHash: "a", previous: before, ownership: .owned) == .stillStale(reportedHash: "b"))
    // No baseline (the daemon was unreachable before): any matching answer is the new daemon.
    #expect(C.judge(health: health(hash: "a", process: after), bundledHash: "a", previous: nil, ownership: .owned) == .replaced(after))
    // A pre-identity daemon that still answers after the restart is a stale one.
    #expect(C.judge(health: health(hash: "b", process: nil), bundledHash: "a", previous: before, ownership: .unknown) == .stillStale(reportedHash: "b"))
    // Another bundle's daemon answering is reported as such.
    let theirs = identity("x", path: foreignLumen)
    #expect(C.judge(health: health(hash: "a", process: theirs), bundledHash: "a", previous: before, ownership: ownership(theirs))
        == .foreign(executablePath: foreignLumen))
}

// MARK: - operations against a fake launchd

@MainActor
private final class FakeServiceManager: DaemonServiceManaging {
    var status: SMAppService.Status = .enabled
    /// What launchd reports once registered: `.enabled`, or
    /// `.requiresApproval` on a Mac that gates Login Items.
    var statusAfterRegister: SMAppService.Status = .enabled
    var registrations = 0
    var unregistrations = 0
    var reinstalls = 0
    func register() throws { registrations += 1; status = statusAfterRegister }
    func unregister() async throws { unregistrations += 1; status = .notRegistered }
    func reinstall() async throws { reinstalls += 1; status = statusAfterRegister }
    func openLoginItems() {}
}

/// A scripted socket: each probe pops the next answer (`nil` = no daemon);
/// an exhausted script keeps answering with its last entry.
@MainActor
private final class ScriptedProbe {
    private var answers: [DaemonHealth?]
    private(set) var probes = 0
    init(_ answers: [DaemonHealth?]) { self.answers = answers }
    func probe(wake: Bool) throws -> DaemonHealth {
        probes += 1
        let next = answers.count > 1 ? answers.removeFirst() : answers.first ?? nil
        guard let next else { throw DaemonProbeError.healthMissing }
        return next
    }
}

/// A real file stands in for the bundled `Lumen`, so the controller's own
/// hashing produces the fingerprint a "fresh" daemon must report. The store
/// is never started, so the controller's post-operation `refresh()` is a
/// no-op rather than a reconcile against a socket nobody listens on.
@MainActor
private final class Fixture {
    let manager = FakeServiceManager()
    let directory: URL
    let bundled: URL
    let bundledHash: String

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-lifecycle-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        bundled = directory.appendingPathComponent("Lumen").resolvingSymlinksInPath()
        try Data("lumen \(UUID().uuidString)".utf8).write(to: bundled)
        bundledHash = try ExecutableFingerprint.sha256Hex(fileAt: bundled)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func ours(_ id: String, pid: Int32 = 100) -> DaemonProcessIdentity {
        identity(id, path: bundled.path, pid: pid)
    }

    func controller(
        probe: ScriptedProbe,
        policy: DaemonManagementPolicy = .automatic,
        bundledExecutableURL: URL? = nil
    ) -> DaemonLifecycleController {
        DaemonLifecycleController(
            store: MacSessionStore(
                socketPath: "/tmp/lumi-test-\(UUID().uuidString.prefix(6)).sock",
                cachePath: directory.appendingPathComponent("cache.sqlite3").path
            ),
            manager: manager,
            policy: policy,
            bundledExecutableURL: bundledExecutableURL ?? bundled,
            probe: { wake in try probe.probe(wake: wake) },
            sleep: { _ in }
        )
    }
}

@Test @MainActor func manualReinstallIsVerifiedByAFreshProcess() async throws {
    let fixture = try Fixture()
    let before = fixture.ours("old")
    let after = fixture.ours("new", pid: 101)
    // The confirmation check sees the old process; it answers once more
    // after the reinstall; then the new one takes over.
    let probe = ScriptedProbe([
        health(hash: "b", process: before),
        health(hash: "b", process: before),
        health(hash: fixture.bundledHash, process: after),
    ])
    let controller = fixture.controller(probe: probe)
    let outcome = try await controller.reinstall(confirmed: before)
    #expect(outcome == .replaced(after))
    #expect(fixture.manager.reinstalls == 1)
    #expect(controller.notice == nil)
    #expect(!controller.isBusy)
}

@Test @MainActor func manualReinstallRefusesWhenTheDaemonChangedSinceConfirmation() async throws {
    let fixture = try Fixture()
    let probe = ScriptedProbe([health(hash: "b", process: fixture.ours("someone-else", pid: 7))])
    let controller = fixture.controller(probe: probe)
    await #expect(throws: DaemonLifecycleController.OperationError.self) {
        try await controller.reinstall(confirmed: fixture.ours("old"))
    }
    #expect(fixture.manager.reinstalls == 0)
    if case .operationFailed = controller.notice {} else { Issue.record("the refusal is shown") }
}

@Test @MainActor func manualReinstallReportsWhenLaunchdKeepsTheOldProcess() async throws {
    let fixture = try Fixture()
    let before = fixture.ours("old", pid: 55)
    // The old process keeps answering for the whole window.
    let probe = ScriptedProbe([health(hash: "b", process: before)])
    let controller = fixture.controller(probe: probe)
    let outcome = try await controller.reinstall(confirmed: before)
    #expect(outcome == .restartNotObserved(previous: before))
    #expect(controller.notice == .restartNotObserved(pid: 55))
    #expect(probe.probes > 2)
}

@Test @MainActor func manualReinstallReportsADaemonFromAnotherBundle() async throws {
    let fixture = try Fixture()
    let theirs = identity("x", path: foreignLumen, pid: 9)
    let probe = ScriptedProbe([nil, health(hash: fixture.bundledHash, process: theirs)])
    let controller = fixture.controller(probe: probe)
    let outcome = try await controller.reinstall(confirmed: nil)
    #expect(outcome == .foreign(executablePath: foreignLumen))
    #expect(controller.notice == .observedForeign(bundlePath: DaemonOwnership.bundlePath(containing: foreignLumen)))
}

@Test @MainActor func installReportsSilenceInsteadOfWaitingForever() async throws {
    let fixture = try Fixture()
    fixture.manager.status = .notRegistered
    let controller = fixture.controller(probe: ScriptedProbe([]))
    try await controller.install()
    #expect(fixture.manager.registrations == 1)
    let seconds = DaemonLifecycleController.restartWindow.components.seconds
    // The last probe's failure travels into the notice.
    #expect(controller.notice == .noResponse(seconds: seconds, detail: String(describing: DaemonConnectionFailure(DaemonProbeError.healthMissing))))
}

@Test @MainActor func installStopsProbingWhenMacOSWantsApproval() async throws {
    let fixture = try Fixture()
    fixture.manager.status = .notRegistered
    fixture.manager.statusAfterRegister = .requiresApproval
    let probe = ScriptedProbe([])
    let controller = fixture.controller(probe: probe)
    try await controller.install()
    // No 20 s wait, no notice: the Status row already says "Waiting for approval".
    #expect(probe.probes == 0)
    #expect(controller.notice == nil)
    #expect(controller.serviceStatus == .requiresApproval)
}

@Test @MainActor func reinstallReportsWhenTheBundledDaemonCannotBeFingerprinted() async throws {
    let fixture = try Fixture()
    let controller = fixture.controller(
        probe: ScriptedProbe([]),
        bundledExecutableURL: fixture.directory.appendingPathComponent("missing-Lumen")
    )
    let outcome = try await controller.reinstall(confirmed: nil)
    guard case .cannotVerify = outcome else {
        Issue.record("expected cannotVerify, got \(outcome)")
        return
    }
    if case .operationFailed = controller.notice {} else { Issue.record("the failure is shown, not a fake silence") }
}

@Test @MainActor func uninstallChecksTheConfirmedProcessThenUnregisters() async throws {
    let fixture = try Fixture()
    let current = fixture.ours("cur", pid: 3)
    let controller = fixture.controller(probe: ScriptedProbe([health(hash: "b", process: current)]))
    try await controller.uninstall(confirmed: current)
    #expect(fixture.manager.unregistrations == 1)
    #expect(fixture.manager.status == .notRegistered)
}

@Test @MainActor func isolatedDaemonRefusesManualActions() async throws {
    let fixture = try Fixture()
    let controller = fixture.controller(probe: ScriptedProbe([]), policy: .manualOnly(.isolatedDaemon))
    await #expect(throws: DaemonLifecycleController.OperationError.self) {
        try await controller.uninstall(confirmed: nil)
    }
    #expect(fixture.manager.unregistrations == 0)
}

@Test @MainActor func developmentBuildOnlyAnnouncesThatItWillNotManage() throws {
    let fixture = try Fixture()
    let controller = fixture.controller(probe: ScriptedProbe([]), policy: .manualOnly(.developmentBuild))
    controller.start()
    #expect(controller.notice == .automaticManagementOff(.developmentBuild))
    #expect(fixture.manager.reinstalls == 0)
}

@Test func managementPolicyIsAutomaticOnlyForAReleaseBuildOnTheInstalledSocket() {
    typealias P = DaemonManagementPolicy
    #expect(P.resolve(isDevelopmentBuild: false, talksToInstalledDaemon: true) == .automatic)
    #expect(P.resolve(isDevelopmentBuild: true, talksToInstalledDaemon: true) == .manualOnly(.developmentBuild))
    #expect(P.resolve(isDevelopmentBuild: false, talksToInstalledDaemon: false) == .manualOnly(.isolatedDaemon))
    // Isolation wins: a development build on a test socket must not offer
    // buttons that would act on the registered daemon.
    #expect(P.resolve(isDevelopmentBuild: true, talksToInstalledDaemon: false) == .manualOnly(.isolatedDaemon))
    #expect(P.manualOnly(.developmentBuild).allowsManualActions)
    #expect(!P.manualOnly(.isolatedDaemon).allowsManualActions)
}
