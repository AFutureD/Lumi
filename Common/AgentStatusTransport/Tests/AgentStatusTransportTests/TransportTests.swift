import Foundation
import Testing
@testable import AgentStatusTransport

@Test func unknownProtocolValuesRemainDecodable() throws {
    let lifecycle = try JSONDecoder().decode(SessionLifecycle.self, from: Data("\"paused_by_provider\"".utf8))
    #expect(lifecycle == .unknown("paused_by_provider"))

    let payloadJSON = Data("""
    {"type":"future_event","unknown":{"kind":"future_event","summary":"available after upgrade"}}
    """.utf8)
    let payload = try JSONDecoder().decode(TimelinePayload.self, from: payloadJSON)
    #expect(payload == .unknown(UnknownTimelinePayload(kind: "future_event", summary: "available after upgrade")))
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
        agent: .codex,
        title: "Implement transport",
        workspace: "/tmp/project",
        lifecycle: .running,
        phase: .executing,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date
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

@Test func deleteSessionRequestRoundTripsWithItsSessionID() throws {
    let request = IPCRequest(
        operation: .deleteSession,
        sessionID: SessionID("session-to-delete")
    )
    let encoded = try TransportCoding.makeEncoder().encode(request)
    let decoded = try TransportCoding.makeDecoder().decode(IPCRequest.self, from: encoded)

    #expect(decoded == request)
}
