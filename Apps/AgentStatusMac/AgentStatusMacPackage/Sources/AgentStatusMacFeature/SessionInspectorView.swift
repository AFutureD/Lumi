import AgentStatusCore
import SwiftUI

/// Inspector: three metric cards (tokens / context / elapsed) then the
/// Overview / Lineage / Model / Usage groups. Sits below the session header.
@MainActor
struct SessionInspectorView: View {
    let presentation: SessionPagePresentation?

    var body: some View {
        ScrollView {
            if let presentation {
                VStack(alignment: .leading, spacing: AgentStatusDesign.Layout.inspectorSectionSpacing) {
                    metrics(presentation.metrics)
                    ForEach(presentation.summarySections, id: \.kind.rawValue) { section in
                        group(section)
                    }
                }
                .padding(.top, AgentStatusDesign.Layout.inspectorInsets.top)
                .padding(.leading, AgentStatusDesign.Layout.inspectorInsets.left)
                .padding(.trailing, AgentStatusDesign.Layout.inspectorInsets.right)
                .padding(.bottom, AgentStatusDesign.Layout.inspectorInsets.bottom)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .environment(\.colorScheme, .light)
    }

    private func metrics(_ metrics: SessionMetricsPresentation) -> some View {
        HStack(spacing: 8) {
            metricCard(label: "Tokens") { Text(metrics.totalTokensText) }
            metricCard(label: "Context") { Text(metrics.contextText) }
            metricCard(label: "Elapsed") {
                if metrics.endedAt == nil {
                    // Live sessions tick once per second; only this label re-renders.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(metrics.elapsedText(now: context.date))
                    }
                } else {
                    Text(metrics.elapsedText(now: metrics.endedAt ?? .now))
                }
            }
        }
    }

    private func metricCard(label: String, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            value()
                .font(AgentStatusDesign.Font.UI.metricValue)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .font(AgentStatusDesign.Font.UI.metricLabel)
                .kerning(0.4)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 5, y: 4)
    }

    private func group(_ section: SessionSummarySectionPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(AgentStatusDesign.Font.UI.group)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(section.fields.enumerated()), id: \.offset) { _, field in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(field.label)
                            .font(AgentStatusDesign.Font.UI.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Text(field.value)
                            .font(field.isMonospaced ? AgentStatusDesign.Font.UI.mono : AgentStatusDesign.Font.UI.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .help(field.value)
                    }
                }
            }
        }
    }
}
