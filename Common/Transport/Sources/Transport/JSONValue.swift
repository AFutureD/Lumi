import Foundation

public enum JSONValue: Codable, Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Decimal)
    case boolean(Bool)
    case null

    public init(jsonObject: Any) throws {
        switch jsonObject {
        case is NSNull:
            self = .null
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            if String(cString: value.objCType) == "c" {
                self = .boolean(value.boolValue)
            } else if let number = Decimal(
                string: value.stringValue,
                locale: Locale(identifier: "en_US_POSIX")
            ) {
                self = .number(number)
            } else {
                throw JSONValueError.unsupportedNumber(value.stringValue)
            }
        case let value as [Any]:
            self = .array(try value.map(JSONValue.init(jsonObject:)))
        case let value as [String: Any]:
            self = .object(try value.mapValues(JSONValue.init(jsonObject:)))
        default:
            throw JSONValueError.unsupportedType(String(describing: type(of: jsonObject)))
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public extension JSONValue {
    /// Foundation representation (`String` / `NSNumber` / `[Any]` /
    /// `[String: Any]` / `NSNull`), for helpers that inspect loose JSON.
    var foundationObject: Any {
        switch self {
        case let .object(value): value.mapValues(\.foundationObject)
        case let .array(value): value.map(\.foundationObject)
        case let .string(value): value
        case let .number(value): value as NSDecimalNumber
        case let .boolean(value): value
        case .null: NSNull()
        }
    }
}

/// Typed reads of loose JSON, for code that interprets an agent's own record
/// shapes (`AgentRecordShapes`). A mismatch is `nil`, never a trap.
public extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case let .object(value) = self { value[key] } else { nil }
    }

    var stringValue: String? {
        if case let .string(value) = self { value } else { nil }
    }

    /// A string that says something: `nil` for empty.
    var text: String? {
        if case let .string(value) = self, !value.isEmpty { value } else { nil }
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { value } else { nil }
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { value } else { nil }
    }

    var boolValue: Bool? {
        if case let .boolean(value) = self { value } else { nil }
    }

    var int64Value: Int64? {
        if case let .number(value) = self { NSDecimalNumber(decimal: value).int64Value } else { nil }
    }

    /// The object a JSON-encoded string holds (`"{\"code\":…}"`), as some
    /// agents record call arguments.
    var decodedObjectString: JSONValue? {
        guard case let .string(value) = self, value.hasPrefix("{"),
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return try? JSONValue(jsonObject: object)
    }
}

public enum JSONValueError: Error, Equatable, Sendable {
    case unsupportedType(String)
    case unsupportedNumber(String)
}
