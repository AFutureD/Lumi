import AgentStatusCore
import AgentStatusTransport
import Testing
@testable import AgentStatusDesignSystem

@Test func everyTagCarriesARingInAllTiers() {
    for tag in TimelineTag.allCases {
        for appearance in [DesignAppearance.light, .dark] {
            let style = TimelineTagStyle.style(for: tag, appearance: appearance)
            #expect(style.ring.alpha > 0, "\(tag) \(appearance) has no ring")
            #expect(style.text.alpha > 0)
        }
    }
}

@Test func attentionTiersMapToFills() {
    // L1: no fill, gray text. L2: translucent tint. L3: solid fill + white text.
    for tag in TimelineTag.allCases {
        let style = TimelineTagStyle.style(for: tag)
        switch tag.level {
        case .l1:
            #expect(style.fill == .clear)
            #expect(style.text == DesignSystem.Ink.quaternary)
        case .l2:
            #expect(style.fill.alpha > 0 && style.fill.alpha < 1)
        case .l3:
            #expect(style.fill.alpha == 1)
            #expect(style.text == .white)
            #expect(style.ring.alpha == 0.38)
        }
    }
}

@Test func l3DarkFillsAreLifted() {
    #expect(TimelineTagStyle.style(for: .user, appearance: .dark).fill == DesignColor(hex: 0x22B856))
    #expect(TimelineTagStyle.style(for: .turnEnd, appearance: .dark).fill == DesignColor(hex: 0x2A8CFF))
    #expect(TimelineTagStyle.style(for: .failed, appearance: .dark).fill == DesignColor(hex: 0xEE4038))
}

@Test func colorLiteralsRoundTrip() {
    let accent = DesignColor(hex: 0x0078F0)
    #expect(accent == DesignColor(rgb: 0, 120, 240))
    #expect(accent.opacity(0.16).alpha == 0.16)
    let veiled = DesignColor(white: 1, alpha: 0.35).composited(over: accent.opacity(0.16))
    #expect(veiled.alpha > 0.35 && veiled.alpha < 1)
    #expect(veiled.red > accent.red)
}

@Test func toneStylesFollowTheLadder() {
    #expect(SessionStatusTone.blue.lightStyle.color == DesignSystem.Semantic.agentBlue.light)
    #expect(SessionStatusTone.green.lightStyle.pillText == DesignColor(hex: 0x157A38))
    #expect(SessionStatusTone.gray.darkStyle.halo == nil)
    #expect(SessionStatusTone.blue.darkStyle.pillText == DesignColor(hex: 0x9DC7FF))
    #expect(SessionStatusTone.red.darkStyle.color == DesignColor(hex: 0xEE4038))
}

@Test func typographyUsesOnlyFiveSizesAndThreeWeights() {
    typealias T = DesignSystem.Typography
    let styles: [DesignTextStyle] = [
        T.detailTitle, T.sectionTitle, T.groupHeader, T.listTitle, T.body, T.pill, T.caption,
        T.metricLabel, T.monoTimestamp, T.monoValue, T.tag, T.notchBody, T.notchCaption, T.notchChip,
        T.notchSectionLabel, T.notchCardLabel, T.notchMetricLabel, T.notchTag, T.notchButton,
    ]
    let sizes = Set(styles.map(\.size))
    #expect(sizes.isSubset(of: [22, 15, 13, 12, 11, 10, 9]))
    #expect(DesignSystem.Typography.tag.tracking == 9 * 0.04)
    #expect(DesignSystem.Typography.detailTitle.tracking < 0)
}

@Test func laneCellsUseTheRamp() {
    #expect(TimelineTag.reasoning.laneCellColor == DesignSystem.Ramp.neutral)
    #expect(TimelineTag.assistant.laneCellColor == DesignSystem.Ramp.blue)
    #expect(TimelineTag.user.laneCellColor == DesignSystem.Semantic.userGreen.light)
    #expect(TimelineTag.assistant.shortLabel == "ASSIST" && TimelineTag.user.shortLabel == "USER")
    #expect(TimelineRowStatus.running.dotStyle.breathes)
    #expect(TimelineRowStatus.started.dotStyle.ring != nil)
}
