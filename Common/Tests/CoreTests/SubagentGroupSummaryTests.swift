import Foundation
import Testing
@testable import Core

@Test func subagentBucketsFollowTheStatusTone() {
    #expect(SubagentSummaryBucket(tone: .blue) == .running)
    #expect(SubagentSummaryBucket(tone: .orange) == .waiting)
    #expect(SubagentSummaryBucket(tone: .red) == .failed)
    #expect(SubagentSummaryBucket(tone: .green) == .done)
    #expect(SubagentSummaryBucket(tone: .gray) == .done)
    #expect(SubagentSummaryBucket.allCases == [.running, .waiting, .failed, .done])
}

@Test func subagentSummaryLabelPrintsOnlyNonZeroBucketsInOrder() {
    #expect(SubagentGroupSummary.label(tones: [.gray, .blue, .blue]) == "3 subagents · 2 running · 1 done")
    #expect(SubagentGroupSummary.label(tones: [.blue]) == "1 subagent · 1 running")
    #expect(SubagentGroupSummary.label(tones: [.green, .red, .orange, .blue])
        == "4 subagents · 1 running · 1 waiting · 1 failed · 1 done")
    #expect(SubagentGroupSummary.label(tones: []) == "0 subagents")
}

@Test func subagentOrderingGoesRunningWaitingFailedDoneThenNewestFirst() {
    let base = Date(timeIntervalSince1970: 1_000)
    let items: [(tone: SessionStatusTone, lastActivityAt: Date)] = [
        (.gray, base), (.red, base), (.orange, base), (.blue, base.addingTimeInterval(-10)), (.blue, base),
    ]
    let sorted = items.sorted(by: SubagentGroupSummary.precedes)
    #expect(sorted.map(\.tone) == [.blue, .blue, .orange, .red, .gray])
    #expect(sorted[0].lastActivityAt == base)
}
