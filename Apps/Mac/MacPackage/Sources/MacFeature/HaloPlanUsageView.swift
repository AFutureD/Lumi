import Core
import DesignSystem
import Transport
import AppKit
import SwiftUI

private typealias DS = DesignSystem
private typealias NotchMetric = DesignSystem.Notch

/// The plan-usage cluster in the Notch top bar's leading slot (Notch handoff
/// page 6), also drawn on the Settings preview strip: per agent its mark,
/// then one `label value` cell per chosen window — `5h 42% · 7d 18% · Fable 7%`.
/// Labels 10 / Medium at White 42 %, values 11 SF Mono tabular in pure
/// white (warning orange at 90 %), at least 16 wide. Gaps: label–value 3,
/// cell–cell 6, mark–first cell 6, agent–agent 8. In `switchOnClick` mode
/// the whole cluster is a button that brings up the other agent.
struct HaloPlanUsageClusterView: View {
    @ObservedObject var model: PlanUsageModel
    @ObservedObject var preferences: HaloPlanUsagePreferences
    /// The preview shows sample numbers while the daemon has nothing to show.
    var sampleWhenEmpty = false

    var body: some View {
        if let cluster {
            content(cluster)
        }
    }

    /// Whether the top bar should hand its leading slot to this view.
    var hasContent: Bool { cluster != nil }

    /// True when the strip is drawing the sample rather than live numbers.
    var isSample: Bool {
        sampleWhenEmpty && liveCluster == nil && cluster != nil
    }

    private var liveCluster: HaloPlanUsageCluster? {
        HaloPlanUsagePresentation.cluster(state: model.state, choices: preferences.snapshot(percentStyle: model.percentStyle), now: Date())
    }

    private var cluster: HaloPlanUsageCluster? {
        if let live = liveCluster { return live }
        guard sampleWhenEmpty else { return nil }
        return HaloPlanUsagePresentation.cluster(state: HaloPlanUsagePresentation.sampleState(), choices: preferences.snapshot(percentStyle: model.percentStyle), now: Date())
    }

    @ViewBuilder
    private func content(_ cluster: HaloPlanUsageCluster) -> some View {
        let row = HStack(spacing: NotchMetric.planUsageGroupGap) {
            ForEach(cluster.groups, id: \.provider) { group in
                HStack(spacing: NotchMetric.planUsageIconGap) {
                    if let mark = AgentIcons.mark(for: group.provider, pointSize: NotchMetric.topBarIconBox) {
                        Image(nsImage: mark)
                            .resizable()
                            .frame(width: NotchMetric.topBarIconBox, height: NotchMetric.topBarIconBox)
                            .clipShape(RoundedRectangle(cornerRadius: NotchMetric.planUsageMarkRadius, style: .continuous))
                    }
                    HStack(spacing: NotchMetric.planUsageItemGap) {
                        ForEach(group.entries, id: \.item) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: NotchMetric.planUsageLabelGap) {
                                Text(entry.label)
                                    .designText(DS.Typography.planUsageNotchLabel)
                                    .foregroundStyle(Color(DS.InkDark.planUsageLabel))
                                Text(entry.text)
                                    .font(SwiftUI.Font(DS.Typography.planUsageNotchValue).monospacedDigit())
                                    .tracking(DS.Typography.planUsageNotchValue.tracking)
                                    .foregroundStyle(entry.isWarning ? Color(DS.InkDark.warning) : Color(DS.InkDark.primary))
                                    .frame(minWidth: NotchMetric.planUsageValueMinWidth, alignment: .leading)
                            }
                            .lineLimit(1)
                            .fixedSize()
                        }
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
            .accessibilityHint("Switches to \(PlanUsagePresentation.agentName(next))")
        } else {
            row
        }
    }
}

/// Settings › Notch › Usage preview (macOS handoff page 7b): the cluster on
/// the panel's black at the top band's height and inset, so what is chosen
/// is what will show. In `switchOnClick` mode the whole strip is the button.
struct HaloPlanUsagePreviewStrip: View {
    @ObservedObject var model: PlanUsageModel
    @ObservedObject var preferences: HaloPlanUsagePreferences

    var body: some View {
        let cluster = HaloPlanUsageClusterView(model: model, preferences: preferences, sampleWhenEmpty: true)
        HStack(spacing: 0) {
            if cluster.hasContent {
                cluster
            } else {
                // Nothing chosen: the brand cluster the top bar falls back to.
                HStack(spacing: NotchMetric.topBarLeadingGap) {
                    Image(systemName: "terminal")
                        .font(.system(size: NotchMetric.topBarGlyph, weight: .regular))
                        .foregroundStyle(Color(DS.InkDark.brandIcon))
                        .frame(width: NotchMetric.topBarIconBox, height: NotchMetric.topBarIconBox)
                    Text("Lumi")
                        .designText(DS.Typography.caption)
                        .foregroundStyle(Color(DS.InkDark.secondary))
                }
            }
            Spacer(minLength: 0)
            if cluster.isSample {
                Text("sample")
                    .designText(DS.Typography.caption)
                    .foregroundStyle(Color(DS.InkDark.quaternary))
            }
        }
        .padding(.horizontal, DS.PlanUsage.previewInset)
        .frame(height: DS.PlanUsage.previewHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(DS.SurfaceDark.panel), in: RoundedRectangle(cornerRadius: DS.PlanUsage.previewRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            guard preferences.agentsMode == .switchOnClick else { return }
            preferences.selectedProvider = preferences.selectedProvider == .claude ? .codex : .claude
        }
    }
}
