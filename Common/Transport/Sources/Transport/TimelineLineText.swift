import Foundation

/// The text of one Activity row, worked out from what the record holds at
/// the moment it is shown. Nothing here is stored: a row's line is a reading
/// of its `name` / `kind` / `content`, so the record stays the one source.
///
/// Shape: `label · detail · … · duration`. For a tool the label is the tool
/// name, or the action Codex itself read out of a command (`Read`, `Search`,
/// `List`, `Run`).
public enum TimelineLineText {
    // MARK: - Tool

    /// `name` is the resolved tool name: a result recorded without one
    /// borrows its call's (`TimelineProjection`). `isTruncated` says the row
    /// is a mirror's trimmed copy: figures counted over its content would be
    /// counts of a part, so they are left out until the whole row is there.
    public static func tool(_ tool: ToolTimelinePayload, name: String, isTruncated: Bool = false) -> String {
        let time = duration(tool.durationMilliseconds)
        // The script wrapper says nothing readable; its id pairs the call
        // with its output.
        if CodexScriptCall.isWrapper(name: name, content: tool.content) {
            return joined([name, tool.toolUseID])
        }
        if tool.isResult, let item = CodexItemShape(tool.content) {
            return joined(codexItem(item, failed: tool.status == .failed, isTruncated: isTruncated) + [time])
        }
        switch tool.status {
        case .started:
            return joined([name, callDetail(tool.content)])
        case .succeeded:
            return joined([name, resultDetail(tool.content), time])
        case .failed:
            return joined([name, resultDetail(tool.content) ?? "failed", time])
        }
    }

    /// What a call is for: the caller's own description when it wrote one,
    /// else the argument it acts on, else the argument names.
    static func callDetail(_ content: JSONValue?) -> String? {
        if let input = ToolInputShape(content) {
            if let line = LineExcerpt.firstLine(input.detail) { return line }
            let names = input.argumentNames.prefix(4).joined(separator: ", ")
            return names.isEmpty ? nil : names
        }
        return LineExcerpt.firstLine(content?.stringValue)
    }

    static func resultDetail(_ content: JSONValue?) -> String? {
        LineExcerpt.firstLine(ToolResultText.stored(content))
    }

    /// Label and details of one Codex item, duration excluded.
    static func codexItem(_ item: CodexItemShape, failed: Bool, isTruncated: Bool = false) -> [String?] {
        switch item {
        case let .command(command):
            let exit: String? = command.failed || failed ? command.exitCode.map { "exit \($0)" } ?? "failed" : nil
            return commandParts(command.actions) + [exit]

        case let .fileChange(change):
            guard let first = change.files.first else { return ["Edit"] }
            let added = change.files.reduce(0) { $0 + $1.addedLines }
            let removed = change.files.reduce(0) { $0 + $1.removedLines }
            // A diff cut short would count only the lines that were kept.
            let counts = isTruncated ? "" : " +\(added) -\(removed)"
            if change.files.count > 1 { return ["Edit", "\(change.files.count) files\(counts)"] }
            let verb = switch first.kind {
            case .add: "Create"
            case .delete: "Delete"
            case .update: "Edit"
            }
            return [verb, "\(first.name)\(counts)"]

        case let .imageView(path):
            return ["View image", (path as NSString).lastPathComponent]

        case let .mcpToolCall(call):
            return [call.name, callDetail(call.arguments)]

        case let .webSearch(search):
            switch search.action {
            case let .openPage(url):
                return ["Open page", LineExcerpt.firstLine(url ?? search.query)]
            case let .findInPage(pattern):
                return ["Find in page", LineExcerpt.firstLine(pattern ?? search.query)]
            case .search, .other:
                return ["Web search", LineExcerpt.firstLine(search.query ?? search.queries.first)]
            }

        case let .imageGeneration(generation):
            return ["Generate image", generation.savedPath.map { ($0 as NSString).lastPathComponent }]

        case let .other(kind, fields):
            return [kind, LineExcerpt.firstLine(fields["query"]?.stringValue)]
        }
    }

    /// Codex's reading of one command as line parts: neighbouring actions of
    /// a kind share one label (`Read · A, B`), a new kind starts a new pair.
    static func commandParts(_ actions: [CodexItemShape.Command.Action]) -> [String?] {
        var parts: [String?] = []
        var lastLabel: String?
        var objects: [String] = []
        func flush() {
            guard let lastLabel else { return }
            parts.append(lastLabel)
            if !objects.isEmpty { parts.append(objects.joined(separator: ", ")) }
        }
        for action in actions {
            let (label, object): (String, String?) = switch action {
            case let .read(name, _):
                ("Read", name)
            case let .search(query, path):
                ("Search", [query.map { "\"\($0)\"" }, path.map { "in \($0)" }].compactMap { $0 }.joined(separator: " "))
            case let .listFiles(path):
                ("List", path)
            case let .run(command):
                ("Run", LineExcerpt.oneLine(command))
            }
            if label != lastLabel {
                flush()
                lastLabel = label
                objects = []
            }
            if let object = LineExcerpt.oneLine(object) { objects.append(object) }
        }
        flush()
        return parts
    }

    // MARK: - Context / configuration

    public static func context(kind: String, content: JSONValue?) -> String {
        switch kind {
        case "base_instructions": return "Base instructions"
        case "world_state": return "World state"
        case "compacted": return "Compaction summary"
        case "context_compacted": return "Context compacted"
        default: break
        }
        if let text = content?.stringValue {
            return LineExcerpt.firstLine(text) ?? spaced(kind)
        }
        if let fields = content?.objectValue {
            // A file Claude Code loaded as instructions (hook): which file,
            // and why it was loaded.
            if kind == "instructions", let path = fields["file_path"]?.text {
                return joined([(path as NSString).lastPathComponent, fields["load_reason"]?.text])
            }
            if let line = attachment(fields, kind: kind) { return line }
        }
        return spaced(kind)
    }

    public static func config(kind: String, content: JSONValue?) -> String {
        let fields = content?.objectValue
        switch kind {
        case "cwd_changed":
            if let directory = fields?["new_cwd"]?.text { return directory }
        case "config_change":
            // Which settings file changed, and which scope it belongs to.
            if let path = fields?["file_path"]?.text {
                return joined([fields?["source"]?.text, (path as NSString).lastPathComponent])
            }
        case "turn_context":
            let line = joined([fields?["model"]?.text, fields?["effort"]?.text, fields?["cwd"]?.text])
            if !line.isEmpty { return line }
        case "thread_settings":
            let line = joined([fields?["model"]?.text, fields?["reasoning_effort"]?.text])
            return line.isEmpty ? "Thread settings" : line
        default:
            break
        }
        if let fields, let line = attachment(fields, kind: kind) { return line }
        return spaced(kind)
    }

    /// A Claude transcript attachment, stored whole: what it added, which
    /// file it is about, or its own first line.
    private static func attachment(_ fields: [String: JSONValue], kind: String) -> String? {
        guard fields["type"]?.stringValue == kind else { return nil }
        if let names = fields["addedNames"]?.arrayValue, !names.isEmpty, names.allSatisfy({ $0.stringValue != nil }) {
            return "\(spaced(kind)) · \(names.count) tools"
        }
        if let path = fields["filename"]?.stringValue ?? fields["path"]?.stringValue {
            return "\(kind) · \(path)"
        }
        return LineExcerpt.firstLine(fields["content"]?.stringValue)
    }

    // MARK: - Parts

    static func joined(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// `nil` under a millisecond: `0ms` says nothing.
    public static func duration(_ milliseconds: Int64?) -> String? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        if milliseconds < 1_000 { return "\(milliseconds)ms" }
        let seconds = Double(milliseconds) / 1_000
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }

    /// A record kind as words: `hook_success` → `hook success`.
    static func spaced(_ kind: String) -> String {
        kind.replacingOccurrences(of: "_", with: " ")
    }
}
