import Foundation
import Testing
@testable import Transport

@Test func unknownProtocolValuesAreDecodingErrors() throws {
    // Every end ships together: a value this build does not know is a bug
    // to surface, not something to carry along as a raw string.
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SessionLifecycle.self, from: Data("\"paused_by_provider\"".utf8))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(TimelinePayload.self, from: Data(#"{"type":"future_event"}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(IPCOperation.self, from: Data("\"snapshot_sessions\"".utf8))
    }
}

@Test func transportDatesCarryMillisecondsOnEveryHop() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000.266)
    let encoded = try TransportCoding.makeEncoder().encode([date])
    #expect(String(decoding: encoded, as: UTF8.self) == #"["2023-11-14T22:13:20.266Z"]"#)
    let decoded = try TransportCoding.makeDecoder().decode([Date].self, from: encoded)
    #expect(abs(decoded[0].timeIntervalSince(date)) < 0.001)
    // Whole-second RFC 3339 is still a valid date (the Relay and older rows).
    let plain = try TransportCoding.makeDecoder().decode([Date].self, from: Data(#"["2023-11-14T22:13:20Z"]"#.utf8))
    #expect(plain[0] == Date(timeIntervalSince1970: 1_700_000_000))
}

@Test func frameCodecHandlesPartialAndMultipleFrames() throws {
    let first = Data("first".utf8)
    let second = Data("second".utf8)
    let firstFrame = try LengthPrefixedFrameCodec.encode(first)
    let secondFrame = try LengthPrefixedFrameCodec.encode(second)

    var partial = Data(firstFrame.prefix(5))
    #expect(try LengthPrefixedFrameCodec.decodeAvailableFrames(from: &partial).isEmpty)
    partial.append(firstFrame.dropFirst(5))
    partial.append(secondFrame)

    let decoded = try LengthPrefixedFrameCodec.decodeAvailableFrames(from: &partial)
    #expect(decoded == [first, second])
    #expect(partial.isEmpty)
}

@Test func relayGoldenFixtureMatchesCanonicalRoutingShape() throws {
    let fixture = try TransportGoldenFixtures.relayRoutingV1()
    let frame = try TransportCoding.makeDecoder().decode(RelayRoutingFrame.self, from: fixture)

    #expect(frame.version == .current)
    #expect(frame.hostID == HostID("host-fixture"))
    #expect(frame.deviceID == DeviceID("device-fixture"))
    #expect(frame.sequence == 42)
    #expect(frame.kind == .data)

    let encoded = try TransportCoding.makeEncoder().encode(frame)
    let expectedObject = try JSONSerialization.jsonObject(with: fixture) as? NSDictionary
    let actualObject = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary
    #expect(actualObject == expectedObject)
}

@Test func sessionRoundTripKeepsTimelineContent() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let sessionID = SessionID("session-1")
    let summary = SessionSummary(
        id: sessionID,
        agent: .codexSubagent,
        title: "Implement transport",
        workspace: "/tmp/project",
        lifecycle: .running,
        phase: .executing,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date,
        lineage: SessionLineage(
            threadSource: "subagent",
            parentSessionID: SessionID("parent-session"),
            subagentDepth: 1,
            agentNickname: "Hypatia",
            agentPath: "/root/docs_review",
            subagentKind: "thread_spawn"
        )
    )
    let item = TimelineItem(
        id: TimelineItemID("item-1"),
        sessionID: sessionID,
        turnID: TurnID("turn-1"),
        occurredAt: date,
        payload: .tool(ToolTimelinePayload(name: "swift test", status: .succeeded, durationMilliseconds: 1200))
    )
    let detail = SessionDetail(summary: summary, timeline: [item])

    let encoded = try TransportCoding.makeEncoder().encode(detail)
    let decoded = try TransportCoding.makeDecoder().decode(SessionDetail.self, from: encoded)
    #expect(decoded == detail)
}

@Test func diagnosticTimelinePayloadsRoundTripStructuredJSON() throws {
    let payloads: [TimelinePayload] = [
        .modelConfiguration(ModelConfigurationTimelinePayload(
            source: "turn_context",
            model: "gpt-5.6",
            provider: "openai",
            contextWindow: 258_000,
            reasoningEffort: "high",
            clientVersion: "1.0",
            settings: .object(["realtime": .boolean(false)])
        )),
        .internalContext(InternalContextTimelinePayload(
            kind: "world_state",
            content: .object([
                "instructions": .array([.string("one"), .string("two")]),
                "window": .number(2),
            ])
        )),
        .usageMetrics(UsageMetricsTimelinePayload(
            last: TokenUsage(inputTokens: 10, outputTokens: 5, totalTokens: 15),
            total: TokenUsage(inputTokens: 100, outputTokens: 50, totalTokens: 150),
            modelContextWindow: 258_000,
            rateLimits: .object(["used_percent": .number(12.5)])
        )),
    ]

    for payload in payloads {
        let encoded = try TransportCoding.makeEncoder().encode(payload)
        let decoded = try TransportCoding.makeDecoder().decode(TimelinePayload.self, from: encoded)
        #expect(decoded == payload)
    }
}

@Test func jsonValuePreservesFoundationBooleanAndNumberKinds() throws {
    let object = try #require(JSONSerialization.jsonObject(with: Data(#"{"enabled":true,"count":9007199254740993,"ratio":1.5}"#.utf8)) as? [String: Any])
    let value = try JSONValue(jsonObject: object)
    #expect(value == .object([
        "enabled": .boolean(true),
        "count": .number(9_007_199_254_740_993),
        "ratio": .number(1.5),
    ]))

    let encoded = try TransportCoding.makeEncoder().encode(value)
    let decoded = try TransportCoding.makeDecoder().decode(JSONValue.self, from: encoded)
    #expect(decoded == value)
}

@Test func deleteSessionRequestRoundTripsWithItsSessionID() throws {
    let request = IPCRequest(
        operation: .deleteSession,
        sessionID: SessionID("session-to-delete")
    )
    let encoded = try TransportCoding.makeEncoder().encode(request)
    let decoded = try TransportCoding.makeDecoder().decode(IPCRequest.self, from: encoded)

    #expect(decoded == request)
}

@Test func visibleSessionsKeepAProvisionalParentOfAVisibleSubagent() {
    let date = Date(timeIntervalSince1970: 100)
    func summary(_ id: String, lifecycle: SessionLifecycle, firstTurnAt: Date?, parent: String? = nil) -> SessionSummary {
        SessionSummary(
            id: SessionID(id), agent: parent == nil ? .codex : .codexSubagent, title: id,
            lifecycle: lifecycle, phase: .idle, startedAt: date, updatedAt: date, lastActivityAt: date,
            lineage: parent.map { SessionLineage(threadSource: "subagent", parentSessionID: SessionID($0)) },
            firstTurnAt: firstTurnAt
        )
    }
    let stubParent = summary("parent", lifecycle: .starting, firstTurnAt: nil)
    let child = summary("child", lifecycle: .waitingForInput, firstTurnAt: date, parent: "parent")
    let probe = summary("probe", lifecycle: .starting, firstTurnAt: nil)
    let real = summary("real", lifecycle: .running, firstTurnAt: date)
    let visible = SessionSummary.visible([stubParent, child, probe, real]).map(\.id.rawValue)
    #expect(visible == ["parent", "child", "real"])
}
