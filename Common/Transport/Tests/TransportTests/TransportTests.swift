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

@Test func ingestHookFrameRoundTripsWithRawBytesIntact() throws {
    // Hook event IDs are a SHA-256 of the raw stdin bytes: the frame must
    // return them byte for byte, whatever the payload looks like.
    let raw = Data("{\"session_id\":\"s\",\"hook_event_name\":\"Stop\",\"note\":\"emoji 🐛 / 中文\"}".utf8)
    let request = IPCRequest(
        operation: .ingestHook,
        createdAt: Date(timeIntervalSince1970: 1_787_978_780.123),
        agent: .codex,
        env: ["PASEO_AGENT_ID": "ad98cf62", "CODEX_HOME": "/tmp/.codex"],
        data: raw
    )
    let encoded = try TransportCoding.makeEncoder().encode(request)
    let decoded = try TransportCoding.makeDecoder().decode(IPCRequest.self, from: encoded)

    #expect(decoded.operation == .ingestHook)
    #expect(decoded.agent == .codex)
    #expect(decoded.env == request.env)
    #expect(decoded.data == raw)
    // RFC 3339 with milliseconds on the wire.
    let wire = String(data: encoded, encoding: .utf8) ?? ""
    #expect(wire.contains("\"createdAt\":\"2026-08-29T"))
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

@Test func sessionFilterRulesRoundTripBothValueShapes() throws {
    let rules = [
        SessionFilterRule(
            id: SessionFilterRuleID("r1"),
            isEnabled: true,
            conditions: [
                SessionFilterCondition(field: .agent, op: .is, value: .text("codex")),
                SessionFilterCondition(field: .folder, op: .is, value: .text("/tmp/x")),
            ]
        ),
        SessionFilterRule(
            id: SessionFilterRuleID("r2"),
            isEnabled: false,
            conditions: [
                SessionFilterCondition(field: .application, op: .contains, value: .options(["paseo", "raft"])),
                SessionFilterCondition(field: .message, op: .startsWith, value: .text("test:")),
            ]
        ),
    ]
    let encoded = try TransportCoding.makeEncoder().encode(rules)
    let decoded = try TransportCoding.makeDecoder().decode([SessionFilterRule].self, from: encoded)
    #expect(decoded == rules)

    // The value's shape is its tag: a bare string vs a bare array.
    let json = String(decoding: encoded, as: UTF8.self)
    #expect(json.contains(#""value":"codex""#))
    #expect(json.contains(#""value":["paseo","raft"]"#))
}

@Test func sessionFilterUnknownEnumValuesAreDecodingErrors() throws {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SessionFilterField.self, from: Data("\"model\"".utf8))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SessionFilterOperator.self, from: Data("\"matches_regex\"".utf8))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SessionFilterValue.self, from: Data("42".utf8))
    }
}

@Test func sessionFilterIPCOperationsRoundTrip() throws {
    for (op, raw) in [(IPCOperation.getSessionFilters, "\"get_session_filters\""), (.setSessionFilters, "\"set_session_filters\"")] {
        let encoded = try JSONEncoder().encode(op)
        #expect(String(decoding: encoded, as: UTF8.self) == raw)
        #expect(try JSONDecoder().decode(IPCOperation.self, from: encoded) == op)
    }
    let request = IPCRequest(
        operation: .setSessionFilters,
        filters: [SessionFilterRule(conditions: [SessionFilterCondition(field: .agent, op: .is, value: .text("claude"))])]
    )
    let decoded = try TransportCoding.makeDecoder().decode(
        IPCRequest.self,
        from: TransportCoding.makeEncoder().encode(request)
    )
    #expect(decoded.filters == request.filters)
}

@Test func filterHiddenIDsAreTransitiveOverLineage() {
    let date = Date(timeIntervalSince1970: 10)
    func make(_ id: String, parent: String? = nil, hidden: Bool = false) -> SessionSummary {
        SessionSummary(
            id: SessionID(id), agent: .codex, title: "T",
            lifecycle: .running, phase: .thinking,
            startedAt: date, updatedAt: date, lastActivityAt: date,
            hiddenByFilter: hidden,
            lineage: parent.map { SessionLineage(parentSessionID: SessionID($0)) }
        )
    }
    let hidden = SessionSummary.filterHiddenIDs([
        make("root", hidden: true),
        make("child", parent: "root"),
        make("other"),
        make("other-child", parent: "other"),
    ])
    #expect(hidden == [SessionID("root"), SessionID("child")])
}

@Test func usageDayIsStrictISOAndOrdersByCalendar() throws {
    let day = try #require(UsageDay(rawValue: "2026-09-05"))
    #expect(day == UsageDay(year: 2026, month: 9, day: 5))
    #expect(day.rawValue == "2026-09-05")
    #expect(UsageDay(year: 2026, month: 8, day: 31) < day)
    #expect(UsageDay(year: 2025, month: 12, day: 31) < UsageDay(year: 2026, month: 1, day: 1))
    for bad in ["2026-9-5", "20260905", "2026-13-01", "2026-09-32", "2026-09-05T00:00:00Z", ""] {
        #expect(UsageDay(rawValue: bad) == nil, Comment(rawValue: bad))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(UsageDay.self, from: Data("\"2026/09/05\"".utf8))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(UsagePricingSource.self, from: Data("\"litellm\"".utf8))
    }
}

@Test func usageReportRoundTripsThroughIPC() throws {
    let tokens = UsageTokens(input: 2, cacheRead: 37_690, cacheWrite5m: 0, cacheWrite1h: 21_292, output: 496, reasoning: 146)
    #expect(tokens.total == 2 + 37_690 + 21_292 + 496)
    #expect(tokens.cacheWrite == 21_292)
    let report = UsageReport(
        since: UsageDay(year: 2026, month: 9, day: 1),
        until: UsageDay(year: 2026, month: 9, day: 5),
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000.266),
        totals: UsageSlice(tokens: tokens, costUSD: 1.234, unpricedTokens: 14, calls: 3, sessions: 2, turns: 2, lastDay: UsageDay(year: 2026, month: 9, day: 5)),
        byAgent: [UsageSlice(agent: .claude, tokens: tokens, costUSD: 1.234, calls: 3, sessions: 2, turns: 2)],
        byProject: [UsageSlice(workspace: "/Users/me/Developer/lumi", tokens: tokens, costUSD: 1.234, calls: 3, sessions: 2, turns: 2)],
        byModel: [
            UsageSlice(agent: .claude, model: "claude-fable-5", provider: "anthropic", tokens: tokens, costUSD: 1.234, calls: 2, sessions: 2, turns: 2),
            UsageSlice(agent: .claude, model: "<synthetic>", tokens: UsageTokens(output: 14), costUSD: nil, unpricedTokens: 14, calls: 1, sessions: 1, turns: 1),
        ],
        byDay: [UsageSlice(period: UsagePeriod(unit: .day, start: UsageDay(year: 2026, month: 9, day: 5)), tokens: tokens, costUSD: 1.234, calls: 3, sessions: 2, turns: 2)],
        byWeek: [UsageSlice(period: UsagePeriod(unit: .week, start: UsageDay(year: 2026, month: 8, day: 31)), tokens: tokens, costUSD: 1.234, calls: 3, sessions: 2, turns: 2)],
        byMonth: [UsageSlice(period: UsagePeriod(unit: .month, start: UsageDay(year: 2026, month: 9, day: 1)), tokens: tokens, costUSD: 1.234, calls: 3, sessions: 2, turns: 2)],
        trendUnit: .day,
        trend: [
            UsageSlice(agent: .claude, model: "claude-fable-5", provider: "anthropic", period: UsagePeriod(unit: .day, start: UsageDay(year: 2026, month: 9, day: 5)), tokens: tokens, costUSD: 1.234, calls: 2, sessions: 2, turns: 2),
        ],
        pricing: UsagePricingStatus(source: .cached, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000), modelCount: 1_234),
        scan: UsageScanStatus(scannedFiles: 1_650, pendingFiles: 0, lastScanAt: Date(timeIntervalSince1970: 1_700_000_100), isScanning: false)
    )
    let response = IPCResponse(status: .ok, usage: report)
    let encoded = try TransportCoding.makeEncoder().encode(response)
    let decoded = try TransportCoding.makeDecoder().decode(IPCResponse.self, from: encoded)
    #expect(decoded.usage == report)
    let json = String(decoding: encoded, as: UTF8.self)
    #expect(json.contains(#""since":"2026-09-01""#))
    #expect(json.contains(#""source":"cached""#))
    // An unpriced row omits its cost rather than reporting zero.
    #expect(json.contains(#""model":"<synthetic>""#))
    #expect(!json.contains(#""costUSD":0"#))
    #expect(json.contains(#""trendUnit":"day""#))
    #expect(json.contains(#""period":{"start":"2026-08-31","unit":"week"}"#) || json.contains(#""period":{"unit":"week","start":"2026-08-31"}"#))
    // An hour period carries its hour; a day period leaves it out.
    let hour = UsagePeriod(unit: .hour, start: UsageDay(year: 2026, month: 9, day: 5), hour: 9)
    let day = UsagePeriod(unit: .day, start: UsageDay(year: 2026, month: 9, day: 5), hour: 9)
    #expect(hour.hour == 9 && day.hour == nil)
    #expect(UsagePeriod(unit: .hour, start: UsageDay(year: 2026, month: 9, day: 5), hour: 8) < hour)
    #expect(day < hour)

    let request = IPCRequest(operation: .usageReport, since: report.since, until: report.until)
    let requestJSON = String(decoding: try TransportCoding.makeEncoder().encode(request), as: UTF8.self)
    #expect(requestJSON.contains(#""operation":"usage_report""#))
    let decodedRequest = try TransportCoding.makeDecoder().decode(IPCRequest.self, from: Data(requestJSON.utf8))
    #expect(decodedRequest.since == report.since)
    #expect(decodedRequest.until == report.until)
}
