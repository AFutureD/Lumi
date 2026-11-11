import Transport

/// One copy of each large value in a Claude tool result.
///
/// A transcript `tool_result` is stored as `{"content": …, "toolUseResult": …}`:
/// `content` is what the model saw, `toolUseResult` is Claude Code's own
/// structured record of the same call. For a screenshot both carry the same
/// base64 image (`content[0].source.data` and `toolUseResult.file.base64`);
/// for a shell command `toolUseResult.stdout` repeats the output text.
///
/// Every string of at least `minimumBytes` UTF-8 bytes inside
/// `toolUseResult` that equals a string inside `content` is replaced by a
/// reference object `{"lumi.sameAs": "<JSON Pointer>"}` whose pointer
/// (RFC 6901) is relative to the tool content object, e.g.
/// `/content/0/source/data`. The reference is an object where the original
/// was a string, so a reader expecting the value fails visibly instead of
/// decoding something else; `content` itself is never changed.
public enum ToolResultDeduplication {
    /// Strings shorter than this stay inline: the reference would not pay
    /// for itself.
    public static let minimumBytes = 1024
    /// The single key of a reference object.
    public static let referenceKey = "lumi.sameAs"
    static let primaryKey = "content"
    static let secondaryKey = "toolUseResult"

    /// The tool content object with its `toolUseResult` duplicates replaced
    /// by references. Objects without both keys come back unchanged; applying
    /// it twice changes nothing more.
    public static func deduplicated(_ content: [String: JSONValue]) -> [String: JSONValue] {
        guard let primary = content[primaryKey], let secondary = content[secondaryKey] else { return content }
        var pointers: [String: String] = [:]
        collectStrings(primary, pointer: "/" + escape(primaryKey), into: &pointers)
        guard !pointers.isEmpty else { return content }
        var result = content
        result[secondaryKey] = replacingDuplicates(secondary, pointers: pointers)
        return result
    }

    /// `deduplicated(_:)` over a stored tool payload content value.
    public static func deduplicated(_ content: JSONValue) -> JSONValue {
        guard case let .object(object) = content else { return content }
        return .object(deduplicated(object))
    }

    /// The first pointer of every long string, depth-first in key order so
    /// the pointer chosen for a repeated value is stable across runs.
    private static func collectStrings(_ value: JSONValue, pointer: String, into pointers: inout [String: String]) {
        switch value {
        case let .string(text) where text.utf8.count >= minimumBytes:
            if pointers[text] == nil { pointers[text] = pointer }
        case let .array(values):
            for (index, element) in values.enumerated() {
                collectStrings(element, pointer: "\(pointer)/\(index)", into: &pointers)
            }
        case let .object(object):
            for key in object.keys.sorted() {
                collectStrings(object[key]!, pointer: "\(pointer)/\(escape(key))", into: &pointers)
            }
        default:
            break
        }
    }

    private static func replacingDuplicates(_ value: JSONValue, pointers: [String: String]) -> JSONValue {
        switch value {
        case let .string(text) where text.utf8.count >= minimumBytes:
            guard let pointer = pointers[text] else { return value }
            return .object([referenceKey: .string(pointer)])
        case let .array(values):
            return .array(values.map { replacingDuplicates($0, pointers: pointers) })
        case let .object(object):
            return .object(object.mapValues { replacingDuplicates($0, pointers: pointers) })
        default:
            return value
        }
    }

    /// RFC 6901 reference-token escaping: `~` → `~0`, `/` → `~1`.
    static func escape(_ key: String) -> String {
        key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }
}
