import Foundation

// Readers of the agents' own record shapes — the one place that knows how a
// Claude tool input or result, or a Codex item, is laid out inside a stored
// row's `content`. The Activity line (`TimelineLineText`) and the preview
// both read through these, so the stored record is the single source and
// nothing derived from it is stored alongside it.

/// One line of text taken from a longer value.
public enum LineExcerpt {
    public static let maximumCharacters = 160

    /// The first non-empty line, whitespace-trimmed and capped. `nil` when
    /// the value has no visible line.
    public static func firstLine(_ value: String?, maximumCharacters: Int = maximumCharacters) -> String? {
        guard let value else { return nil }
        let line = value
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        return capped(line, maximumCharacters)
    }

    /// The whole value on one line: whitespace runs (line breaks included)
    /// collapsed to a space, capped. For a command, whose later lines matter.
    public static func oneLine(_ value: String?, maximumCharacters: Int = maximumCharacters) -> String? {
        guard let value else { return nil }
        var line = ""
        var pendingSpace = false
        for character in value {
            if character.isWhitespace {
                pendingSpace = !line.isEmpty
            } else {
                if pendingSpace { line.append(" ") }
                pendingSpace = false
                line.append(character)
                // One past the cap is enough to know the value was cut.
                if line.count > maximumCharacters { break }
            }
        }
        return capped(line, maximumCharacters)
    }

    private static func capped(_ line: String, _ maximumCharacters: Int) -> String? {
        guard !line.isEmpty else { return nil }
        return line.count <= maximumCharacters ? line : String(line.prefix(maximumCharacters)) + "…"
    }
}

/// A tool call's input when it is an object of named arguments — a Claude
/// `tool_use.input`, a hook's `tool_input`, or the object inside a
/// JSON-encoded arguments string (Codex `function_call.arguments`).
public struct ToolInputShape: Sendable {
    public let arguments: [String: JSONValue]

    public init?(_ content: JSONValue?) {
        guard let arguments = content?.objectValue ?? content?.decodedObjectString?.objectValue else { return nil }
        self.arguments = arguments
    }

    /// Argument names that say what a call is for, most telling first: what
    /// the caller wrote about the call, then what the call acts on.
    static let detailKeys = [
        "description", "title", "command", "cmd", "file_path", "path", "pattern", "query", "url", "prompt",
        "input", "text",
    ]

    /// The most telling argument, whole.
    public var detail: String? {
        for key in Self.detailKeys {
            if let text = string(key) { return text }
        }
        return nil
    }

    /// A string argument with something to read in it; a list of strings
    /// reads as one line. Blank text is no argument: an empty `description`
    /// must not hide the command under it.
    public func string(_ key: String) -> String? {
        guard let value = arguments[key] else { return nil }
        let text: String? = if let parts = value.arrayValue, !parts.isEmpty {
            parts.allSatisfy({ $0.stringValue != nil }) ? parts.compactMap(\.stringValue).joined(separator: " ") : nil
        } else {
            value.stringValue
        }
        guard let text, text.contains(where: { !$0.isWhitespace }) else { return nil }
        return text
    }

    public var argumentNames: [String] { arguments.keys.sorted() }
}

/// The readable text of a tool result in the shapes agents record it.
public enum ToolResultText {
    /// Text of a content-block array (`[{type, text}]`) or a plain string.
    public static func blocks(_ value: JSONValue?) -> String? {
        if let text = value?.stringValue { return text }
        guard let blocks = value?.arrayValue else { return nil }
        let parts = blocks.compactMap { $0["text"]?.stringValue }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Best-effort text of one raw result value.
    public static func text(of value: JSONValue?) -> String? {
        switch value {
        case let .string(text):
            // `{"output":"...","metadata":{...}}` encoded as a JSON string.
            if let inner = value?.decodedObjectString?["output"]?.stringValue { return inner }
            // Python-ish repr of a content array: pull the text field.
            if text.hasPrefix("[{"), let range = text.range(of: "'text': '") ?? text.range(of: "\"text\": \"") {
                let rest = text[range.upperBound...]
                let end = rest.firstIndex(where: { $0 == "'" || $0 == "\"" }) ?? rest.endIndex
                return String(rest[..<end]).replacingOccurrences(of: "\\n", with: "\n")
            }
            return text
        case let .object(object):
            if let output = object["output"]?.stringValue { return output }
            if let text = blocks(object["content"]) { return text }
            // A shell result as Claude Code hands it to hooks: `{stdout, stderr, …}`.
            return object["text"]?.stringValue ?? object["stdout"]?.stringValue
        case .array:
            return blocks(value)
        default:
            return nil
        }
    }

    /// Text of a stored result row's `content`: a Claude transcript result
    /// (`{content, toolUseResult}`), a hook result (`{tool_result,
    /// tool_response}`), or a bare value.
    public static func stored(_ content: JSONValue?) -> String? {
        guard let object = content?.objectValue else { return text(of: content) }
        if let hookResult = object["tool_result"] ?? object["tool_response"] { return text(of: hookResult) }
        return text(of: content) ?? object["toolUseResult"]?["stdout"]?.stringValue
    }
}

/// A Codex `item_completed` item as stored whole in a tool row's `content`:
/// what Codex itself recorded about one action it took.
public enum CodexItemShape: Sendable {
    case command(Command)
    case fileChange(FileChange)
    case imageView(path: String)
    case mcpToolCall(McpToolCall)
    case webSearch(WebSearch)
    case imageGeneration(ImageGeneration)
    /// An `Extension` kind with no reading of its own (`clock.sleep`, …).
    case other(kind: String, fields: [String: JSONValue])

    public init?(_ content: JSONValue?) {
        guard let fields = content?.objectValue, let type = fields["type"]?.stringValue else { return nil }
        switch type {
        case "CommandExecution":
            self = .command(Command(fields))
        case "FileChange":
            self = .fileChange(FileChange(fields))
        case "ImageView":
            guard let path = fields["path"]?.stringValue else { return nil }
            self = .imageView(path: path)
        case "McpToolCall":
            self = .mcpToolCall(McpToolCall(fields))
        case "Extension":
            let kind = fields["kind"]?.stringValue ?? "Extension"
            switch kind {
            case "web.search": self = .webSearch(WebSearch(fields))
            case "image_gen.generation": self = .imageGeneration(ImageGeneration(fields))
            default: self = .other(kind: kind, fields: fields)
            }
        default:
            return nil
        }
    }

    /// One shell command Codex ran, with Codex's own reading of what the
    /// command does (`parsed_cmd`).
    public struct Command: Sendable {
        public enum Action: Equatable, Sendable {
            case read(name: String, path: String?)
            case search(query: String?, path: String?)
            case listFiles(path: String?)
            case run(command: String)
        }

        /// The command as typed, without the `zsh -lc` wrapper around it.
        public let commandLine: String
        public let actions: [Action]
        public let workingDirectory: String?
        public let exitCode: Int64?
        public let output: String?
        public let failed: Bool

        init(_ fields: [String: JSONValue]) {
            let argv = fields["command"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let line: String = if argv.count >= 3, ["-lc", "-c"].contains(argv[1]) {
                argv[2...].joined(separator: " ")
            } else if !argv.isEmpty {
                argv.joined(separator: " ")
            } else {
                fields["command"]?.stringValue ?? ""
            }
            commandLine = line
            let parsed: [Action] = (fields["parsed_cmd"]?.arrayValue ?? []).compactMap { entry in
                switch entry["type"]?.stringValue {
                case "read":
                    guard let name = entry["name"]?.text ?? entry["path"]?.text else { return nil }
                    return .read(name: name, path: entry["path"]?.text)
                case "search":
                    return .search(query: entry["query"]?.text, path: entry["path"]?.text)
                case "list_files":
                    return .listFiles(path: entry["path"]?.text)
                case "unknown":
                    return .run(command: entry["cmd"]?.text ?? line)
                default:
                    return nil
                }
            }
            actions = parsed.isEmpty ? [.run(command: line)] : parsed
            let directory = fields["cwd"]?.text
            workingDirectory = directory.flatMap { $0.hasPrefix("file://") ? URL(string: $0)?.path : $0 }
            exitCode = fields["exit_code"]?.int64Value
            output = fields["aggregated_output"]?.stringValue
            failed = fields["status"]?.stringValue == "failed"
        }
    }

    /// The files one patch touched.
    public struct FileChange: Sendable {
        public struct File: Sendable {
            public enum Kind: String, Sendable { case add, delete, update }
            public let path: String
            public let kind: Kind
            public let addedLines: Int
            public let removedLines: Int
            /// The unified diff of an update; `nil` for an add or a delete.
            public let unifiedDiff: String?
            /// The whole file of an add or a delete.
            public let content: String?
            public let movedTo: String?

            public var name: String { (path as NSString).lastPathComponent }
        }

        /// In path order.
        public let files: [File]

        init(_ fields: [String: JSONValue]) {
            let changes = fields["changes"]?.objectValue ?? [:]
            files = changes.keys.sorted().map { path in
                let change = changes[path]
                let kind = change?["type"]?.stringValue.flatMap(File.Kind.init(rawValue:)) ?? .update
                let diff = change?["unified_diff"]?.stringValue
                let content = change?["content"]?.stringValue
                let (added, removed): (Int, Int) = switch kind {
                case .add: (Self.lineCount(content), 0)
                case .delete: (0, Self.lineCount(content))
                case .update: Self.diffCounts(diff)
                }
                return File(
                    path: path, kind: kind, addedLines: added, removedLines: removed,
                    unifiedDiff: diff, content: content, movedTo: change?["move_path"]?.text
                )
            }
        }

        static func lineCount(_ text: String?) -> Int {
            guard let text, !text.isEmpty else { return 0 }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            return text.hasSuffix("\n") ? lines - 1 : lines
        }

        /// Added / removed lines of a unified diff, file headers excluded.
        static func diffCounts(_ diff: String?) -> (Int, Int) {
            guard let diff else { return (0, 0) }
            var added = 0, removed = 0
            for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
                if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
            }
            return (added, removed)
        }
    }

    public struct McpToolCall: Sendable {
        public let server: String?
        public let tool: String?
        public let arguments: JSONValue?
        public let result: JSONValue?

        init(_ fields: [String: JSONValue]) {
            server = fields["server"]?.text
            tool = fields["tool"]?.text
            arguments = fields["arguments"]
            result = fields["result"]
        }

        /// `server/tool`.
        public var name: String {
            let name = [server, tool].compactMap { $0 }.joined(separator: "/")
            return name.isEmpty ? "MCP tool" : name
        }

        public var resultText: String? { ToolResultText.text(of: result) }
    }

    public struct WebSearch: Sendable {
        public enum Action: Equatable, Sendable {
            case search
            case openPage(url: String?)
            case findInPage(pattern: String?)
            case other
        }

        public struct Result: Sendable {
            public let title: String?
            public let url: String?
            public let snippet: String?
        }

        public let query: String?
        public let action: Action
        /// Every query of one search action; `query` is Codex's one-line form.
        public let queries: [String]
        public let results: [Result]

        init(_ fields: [String: JSONValue]) {
            query = fields["query"]?.text
            let rawAction = fields["action"]
            action = switch rawAction?["type"]?.stringValue {
            case "openPage": .openPage(url: rawAction?["url"]?.text)
            case "findInPage": .findInPage(pattern: rawAction?["pattern"]?.text)
            case "search": .search
            // No action recorded: all the item says is what was looked for.
            case nil where rawAction == nil: .search
            default: .other
            }
            queries = rawAction?["queries"]?.arrayValue?.compactMap(\.text) ?? []
            results = (fields["results"]?.arrayValue ?? []).map {
                Result(title: $0["title"]?.text, url: $0["url"]?.text, snippet: $0["snippet"]?.text)
            }
        }
    }

    public struct ImageGeneration: Sendable {
        public let savedPath: String?
        public let revisedPrompt: String?
        /// The generated image, base64.
        public let imageBase64: String?

        init(_ fields: [String: JSONValue]) {
            savedPath = fields["savedPath"]?.text
            revisedPrompt = fields["revisedPrompt"]?.text
            imageBase64 = fields["result"]?.text
        }
    }
}

/// Codex code mode: the model's one tool is `exec`, a JavaScript source that
/// calls the real tools. The call and its output are the script's wrapper;
/// what the script did is recorded as items of its own (`CodexItemShape`),
/// which carry no reference back to the call.
public enum CodexScriptCall {
    public static let toolName = "exec"

    /// A wrapper row holds source text or output text, never named arguments.
    public static func isWrapper(name: String, content: JSONValue?) -> Bool {
        guard name == toolName else { return false }
        switch content {
        case nil, .string: return true
        default: return false
        }
    }
}
