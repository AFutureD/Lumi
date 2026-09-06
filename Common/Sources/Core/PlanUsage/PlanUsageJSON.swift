import Transport
import Foundation

/// Small parsing helpers shared by the Claude and Codex plan-usage mappers.
/// Both providers answer loosely typed JSON, so everything goes through
/// `JSONSerialization` and these guards rather than `Codable`.
enum PlanUsageJSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func number(_ value: Any?) -> Double? {
        if let number = JSONNumber.nonBoolean(value) { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    /// A provider percentage clamped to the 0…100 the Notch can draw.
    static func percent(_ value: Any?) -> Double? {
        guard let number = number(value), number.isFinite else { return nil }
        return min(max(number, 0), 100)
    }

    /// A reset time as either RFC 3339 text or an epoch number — seconds when
    /// below 1e10, milliseconds otherwise (both providers have shipped both).
    static func date(_ value: Any?) -> Date? {
        if let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return TransportCoding.parseDate(text)
        }
        guard let number = number(value), number.isFinite else { return nil }
        return Date(timeIntervalSince1970: abs(number) < 1e10 ? number : number / 1_000)
    }

    /// `word_word` / `word word` → `Word Word`.
    static func titleCased(_ text: String, separator: Character, lowercasingTail: Bool = false) -> String {
        text.split(separator: separator)
            .map { word in
                let head = word.prefix(1).uppercased()
                let tail = lowercasingTail ? word.dropFirst().lowercased() : String(word.dropFirst())
                return head + tail
            }
            .joined(separator: " ")
    }
}

/// The middle segment of a JSON Web Token, decoded — no signature check;
/// the claims only name the account and say when the token lapses.
public struct JWTPayload {
    public let claims: [String: Any]

    public init?(token: String) {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while !payload.count.isMultiple(of: 4) { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        claims = json
    }

    public func string(_ key: String) -> String? {
        (claims[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `exp`, as a date.
    public var expiresAt: Date? {
        PlanUsageJSON.number(claims["exp"]).map { Date(timeIntervalSince1970: $0) }
    }
}

/// Shared by both providers: a token is "expired" a little before its
/// stated expiry so a request never goes out with a token that dies in
/// flight.
public enum PlanUsageTokenExpiry {
    public static let margin: TimeInterval = 5 * 60

    public static func isExpired(_ expiresAt: Date?, now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= margin
    }
}

/// What a provider mapper makes of a usage response body.
public struct PlanUsageFetchOutcome: Hashable, Sendable {
    public var limits: [PlanUsageLimit]

    public init(limits: [PlanUsageLimit]) {
        self.limits = limits
    }
}

public enum PlanUsageParseError: Error, Hashable, Sendable, LocalizedError {
    case invalidJSON
    case noLimits

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: "The usage response is not a JSON object."
        case .noLimits: "The usage response carries no rate-limit windows."
        }
    }
}
