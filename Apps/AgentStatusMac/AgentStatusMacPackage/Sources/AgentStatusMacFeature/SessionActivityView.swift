import AppKit
import SwiftUI

/// UI state that must survive `rootView` replacement: the lane filter, the
/// transient jump highlight, and whether the list is pinned to the bottom.
@MainActor
final class SessionActivityState: ObservableObject {
    private static let timelineModeKey = "AgentStatus.Activity.TimelineMode"

    /// Lanes vs single line; a user preference, so it survives session changes.
    @Published var timelineMode: ActivityTimelineMode {
        didSet { UserDefaults.standard.set(timelineMode.rawValue, forKey: Self.timelineModeKey) }
    }
    @Published var highlightedID: String?
    var followsBottom = false
    private var highlightTask: Task<Void, Never>?

    init() {
        timelineMode = UserDefaults.standard.string(forKey: Self.timelineModeKey)
            .flatMap(ActivityTimelineMode.init(rawValue:)) ?? .lanes
    }

    func reset() {
        highlightedID = nil
        followsBottom = false
        highlightTask?.cancel()
    }

    func highlight(_ id: String) {
        highlightTask?.cancel()
        highlightedID = id
        highlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled, self?.highlightedID == id else { return }
            self?.highlightedID = nil
        }
    }
}

/// Activity: pinned header (title · count · lane filter · three-lane timeline)
/// over a chronological list of rows. Clicking a lane cell jumps to its row;
/// clicking a row opens the raw JSON.
@MainActor
struct SessionActivityView: View {
    let presentation: SessionPagePresentation?
    @ObservedObject var state: SessionActivityState
    let onPreview: (SessionActivityPresentation) -> Void

    private var visibleActivities: [SessionActivityPresentation] {
        presentation?.activities ?? []
    }

    var body: some View {
        let activities = visibleActivities
        ScrollViewReader { proxy in
            ScrollView {
                if activities.isEmpty {
                    Text(presentation == nil ? "" : "No Activity")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                            SessionActivityRow(
                                activity: activity,
                                isZebra: index.isMultiple(of: 2) == false,
                                isHighlighted: state.highlightedID == activity.id,
                                onOpen: { onPreview(activity) }
                            )
                            .id(sessionActivityRowID(for: activity))
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 24)
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
            } action: { _, nearBottom in
                state.followsBottom = nearBottom
            }
            .onChange(of: activities.count) { previous, current in
                guard current > previous, state.followsBottom, let last = activities.last else { return }
                proxy.scrollTo(sessionActivityRowID(for: last), anchor: .bottom)
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                header(activities: activities, proxy: proxy)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.colorScheme, .light)
    }

    private func header(activities: [SessionActivityPresentation], proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Text("Activity")
                    .font(AgentStatusDesign.Font.UI.section)
                    .fixedSize()
                Text("\(activities.count)")
                    .font(AgentStatusDesign.Font.UI.pill.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(AgentStatusDesign.Color.UI.chipFill, in: Capsule())
                Spacer(minLength: 8)
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        state.timelineMode = state.timelineMode.toggled
                    }
                } label: {
                    Image(systemName: "arrow.up.and.line.horizontal.and.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 14, height: 12)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help(state.timelineMode == .lanes ? "Show one timeline row" : "Show three lanes")
                .accessibilityLabel("Toggle timeline density")
            }

            if !activities.isEmpty {
                SessionActivityTimeline(activities: activities, mode: state.timelineMode) { activity in
                    withAnimation(.easeInOut(duration: 0.22)) {
                        proxy.scrollTo(sessionActivityRowID(for: activity), anchor: .center)
                    }
                    state.highlight(activity.id)
                }
            }
        }
        .padding(.horizontal, AgentStatusDesign.Layout.activityHorizontalInset)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottom) {
            AgentStatusDesign.Color.UI.hairline.frame(height: 1)
        }
    }
}

private func sessionActivityRowID(for activity: SessionActivityPresentation) -> String {
    "activity-row:\(activity.id)"
}

/// Three lanes (Input / Tools / Model); one 13pt column per item; empty lanes stay clear.
private struct SessionActivityTimeline: View {
    private static let cellSize = AgentStatusDesign.Layout.laneCellSize
    private static let spacing = AgentStatusDesign.Layout.laneCellSpacing

    let activities: [SessionActivityPresentation]
    let mode: ActivityTimelineMode
    let onSelect: (SessionActivityPresentation) -> Void

    private var stripHeight: CGFloat {
        mode == .lanes ? Self.cellSize * 3 + Self.spacing * 2 : Self.cellSize
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: Self.spacing) {
                if mode == .lanes {
                    ForEach(SessionActivityLane.allCases, id: \.rawValue) { lane in
                        laneLabel(lane.title)
                    }
                } else {
                    laneLabel("Timeline")
                }
            }
            .frame(width: AgentStatusDesign.Layout.laneNameWidth, alignment: .trailing)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(activities, id: \.id) { activity in
                        if mode == .lanes {
                            VStack(spacing: Self.spacing) {
                                ForEach(SessionActivityLane.allCases, id: \.rawValue) { lane in
                                    if activity.category.lane == lane {
                                        cell(for: activity)
                                    } else {
                                        Color.clear
                                            .frame(width: Self.cellSize, height: Self.cellSize)
                                            .accessibilityHidden(true)
                                    }
                                }
                            }
                        } else {
                            cell(for: activity)
                        }
                    }
                }
            }
            .frame(height: stripHeight)
        }
        .frame(height: stripHeight)
    }

    private func laneLabel(_ title: String) -> some View {
        Text(title)
            .font(AgentStatusDesign.Font.UI.laneName)
            .foregroundStyle(.secondary)
            .frame(height: Self.cellSize)
    }

    private func cell(for activity: SessionActivityPresentation) -> some View {
        Button {
            onSelect(activity)
        } label: {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(activity.category.laneCellColor)
                .frame(width: Self.cellSize, height: Self.cellSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(activity.category.tag): \(activity.content)")
        .accessibilityLabel("Jump to \(activity.category.tag), \(activity.content)")
    }
}

/// `[time 56] [tag 82] [content] [chevron]`, 40pt tall.
private struct SessionActivityRow: View {
    let activity: SessionActivityPresentation
    let isZebra: Bool
    let isHighlighted: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Text(activity.occurredAt)
                    .font(AgentStatusDesign.Font.UI.monoSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: AgentStatusDesign.Layout.activityTimestampWidth, alignment: .leading)

                SessionActivityTag(category: activity.category)
                    .frame(width: AgentStatusDesign.Layout.activityTagWidth)

                Text(activity.content)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, AgentStatusDesign.Layout.activityHorizontalInset)
            .frame(height: AgentStatusDesign.Layout.activityRowHeight)
            .background(rowBackground)
            .overlay(alignment: .bottom) {
                AgentStatusDesign.Color.UI.hairline.frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(activity.category.tag), \(activity.content), \(activity.occurredAt)")
        .animation(.easeOut(duration: 0.2), value: isHighlighted)
    }

    private var rowBackground: Color {
        if isHighlighted { return Color.accentColor.opacity(0.12) }
        return isZebra ? AgentStatusDesign.Color.UI.zebra : .clear
    }
}

private struct SessionActivityTag: View {
    let category: SessionActivityCategory

    var body: some View {
        Text(category.tag)
            .font(AgentStatusDesign.Font.UI.tag)
            .kerning(0.36)
            .foregroundStyle(category.labelForeground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .background(
                category.labelBackground,
                in: RoundedRectangle(cornerRadius: AgentStatusDesign.Layout.activityTagCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AgentStatusDesign.Layout.activityTagCornerRadius, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
            }
    }
}
