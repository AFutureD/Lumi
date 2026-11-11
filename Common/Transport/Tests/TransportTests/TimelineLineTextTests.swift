import Foundation
import Testing
@testable import Transport

// The Activity line is read from the record at display time. These pin the
// reading of every record shape the agents write.

private func call(_ name: String, _ content: JSONValue?, id: String? = "id1") -> String {
    TimelineLineText.tool(ToolTimelinePayload(name: name, content: content, status: .started, toolUseID: id), name: name)
}

private func result(
    _ name: String, _ content: JSONValue?, failed: Bool = false, milliseconds: Int64? = nil, id: String? = "id1"
) -> String {
    TimelineLineText.tool(
        ToolTimelinePayload(
            name: name, content: content, status: failed ? .failed : .succeeded,
            durationMilliseconds: milliseconds, toolUseID: id
        ),
        name: name
    )
}

// MARK: - Calls

@Test func aCallShowsItsDescriptionBeforeItsCommand() {
    let input: JSONValue = .object(["command": .string("ls -la"), "description": .string("List files in current directory")])
    #expect(call("Bash", input) == "Bash · List files in current directory")
}

@Test func aCallWithoutDescriptionShowsWhatItActsOn() {
    #expect(call("Bash", .object(["command": .string("git status\necho done")])) == "Bash · git status")
    #expect(call("Read", .object(["file_path": .string("/repo/a.swift"), "limit": .number(20)])) == "Read · /repo/a.swift")
    #expect(call("WebSearch", .object(["query": .string("swift 6.2")])) == "WebSearch · swift 6.2")
}

@Test func aCallWithNoTellingArgumentListsItsArgumentNames() {
    let input: JSONValue = .object(["pid": .number(1), "window_id": .number(2), "steps": .array([]), "observe": .object([:]), "zeta": .null])
    #expect(call("mcp__cua__run_steps", input) == "mcp__cua__run_steps · observe, pid, steps, window_id")
    #expect(call("Tool", nil) == "Tool")
}

@Test func argumentsEncodedAsAJSONStringReadAsArguments() {
    #expect(call("js", .string(#"{"code":"await page.goto('x')","title":"Open the page"}"#)) == "js · Open the page")
    #expect(call("shell", .string("first line\nsecond line")) == "shell · first line")
}

// MARK: - Results

@Test func aClaudeResultShowsItsFirstLineOfText() {
    let transcript: JSONValue = .object(["content": .string("\nBuild complete!\nmore"), "toolUseResult": .object(["stdout": .string("ignored")])])
    #expect(result("Bash", transcript) == "Bash · Build complete!")
    let blocks: JSONValue = .object(["content": .array([.object(["type": .string("text"), "text": .string("from a block")])])])
    #expect(result("Bash", blocks) == "Bash · from a block")
    let imageOnly: JSONValue = .object([
        "content": .array([.object(["type": .string("image")])]),
        "toolUseResult": .object(["stdout": .string("fallback stdout")]),
    ])
    #expect(result("Read", imageOnly) == "Read · fallback stdout")
    let hook: JSONValue = .object(["tool_response": .object(["output": .string("hook output")])])
    #expect(result("Bash", hook, milliseconds: 7_100) == "Bash · hook output · 7.1s")
}

@Test func aFailedResultWithoutTextSaysFailed() {
    #expect(result("Bash", nil, failed: true) == "Bash · failed")
    #expect(result("Bash", .string("permission denied"), failed: true, milliseconds: 20) == "Bash · permission denied · 20ms")
}

// MARK: - Codex

@Test func theScriptWrapperShowsItsToolUseID() {
    #expect(call("exec", .string("const r = await tools.exec_command({cmd:\"ls\"});"), id: "call_abc") == "exec · call_abc")
    #expect(result("exec", .string("Script completed\nWall time 3.3 seconds"), id: "call_abc") == "exec · call_abc")
    // A tool of the same name that takes named arguments is not the wrapper.
    #expect(call("exec", .object(["command": .string("ls")]), id: "call_abc") == "exec · ls")
}

private func command(_ argv: [String], parsed: [JSONValue], status: String = "completed", exit: Int = 0) -> JSONValue {
    .object([
        "type": .string("CommandExecution"),
        "id": .string("exec-1"),
        "command": .array(argv.map(JSONValue.string)),
        "cwd": .string("file:///repo"),
        "parsed_cmd": .array(parsed),
        "status": .string(status),
        "exit_code": .number(Decimal(exit)),
        "aggregated_output": .string("out"),
    ])
}

@Test func aCommandShowsWhatCodexReadOutOfIt() {
    let read: JSONValue = .object(["type": .string("read"), "cmd": .string("cat SKILL.md"), "name": .string("SKILL.md"), "path": .string("/x/SKILL.md")])
    #expect(result("Shell", command(["/bin/zsh", "-lc", "cat SKILL.md"], parsed: [read])) == "Read · SKILL.md")

    let second: JSONValue = .object(["type": .string("read"), "cmd": .string("nl b"), "name": .string("B.swift"), "path": .string("B.swift")])
    let search: JSONValue = .object(["type": .string("search"), "cmd": .string("rg health"), "query": .string("health"), "path": .string("Sources")])
    let list: JSONValue = .object(["type": .string("list_files"), "cmd": .string("rg --files"), "path": .string("Sources")])
    #expect(
        result("Shell", command(["/bin/zsh", "-lc", "…"], parsed: [read, second, search, list]), milliseconds: 1_500)
            == "Read · SKILL.md, B.swift · Search · \"health\" in Sources · List · Sources · 1.5s"
    )
    let bare: JSONValue = .object(["type": .string("search"), "cmd": .string("rg x"), "query": .string("x"), "path": .null])
    #expect(result("Shell", command(["/bin/zsh", "-lc", "rg x"], parsed: [bare])) == "Search · \"x\"")
}

@Test func anUnreadCommandShowsTheCommandWithoutItsShellWrapper() {
    let unknown: JSONValue = .object(["type": .string("unknown"), "cmd": .string("git status --short\ngit diff --stat")])
    #expect(
        result("Shell", command(["/bin/zsh", "-lc", "git status --short\ngit diff --stat"], parsed: [unknown]))
            == "Run · git status --short git diff --stat"
    )
    // No reading recorded: the command itself, unwrapped.
    #expect(result("Shell", command(["/bin/zsh", "-lc", "make build"], parsed: [])) == "Run · make build")
}

@Test func aFailedCommandSaysItsExitCode() {
    let unknown: JSONValue = .object(["type": .string("unknown"), "cmd": .string("curl -L https://example.com")])
    #expect(
        result("Shell", command(["/bin/zsh", "-lc", "curl -L https://example.com"], parsed: [unknown], status: "failed", exit: 56), failed: true, milliseconds: 486)
            == "Run · curl -L https://example.com · exit 56 · 486ms"
    )
}

@Test func aFileChangeCountsItsLines() {
    let update: JSONValue = .object([
        "type": .string("FileChange"),
        "changes": .object(["/repo/docs/model.md": .object([
            "type": .string("update"),
            "unified_diff": .string("--- a\n+++ b\n@@ -1,2 +1,3 @@\n keep\n-old\n+new\n+more\n"),
            "move_path": .null,
        ])]),
        "status": .string("completed"),
    ])
    #expect(result("Apply patch", update) == "Edit · model.md +2 -1")

    let add: JSONValue = .object([
        "type": .string("FileChange"),
        "changes": .object(["/repo/new.txt": .object(["type": .string("add"), "content": .string("a\nb\nc\n")])]),
    ])
    #expect(result("Apply patch", add) == "Create · new.txt +3 -0")

    let many: JSONValue = .object([
        "type": .string("FileChange"),
        "changes": .object([
            "/repo/a": .object(["type": .string("add"), "content": .string("one")]),
            "/repo/b": .object(["type": .string("delete"), "content": .string("x\ny")]),
        ]),
    ])
    #expect(result("Apply patch", many) == "Edit · 2 files +1 -2")
}

@Test func webImageAndMCPItemsReadTheirOwnFields() {
    let open: JSONValue = .object([
        "type": .string("Extension"), "kind": .string("web.search"), "query": .string("https://example.com/docs"),
        "action": .object(["type": .string("openPage"), "url": .string("https://example.com/docs")]),
    ])
    #expect(result("web.search", open) == "Open page · https://example.com/docs")
    let search: JSONValue = .object([
        "type": .string("Extension"), "kind": .string("web.search"), "query": .string("tsnet only ..."),
        "action": .object(["type": .string("search"), "query": .null, "queries": .array([.string("tsnet only"), .string("two")])]),
    ])
    #expect(result("web.search", search) == "Web search · tsnet only ...")
    // A row kept from before the action was recorded has only its query.
    #expect(result("web.search", .object(["type": .string("Extension"), "kind": .string("web.search"), "query": .string("q")])) == "Web search · q")

    #expect(result("View image", .object(["type": .string("ImageView"), "path": .string("/tmp/shots/a.png")])) == "View image · a.png")
    let generated: JSONValue = .object([
        "type": .string("Extension"), "kind": .string("image_gen.generation"), "savedPath": .string("/out/tower.png"),
    ])
    #expect(result("image_gen.generation", generated) == "Generate image · tower.png")

    let mcp: JSONValue = .object([
        "type": .string("McpToolCall"), "server": .string("codex_app"), "tool": .string("set_thread_title"),
        "arguments": .object(["title": .string("[Rex] Remote login")]),
        "result": .object(["content": .array([.object(["type": .string("text"), "text": .string("{\"ok\":true}")])])]),
    ])
    #expect(result("codex_app/set_thread_title", mcp, milliseconds: 880) == "codex_app/set_thread_title · [Rex] Remote login · 880ms")
}

// MARK: - Context / configuration

@Test func contextLinesAreReadFromKindAndContent() {
    #expect(TimelineLineText.context(kind: "base_instructions", content: .object(["text": .string("…")])) == "Base instructions")
    #expect(TimelineLineText.context(kind: "world_state", content: .object([:])) == "World state")
    #expect(TimelineLineText.context(kind: "compacted", content: .object([:])) == "Compaction summary")
    #expect(TimelineLineText.context(kind: "task_notification", content: .string("<task-notification>\nbody")) == "<task-notification>")
    #expect(TimelineLineText.context(kind: "stop_hook_summary", content: nil) == "stop hook summary")
    #expect(
        TimelineLineText.context(kind: "instructions", content: .object(["file_path": .string("/repo/CLAUDE.md"), "load_reason": .string("session_start")]))
            == "CLAUDE.md · session_start"
    )
    #expect(TimelineLineText.context(kind: "instructions", content: .object(["file_path": .string("/repo/CLAUDE.md")])) == "CLAUDE.md")
}

@Test func aClaudeAttachmentReadsWhatItAdds() {
    let delta: JSONValue = .object(["type": .string("deferred_tools_delta"), "addedNames": .array([.string("a"), .string("b")])])
    #expect(TimelineLineText.context(kind: "deferred_tools_delta", content: delta) == "deferred tools delta · 2 tools")
    let file: JSONValue = .object(["type": .string("edited_text_file"), "filename": .string("/repo/a.swift"), "snippet": .string("…")])
    #expect(TimelineLineText.context(kind: "edited_text_file", content: file) == "edited_text_file · /repo/a.swift")
    let listing: JSONValue = .object(["type": .string("skill_listing"), "content": .string("- skill one\n- skill two")])
    #expect(TimelineLineText.context(kind: "skill_listing", content: listing) == "- skill one")
    let plain: JSONValue = .object(["type": .string("hook_success"), "stdout": .string("ok")])
    #expect(TimelineLineText.context(kind: "hook_success", content: plain) == "hook success")
    #expect(TimelineLineText.config(kind: "auto_mode", content: .object(["type": .string("auto_mode"), "bypass": .boolean(false)])) == "auto mode")
}

@Test func configLinesAreReadFromKindAndContent() {
    #expect(TimelineLineText.config(kind: "cwd_changed", content: .object(["new_cwd": .string("/repo"), "old_cwd": .string("/")])) == "/repo")
    #expect(
        TimelineLineText.config(kind: "config_change", content: .object(["file_path": .string("/repo/.claude/settings.json"), "source": .string("project_settings")]))
            == "project_settings · settings.json"
    )
    let turn: JSONValue = .object(["model": .string("gpt-6.1-sol"), "effort": .string("xhigh"), "cwd": .string("/repo"), "turn_id": .string("t")])
    #expect(TimelineLineText.config(kind: "turn_context", content: turn) == "gpt-6.1-sol · xhigh · /repo")
    #expect(TimelineLineText.config(kind: "thread_settings", content: .object(["model": .string("gpt-6.1-sol"), "reasoning_effort": .string("xhigh")])) == "gpt-6.1-sol · xhigh")
    #expect(TimelineLineText.config(kind: "thread_settings", content: .object([:])) == "Thread settings")
}

// MARK: - Trimming keeps the line

@Test func aTrimmedRowKeepsTheFieldsItsLineIsReadFrom() {
    let output = String(repeating: "x", count: 200_000)
    let item = TimelineItem(
        id: TimelineItemID("codex_item:s:exec-1"), sessionID: SessionID("s"), turnID: nil,
        occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
        payload: .tool(ToolTimelinePayload(
            name: "Shell",
            content: .object([
                "type": .string("CommandExecution"),
                "command": .array([.string("/bin/zsh"), .string("-lc"), .string("make test")]),
                "parsed_cmd": .array([.object(["type": .string("unknown"), "cmd": .string("make test")])]),
                "aggregated_output": .string(output),
                "exit_code": .number(0),
                "status": .string("completed"),
            ]),
            status: .succeeded, toolUseID: "exec-1"
        ))
    )
    let trimmed = TimelineContentBudget.trimmed(item)
    #expect(trimmed.isTruncated)
    #expect(TimelineContentBudget.encodedSize(trimmed) <= TimelineContentBudget.maxItemBytes)
    guard case let .tool(tool) = trimmed.payload else { Issue.record("not a tool"); return }
    #expect(TimelineLineText.tool(tool, name: tool.name) == "Run · make test")
    #expect((tool.content?["aggregated_output"]?.stringValue?.utf8.count ?? 0) <= 4 * 1024)
    // Trimming is a pure function of the row: the mirror's "is this that
    // very row, trimmed" check depends on it.
    #expect(TimelineContentBudget.trimmed(item) == trimmed)
}

@Test func aRowTooWideToCutLosesItsContent() {
    // Thousands of short strings: no single one is long enough to cut.
    let wide: JSONValue = .array((0 ..< 20_000).map { .string("entry-\($0)") })
    let item = TimelineItem(
        id: TimelineItemID("c"), sessionID: SessionID("s"), turnID: nil,
        occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
        payload: .context(ContextTimelinePayload(kind: "deferred_tools_record", content: wide))
    )
    let trimmed = TimelineContentBudget.trimmed(item)
    guard case let .context(context) = trimmed.payload else { Issue.record("not context"); return }
    #expect(trimmed.isTruncated)
    #expect(context.content == nil)
    #expect(TimelineLineText.context(kind: context.kind, content: context.content) == "deferred tools record")
}
