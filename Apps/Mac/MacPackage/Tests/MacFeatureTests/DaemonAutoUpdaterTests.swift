import Transport
import Foundation
import Testing
@testable import MacFeature

private func healthReporting(_ hash: String?) -> DaemonHealth {
    DaemonHealth(
        daemonVersion: "test",
        executableHash: hash,
        uptimeSeconds: 1,
        activeSessionCount: 0,
        retainedSessionCount: 0,
        socketPath: "/tmp/lumi.sock",
        relayConnected: false
    )
}

@Test func autoUpdaterWaitsWhileHealthIsUnknown() {
    #expect(DaemonAutoUpdater.decide(bundledHash: "a", health: nil, alreadyAttempted: false) == .wait)
    #expect(DaemonAutoUpdater.decide(bundledHash: "a", health: nil, alreadyAttempted: true) == .wait)
}

@Test func autoUpdaterRestartsAnUnreachableRegisteredDaemon() {
    // A registration whose binary launchd cannot spawn (rebuilt or deleted
    // bundle) never reports health; after the grace it earns one reinstall.
    let decision = DaemonAutoUpdater.decide(
        bundledHash: "a", health: nil, alreadyAttempted: false, unreachableGraceElapsed: true
    )
    guard case .restart = decision else {
        Issue.record("expected restart, got \(decision)")
        return
    }
    // Post-restart silence is a daemon still booting — wait, never loop.
    #expect(DaemonAutoUpdater.decide(
        bundledHash: "a", health: nil, alreadyAttempted: true, unreachableGraceElapsed: true
    ) == .wait)
}

@Test func autoUpdaterIsDoneWhenHashesMatch() {
    #expect(DaemonAutoUpdater.decide(
        bundledHash: "a", health: healthReporting("a"), alreadyAttempted: false
    ) == .upToDate)
}

@Test func autoUpdaterRestartsOnMismatchOrMissingFingerprint() {
    for stale in [healthReporting("b"), healthReporting(nil), healthReporting("")] {
        let decision = DaemonAutoUpdater.decide(bundledHash: "a", health: stale, alreadyAttempted: false)
        guard case .restart = decision else {
            Issue.record("expected restart, got \(decision)")
            continue
        }
    }
}

@Test func autoUpdaterNeverRestartsTwice() {
    for stale in [healthReporting("b"), healthReporting(nil)] {
        #expect(DaemonAutoUpdater.decide(
            bundledHash: "a", health: stale, alreadyAttempted: true
        ) == .stillStale)
    }
}
