import DesignSystem
import Transport
import AppKit
import SwiftUI

private typealias DS = DesignSystem
private typealias NotchMetric = DesignSystem.Notch

/// The plan-usage cluster in the Notch top bar's leading slot (and, on a
/// black strip, the Settings preview): `[Claude glyph] 42% 18% 7%  [Codex
/// glyph] 12%`. One group per agent, 15pt glyph box, 4pt gaps inside a
/// group, the top bar's 10pt gap between groups. In `switchOnClick` mode the
/// whole cluster is a button that brings up the other agent.
struct HaloPlanUsageClusterView: View {
    @ObservedObject var model: PlanUsageModel
    @ObservedObject var preferences: HaloPlanUsagePreferences
    /// The preview shows sample numbers while the daemon has none.
    var sampleWhenEmpty = false

    var body: some View {
        if let cluster {
            content(cluster)
        }
    }

    /// Whether the top bar should hand its leading slot to this view.
    var hasContent: Bool { cluster != nil }

    private var cluster: HaloPlanUsageCluster? {
        let choices = preferences.snapshot
        if let live = HaloPlanUsagePresentation.cluster(state: model.state, choices: choices, now: Date()) {
            return live
        }
        guard sampleWhenEmpty, choices.enabled else { return nil }
        return HaloPlanUsagePresentation.cluster(state: HaloPlanUsagePresentation.sampleState(), choices: choices, now: Date())
    }

    @ViewBuilder
    private func content(_ cluster: HaloPlanUsageCluster) -> some View {
        let row = HStack(spacing: NotchMetric.topBarLeadingGap) {
            ForEach(cluster.groups, id: \.provider) { group in
                HStack(spacing: NotchMetric.planUsageGap) {
                    if let icon = AgentIcons.mark(for: group.provider, pointSize: NotchMetric.topBarIconBox) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: NotchMetric.topBarIconBox, height: NotchMetric.topBarIconBox)
                            .opacity(group.isAvailable ? 1 : DS.Opacity.planUsageUnavailable)
                    }
                    ForEach(group.entries, id: \.item) { entry in
                        Text(entry.text)
                            .font(SwiftUI.Font(DS.Typography.caption).monospacedDigit())
                            .foregroundStyle(entry.isWarning ? Color(DS.InkDark.warning) : Color(DS.InkDark.secondary))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
        }
        .help(cluster.help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Plan usage")
        .accessibilityValue(cluster.help)

        if let next = cluster.nextProvider {
            Button {
                preferences.selectedProvider = next
            } label: {
                row.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Switches to \(next == .claude ? "Claude Code" : "Codex")")
        } else {
            row
        }
    }
}

/// Settings › Notch › Usage preview: the cluster on the panel's black, at
/// the top bar's height and inset, so what is chosen is what will show.
struct HaloPlanUsagePreviewStrip: View {
    @ObservedObject var model: PlanUsageModel
    @ObservedObject var preferences: HaloPlanUsagePreferences

    var body: some View {
        HStack(spacing: 0) {
            HaloPlanUsageClusterView(model: model, preferences: preferences, sampleWhenEmpty: true)
            Spacer(minLength: 0)
            if isSample {
                Text("sample")
                    .font(Design.Font.UI.caption)
                    .foregroundStyle(Color(DS.InkDark.quaternary))
            }
        }
        .padding(.horizontal, NotchMetric.topBarSideInset)
        .frame(height: NotchMetric.topBandHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(DS.SurfaceDark.panel), in: RoundedRectangle(cornerRadius: DS.Radius.notchCard, style: .continuous))
    }

    private var isSample: Bool {
        HaloPlanUsagePresentation.cluster(state: model.state, choices: preferences.snapshot, now: Date()) == nil
    }
}
