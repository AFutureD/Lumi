import Core
import Transport
import Foundation
import Testing
@testable import IOSFeature

@Test func relativeTimeUsesOneUnit() {
    let now = Date(timeIntervalSince1970: 100_000)
    #expect(SessionRelativeTimeFormatter.string(from: now.addingTimeInterval(-3), now: now) == "3s")
    #expect(SessionRelativeTimeFormatter.string(from: now, now: now) == "0s")
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
            TimelineItem(id: TimelineItemID("1"), sessionID: sessionID, occurredAt: base, payload: .tool(.init(name: "shell", content: .object(["command": .string("swift build"), "timeout": .number(60)]), status: .started, toolUseID: "x"))),
            TimelineItem(id: TimelineItemID("2"), sessionID: sessionID, occurredAt: base.addingTimeInterval(1), payload: .tool(.init(name: "shell", content: .string("error: boom\nat line 3"), status: .failed, durationMilliseconds: 1_500, toolUseID: "x"))),
        ]
    )
    let presentation = SessionDetailPresentationBuilder.make(detail: detail)
    #expect(presentation.activities.map(\.label) == ["TOOL", "FAILED"])
    let sheet = ActivityDetailPresentationBuilder.make(for: presentation.activities[1], in: presentation.activities)
    #expect(sheet.isFailed)
    // The page shows what the records hold — the command, the whole output
    // — not the rows' one-line text.
    #expect(presentation.activities.map(\.content) == ["shell · swift build", "shell · error: boom · 1.5s"])
    #expect(sheet.sections.map(\.title) == ["Status", "Input", "Command", "Error"])
    #expect(sheet.sections[0].text == "Status: Failed\nDuration: 1.5s")
    #expect(sheet.sections[1].text == "timeout: 60")
    #expect(sheet.sections[2].text == "$ swift build")
    #expect(sheet.sections[3].text == "error: boom\nat line 3")

    // A call still waiting for its result says so.
    let waiting = SessionDetailPresentationBuilder.make(detail: SessionDetail(summary: detail.summary, timeline: [detail.timeline[0]]))
    let running = ActivityDetailPresentationBuilder.make(for: waiting.activities[0], in: waiting.activities)
    #expect(running.sections.last?.text == "Still running…")
}
