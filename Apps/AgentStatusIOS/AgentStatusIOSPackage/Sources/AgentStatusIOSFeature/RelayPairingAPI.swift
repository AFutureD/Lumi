import AgentStatusRemote
import AgentStatusTransport
import Foundation

/// The four Relay calls an iPhone makes to pair (claim the code, submit
/// itself, poll the session, cancel). Production talks to whichever Relay
/// the code came from; tests script it.
protocol RelayPairingAPI: Sendable {
    func claim(relayURL: URL, code: String) async throws -> RelayPairingClaim
    func submit(relayURL: URL, hostID: HostID, sessionID: String, deviceID: DeviceID, deviceName: String, devicePublicKey: Data) async throws
    func status(relayURL: URL, hostID: HostID, sessionID: String) async throws -> RelayPairingSessionStatus
    func cancel(relayURL: URL, hostID: HostID, sessionID: String) async throws
}

struct LiveRelayPairingAPI: RelayPairingAPI {
    func claim(relayURL: URL, code: String) async throws -> RelayPairingClaim {
        try await RelayRESTClient(baseURL: relayURL).claimPairing(code: code)
    }

    func submit(relayURL: URL, hostID: HostID, sessionID: String, deviceID: DeviceID, deviceName: String, devicePublicKey: Data) async throws {
        try await RelayRESTClient(baseURL: relayURL).submitPairingDevice(
            hostID: hostID, sessionID: sessionID, deviceID: deviceID, deviceName: deviceName, devicePublicKey: devicePublicKey
        )
    }

    func status(relayURL: URL, hostID: HostID, sessionID: String) async throws -> RelayPairingSessionStatus {
        try await RelayRESTClient(baseURL: relayURL).pairingSession(hostID: hostID, sessionID: sessionID)
    }

    func cancel(relayURL: URL, hostID: HostID, sessionID: String) async throws {
        try await RelayRESTClient(baseURL: relayURL).cancelPairing(hostID: hostID, sessionID: sessionID, bearerToken: sessionID)
    }
}

/// Where a pairing attempt is, as the screens show it.
enum PairingProgress: Equatable, Sendable {
    /// The code is being spent at the Relay.
    case claiming
    /// The Mac knows about us; waiting for it to reveal its nonce.
    case waitingForMac(hostName: String?, relayHost: String)
    /// Both ends can show the SAS; waiting for the Mac to press Match.
    case comparing(sas: String, hostName: String?, relayHost: String)
    /// Paired: the channel is installed and syncing.
    case paired(hostID: HostID, hostName: String?, relayHost: String)
}

/// The four failures the screens know (design: Add Mac 失败四态) — and only
/// those. Anything else that ends an attempt is folded into the nearest one
/// (`RelayPairingAttempt.failure(for:)`). Nothing is written to the Keychain
/// on any of them.
enum PairingFailure: Error, Equatable, Sendable {
    /// ① The code is wrong, already spent, or its session is gone (expired /
    /// cancelled on the Mac): back to the entry screen, red cells.
    case badCode
    /// ② The Relay cannot reach the Mac right now (no Host socket) — or we
    /// cannot reach the Relay. `Try again` resumes the same session.
    case hostOffline
    /// ③ The Mac pressed Don't match, or let the 60 s pass.
    case rejected
    /// ④ The revealed key + nonce do not open the commitment we got at claim.
    case commitMismatch
}
