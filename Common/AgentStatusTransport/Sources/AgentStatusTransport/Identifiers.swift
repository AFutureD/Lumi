import Foundation

public struct ProtocolVersion: Codable, Hashable, Sendable {
    public static let current = ProtocolVersion(major: 1, minor: 2)

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

/// The one JSON coder for every hop (helper → daemon, daemon ↔ Mac, daemon →
/// Relay → iPhone, stored session BLOBs). Dates travel as RFC 3339 with
/// milliseconds (`2026-08-22T00:27:36.266Z`) so that items a few hundred
/// milliseconds apart still sort by time on every end, not by id.
public enum TransportCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateFormat))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = parseDate(value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an RFC 3339 date: \(value)")
            }
            return date
        }
        return decoder
    }

    static let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondDateFormat = Date.ISO8601FormatStyle()

    /// RFC 3339 in UTC, with or without a fractional part (the Relay worker
    /// and this coder write milliseconds; whole seconds are valid too).
    public static func parseDate(_ value: String) -> Date? {
        (try? dateFormat.parse(value)) ?? (try? wholeSecondDateFormat.parse(value))
    }
}
