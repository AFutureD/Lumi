import AgentStatusCore
import AgentStatusTransport
import Foundation
import Testing
@testable import AgentStatusIOSFeature

@Test func relativeTimeUsesOneUnit() {
    let now = Date(timeIntervalSince1970: 100_000)
    #expect(SessionRelativeTimeFormatter.string(from: now.addingTimeInterval(-3), now: now) == "now")
    #expect(SessionRelativeTimeFormatter.string(from: now.addingTimeInterval(-42), now: now) == "42s")
    #expect(SessionRelativeTimeFormatter.string(from: now.addingTimeInterval(-14 * 60), now: now) == "14m")
    #expect(SessionRelativeTimeFormatter.string(from: now.addingTimeInterval(-3_700), now: now) == "1h")
    #expect(SessionRelativeTimeFormatter.string(from: now.addingTimeInterval(-3 * 86_400), now: now) == "3d")
}

@Test func compactDurationRoundsDown() {
    #expect(CompactDurationText.string(from: 12) == "12s")
    #expect(CompactDurationText.string(from: 161) == "2m")
    #expect(CompactDurationText.string(from: 3_599) == "59m")
    #expect(CompactDurationText.string(from: 3_600) == "1h")
}

@Test func elapsedText() {
    #expect(SessionElapsedFormatter.string(from: 12) == "12s")
    #expect(SessionElapsedFormatter.string(from: 223) == "3m 43s")
    #expect(SessionElapsedFormatter.string(from: 3_720) == "1h 02m")
    #expect(SessionElapsedFormatter.string(from: 2 * 86_400 + 3 * 3_600) == "2d 03h")
}

@Test func workspaceAbbreviatesAnyMacHome() {
    #expect(SessionPagePresentationBuilder.abbreviatedWorkspace("/Users/huanan/dev/lumi") == "~/dev/lumi")
    #expect(SessionPagePresentationBuilder.abbreviatedWorkspace("/Users/huanan") == "~")
    #expect(SessionPagePresentationBuilder.abbreviatedWorkspace("/opt/work") == "/opt/work")
    #expect(SessionPagePresentationBuilder.abbreviatedWorkspace(nil) == nil)
    #expect(SessionPagePresentationBuilder.abbreviatedWorkspace("") == nil)
}

@Test func toolCallAndResultPairIntoCommandAndOutput() {
    let sessionID = SessionID("s")
    let base = Date(timeIntervalSince1970: 0)
    let detail = SessionDetail(
        summary: SessionSummary(id: sessionID, agent: .codex, title: "t", lifecycle: .running, phase: .executing, startedAt: base, updatedAt: base, lastActivityAt: base),
        timeline: [
            TimelineItem(id: TimelineItemID("1"), sessionID: sessionID, occurredAt: base, payload: .tool(.init(name: "shell", summary: "swift build", status: .started, toolUseID: "x"))),
            TimelineItem(id: TimelineItemID("2"), sessionID: sessionID, occurredAt: base.addingTimeInterval(1), payload: .tool(.init(name: "shell", summary: "error: boom", status: .failed, durationMilliseconds: 1_500, toolUseID: "x"))),
        ]
    )
    let presentation = SessionDetailPresentationBuilder.make(detail: detail)
    #expect(presentation.activities.map(\.label) == ["TOOL", "FAILED"])
    let sheet = ActivityDetailPresentationBuilder.make(for: presentation.activities[1], in: presentation.activities)
    #expect(sheet.isFailed)
    #expect(sheet.sections.map(\.title) == ["Command", "Output"])
    #expect(sheet.sections[0].text == "shell · swift build")
    #expect(sheet.sections[1].text == "shell · error: boom · 1.5s")
}
