import AppKit
import SwiftUI

@MainActor
struct SessionDetailScrollableView: View {
    let presentation: SessionPagePresentation?
    let onPreview: (SessionActivityPresentation) -> Void

    var body: some View {
        ScrollViewReader { activityScrollProxy in
            ScrollView {
                if let presentation {
                    LazyVStack(
                        alignment: .leading,
                        spacing: 28,
                        pinnedViews: [.sectionHeaders]
                    ) {
                        summary(sections: presentation.summarySections)
                        activitySection(
                            presentation.activities,
                            scrollProxy: activityScrollProxy
                        )
                    }
                    .frame(
                        minWidth: AgentStatusDetailLayout.minimumContentWidth,
                        maxWidth: AgentStatusDetailLayout.maximumContentWidth,
                        alignment: .topLeading
                    )
                    .padding(.horizontal, AgentStatusDetailLayout.horizontalInset)
                    .padding(.top, AgentStatusDetailLayout.topInset)
                    .padding(.bottom, AgentStatusDetailLayout.bottomInset)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private func summary(
        sections: [SessionSummarySectionPresentation]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Summary")
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: 16) {
                ForEach(sections, id: \.kind.rawValue) { section in
                    SessionSummaryCard(section: section)
                }
            }
        }
    }

    private func activitySection(
        _ activities: [SessionActivityPresentation],
        scrollProxy: ScrollViewProxy
    ) -> some View {
        Section {
            if activities.isEmpty {
                Text("No Activity")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(activities, id: \.id) { activity in
                        Button {
                            onPreview(activity)
                        } label: {
                            SessionActivityRow(activity: activity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "\(activity.category.tag), \(activity.content), \(activity.occurredAt)"
                        )
                        .id(sessionActivityRowID(for: activity))

                        if activity.id != activities.last?.id {
                            Divider()
                                .padding(.leading, 110)
                        }
                    }
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Activity")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("\(activities.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }

                if !activities.isEmpty {
                    SessionActivityTimeline(activities: activities) { activity in
                        withAnimation(.easeInOut(duration: 0.22)) {
                            scrollProxy.scrollTo(
                                sessionActivityRowID(for: activity),
                                anchor: .center
                            )
                        }
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(Color.white)
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
    }
}

private func sessionActivityRowID(for activity: SessionActivityPresentation) -> String {
    "activity-row:\(activity.id)"
}

private struct SessionActivityTimeline: View {
    private static let cellSize: CGFloat = 13
    private static let rowSpacing: CGFloat = 4

    let activities: [SessionActivityPresentation]
    let onSelect: (SessionActivityPresentation) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: Self.rowSpacing) {
                ForEach(SessionActivityLane.allCases, id: \.rawValue) { lane in
                    Text(lane.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(height: Self.cellSize)
                }
            }
            .frame(width: 36, alignment: .trailing)

            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(alignment: .top, spacing: 4) {
                    ForEach(activities, id: \.id) { activity in
                        VStack(spacing: Self.rowSpacing) {
                            ForEach(SessionActivityLane.allCases, id: \.rawValue) { lane in
                                if activity.category.lane == lane {
                                    Button {
                                        onSelect(activity)
                                    } label: {
                                        SessionActivityTimelineCell(category: activity.category)
                                    }
                                    .buttonStyle(.plain)
                                    .help("\(activity.category.tag): \(activity.content)")
                                    .accessibilityLabel(
                                        "Jump to \(activity.category.tag), \(activity.content)"
                                    )
                                } else {
                                    Color.clear
                                        .frame(width: Self.cellSize, height: Self.cellSize)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
    }
}

private struct SessionActivityTimelineCell: View {
    private let cellSize: CGFloat = 13
    let category: SessionActivityCategory

    var body: some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(category.backgroundColor)
            .frame(width: cellSize, height: cellSize)
            .overlay {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .stroke(
                        category == .system
                            ? Color(nsColor: .separatorColor)
                            : .clear,
                        lineWidth: 1
                    )
            }
            .contentShape(Rectangle())
    }
}

private struct SessionSummaryCard: View {
    let section: SessionSummarySectionPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(section.title)
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(section.fields.enumerated()), id: \.offset) { _, field in
                    HStack(alignment: .firstTextBaseline, spacing: 20) {
                        Text(field.label)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 132, alignment: .leading)
                        Text(field.value)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
    }
}

private struct SessionActivityRow: View {
    let activity: SessionActivityPresentation

    var body: some View {
        HStack(spacing: 12) {
            SessionActivityTag(category: activity.category)
                .frame(width: 86)

            Text(activity.content)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(activity.occurredAt)
                .font(.system(size: 10, design: .monospaced).monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
        .contentShape(Rectangle())
        .frame(height: 44)
        .padding(.horizontal, 12)
    }
}

private struct SessionActivityTag: View {
    let category: SessionActivityCategory

    var body: some View {
        Text(category.tag)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(category.foregroundColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(category.backgroundColor, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                if category == .system {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
            }
    }
}

private extension SessionActivityCategory {
    var backgroundColor: Color {
        switch self {
        case .system: .white
        case .context: Color(nsColor: .systemBlue)
        case .user: Color(nsColor: .systemGreen)
        case .assistantReasoning: Color(nsColor: .systemPurple).opacity(0.16)
        case .assistant: Color(nsColor: .systemPurple)
        case .tool: Color(nsColor: .systemYellow)
        case .subagent: Color(nsColor: .systemOrange)
        case .other: Color(nsColor: .systemRed)
        }
    }

    var foregroundColor: Color {
        switch self {
        case .system: .primary
        case .assistantReasoning: Color(nsColor: .systemPurple)
        case .tool: .black
        case .context, .user, .assistant, .subagent, .other: .white
        }
    }
}
