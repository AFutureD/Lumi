import Testing
@testable import IOSFeature

// L4 §4.4 cases, at the iPhone's 345pt available width (393 − 32 − 16).

private let available = 345.0

@Test func twoShortChipsShareALineUncapped() {
    let lines = SubagentChipLayout.lines(widths: [120, 110], availableWidth: available)
    #expect(lines.count == 1)
    #expect(lines[0].map(\.index) == [0, 1])
    // Wider one (120) is capped at min(⅔ · 345, 345 − 110 − 6) = 229 — above
    // its natural width, so it stays natural.
    #expect(lines[0][0].maxWidth == 229)
    #expect(lines[0][1].maxWidth == nil)
}

@Test func shortAndLongPairWithTheLongOneCapped() {
    let lines = SubagentChipLayout.lines(widths: [100, 300], availableWidth: available)
    #expect(lines.count == 1)
    #expect(lines[0][0].maxWidth == nil)
    // min(⅔ · 345, 345 − 100 − 6) = min(230, 239) = 230
    #expect(lines[0][1].maxWidth == 230)
}

@Test func theRemainingSpaceCapsTheWiderChipWhenTighter() {
    // narrow 160 (< 172.5 so it pairs) leaves 345 − 160 − 6 = 179 < 230.
    let lines = SubagentChipLayout.lines(widths: [160, 250], availableWidth: available)
    #expect(lines.count == 1)
    #expect(lines[0][1].maxWidth == 179)
}

@Test func twoLongChipsTakeALineEach() {
    let lines = SubagentChipLayout.lines(widths: [200, 210], availableWidth: available)
    #expect(lines.count == 2)
    #expect(lines[0][0].maxWidth == available)
    #expect(lines[1][0].maxWidth == available)
}

@Test func threeChipsPairThenLeaveOne() {
    let lines = SubagentChipLayout.lines(widths: [130, 140, 120], availableWidth: available)
    #expect(lines.map { $0.map(\.index) } == [[0, 1], [2]])
}

@Test func singleOverlongChipTakesFullWidth() {
    let lines = SubagentChipLayout.lines(widths: [400], availableWidth: available)
    #expect(lines == [[SubagentChipPlacement(index: 0, maxWidth: available)]])
}

@Test func noChipsNoLines() {
    #expect(SubagentChipLayout.lines(widths: [], availableWidth: available).isEmpty)
}
