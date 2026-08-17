import Foundation

public struct ProtocolVersion: Codable, Hashable, Sendable {
    public static let current = ProtocolVersion(major: 1, minor: 0)

    public let major: UInt16
    public let minor: UInt16

    public init(major: UInt16, minor: UInt16) {
        self.major = major
        self.minor = minor
    }

    public func isCompatible(with other: ProtocolVersion) -> Bool {
        major == other.major
    }

    private enum CodingKeys: String, CodingKey {
        case major
        case minor
    }
}

public protocol AgentStatusIdentifier: RawRepresentable, Codable, Hashable, Sendable
where RawValue == String {
    init(rawValue: String)
}

public extension AgentStatusIdentifier {
    init() {
        self.init(rawValue: UUID().uuidString.lowercased())
    }

    init(_ value: String) {
        self.init(rawValue: value)
    }
}

public struct RequestID: AgentStatusIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct EventID: AgentStatusIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct SessionID: AgentStatusIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct TurnID: AgentStatusIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct TimelineItemID: AgentStatusIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct DeviceID: AgentStatusIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct HostID: AgentStatusIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct TransportEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let version: ProtocolVersion
    public let requestID: RequestID
    public let sentAt: Date
    public let payload: Payload

    public init(
        version: ProtocolVersion = .current,
        requestID: RequestID = RequestID(),
        sentAt: Date = Date(),
        payload: Payload
    ) {
        self.version = version
        self.requestID = requestID
        self.sentAt = sentAt
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID
        case sentAt
        case payload
    }
}

public enum TransportCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
