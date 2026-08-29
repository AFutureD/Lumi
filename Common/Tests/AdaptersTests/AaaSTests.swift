import Transport
import Foundation
import Testing
@testable import Adapters

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("aaas-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writePaseoAgent(home: URL, workspace: String, agentID: String, json: String) throws {
    let dir = home.appendingPathComponent(".paseo/agents/\(workspace)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try json.write(to: dir.appendingPathComponent("\(agentID).json"), atomically: true, encoding: .utf8)
}

@Test func paseoTitleIsReadFromTheAgentJSON() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let agentID = "14d83292-45c5-45dd-9825-be971183e17b"
    try writePaseoAgent(
        home: home, workspace: "Users-x-proj", agentID: agentID,
        json: #"{"id":"\#(agentID)","provider":"claude","title":"你会使用 computer use 么？"}"#
    )
    // A sibling agent in another workspace must not shadow the lookup.
    try writePaseoAgent(
        home: home, workspace: "Users-x-other", agentID: "00000000-0000-0000-0000-000000000000",
        json: #"{"title":"other"}"#
    )

    let aaas = AaaS.detect(provider: .claude, environment: ["PASEO_AGENT_ID": agentID], homeDirectory: home)
    #expect(aaas.kind == .paseo)
    #expect(aaas.agentID == agentID)
    #expect(aaas.title == "你会使用 computer use 么？")
}

@Test func paseoHomeEnvironmentOverridesTheDefaultRoot() throws {
    let home = try temporaryDirectory()
    let paseoHome = try temporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: paseoHome)
    }
    let agentID = "aaaaaaaa-0000-0000-0000-000000000001"
    let dir = paseoHome.appendingPathComponent("agents/ws", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try #"{"title":"from paseo home"}"#
        .write(to: dir.appendingPathComponent("\(agentID).json"), atomically: true, encoding: .utf8)

    let aaas = AaaS.detect(
        provider: .claude,
        environment: ["PASEO_AGENT_ID": agentID, "PASEO_HOME": paseoHome.path],
        homeDirectory: home
    )
    #expect(aaas.title == "from paseo home")
}

@Test func paseoDetectsWithoutATitleWhenTheStoreIsMissingOrMalformed() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let agentID = "aaaaaaaa-0000-0000-0000-000000000002"

    // No ~/.paseo at all.
    var aaas = AaaS.detect(provider: .claude, environment: ["PASEO_AGENT_ID": agentID], homeDirectory: home)
    #expect(aaas.kind == .paseo)
    #expect(aaas.title == nil)

    // Malformed JSON.
    try writePaseoAgent(home: home, workspace: "ws", agentID: agentID, json: "{not json")
    aaas = AaaS.detect(provider: .claude, environment: ["PASEO_AGENT_ID": agentID], homeDirectory: home)
    #expect(aaas.title == nil)

    // Valid JSON, no usable title.
    try writePaseoAgent(home: home, workspace: "ws", agentID: agentID, json: #"{"title":"  "}"#)
    aaas = AaaS.detect(provider: .claude, environment: ["PASEO_AGENT_ID": agentID], homeDirectory: home)
    #expect(aaas.title == nil)
}

@Test func raftTitleIsTheQuotedNameOnTheSystemPromptFirstLine() throws {
    let transport = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: transport) }
    try """
    You are "Fable", an AI agent in Raft (former Slock) — a collaborative platform.

    ## Who you are
    Not "someone else".
    """.write(to: transport.appendingPathComponent("claude-system-prompt.md"), atomically: true, encoding: .utf8)

    let aaas = AaaS.detect(
        provider: .claude,
        environment: [
            "SLOCK_AGENT_ID": "65e8e001-1d5e-4fe0-b977-aac119612fc6",
            "SLOCK_CLI_TRANSPORT_DIR": transport.path,
        ],
        homeDirectory: transport
    )
    #expect(aaas.kind == .raft)
    #expect(aaas.agentID == "65e8e001-1d5e-4fe0-b977-aac119612fc6")
    #expect(aaas.title == "Fable")
}

@Test func raftDetectsOnSlockHomeAloneWithNoAgentIDAndNoTitle() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    // Raft's daemon utility sessions (its account-usage poll) inherit only
    // SLOCK_HOME — no agent id, no transport dir.
    let aaas = AaaS.detect(
        provider: .claude,
        environment: ["SLOCK_HOME": "/Users/x/.slock", "TERM_PROGRAM": "ghostty", "CLAUDE_CODE_ENTRYPOINT": "sdk-cli"],
        homeDirectory: home
    )
    #expect(aaas.kind == .raft)
    #expect(aaas.agentID == nil)
    #expect(aaas.title == nil)
    #expect(aaas.terminalProgram == "ghostty")
}

@Test func raftDetectsWithoutATitleWhenThePromptIsMissingOrUnrecognized() throws {
    let transport = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: transport) }
    let environment = [
        "SLOCK_AGENT_ID": "65e8e001-1d5e-4fe0-b977-aac119612fc6",
        "SLOCK_CLI_TRANSPORT_DIR": transport.path,
    ]

    // No prompt file.
    var aaas = AaaS.detect(provider: .claude, environment: environment, homeDirectory: transport)
    #expect(aaas.kind == .raft)
    #expect(aaas.title == nil)

    // First line without the marker.
    try "A different opening.\nYou are \"Fable\", but on line two."
        .write(to: transport.appendingPathComponent("claude-system-prompt.md"), atomically: true, encoding: .utf8)
    aaas = AaaS.detect(provider: .claude, environment: environment, homeDirectory: transport)
    #expect(aaas.title == nil)

    // Transport dir env missing entirely.
    aaas = AaaS.detect(provider: .claude, environment: ["SLOCK_AGENT_ID": "x"], homeDirectory: transport)
    #expect(aaas.title == nil)
}

// Detection is total: every session belongs to exactly one AaaS. The codex
// engine splits on the OpenAI desktop app's bundle identifier; everything
// else — terminal CLI, IDE extensions — is the Codex CLI.
@Test func codexSessionsSplitBetweenChatGPTAppAndCodexCLI() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }

    #expect(AaaS.detect(provider: .codex, environment: ["__CFBundleIdentifier": "com.openai.codex"], homeDirectory: home).kind == .chatgpt)
    #expect(AaaS.detect(provider: .codex, environment: ["__CFBundleIdentifier": "com.openai.chat"], homeDirectory: home).kind == .chatgpt)
    #expect(AaaS.detect(provider: .codex, environment: ["__CFBundleIdentifier": "com.microsoft.VSCode"], homeDirectory: home).kind == .codex)
    #expect(AaaS.detect(provider: .codex, environment: ["__CFBundleIdentifier": "com.apple.Terminal"], homeDirectory: home).kind == .codex)
    #expect(AaaS.detect(provider: .codex, environment: [:], homeDirectory: home).kind == .codex)
}

// The claude engine splits on the desktop entrypoint (either signal is
// enough); cli / SDK entrypoints and a bare environment are Claude Code.
@Test func claudeSessionsSplitBetweenDesktopAppAndClaudeCode() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }

    #expect(AaaS.detect(provider: .claude, environment: ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop"], homeDirectory: home).kind == .claudeDesktop)
    #expect(AaaS.detect(provider: .claude, environment: ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop-3p"], homeDirectory: home).kind == .claudeDesktop)
    #expect(AaaS.detect(provider: .claude, environment: ["__CFBundleIdentifier": "com.anthropic.claudefordesktop"], homeDirectory: home).kind == .claudeDesktop)
    #expect(AaaS.detect(provider: .claude, environment: ["CLAUDE_CODE_ENTRYPOINT": "cli"], homeDirectory: home).kind == .claudeCode)
    #expect(AaaS.detect(provider: .claude, environment: ["CLAUDE_CODE_ENTRYPOINT": "sdk-ts"], homeDirectory: home).kind == .claudeCode)
    #expect(AaaS.detect(provider: .claude, environment: [:], homeDirectory: home).kind == .claudeCode)
    // Historic assertion, deliberately inverted: a bare CLAUDE_PROJECT_DIR
    // used to detect nothing; under the total two-layer model it is a plain
    // Claude Code session.
    #expect(AaaS.detect(provider: .claude, environment: ["CLAUDE_PROJECT_DIR": "/x"], homeDirectory: home).kind == .claudeCode)
}

@Test func terminalProgramIsCapturedOnEveryKind() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }

    #expect(AaaS.detect(provider: .claude, environment: ["CLAUDE_CODE_ENTRYPOINT": "cli", "TERM_PROGRAM": "ghostty"], homeDirectory: home).terminalProgram == "ghostty")
    #expect(AaaS.detect(provider: .codex, environment: ["TERM_PROGRAM": "Apple_Terminal"], homeDirectory: home).terminalProgram == "Apple_Terminal")
    #expect(AaaS.detect(provider: .claude, environment: ["PASEO_AGENT_ID": "p-1", "TERM_PROGRAM": "vscode"], homeDirectory: home).terminalProgram == "vscode")
    #expect(AaaS.detect(provider: .claude, environment: ["CLAUDE_CODE_ENTRYPOINT": "cli", "TERM_PROGRAM": "  "], homeDirectory: home).terminalProgram == nil)
    #expect(AaaS.detect(provider: .codex, environment: [:], homeDirectory: home).terminalProgram == nil)
}

// Wrappers may themselves run inside a desktop app or terminal; their
// markers are the most specific signal and always win.
@Test func wrapperMarkersOutrankDesktopAndTerminalSignals() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }

    let both = AaaS.detect(
        provider: .claude,
        environment: ["PASEO_AGENT_ID": "p-1", "SLOCK_AGENT_ID": "s-1"],
        homeDirectory: home
    )
    #expect(both.kind == .paseo)

    let paseoInsideDesktop = AaaS.detect(
        provider: .claude,
        environment: ["PASEO_AGENT_ID": "p-1", "CLAUDE_CODE_ENTRYPOINT": "claude-desktop"],
        homeDirectory: home
    )
    #expect(paseoInsideDesktop.kind == .paseo)

    let raftOverChatGPT = AaaS.detect(
        provider: .codex,
        environment: ["SLOCK_AGENT_ID": "s-1", "__CFBundleIdentifier": "com.openai.codex"],
        homeDirectory: home
    )
    #expect(raftOverChatGPT.kind == .raft)

    // A blank wrapper id is no marker at all.
    #expect(AaaS.detect(provider: .codex, environment: ["PASEO_AGENT_ID": "  "], homeDirectory: home).kind == .codex)
}

@Test func ownershipDropsTheTransientTitle() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let agentID = "aaaaaaaa-0000-0000-0000-000000000003"
    try writePaseoAgent(home: home, workspace: "ws", agentID: agentID, json: #"{"title":"named"}"#)

    let aaas = AaaS.detect(
        provider: .codex,
        environment: ["PASEO_AGENT_ID": agentID, "TERM_PROGRAM": "ghostty"],
        homeDirectory: home
    )
    #expect(aaas.title == "named")
    let ownership = aaas.ownership
    #expect(ownership == SessionAaaS(kind: .paseo, agentID: agentID, terminalProgram: "ghostty"))
    #expect(!ownership.allowsNativeTitle)
    #expect(SessionAaaS(kind: .chatgpt).allowsNativeTitle)
    #expect(SessionAaaS(kind: .claudeCode).allowsNativeTitle)
}
