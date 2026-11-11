import Transport
import Foundation

/// What opening an Activity row shows a person: the row's own records, read
/// through the same shapes its line is read from (`AgentRecordShapes`), laid
/// out as titled sections. The records themselves ride along (`items`) —
/// they are what the Raw view prints, and what a mirror fetches whole when
/// it holds trimmed copies.
///
/// A tool's call and result open as one preview: both halves of the pair,
/// whichever row was opened.
public struct ActivityPreview: Equatable, Sendable {
    public struct Fact: Equatable, Sendable {
        public let label: String
        public let value: String

        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public enum Image: Equatable, Sendable {
        case base64(String)
        case file(path: String)
    }

    public struct Link: Equatable, Sendable {
        public let title: String
        public let url: String?
        public let detail: String?
    }

    public enum Body: Equatable, Sendable {
        /// Text as someone wrote it.
        case prose(String)
        /// Text written as Markdown (an assistant message).
        case markdown(String)
        /// Text a machine wrote or reads: a command, output, a file.
        case code(String)
        /// A unified diff.
        case diff(String)
        case image(Image)
        case facts([Fact])
        case links([Link])
    }

    public struct Section: Equatable, Sendable {
        public let title: String
        public let body: Body

        public init(_ title: String, _ body: Body) {
            self.title = title
            self.body = body
        }
    }

    public let tag: TimelineTag
    /// The row's line.
    public let title: String
    /// Short facts about the whole row: status, exit code, duration.
    public let facts: [Fact]
    public let sections: [Section]
    /// The records behind the preview, call before result.
    public let items: [TimelineItem]

    /// Records held as trimmed copies: their whole form is on the daemon.
    public var truncatedItemIDs: [TimelineItemID] { items.filter(\.isTruncated).map(\.id) }
}

public enum ActivityPreviewBuilder {
    /// The records one row opens: its own, plus the other half of a tool
    /// call / result pair found among the session's rows.
    public static func items(for row: TimelineRow, among rows: [TimelineRow]) -> [TimelineItem] {
        guard let toolUseID = row.toolUseID, [.tool, .result, .failed].contains(row.tag) else { return row.items }
        let paired = rows.filter { $0.toolUseID == toolUseID }
        let call = paired.first { $0.tag == .tool }
        let result = paired.first { $0.tag == .result || $0.tag == .failed }
        let items = [call, result].compactMap { $0 }.flatMap(\.items)
        return items.isEmpty ? row.items : items
    }

    public static func make(for row: TimelineRow, among rows: [TimelineRow]) -> ActivityPreview {
        make(tag: row.tag, title: row.text, items: items(for: row, among: rows))
    }

    /// The preview of a row from its records — also the rebuild after a
    /// mirror fetched the whole copies of trimmed ones.
    public static func make(tag: TimelineTag, title: String, items: [TimelineItem]) -> ActivityPreview {
        var facts: [ActivityPreview.Fact] = []
        var sections: [ActivityPreview.Section] = []
        switch items.first?.payload {
        case let .message(message):
            sections = [.init("Message", message.role == .assistant ? .markdown(message.text) : .prose(message.text))]
        case let .reasoning(reasoning):
            if !reasoning.text.isEmpty { sections = [.init("Reasoning", .prose(reasoning.text))] }
        case .tool:
            (facts, sections) = tool(items)
        case let .context(context):
            sections = record(context.content)
        case let .config(config):
            sections = record(config.content)
        case let .plan(plan):
            let steps = plan.steps.map { step in
                let mark = switch step.status {
                case .pending: "○"
                case .inProgress: "◐"
                case .completed: "●"
                }
                return "\(mark) \(step.text)"
            }
            let text = ([plan.explanation].compactMap { $0 } + steps).joined(separator: "\n")
            if !text.isEmpty { sections = [.init("Plan", .prose(text))] }
        case let .error(error):
            sections = [.init(error.title, .prose(error.message))]
        case let .turnEnd(end):
            if let message = end.message, !message.isEmpty { sections = [.init("Turn", .markdown(message))] }
        case let .internalContext(context):
            sections = record(context.content)
        case .subagent, .sessionMarker, .modelConfiguration, .usageMetrics, nil:
            break
        }
        return ActivityPreview(tag: tag, title: title, facts: facts, sections: sections, items: items)
    }

    // MARK: - Tools

    private static func tool(_ items: [TimelineItem]) -> ([ActivityPreview.Fact], [ActivityPreview.Section]) {
        let tools = items.compactMap { item -> ToolTimelinePayload? in
            if case let .tool(tool) = item.payload { tool } else { nil }
        }
        let call = tools.first(where: \.isCall)
        let result = tools.first(where: \.isResult)
        var facts: [ActivityPreview.Fact] = []
        var sections: [ActivityPreview.Section] = []

        if let result, let item = CodexItemShape(result.content) {
            (facts, sections) = codexItem(item, failed: result.status == .failed)
        } else if let wrapper = call ?? result, CodexScriptCall.isWrapper(name: call?.name ?? wrapper.name, content: wrapper.content) {
            // The script as the model wrote it, and what running it printed.
            if let source = call?.content?.stringValue, !source.isEmpty { sections.append(.init("Script", .code(source))) }
            if let output = result?.content?.stringValue, !output.isEmpty { sections.append(.init("Output", .code(output))) }
        } else {
            if let call { sections += input(call.content) }
            if let result { sections += output(result) }
        }

        let status = switch result?.status {
        case .failed: "Failed"
        case .succeeded: "Succeeded"
        default: "Running"
        }
        facts.insert(.init("Status", status), at: 0)
        if let time = TimelineLineText.duration(result?.durationMilliseconds) { facts.append(.init("Duration", time)) }
        return (facts, sections)
    }

    /// A call's named arguments: the command or the change it carries shown
    /// as what it is, every other argument listed.
    private static func input(_ content: JSONValue?) -> [ActivityPreview.Section] {
        guard let input = ToolInputShape(content) else {
            guard let text = content?.stringValue, !text.isEmpty else { return [] }
            return [.init("Input", .code(text))]
        }
        var sections: [ActivityPreview.Section] = []
        var shown: Set<String> = []
        if let command = input.string("command") ?? input.string("cmd") {
            sections.append(.init("Command", .code("$ " + command)))
            shown.formUnion(["command", "cmd"])
        }
        if let old = input.arguments["old_string"]?.stringValue, let new = input.arguments["new_string"]?.stringValue {
            sections.append(.init("Change", .diff(replacementDiff(old: old, new: new))))
            shown.formUnion(["old_string", "new_string"])
        } else if input.arguments["file_path"] != nil, let text = input.arguments["content"]?.stringValue {
            sections.append(.init("Content", .code(text)))
            shown.insert("content")
        }
        let rest = input.argumentNames.filter { !shown.contains($0) }.compactMap { name in
            input.arguments[name].map { ActivityPreview.Fact(name, display($0)) }
        }
        if !rest.isEmpty { sections.insert(.init("Input", .facts(rest)), at: 0) }
        return sections
    }

    private static func output(_ result: ToolTimelinePayload) -> [ActivityPreview.Section] {
        var sections: [ActivityPreview.Section] = []
        let fields = result.content?.objectValue
        // The edit as Claude Code applied it, when it recorded one.
        if let hunks = fields?["toolUseResult"]?["structuredPatch"]?.arrayValue, !hunks.isEmpty {
            sections.append(.init("Diff", .diff(patchDiff(hunks))))
        }
        if let text = ToolResultText.stored(result.content), !text.isEmpty {
            sections.append(.init(result.status == .failed ? "Error" : "Output", .code(text)))
        }
        for block in fields?["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "image" {
            if let data = block["source"]?["data"]?.text { sections.append(.init("Image", .image(.base64(data)))) }
        }
        return sections
    }

    private static func codexItem(
        _ item: CodexItemShape, failed: Bool
    ) -> ([ActivityPreview.Fact], [ActivityPreview.Section]) {
        var facts: [ActivityPreview.Fact] = []
        var sections: [ActivityPreview.Section] = []
        switch item {
        case let .command(command):
            sections.append(.init("Command", .code("$ " + command.commandLine)))
            if let output = command.output, !output.isEmpty { sections.append(.init("Output", .code(output))) }
            if let code = command.exitCode { facts.append(.init("Exit code", String(code))) }
            if let directory = command.workingDirectory { facts.append(.init("Directory", directory)) }

        case let .fileChange(change):
            for file in change.files {
                let verb = switch file.kind {
                case .add: "Created"
                case .delete: "Deleted"
                case .update: "Edited"
                }
                let body: ActivityPreview.Body = file.unifiedDiff.map { .diff($0) } ?? .code(file.content ?? "")
                sections.append(.init("\(verb) · \(file.path)", body))
            }

        case let .imageView(path):
            facts.append(.init("Path", path))
            sections.append(.init("Image", .image(.file(path: path))))

        case let .mcpToolCall(call):
            if let arguments = call.arguments?.objectValue, !arguments.isEmpty {
                sections.append(.init("Input", .facts(arguments.keys.sorted().map { .init($0, display(arguments[$0]!)) })))
            }
            if let text = call.resultText, !text.isEmpty {
                sections.append(.init(failed ? "Error" : "Output", .code(text)))
            }

        case let .webSearch(search):
            let queries = search.queries.isEmpty ? [search.query].compactMap { $0 } : search.queries
            switch search.action {
            case let .openPage(url):
                facts.append(.init("Action", "Open page"))
                if let url = url ?? search.query { sections.append(.init("Page", .links([.init(title: url, url: url, detail: nil)]))) }
            case let .findInPage(pattern):
                facts.append(.init("Action", "Find in page"))
                if let pattern { sections.append(.init("Pattern", .prose(pattern))) }
            case .search, .other:
                facts.append(.init("Action", "Search"))
                if !queries.isEmpty { sections.append(.init("Queries", .prose(queries.joined(separator: "\n")))) }
            }
            let links = search.results.compactMap { result -> ActivityPreview.Link? in
                guard let title = result.title ?? result.url else { return nil }
                return .init(title: title, url: result.url, detail: result.snippet)
            }
            if !links.isEmpty { sections.append(.init("Results", .links(links))) }

        case let .imageGeneration(generation):
            if let path = generation.savedPath { facts.append(.init("Saved to", path)) }
            if let image = generation.imageBase64 {
                sections.append(.init("Image", .image(.base64(image))))
            } else if let path = generation.savedPath {
                sections.append(.init("Image", .image(.file(path: path))))
            }
            if let prompt = generation.revisedPrompt { sections.append(.init("Prompt", .prose(prompt))) }

        case let .other(_, fields):
            let shown = fields.keys.sorted().filter { $0 != "type" && $0 != "id" }
            if !shown.isEmpty { sections.append(.init("Record", .facts(shown.map { .init($0, display(fields[$0]!)) }))) }
        }
        return (facts, sections)
    }

    // MARK: - Context / configuration

    /// A record's content as it is: its text, or its fields one by one.
    private static func record(_ content: JSONValue?) -> [ActivityPreview.Section] {
        switch content {
        case let .string(text):
            return text.isEmpty ? [] : [.init("Content", .prose(text))]
        case let .object(fields):
            guard !fields.isEmpty else { return [] }
            return [.init("Content", .facts(fields.keys.sorted().map { .init($0, display(fields[$0]!)) }))]
        case let .array(values):
            return values.isEmpty ? [] : [.init("Content", .code(display(.array(values))))]
        case .number, .boolean, .null, nil:
            return []
        }
    }

    // MARK: - Rendering of values

    /// A value as a person reads it: text as it is, anything structured as
    /// indented JSON.
    static func display(_ value: JSONValue) -> String {
        switch value {
        case let .string(text):
            return text
        case let .boolean(flag):
            return flag ? "true" : "false"
        case .null:
            return "null"
        case .number, .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }

    /// An `old_string` → `new_string` replacement as a diff: what goes, then
    /// what comes.
    static func replacementDiff(old: String, new: String) -> String {
        let removed = old.split(separator: "\n", omittingEmptySubsequences: false).map { "-" + $0 }
        let added = new.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }
        return (removed + added).joined(separator: "\n")
    }

    /// Claude Code's `structuredPatch` hunks as unified diff text.
    static func patchDiff(_ hunks: [JSONValue]) -> String {
        hunks.map { hunk -> String in
            func number(_ key: String) -> String { hunk[key]?.int64Value.map(String.init) ?? "0" }
            let header = "@@ -\(number("oldStart")),\(number("oldLines")) +\(number("newStart")),\(number("newLines")) @@"
            let lines = hunk["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return ([header] + lines).joined(separator: "\n")
        }.joined(separator: "\n")
    }
}
