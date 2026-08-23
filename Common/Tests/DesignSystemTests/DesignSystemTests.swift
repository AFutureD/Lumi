import Core
import Transport
import Testing
@testable import DesignSystem

typealias DS = DesignSystem

// MARK: L1 · palette & roles

@Test func rampsReadAsWrittenInTheHandoff() {
    #expect(DS.Palette.blue.s600 == DesignColor(hex: 0x0078F0))
    #expect(DS.Palette.blue.s200 == DesignColor(hex: 0xDBECFD))
    #expect(DS.Palette.neutral.s700 == DesignColor(rgb: 26, 26, 26))
    #expect(DS.Palette.blueDark.d500 == DesignColor(hex: 0x4C9BFF))
    #expect(DS.Palette.orangeDark.d500 == DesignColor(hex: 0xFFB27A))
    #expect(DesignHue.neutral.darkRamp == nil)
    #expect(DesignHue.green.base == DS.Palette.green.s600)
    #expect(DesignHue.green.darkBase == DS.Palette.greenDark.d500)
}

@Test func rolesPickFromTheRamps() {
    #expect(DS.Ink.primary == DS.Palette.neutral.s700)
    #expect(DS.Ink.tertiary == DesignColor(rgb: 114, 114, 114))
    #expect(DS.Ink.accent == DS.Semantic.accent.light)
    #expect(DS.Ink.destructive == DS.Palette.red.s700)
    #expect(DS.Surface.selection == DesignColor(rgb: 242, 242, 242))
    #expect(DS.Surface.hairline == DS.Palette.neutral.s200)
    // Dark is its own table.
    #expect(DS.InkDark.body.alpha == 0.78)
    #expect(DS.InkDark.secondary.alpha == 0.58)
    #expect(DS.InkDark.quaternary.alpha == 0.46)
    #expect(DS.SurfaceDark.card.alpha == 0.10)
    #expect(DS.SurfaceDark.control.alpha == 0.14)
    #expect(DS.SurfaceDark.secondaryButton.alpha == 0.16)
    #expect(DS.SurfaceDark.panel == .black)
    // Notch list extras: the agent tag is translucent so it reads over any
    // chrome backdrop, not just solid black.
    #expect(DS.SurfaceDark.agentTag.alpha == 0.14)
    #expect(DS.SurfaceDark.separator.alpha == 0.08)
    #expect(DS.SurfaceDark.listCard.alpha == 0.07)
    #expect(DS.SurfaceDark.subagentPill.alpha == 0.13)
    #expect(DS.InkDark.agentTagText.alpha == 0.52)
    #expect(DS.InkDark.pillName.alpha == 0.82)
    #expect(DS.InkDark.pillTime.alpha == 0.44)
}

@Test func colorLiteralsRoundTrip() {
    let accent = DesignColor(hex: 0x0078F0)
    #expect(accent == DesignColor(rgb: 0, 120, 240))
    #expect(accent.opacity(0.16).alpha == 0.16)
    let veiled = DesignColor(white: 1, alpha: 0.35).composited(over: accent.opacity(0.16))
    #expect(veiled.alpha > 0.35 && veiled.alpha < 1)
    #expect(veiled.red > accent.red)
}

// MARK: L1 · typography

@Test func typographyUsesSystemStylesAndThreeWeights() {
    typealias T = DS.Typography
    let styles: [DesignTextStyle] = [
        T.title1, T.title3Emphasized, T.bodyEmphasized, T.body, T.subheadlineEmphasized, T.subheadline,
        T.caption2, T.footnote, T.footnoteMono, T.subheadlineMono, T.tag, T.tagCompact, T.countBadge,
        T.notchLabel, T.notchSectionLabel, T.notchMetricLabel, T.notchBody, T.notchButton, T.notchSecondaryButton,
        T.notchAgentTag, T.notchActivityTag,
    ]
    #expect(Set(styles.map(\.size)).isSubset(of: [22, 15, 13, 12, 11, 10, 9]))
    // No Bold anywhere.
    #expect(styles.allSatisfy { [.regular, .medium, .semibold].contains($0.weight) })
    // Line heights follow the system styles.
    #expect(T.title1.lineHeight == 26 && T.title1.weight == .regular)
    #expect(T.title3Emphasized.lineHeight == 20)
    #expect(T.body.lineHeight == 16 && T.subheadline.lineHeight == 14 && T.caption2.lineHeight == 13)
    #expect(T.caption2.weight == .medium && T.caption2.tracking == 10 * 0.04)
    #expect(T.tag.tracking == 9 * 0.04)
    #expect(T.monoTimestamp.family == .mono && T.monoValue.family == .mono)
}

// MARK: L2 · tag

@Test func everyTagCarriesARingInAllTiers() {
    for tag in TimelineTag.allCases {
        for appearance in [DesignAppearance.light, .dark] {
            let style = tag.tagStyle(appearance)
            #expect(style.ring.alpha > 0, "\(tag) \(appearance) has no ring")
            #expect(style.text.alpha > 0)
        }
    }
}

@Test func attentionTiersMapToFills() {
    for tag in TimelineTag.allCases {
        let style = tag.tagStyle(.light)
        switch tag.level {
        case .l1:
            #expect(style.fill == .clear)
            // Neutral L1 tags stay grey; every other hue's L1 text matches its L2 tint text.
            #expect(style.text == (tag.hue == .neutral ? DS.Ink.quaternary : tag.hue.lightTint.text))
        case .l2:
            #expect(style.fill.alpha > 0 && style.fill.alpha < 1)
            #expect(style.text == tag.hue.ramp.s700 || tag.hue == .yellow)
        case .l3:
            #expect(style.fill == tag.hue.base)
            #expect(style.text == .white)
            #expect(style.ring.alpha == 0.38)
        }
    }
}

@Test func darkTiersReadFromTheDarkTable() {
    #expect(TimelineTag.user.tagStyle(.dark).fill == DesignColor(hex: 0x22B856))
    #expect(TimelineTag.turnEnd.tagStyle(.dark).fill == DesignColor(hex: 0x2A8CFF))
    #expect(TimelineTag.failed.tagStyle(.dark).fill == DesignColor(hex: 0xEE4038))
    #expect(TimelineTag.assistant.tagStyle(.dark).text == DesignColor(hex: 0x9DC7FF))
    #expect(TimelineTag.plan.tagStyle(.dark).text == DesignColor(hex: 0xC9AEFB))
    #expect(TimelineTag.session.tagStyle(.dark).ring.alpha == 0.20)
    #expect(TimelineTag.session.tagStyle(.dark).text.alpha == 0.38)
}

@Test func tagHuesFollowTheCategoryTable() {
    #expect(TimelineTag.tool.hue == .yellow && TimelineTag.result.hue == .yellow)
    #expect(TimelineTag.plan.hue == .purple && TimelineTag.subagent.hue == .orange)
    #expect(TimelineTag.assistant.hue == .blue && TimelineTag.turnEnd.hue == .blue)
    #expect(TimelineTag.user.hue == .green && TimelineTag.failed.hue == .red)
    #expect(TimelineTag.context.hue == .neutral && TimelineTag.contextGroup.hue == .neutral)
    #expect(TimelineTag.reasoning.hue == .blue)
    // REASONING / TOOL are L1 but keep their hue — same text as the L2 tint. CONTEXT stays neutral grey.
    #expect(TimelineTag.tool.level == .l1)
    #expect(TimelineTag.context.tagStyle(.light).text == DS.Ink.quaternary)
    #expect(TimelineTag.reasoning.tagStyle(.light).text == DesignColor(hex: 0x0069D7))
    #expect(TimelineTag.tool.tagStyle(.light).text == DesignColor(hex: 0x8A6A00))
    #expect(TimelineTag.reasoning.laneCellColor == DS.Palette.neutralMarker)
    #expect(TimelineTag.assistant.laneCellColor == DS.Palette.blue.s200)
    #expect(TimelineTag.user.laneCellColor == DS.Palette.green.s600)
    #expect(TimelineTag.assistant.shortLabel == "ASSIST" && TimelineTag.user.shortLabel == "USER")
    // TOOL (L1) and RESULT (L2) share a hue and must share a pair-highlight colour
    // despite the tier split, or their toolUseID-linked rows stop looking paired.
    #expect(TimelineTag.tool.categoryColor == TimelineTag.result.categoryColor)
    #expect(TimelineTag.tool.categoryColor == DS.Palette.yellow.s600)
}

// MARK: L2 · status dot

@Test func statusDotHalosDifferByAppearance() {
    #expect(DesignHue.blue.statusDot(.breathing, appearance: .light).halo.alpha == 0.20)
    #expect(DesignHue.blue.statusDot(.breathing, appearance: .dark).halo.alpha == 0.32)
    #expect(DesignHue.neutral.statusDot(.breathing, appearance: .dark).halo.alpha == 0.14)
    #expect(DesignHue.neutral.statusDot(.solid, appearance: .dark).color.alpha == 0.42)
    #expect(TimelineRowStatus.info.dotStyle() == nil)
    #expect(TimelineRowStatus.started.dotStyle()?.isHollow == true)
    #expect(TimelineRowStatus.running.dotStyle()?.breathes == true)
    #expect(TimelineRowStatus.succeeded.dotStyle()?.color == DS.Palette.green.s600)
}

@Test func turnPhasesOnlyChangeTheDot() {
    #expect(TurnPhase.thinking.dotStyle().breathes && TurnPhase.thinking.dotHue == .blue)
    #expect(TurnPhase.waitingForApproval.dotHue == .green)
    #expect(TurnPhase.subagentRunning.dotHue == .orange)
    #expect(TurnPhase.compacting.dotHue == .neutral && TurnPhase.compacting.dotForm == .breathing)
    #expect(TurnPhase.idle.dotForm == .solid)
}

// MARK: L3 · pill & lifecycle

@Test func pillStylesFollowTheTables() {
    let blue = DesignHue.blue.pillStyle(.light)
    #expect(blue.fill == DS.Palette.blue.s600.opacity(0.14))
    #expect(blue.text == DesignColor(hex: 0x0069D7) && blue.dot == DesignColor(hex: 0x0078F0))
    #expect(blue.ring == DS.Palette.blue.s600.opacity(0.24))
    let green = DesignHue.green.pillStyle(.light)
    #expect(green.text == DesignColor(hex: 0x199242))
    let neutral = DesignHue.neutral.pillStyle(.light)
    #expect(neutral.fill == DS.Surface.chipFill && neutral.text == DS.Ink.tertiary)
    let darkBlue = DesignHue.blue.pillStyle(.dark)
    #expect(darkBlue.fill == DesignColor(hex: 0x4C9BFF, alpha: 0.18) && darkBlue.text == DesignColor(hex: 0x9DC7FF))
    let darkNeutral = DesignHue.neutral.pillStyle(.dark)
    #expect(darkNeutral.fill.alpha == 0.12 && darkNeutral.ring.alpha == 0.18 && darkNeutral.text.alpha == 0.78)
}

@Test func lifecycleTiersBreatheOnlyWhileInProgress() {
    #expect(SessionStatusTone.blue.lightStyle.halo != nil)
    #expect(SessionStatusTone.green.lightStyle.halo != nil)
    #expect(SessionStatusTone.gray.lightStyle.halo == nil)
    #expect(SessionStatusTone.red.lightStyle.halo == nil)
    #expect(SessionStatusTone.gray.darkStyle.halo == nil)
    #expect(SessionStatusTone.blue.lightStyle.color == DS.Semantic.accent.light)
    #expect(SessionStatusTone.blue.darkStyle.pill.text == DesignColor(hex: 0x9DC7FF))
    #expect(SessionStatusTone.red.darkStyle.color == DesignColor(hex: 0xEE4038))
    #expect(SessionStatusTone.gray.darkStyle.color.alpha == 0.42)
}
