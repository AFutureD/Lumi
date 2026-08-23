import AgentStatusLogging
import Logging
import AgentStatusTransport
import Foundation

private let log = Logger(label: "relay")

public enum RelayClientError: Error, Sendable {
    case invalidResponse
    case unauthorized
    /// The Relay answered with one of its own error codes
    /// (`invalid_or_expired_code`, `host_offline`, `invalid_state`, `rate_limited`, …).
    case relay(status: Int, code: String)
    case server(status: Int, message: String)
    case notConnected
    case unsupportedMessage
}

public struct RelayDeviceRecord: Codable, Hashable, Sendable {
    public let id: DeviceID
    public let name: String
    public let publicKey: Data
    public let pairedAt: Date
    public let revokedAt: Date?

    public init(id: DeviceID, name: String, publicKey: Data, pairedAt: Date, revokedAt: Date?) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.pairedAt = pairedAt
        self.revokedAt = revokedAt
    }
}

// MARK: - Pairing v2 wire shapes

/// `POST /v1/hosts/:h/pairing-sessions` → what the Mac shows.
public struct RelayPairingSessionCreated: Codable, Hashable, Sendable {
    public let sessionID: String
    public let code: String
    public let expiresAt: Date

    public init(sessionID: String, code: String, expiresAt: Date) {
        self.sessionID = sessionID
        self.code = code
        self.expiresAt = expiresAt
    }
}

/// `POST /v1/pairing/claim` → what the iPhone learns from the code: which
/// Mac, and the Mac's commitment (no key, no nonce yet).
public struct RelayPairingClaim: Codable, Hashable, Sendable {
    public let sessionID: String
    public let hostID: HostID
    public let hostName: String?
    public let commit: Data

    public init(sessionID: String, hostID: HostID, hostName: String?, commit: Data) {
        self.sessionID = sessionID
        self.hostID = hostID
        self.hostName = hostName
        self.commit = commit
    }
}

/// `GET /v1/hosts/:h/pairing-sessions/:s` — fields appear as the session
/// advances: key + nonce from `revealed`, token only when `approved`.
public struct RelayPairingSessionStatus: Codable, Hashable, Sendable {
    public let state: PairingSessionState
    public let hostName: String?
    public let hostPublicKey: Data?
    public let hostNonce: Data?
    public let deviceToken: String?
    public let pairedAt: Date?

    public init(
        state: PairingSessionState,
        hostName: String? = nil,
        hostPublicKey: Data? = nil,
        hostNonce: Data? = nil,
        deviceToken: String? = nil,
        pairedAt: Date? = nil
    ) {
        self.state = state
        self.hostName = hostName
        self.hostPublicKey = hostPublicKey
        self.hostNonce = hostNonce
        self.deviceToken = deviceToken
        self.pairedAt = pairedAt
    }
}

/// Host WSS control message `pairing_device`: an iPhone submitted itself to
/// the Mac's live session. The daemon derives the SAS from this, then reveals.
public struct RelayPairingDeviceNotice: Hashable, Sendable {
    public let sessionID: String
    public let deviceID: DeviceID
    public let deviceName: String
    public let devicePublicKey: Data

    public init(sessionID: String, deviceID: DeviceID, deviceName: String, devicePublicKey: Data) {
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.devicePublicKey = devicePublicKey
    }
}

public struct RelayRESTClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func registerHost(hostID: HostID, hostSecret: String) async throws {
        struct Body: Encodable { let hostSecret: String }
        _ = try await send(
            path: "/v1/hosts/\(hostID.rawValue)",
            method: "PUT",
            body: Body(hostSecret: hostSecret)
        ) as EmptyResponse
    }

    // MARK: Pairing v2 — host side

    public func createPairingSession(
        hostID: HostID,
        commit: Data,
        hostPublicKey: Data,
        hostName: String?,
        expiresAt: Date,
        hostSecret: String
    ) async throws -> RelayPairingSessionCreated {
        struct Body: Encodable {
            let commit: Data
            let hostPublicKey: Data
            let hostName: String?
            let expiresAt: Date
        }
        return try await send(
            path: "/v1/hosts/\(hostID.rawValue)/pairing-sessions",
            method: "POST",
            bearerToken: hostSecret,
            body: Body(commit: commit, hostPublicKey: hostPublicKey, hostName: hostName, expiresAt: expiresAt)
        )
    }

    public func revealPairing(hostID: HostID, sessionID: String, hostNonce: Data, hostSecret: String) async throws {
        struct Body: Encodable { let hostNonce: Data }
        _ = try await send(
            path: "/v1/hosts/\(hostID.rawValue)/pairing-sessions/\(sessionID)/reveal",
            method: "POST",
            bearerToken: hostSecret,
            body: Body(hostNonce: hostNonce)
        ) as StateResponse
    }

    public func decidePairing(hostID: HostID, sessionID: String, approved: Bool, hostSecret: String) async throws {
        struct Body: Encodable { let approved: Bool }
        _ = try await send(
            path: "/v1/hosts/\(hostID.rawValue)/pairing-sessions/\(sessionID)/decision",
            method: "POST",
            bearerToken: hostSecret,
            body: Body(approved: approved)
        ) as StateResponse
    }

    /// Either end cancels with its own credential (Host secret or sessionID).
    public func cancelPairing(hostID: HostID, sessionID: String, bearerToken: String) async throws {
        _ = try await send(
            path: "/v1/hosts/\(hostID.rawValue)/pairing-sessions/\(sessionID)",
            method: "DELETE",
            bearerToken: bearerToken
        ) as EmptyResponse
    }

    // MARK: Pairing v2 — device side

    public func claimPairing(code: String) async throws -> RelayPairingClaim {
        struct Body: Encodable { let code: String }
        return try await send(path: "/v1/pairing/claim", method: "POST", body: Body(code: code))
    }

    public func submitPairingDevice(
        hostID: HostID,
        sessionID: String,
        deviceID: DeviceID,
        deviceName: String,
        devicePublicKey: Data
    ) async throws {
        struct Body: Encodable {
            let deviceID: DeviceID
            let deviceName: String
            let devicePublicKey: Data
        }
        _ = try await send(
            path: "/v1/hosts/\(hostID.rawValue)/pairing-sessions/\(sessionID)/device",
            method: "POST",
            bearerToken: sessionID,
            body: Body(deviceID: deviceID, deviceName: deviceName, devicePublicKey: devicePublicKey)
        ) as StateResponse
    }

    public func pairingSession(hostID: HostID, sessionID: String) async throws -> RelayPairingSessionStatus {
        try await send(
            path: "/v1/hosts/\(hostID.rawValue)/pairing-sessions/\(sessionID)",
            method: "GET",
            bearerToken: sessionID
        )
    }

    public func devices(hostID: HostID, hostSecret: String) async throws -> [RelayDeviceRecord] {
        let response: DeviceListResponse = try await send(
            path: "/v1/hosts/\(hostID.rawValue)/devices",
            method: "GET",
            bearerToken: hostSecret
        )
        return response.devices
    }

    public func revoke(hostID: HostID, deviceID: DeviceID, hostSecret: String) async throws {
        _ = try await send(
            path: "/v1/hosts/\(hostID.rawValue)/devices/\(deviceID.rawValue)",
            method: "DELETE",
            bearerToken: hostSecret
        ) as EmptyResponse
    }

    /// Deletes the device record (a revoked row the Mac no longer wants to see).
    public func removeDevice(hostID: HostID, deviceID: DeviceID, hostSecret: String) async throws {
        _ = try await send(
            path: "/v1/hosts/\(hostID.rawValue)/devices/\(deviceID.rawValue)?purge=1",
            method: "DELETE",
            bearerToken: hostSecret
        ) as EmptyResponse
    }

    private func send<ResponseBody: Decodable>(
        path: String,
        method: String,
        bearerToken: String? = nil
    ) async throws -> ResponseBody {
        try await send(path: path, method: method, bearerToken: bearerToken, body: Optional<String>.none)
    }

    private func send<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        method: String,
        bearerToken: String? = nil,
        body: RequestBody?
    ) async throws -> ResponseBody {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw RelayClientError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try TransportCoding.makeEncoder().encode(body)
        }
        let started = ContinuousClock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            log.warning("relay_rest_failed", metadata: .fields([
                "method": method,
                "path": Self.redactedPath(path),
                "ms": LogClock.milliseconds(since: started),
                "error": error,
            ]))
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw RelayClientError.invalidResponse }
        log.log(level: (200..<300).contains(http.statusCode) ? .debug : .warning, "relay_rest", metadata: .fields([
            "method": method,
            "path": Self.redactedPath(path),
            "status": http.statusCode,
            "bytes_out": request.httpBody?.count ?? 0,
            "bytes_in": data.count,
            "ms": LogClock.milliseconds(since: started),
        ]))
        if http.statusCode == 401 { throw RelayClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            if let body = try? JSONDecoder().decode(RelayErrorBody.self, from: data) {
                throw RelayClientError.relay(status: http.statusCode, code: body.error)
            }
            throw RelayClientError.server(
                status: http.statusCode,
                message: String(data: data, encoding: .utf8) ?? "Relay request failed"
            )
        }
        if ResponseBody.self == EmptyResponse.self && data.isEmpty {
            return EmptyResponse() as! ResponseBody
        }
        return try TransportCoding.makeDecoder().decode(ResponseBody.self, from: data)
    }

    /// Pairing session ids double as bearer capabilities, so a path that
    /// names one is logged with the id shortened to its first 8 characters.
    static func redactedPath(_ path: String) -> String {
        var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let index = components.firstIndex(of: "pairing-sessions"), index + 1 < components.count,
              components[index + 1].count > 8 else { return path }
        let value = components[index + 1]
        let query = value.firstIndex(of: "?").map { String(value[$0...]) } ?? ""
        components[index + 1] = String(value.prefix(8)) + "…" + query
        return components.joined(separator: "/")
    }
}

public enum RelayConnectionRole: Sendable {
    case host
    case device(DeviceID)
}

/// A control message from the Relay worker itself (never sealed): the host
/// reused a channel sequence, or a frame failed validation.
public struct RelayErrorMessage: Codable, Hashable, Sendable {
    public let code: String
    public let sequence: UInt64?
    public let lastSequence: UInt64?
    public let deviceID: DeviceID?

    public init(code: String, sequence: UInt64? = nil, lastSequence: UInt64? = nil, deviceID: DeviceID? = nil) {
        self.code = code
        self.sequence = sequence
        self.lastSequence = lastSequence
        self.deviceID = deviceID
    }
}

public enum RelayIncomingMessage: Sendable {
    case frame(RelayRoutingFrame)
    case presence(online: Bool)
    case error(RelayErrorMessage)
    /// Host socket only: an iPhone submitted itself to the live pairing session.
    case pairingDevice(RelayPairingDeviceNotice)
    /// Host socket only: the iPhone cancelled the live pairing session.
    case pairingClosed(sessionID: String, reason: String)

    /// What a log line calls the message: frames by kind and sequence,
    /// control messages by type — never their payload.
    public var logName: String {
        switch self {
        case let .frame(frame): "frame:\(frame.kind.rawValue):\(frame.sequence)"
        case let .presence(online): "presence:\(online ? "online" : "offline")"
        case let .error(error): "error:\(error.code)"
        case .pairingDevice: "pairing_device"
        case let .pairingClosed(_, reason): "pairing_closed:\(reason)"
        }
    }
}

public actor RelayWebSocketClient {
    private let baseURL: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func connect(hostID: HostID, role: RelayConnectionRole, token: String) throws {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)
        components?.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        components?.path = "/v1/hosts/\(hostID.rawValue)/ws"
        switch role {
        case .host:
            components?.queryItems = [URLQueryItem(name: "role", value: "host")]
        case let .device(deviceID):
            components?.queryItems = [
                URLQueryItem(name: "role", value: "device"),
                URLQueryItem(name: "deviceId", value: deviceID.rawValue),
            ]
        }
        guard let url = components?.url else { throw RelayClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        let newTask = session.webSocketTask(with: request)
        task?.cancel(with: .goingAway, reason: nil)
        task = newTask
        newTask.resume()
        log.info("relay_ws_connecting", metadata: .fields([
            "relay": baseURL.host ?? baseURL.absoluteString,
            "host": hostID.rawValue,
            "role": Self.roleName(role),
        ]))
    }

    public func send(_ frame: RelayRoutingFrame) async throws {
        guard let task else { throw RelayClientError.notConnected }
        let encoded = try TransportCoding.makeEncoder().encode(frame)
        guard let text = String(data: encoded, encoding: .utf8) else {
            throw RelayClientError.invalidResponse
        }
        do {
            try await task.send(.string(text))
        } catch {
            log.warning("relay_ws_send_failed", metadata: .fields([
                "kind": frame.kind.rawValue,
                "device": frame.deviceID?.rawValue,
                "sequence": frame.sequence,
                "bytes": encoded.count,
                "error": error,
            ]))
            throw error
        }
        log.debug("relay_ws_sent", metadata: .fields([
            "kind": frame.kind.rawValue,
            "device": frame.deviceID?.rawValue,
            "sequence": frame.sequence,
            "bytes": encoded.count,
        ]))
    }

    public func next() async throws -> RelayIncomingMessage {
        guard let task else { throw RelayClientError.notConnected }
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            // A refused upgrade (401/403) or the worker closing with
            // `4003 device revoked` means the credentials are no longer
            // accepted: surface that instead of a generic socket error, so
            // callers stop reconnecting and ask the user to pair again.
            let httpStatus = (task.response as? HTTPURLResponse)?.statusCode
            let closeCode = task.closeCode.rawValue
            let rejected = Self.isCredentialRejection(httpStatus: httpStatus, closeCode: closeCode)
            log.warning("relay_ws_receive_failed", metadata: .fields([
                "http_status": httpStatus,
                "close_code": closeCode,
                "credential_rejected": rejected,
                "error": error,
            ]))
            if rejected {
                throw RelayClientError.unauthorized
            }
            throw error
        }
        let data: Data
        switch message {
        case let .string(text): data = Data(text.utf8)
        case let .data(value): data = value
        @unknown default: throw RelayClientError.unsupportedMessage
        }
        let incoming = try Self.decode(data)
        log.debug("relay_ws_received", metadata: .fields([
            "type": incoming.logName,
            "bytes": data.count,
        ]))
        return incoming
    }

    private static func decode(_ data: Data) throws -> RelayIncomingMessage {
        if let control = try? JSONDecoder().decode(ControlMessage.self, from: data) {
            switch control.type {
            case "presence":
                if let online = control.online { return .presence(online: online) }
            case "error":
                return .error(RelayErrorMessage(
                    code: control.code ?? "unknown",
                    sequence: control.sequence,
                    lastSequence: control.lastSequence,
                    deviceID: control.deviceID.map(DeviceID.init(rawValue:))
                ))
            case "pairing_device":
                if let sessionID = control.sessionID, let deviceID = control.deviceID,
                   let deviceName = control.deviceName, let key = control.devicePublicKey,
                   let devicePublicKey = Data(base64Encoded: key) {
                    return .pairingDevice(RelayPairingDeviceNotice(
                        sessionID: sessionID,
                        deviceID: DeviceID(rawValue: deviceID),
                        deviceName: deviceName,
                        devicePublicKey: devicePublicKey
                    ))
                }
            case "pairing_closed":
                if let sessionID = control.sessionID {
                    return .pairingClosed(sessionID: sessionID, reason: control.reason ?? "cancelled")
                }
            default:
                break
            }
        }
        return .frame(try TransportCoding.makeDecoder().decode(RelayRoutingFrame.self, from: data))
    }

    public func disconnect() {
        if task != nil {
            log.info("relay_ws_disconnected", metadata: .fields(["relay": baseURL.host ?? baseURL.absoluteString]))
        }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private static func roleName(_ role: RelayConnectionRole) -> String {
        switch role {
        case .host: "host"
        case .device: "device"
        }
    }

    /// The worker's close code for a device the Mac revoked (`host-relay.ts`).
    public static let deviceRevokedCloseCode = 4003

    /// True when the Relay refused the credentials: the upgrade came back
    /// 401/403, or the socket was closed with the revoked-device code.
    public static func isCredentialRejection(httpStatus: Int?, closeCode: Int) -> Bool {
        if let httpStatus, httpStatus == 401 || httpStatus == 403 { return true }
        return closeCode == deviceRevokedCloseCode
    }
}

private struct EmptyResponse: Codable {}
private struct StateResponse: Codable { let state: PairingSessionState }
private struct DeviceListResponse: Codable { let devices: [RelayDeviceRecord] }
private struct RelayErrorBody: Decodable { let error: String }
/// `{type:"presence",online}`, `{type:"error",code,sequence,lastSequence,deviceID}`,
/// `{type:"pairing_device",sessionID,deviceID,deviceName,devicePublicKey}` and
/// `{type:"pairing_closed",sessionID,reason}`; routing frames have no `type`
/// key so they never decode as one.
private struct ControlMessage: Decodable {
    let type: String
    let online: Bool?
    let code: String?
    let sequence: UInt64?
    let lastSequence: UInt64?
    let deviceID: String?
    let sessionID: String?
    let deviceName: String?
    let devicePublicKey: String?
    let reason: String?
}
