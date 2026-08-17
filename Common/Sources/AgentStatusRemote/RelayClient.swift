import AgentStatusTransport
import Foundation

public enum RelayClientError: Error, Sendable {
    case invalidResponse
    case unauthorized
    case server(status: Int, message: String)
    case notConnected
    case unsupportedMessage
}

public struct RelayPairingResult: Codable, Hashable, Sendable {
    public let hostID: HostID
    public let deviceID: DeviceID
    public let deviceToken: String
    public let hostPublicKey: Data
    public let pairedAt: Date
}

public struct RelayDeviceRecord: Codable, Hashable, Sendable {
    public let id: DeviceID
    public let name: String
    public let publicKey: Data
    public let pairedAt: Date
    public let revokedAt: Date?
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

    public func createPairingOffer(_ offer: PairingOffer, hostSecret: String) async throws {
        struct Body: Encodable {
            let challenge: String
            let hostPublicKey: Data
            let expiresAt: Date
        }
        _ = try await send(
            path: "/v1/hosts/\(offer.hostID.rawValue)/pairing-offers",
            method: "POST",
            bearerToken: hostSecret,
            body: Body(
                challenge: offer.challenge,
                hostPublicKey: offer.hostPublicKey,
                expiresAt: offer.expiresAt
            )
        ) as PairingOfferResponse
    }

    public func pair(_ request: PairingRequest) async throws -> RelayPairingResult {
        try await send(
            path: "/v1/hosts/\(request.hostID.rawValue)/pair",
            method: "POST",
            body: request
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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayClientError.invalidResponse }
        if http.statusCode == 401 { throw RelayClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
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
}

public enum RelayConnectionRole: Sendable {
    case host
    case device(DeviceID)
}

public enum RelayIncomingMessage: Sendable {
    case frame(RelayRoutingFrame)
    case presence(online: Bool)
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
    }

    public func send(_ frame: RelayRoutingFrame) async throws {
        guard let task else { throw RelayClientError.notConnected }
        let encoded = try TransportCoding.makeEncoder().encode(frame)
        guard let text = String(data: encoded, encoding: .utf8) else {
            throw RelayClientError.invalidResponse
        }
        try await task.send(.string(text))
    }

    public func next() async throws -> RelayIncomingMessage {
        guard let task else { throw RelayClientError.notConnected }
        let message = try await task.receive()
        let data: Data
        switch message {
        case let .string(text): data = Data(text.utf8)
        case let .data(value): data = value
        @unknown default: throw RelayClientError.unsupportedMessage
        }
        if let presence = try? JSONDecoder().decode(PresenceMessage.self, from: data), presence.type == "presence" {
            return .presence(online: presence.online)
        }
        return .frame(try TransportCoding.makeDecoder().decode(RelayRoutingFrame.self, from: data))
    }

    public func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}

private struct EmptyResponse: Codable {}
private struct PairingOfferResponse: Codable { let hostID: HostID; let expiresAt: Date }
private struct DeviceListResponse: Codable { let devices: [RelayDeviceRecord] }
private struct PresenceMessage: Decodable { let type: String; let online: Bool }
