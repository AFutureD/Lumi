import IPCClient
import ServiceManagement
import Transport
import Foundation
import Testing
@testable import MacFeature

private let bundledLumen = URL(fileURLWithPath: "/Applications/Lumi.app/Contents/Resources/Lumen")
private let derivedDataLumen =
    "/Users/dev/Library/Developer/Xcode/DerivedData/Lumi-abc/Build/Products/Debug/Lumi.app/Contents/Resources/Lumen"

private func identity(_ path: String, pid: Int32 = 42) -> DaemonProcessIdentity {
    DaemonProcessIdentity(instanceID: "i-\(pid)", processID: pid, startedAt: Date(timeIntervalSince1970: 1_000), executablePath: path)
}

private func health(_ process: DaemonProcessIdentity?) -> DaemonHealth {
    DaemonHealth(
        daemonVersion: "test", executableHash: "h", process: process, uptimeSeconds: 1,
        activeSessionCount: 0, retainedSessionCount: 0, socketPath: "/tmp/lumi.sock", relayConnected: false
    )
}

@Test func reconnectBackoffDoublesToThirtySecondsAndResetsOnAnswer() {
    var backoff = DaemonReconnectBackoff()
    var delays: [Int64] = []
    for _ in 0..<7 {
        backoff.recordDisconnect()
        delays.append(backoff.delay.components.seconds)
    }
    #expect(delays == [2, 4, 8, 16, 30, 30, 30])
    #expect(backoff.recordConnected() == 7)
    #expect(backoff.recordConnected() == 0)
    backoff.recordDisconnect()
    #expect(backoff.delay.components.seconds == 2)
}

@Test func reconnectBackoffGoesQuietOnceAfterThreeWarnings() {
    var backoff = DaemonReconnectBackoff()
    var loud: [Bool] = []
    var goingQuiet: [Bool] = []
    for _ in 0..<5 {
        backoff.recordDisconnect()
        loud.append(backoff.isLoud)
        goingQuiet.append(backoff.isGoingQuiet)
    }
    #expect(loud == [true, true, true, false, false])
    #expect(goingQuiet == [false, false, false, true, false])
}

@Test func ownershipFollowsTheBundleTheDaemonRunsFrom() {
    #expect(DaemonOwnership.resolve(
        process: identity("/Applications/Lumi.app/Contents/Resources/Lumen"), bundledExecutablePath: bundledLumen.path
    ) == .owned)
    #expect(DaemonOwnership.resolve(process: identity(derivedDataLumen), bundledExecutablePath: bundledLumen.path)
        == .foreign(executablePath: derivedDataLumen))
    // A sibling whose name merely extends ours is another bundle.
    let sibling = "/Applications/Lumi.app 2/Contents/Resources/Lumen"
    #expect(DaemonOwnership.resolve(process: identity(sibling), bundledExecutablePath: bundledLumen.path) == .foreign(executablePath: sibling))
    // No identity (no health, or a daemon from before identity reporting),
    // or a daemon that could not resolve its own path.
    #expect(DaemonOwnership.resolve(process: nil, bundledExecutablePath: bundledLumen.path) == .unknown)
    #expect(DaemonOwnership.resolve(process: identity(""), bundledExecutablePath: bundledLumen.path) == .unknown)
    // An app without a bundled Lumen owns nothing.
    #expect(DaemonOwnership.resolve(process: identity(derivedDataLumen), bundledExecutablePath: nil)
        == .foreign(executablePath: derivedDataLumen))
}

@Test func ownershipNamesTheForeignBundleForDisplay() {
    #expect(DaemonOwnership.bundlePath(containing: derivedDataLumen)
        == "/Users/dev/Library/Developer/Xcode/DerivedData/Lumi-abc/Build/Products/Debug/Lumi.app")
    #expect(DaemonOwnership.bundlePath(containing: "/opt/lumen/Lumen") == "/opt/lumen/Lumen")
}

@Test func connectionFailureClassifiesWhatTheSocketThrew() {
    #expect(DaemonConnectionFailure(DaemonIPCSocketError(operation: "connect", code: ENOENT))
        == .daemonNotRunning(DaemonIPCSocketError(operation: "connect", code: ENOENT).description))
    #expect(DaemonConnectionFailure(DaemonIPCSocketError(operation: "connect", code: ECONNREFUSED))
        == .daemonNotRunning(DaemonIPCSocketError(operation: "connect", code: ECONNREFUSED).description))
    // A socket error past the connect is not "not running".
    if case .other = DaemonConnectionFailure(DaemonIPCSocketError(operation: "read", code: EIO)) {} else {
        Issue.record("a read error must classify as other")
    }
    #expect(DaemonConnectionFailure(DaemonWakeError.unavailable(service: "s", reason: "refused"))
        == .daemonNotRunning(DaemonWakeError.unavailable(service: "s", reason: "refused").description))
    #expect(DaemonConnectionFailure(DaemonWakeError.timedOut(service: "s"))
        == .daemonStarting(DaemonWakeError.timedOut(service: "s").description))
    #expect(DaemonConnectionFailure(DaemonIPCClientError.timedOut) == .daemonNotResponding("no reply in time"))
    #expect(DaemonConnectionFailure(DaemonIPCClientError.incompatibleProtocol(ProtocolVersion(major: 2, minor: 0)))
        == .incompatibleDaemon(major: 2))
    #expect(DaemonConnectionFailure(DaemonIPCClientError.connectionClosed) == .streamClosed)
}

@Test func availabilityAnswersRegistrationBeforeConnectionErrors() {
    typealias A = DaemonAvailability
    func resolve(
        _ service: SMAppService.Status, _ health: DaemonHealth? = nil,
        _ failure: DaemonConnectionFailure? = nil, _ ownership: DaemonOwnership = .unknown,
        isolated: Bool = false
    ) -> A {
        A.resolve(service: service, health: health, failure: failure, ownership: ownership, isolated: isolated)
    }
    // Not registered: the connection error explains nothing the user can act on.
    #expect(resolve(.notRegistered, nil, .daemonNotRunning("connect: ENOENT")) == .notInstalled)
    #expect(resolve(.requiresApproval) == .requiresApproval)
    #expect(resolve(.notFound) == .serviceMissing)
    // Registered: the socket's verdict decides.
    #expect(resolve(.enabled) == .starting)
    #expect(resolve(.enabled, nil, .streamClosed) == .starting)
    #expect(resolve(.enabled, nil, .daemonStarting("wake: no reply")) == .starting)
    #expect(resolve(.enabled, nil, .daemonNotRunning("connect: ENOENT")) == .notRunning(detail: "connect: ENOENT"))
    #expect(resolve(.enabled, nil, .daemonNotResponding("no reply")) == .notResponding(detail: "no reply"))
    #expect(resolve(.enabled, nil, .incompatibleDaemon(major: 2)) == .incompatible(major: 2))
    #expect(resolve(.enabled, nil, .other("boom")) == .failed(detail: "boom"))
    // An isolated daemon has no registration of its own: only the socket speaks.
    #expect(resolve(.notRegistered, nil, .daemonNotRunning("connect: ENOENT"), isolated: true) == .notRunning(detail: "connect: ENOENT"))
    #expect(resolve(.requiresApproval, nil, nil, isolated: true) == .starting)
    // Health wins over everything, and carries whose daemon it is.
    #expect(resolve(.enabled, health(identity("/Applications/Lumi.app/Contents/Resources/Lumen")), nil, .owned) == .running(.owned))
    #expect(resolve(.notRegistered, health(nil), .streamClosed, .unknown) == .running(.unknown))
}

@Test func availabilityOffersTheActionsThatCanHelp() {
    typealias A = DaemonAvailability
    #expect(A.notInstalled.actions == [.install])
    #expect(A.requiresApproval.actions == [.openLoginItems, .uninstall])
    #expect(A.serviceMissing.actions == [])
    #expect(A.running(.owned).actions == [.reinstall, .uninstall])
    #expect(A.notRunning(detail: "x").actions == [.reinstall, .uninstall])
    #expect(A.running(.owned).pill.tone == .green)
    #expect(A.starting.pill.tone == .orange)
    #expect(A.notResponding(detail: "x").pill.tone == .red)
}

@Test func installedDaemonSocketIsDecidedByIsolationNotByTheWakeSwitch() {
    let support = URL(fileURLWithPath: "/tmp/lumi-asb")
    let installed = DaemonEndpoint.defaultSocketPath(environment: [:], applicationSupportDirectory: support)
    #expect(DaemonEndpoint.isInstalledDaemonSocket(installed, environment: [:], applicationSupportDirectory: support))
    // Turning the wake off does not make it another daemon.
    #expect(DaemonEndpoint.isInstalledDaemonSocket(installed, environment: ["LUMI_WAKE_SERVICE": "0"], applicationSupportDirectory: support))
    // Pointing at another socket or support directory does.
    #expect(!DaemonEndpoint.isInstalledDaemonSocket("/tmp/other.sock", environment: [:], applicationSupportDirectory: support))
    #expect(!DaemonEndpoint.isInstalledDaemonSocket(
        "/tmp/other.sock", environment: ["LUMI_SOCKET": "/tmp/other.sock"], applicationSupportDirectory: support
    ))
    #expect(!DaemonEndpoint.isInstalledDaemonSocket(installed, environment: ["LUMI_SUPPORT_DIRECTORY": "/tmp/x"], applicationSupportDirectory: support))
}
