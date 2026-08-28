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

    let wrapper = try #require(AaaS.detect(environment: ["PASEO_AGENT_ID": agentID], homeDirectory: home))
    #expect(wrapper.kind == .paseo)
    #expect(wrapper.agentID == agentID)
    #expect(wrapper.title == "你会使用 computer use 么？")
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

    let wrapper = try #require(AaaS.detect(
        environment: ["PASEO_AGENT_ID": agentID, "PASEO_HOME": paseoHome.path],
        homeDirectory: home
    ))
    #expect(wrapper.title == "from paseo home")
}

@Test func paseoDetectsWithoutATitleWhenTheStoreIsMissingOrMalformed() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let agentID = "aaaaaaaa-0000-0000-0000-000000000002"

    // No ~/.paseo at all.
    var wrapper = try #require(AaaS.detect(environment: ["PASEO_AGENT_ID": agentID], homeDirectory: home))
    #expect(wrapper.kind == .paseo)
    #expect(wrapper.title == nil)

    // Malformed JSON.
    try writePaseoAgent(home: home, workspace: "ws", agentID: agentID, json: "{not json")
    wrapper = try #require(AaaS.detect(environment: ["PASEO_AGENT_ID": agentID], homeDirectory: home))
    #expect(wrapper.title == nil)

    // Valid JSON, no usable title.
    try writePaseoAgent(home: home, workspace: "ws", agentID: agentID, json: #"{"title":"  "}"#)
    wrapper = try #require(AaaS.detect(environment: ["PASEO_AGENT_ID": agentID], homeDirectory: home))
    #expect(wrapper.title == nil)
}

@Test func raftTitleIsTheQuotedNameOnTheSystemPromptFirstLine() throws {
    let transport = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: transport) }
    try """
    You are "Fable", an AI agent in Raft (former Slock) — a collaborative platform.

    ## Who you are
    Not "someone else".
    """.write(to: transport.appendingPathComponent("claude-system-prompt.md"), atomically: true, encoding: .utf8)

    let wrapper = try #require(AaaS.detect(
        environment: [
            "SLOCK_AGENT_ID": "65e8e001-1d5e-4fe0-b977-aac119612fc6",
            "SLOCK_CLI_TRANSPORT_DIR": transport.path,
        ],
        homeDirectory: transport
    ))
    #expect(wrapper.kind == .raft)
    #expect(wrapper.agentID == "65e8e001-1d5e-4fe0-b977-aac119612fc6")
    #expect(wrapper.title == "Fable")
}

@Test func raftDetectsWithoutATitleWhenThePromptIsMissingOrUnrecognized() throws {
    let transport = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: transport) }
    let environment = [
        "SLOCK_AGENT_ID": "65e8e001-1d5e-4fe0-b977-aac119612fc6",
        "SLOCK_CLI_TRANSPORT_DIR": transport.path,
    ]

    // No prompt file.
    var wrapper = try #require(AaaS.detect(environment: environment, homeDirectory: transport))
    #expect(wrapper.kind == .raft)
    #expect(wrapper.title == nil)

    // First line without the marker.
    try "A different opening.\nYou are \"Fable\", but on line two."
        .write(to: transport.appendingPathComponent("claude-system-prompt.md"), atomically: true, encoding: .utf8)
    wrapper = try #require(AaaS.detect(environment: environment, homeDirectory: transport))
    #expect(wrapper.title == nil)

    // Transport dir env missing entirely.
    wrapper = try #require(AaaS.detect(environment: ["SLOCK_AGENT_ID": "x"], homeDirectory: transport))
    #expect(wrapper.title == nil)
}

@Test func detectionPrefersPaseoAndIgnoresUnrelatedEnvironments() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(AaaS.detect(environment: [:], homeDirectory: home) == nil)
    #expect(AaaS.detect(environment: ["CLAUDE_PROJECT_DIR": "/x"], homeDirectory: home) == nil)
    #expect(AaaS.detect(environment: ["PASEO_AGENT_ID": "  "], homeDirectory: home) == nil)

    let both = try #require(AaaS.detect(
        environment: ["PASEO_AGENT_ID": "p-1", "SLOCK_AGENT_ID": "s-1"],
        homeDirectory: home
    ))
    #expect(both.kind == .paseo)
}
