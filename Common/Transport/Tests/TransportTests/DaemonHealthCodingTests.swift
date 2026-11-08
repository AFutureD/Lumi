import Foundation
import Testing
@testable import Transport

/// A daemon from before identity reporting sends no `process`; the app
/// must still decode its health to recognise it as stale.
@Test func daemonHealthDecodesWithoutProcessIdentity() throws {
    let legacy = """
    {"activeSessionCount":1,"daemonVersion":"0.1.0","executableHash":"abc","relayConnected":false,\
    "retainedSessionCount":2,"socketPath":"/s","uptimeSeconds":5}
    """
    let health = try TransportCoding.makeDecoder().decode(DaemonHealth.self, from: Data(legacy.utf8))
    #expect(health.process == nil)
    #expect(health.executableHash == "abc")
}

@Test func daemonProcessIdentityRoundTripsThroughTheWireCoder() throws {
    let identity = DaemonProcessIdentity(
        instanceID: "4F1C",
        processID: 7,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000.123),
        executablePath: "/Applications/Lumi.app/Contents/Resources/Lumen"
    )
    let health = DaemonHealth(
        daemonVersion: "0.1.0", executableHash: "abc", process: identity, uptimeSeconds: 5,
        activeSessionCount: 1, retainedSessionCount: 2, socketPath: "/s", relayConnected: false
    )
    let data = try TransportCoding.makeEncoder().encode(health)
    let decoded = try TransportCoding.makeDecoder().decode(DaemonHealth.self, from: data)
    #expect(decoded.process?.instanceID == "4F1C")
    #expect(decoded.process?.processID == 7)
    #expect(decoded.process?.executablePath == identity.executablePath)
    // Milliseconds survive; finer precision is not promised by the coder.
    #expect(abs((decoded.process?.startedAt.timeIntervalSince1970 ?? 0) - identity.startedAt.timeIntervalSince1970) < 0.001)
}
