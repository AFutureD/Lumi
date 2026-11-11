import Foundation
import Testing
import Transport
@testable import Core

// Opening a row reads its records for a person: both halves of a tool pair,
// each record shape shown as what it is.

private let session = SessionID("s")
private let at = Date(timeIntervalSince1970: 1_700_000_000)

private func item(_ id: String, _ offset: TimeInterval, _ payload: TimelinePayload, truncated: Bool? = nil) -> TimelineItem {
    TimelineItem(
        id: TimelineItemID(id), sessionID: session, turnID: TurnID("t"),
        occurredAt: at.addingTimeInterval(offset), payload: payload, truncated: truncated
    )
}

private func preview(opening index: Int, _ items: [TimelineItem]) -> ActivityPreview {
    let rows = TimelineProjection.rows(from: items)
    return ActivityPreviewBuilder.make(for: rows[index], among: rows)
}

private func section(_ preview: ActivityPreview, _ title: String) -> ActivityPreview.Body? {
    preview.sections.first { $0.title == title }?.body
}

@Test func aCallAndItsResultOpenAsOnePreviewFromEitherRow() {
    let items = [
        item("call", 0, .tool(ToolTimelinePayload(
            name: "Bash",
            content: .object(["command": .string("git status"), "description": .string("Show working tree status"), "timeout": .number(5000)]),
            status: .started, toolUseID: "tu"
        ))),
        item("other", 1, .message(MessageTimelinePayload(role: .assistant, text: "**done**"))),
        item("result", 2, .tool(ToolTimelinePayload(
            name: "Bash",
            content: .object(["content": .string("On branch main\nnothing to commit"), "toolUseResult": .object(["stdout": .string("…")])]),
            status: .succeeded, toolUseID: "tu"
        ))),
    ]
    let fromCall = preview(opening: 0, items)
    let fromResult = preview(opening: 2, items)
    #expect(fromCall.items.map(\.id.rawValue) == ["call", "result"])
    #expect(fromResult.items == fromCall.items)
    #expect(fromCall.sections == fromResult.sections)
    #expect(fromCall.title == "Bash · Show working tree status")
    #expect(section(fromCall, "Command") == .code("$ git status"))
    #expect(section(fromCall, "Input") == .facts([.init("description", "Show working tree status"), .init("timeout", "5000")]))
    #expect(section(fromCall, "Output") == .code("On branch main\nnothing to commit"))
    #expect(fromCall.facts.first == .init("Status", "Succeeded"))

    // A message opens alone, as the Markdown it was written in.
    let message = preview(opening: 1, items)
    #expect(message.items.map(\.id.rawValue) == ["other"])
    #expect(message.sections == [.init("Message", .markdown("**done**"))])
}

@Test func aCallWithoutAResultIsStillRunning() {
    let running = preview(opening: 0, [
        item("call", 0, .tool(ToolTimelinePayload(name: "Bash", content: .object(["command": .string("sleep 60")]), status: .started, toolUseID: "tu"))),
    ])
    #expect(running.facts == [.init("Status", "Running")])
    #expect(running.sections == [.init("Command", .code("$ sleep 60"))])
}

@Test func anEditShowsItsDiffAndAFailureItsError() {
    let edit = preview(opening: 0, [
        item("call", 0, .tool(ToolTimelinePayload(
            name: "Edit",
            content: .object(["file_path": .string("/repo/a.swift"), "old_string": .string("let a = 1"), "new_string": .string("let a = 2\nlet b = 3")]),
            status: .started, toolUseID: "tu"
        ))),
        item("result", 1, .tool(ToolTimelinePayload(
            name: "Edit",
            content: .object([
                "content": .string("The file has been updated."),
                "toolUseResult": .object(["structuredPatch": .array([.object([
                    "oldStart": .number(4), "oldLines": .number(1), "newStart": .number(4), "newLines": .number(2),
                    "lines": .array([.string("-let a = 1"), .string("+let a = 2"), .string("+let b = 3")]),
                ])])]),
            ]),
            status: .succeeded, toolUseID: "tu"
        ))),
    ])
    #expect(section(edit, "Change") == .diff("-let a = 1\n+let a = 2\n+let b = 3"))
    #expect(section(edit, "Diff") == .diff("@@ -4,1 +4,2 @@\n-let a = 1\n+let a = 2\n+let b = 3"))
    #expect(section(edit, "Input") == .facts([.init("file_path", "/repo/a.swift")]))

    let failed = preview(opening: 0, [
        item("result", 1, .tool(ToolTimelinePayload(name: "Bash", content: .string("permission denied"), status: .failed, toolUseID: "tu")))
    ])
    #expect(failed.facts.first == .init("Status", "Failed"))
    #expect(section(failed, "Error") == .code("permission denied"))
}

@Test func aScreenshotResultShowsTheImage() {
    let shot = preview(opening: 0, [
        item("result", 0, .tool(ToolTimelinePayload(
            name: "Read",
            content: .object(["content": .array([.object([
                "type": .string("image"),
                "source": .object(["type": .string("base64"), "media_type": .string("image/png"), "data": .string("AAAA")]),
            ])])]),
            status: .succeeded, toolUseID: "tu"
        ))),
    ])
    #expect(section(shot, "Image") == .image(.base64("AAAA")))
}

@Test func aCodexCommandShowsWhatRanAndHowItEnded() {
    let command = preview(opening: 0, [
        item("codex_item:s:exec-1", 0, .tool(ToolTimelinePayload(
            name: "Shell",
            content: .object([
                "type": .string("CommandExecution"),
                "command": .array([.string("/bin/zsh"), .string("-lc"), .string("curl -L https://example.com")]),
                "cwd": .string("file:///repo"),
                "parsed_cmd": .array([.object(["type": .string("unknown"), "cmd": .string("curl -L https://example.com")])]),
                "status": .string("failed"), "exit_code": .number(56), "aggregated_output": .string("curl: (56)"),
            ]),
            status: .failed, durationMilliseconds: 486, toolUseID: "exec-1"
        ))),
    ])
    #expect(command.title == "Run · curl -L https://example.com · exit 56 · 486ms")
    #expect(command.facts == [
        .init("Status", "Failed"), .init("Exit code", "56"), .init("Directory", "/repo"), .init("Duration", "486ms"),
    ])
    #expect(command.sections == [.init("Command", .code("$ curl -L https://example.com")), .init("Output", .code("curl: (56)"))])
}

@Test func theScriptWrapperShowsItsSourceAndItsOutput() {
    let items = [
        item("tool:s:call_1:call", 0, .tool(ToolTimelinePayload(name: "exec", content: .string("text(await tools.exec_command({cmd:\"ls\"}))"), status: .started, toolUseID: "call_1"))),
        item("tool:s:call_1:result", 3, .tool(ToolTimelinePayload(name: "exec", content: .string("Script completed\nOutput:\n"), status: .succeeded, toolUseID: "call_1"))),
    ]
    let wrapper = preview(opening: 1, items)
    #expect(wrapper.title == "exec · call_1")
    #expect(wrapper.sections == [
        .init("Script", .code("text(await tools.exec_command({cmd:\"ls\"}))")),
        .init("Output", .code("Script completed\nOutput:\n")),
    ])
}

@Test func codexFileChangesWebSearchesAndImagesReadTheirOwnFields() {
    let change = preview(opening: 0, [
        item("codex_item:s:exec-2", 0, .tool(ToolTimelinePayload(
            name: "Apply patch",
            content: .object(["type": .string("FileChange"), "changes": .object([
                "/repo/a.md": .object(["type": .string("update"), "unified_diff": .string("@@\n-a\n+b\n")]),
                "/repo/new.txt": .object(["type": .string("add"), "content": .string("hello\n")]),
            ])]),
            status: .succeeded, toolUseID: "exec-2"
        ))),
    ])
    #expect(change.sections == [
        .init("Edited · /repo/a.md", .diff("@@\n-a\n+b\n")),
        .init("Created · /repo/new.txt", .code("hello\n")),
    ])

    let search = preview(opening: 0, [
        item("codex_item:s:exec-3", 0, .tool(ToolTimelinePayload(
            name: "web.search",
            content: .object([
                "type": .string("Extension"), "kind": .string("web.search"), "query": .string("tsnet ..."),
                "action": .object(["type": .string("search"), "queries": .array([.string("tsnet only"), .string("tsnet ssh")])]),
                "results": .array([.object(["title": .string("Tailscale SSH"), "url": .string("https://tailscale.com/kb/ssh"), "snippet": .string("When you enable")])]),
            ]),
            status: .succeeded, toolUseID: "exec-3"
        ))),
    ])
    #expect(section(search, "Queries") == .prose("tsnet only\ntsnet ssh"))
    #expect(section(search, "Results") == .links([.init(title: "Tailscale SSH", url: "https://tailscale.com/kb/ssh", detail: "When you enable")]))

    let image = preview(opening: 0, [
        item("codex_item:s:exec-4", 0, .tool(ToolTimelinePayload(
            name: "View image", content: .object(["type": .string("ImageView"), "path": .string("/tmp/a.png")]),
            status: .succeeded, toolUseID: "exec-4"
        ))),
    ])
    #expect(section(image, "Image") == .image(.file(path: "/tmp/a.png")))
}

@Test func aContextRecordShowsItsTextOrItsFields() {
    let text = preview(opening: 0, [item("c", 0, .context(ContextTimelinePayload(kind: "system_reminder", content: .string("Remember the rules"))))])
    #expect(text.sections == [.init("Content", .prose("Remember the rules"))])

    let fields = preview(opening: 0, [item("k", 0, .config(ConfigTimelinePayload(
        kind: "cwd_changed", content: .object(["new_cwd": .string("/repo"), "old_cwd": .string("/")])
    )))])
    #expect(fields.sections == [.init("Content", .facts([.init("new_cwd", "/repo"), .init("old_cwd", "/")]))])

    let empty = preview(opening: 0, [item("e", 0, .context(ContextTimelinePayload(kind: "stop_hook_summary")))])
    #expect(empty.sections.isEmpty)
    #expect(empty.title == "stop hook summary")
}

@Test func aPreviewNamesTheRecordsHeldTrimmedAndRebuildsFromWholeOnes() {
    let trimmed = item("result", 0, .tool(ToolTimelinePayload(name: "Bash", content: .string("cut…"), status: .succeeded, toolUseID: "tu")), truncated: true)
    let held = preview(opening: 0, [trimmed])
    #expect(held.truncatedItemIDs == [TimelineItemID("result")])

    let whole = item("result", 0, .tool(ToolTimelinePayload(name: "Bash", content: .string("the whole output"), status: .succeeded, toolUseID: "tu")))
    let rebuilt = ActivityPreviewBuilder.make(tag: held.tag, title: held.title, items: [whole])
    #expect(rebuilt.truncatedItemIDs.isEmpty)
    #expect(section(rebuilt, "Output") == .code("the whole output"))
}

@Test func rawDataPrintsDatesAsDates() {
    let record = item("m", 0, .message(MessageTimelinePayload(role: .user, text: "hi")))
    let raw = SessionPagePresentationBuilder.rawData(for: [record])
    #expect(raw.contains("\"occurredAt\" : \"2023-11-14T22:13:20.000Z\""))
}
