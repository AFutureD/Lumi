import AgentStatusTransport
import AppKit
import SwiftUI

/// UI state that must survive `rootView` replacement: the lane strip mode,
/// the transient jump highlight, the hovered tool pair, and whether the list
/// is pinned to the bottom.
@MainActor
final class SessionActivityState: ObservableObject {
    private static let timelineModeKey = "AgentStatus.Activity.TimelineMode"

    /// Lanes vs single line; a user preference, so it survives session changes.
    @Published var timelineMode: ActivityTimelineMode {
        didSet { UserDefaults.standard.set(timelineMode.rawValue, forKey: Self.timelineModeKey) }
    }
    @Published var highlightedID: String?
    /// `toolUseID` under the pointer; its TOOL and RESULT rows light up together.
    @Published var hoveredToolUseID: String?
    var followsBottom = false
    /// Keeps the lane strip and the row list scrolled in step (not published:
    /// it is driven from scroll callbacks and must not re-render the list).
    let scrollSync = ActivityScrollSync()
    private var highlightTask: Task<Void, Never>?

    init() {
        timelineMode = UserDefaults.standard.string(forKey: Self.timelineModeKey)
            .flatMap(ActivityTimelineMode.init(rawValue:)) ?? .lanes
    }

    func reset() {
        highlightedID = nil
        hoveredToolUseID = nil
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

/// Activity: pinned header (title · count · lane strip toggle · User/Model/Exec
/// lane strip) over a chronological list of `TimelineRow`s. Turn boundaries
/// read from the rows themselves (USER … TURN END); there is no turn header.
/// Clicking a lane cell jumps to its row; clicking a row reveals its detail.
@MainActor
struct SessionActivityView: View {
    let presentation: SessionPagePresentation?
    @ObservedObject var state: SessionActivityState
    let onPreview: (SessionActivityPresentation) -> Void

    private var visibleActivities: [SessionActivityPresentation] {
        presentation?.activities ?? []
    }

    @State private var listPosition = ScrollPosition(edge: .top)

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
                        ForEach(activities) { activity in
                            SessionActivityRow(
                                activity: activity,
                                isHighlighted: state.highlightedID == activity.id,
                                isPairHighlighted: activity.toolUseID != nil
                                    && state.hoveredToolUseID == activity.toolUseID,
                                onHover: { hovering in
                                    if hovering {
                                        state.hoveredToolUseID = activity.toolUseID
                                    } else if state.hoveredToolUseID == activity.toolUseID {
                                        state.hoveredToolUseID = nil
                                    }
                                },
                                onOpen: { onPreview(activity) }
                            )
                            .id(sessionActivityRowID(for: activity))
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 24)
                }
            }
            .scrollPosition($listPosition)
            .onScrollGeometryChange(for: ActivityScrollSync.Geometry.self) { geometry in
                ActivityScrollSync.Geometry(
                    offset: geometry.contentOffset.y + geometry.contentInsets.top,
                    content: geometry.contentSize.height,
                    viewport: geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
                )
            } action: { _, geometry in
                state.followsBottom = geometry.offset + geometry.viewport >= geometry.content - 48
                state.scrollSync.listDidScroll(geometry)
            }
            .onAppear {
                state.scrollSync.scrollList = { offset in
                    listPosition.scrollTo(y: offset)
                }
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
                    Image(systemName: state.timelineMode == .lanes
                        ? "arrow.down.and.line.horizontal.and.arrow.up"
                        : "arrow.up.and.line.horizontal.and.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 14, height: 12)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help(state.timelineMode == .lanes ? "Show one timeline row" : "Show three lanes")
                .accessibilityLabel("Toggle timeline density")
            }

            if !activities.isEmpty {
                SessionActivityTimeline(
                    activities: activities.filter(\.appearsInLaneStrip),
                    mode: state.timelineMode,
                    sync: state.scrollSync
                ) { activity in
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
            AgentStatusDesign.Color.UI.activityHairline.frame(height: 1)
        }
    }
}

private extension SessionActivityPresentation {
    /// Rows that earn a lane-strip cell. TOOL calls are list-only (their
    /// RESULT stands for the call in the Exec lane), and Claude's periodic
    /// `total_tokens_reminder` context is bookkeeping noise in the strip.
    var appearsInLaneStrip: Bool {
        switch tag {
        case .tool:
            return false
        case .context:
            if case let .context(payload) = rawItem.payload, payload.kind == "total_tokens_reminder" {
                return false
            }
            return true
        default:
            return true
        }
    }
}

private func sessionActivityRowID(for activity: SessionActivityPresentation) -> String {
    "activity-row:\(activity.id)"
}

/// Keeps the lane strip and the row list at the same relative scroll offset.
/// Both sides report their geometry from `onScrollGeometryChange`; whichever
/// moved asks the other to follow, and a side that is already within a point
/// of the mapped position does nothing — so the two callbacks settle instead
/// of ping-ponging. Plain class on purpose: nothing here may trigger a SwiftUI
/// re-render of the list.
@MainActor
final class ActivityScrollSync {
    struct Geometry: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var viewport: CGFloat = 0

        var range: CGFloat { max(0, content - viewport) }
        var fraction: Double { range > 0 ? Double(min(max(offset, 0), range) / range) : 0 }
    }

    var scrollList: ((CGFloat) -> Void)?
    var scrollStrip: ((CGFloat) -> Void)?

    private(set) var list = Geometry()
    private(set) var strip = Geometry()

    func listDidScroll(_ geometry: Geometry) {
        list = geometry
        guard strip.range > 0 else { return }
        let target = CGFloat(geometry.fraction) * strip.range
        if abs(target - strip.offset) > 1 {
            scrollStrip?(target)
        }
    }

    func stripDidScroll(_ geometry: Geometry) {
        strip = geometry
        guard list.range > 0 else { return }
        let target = CGFloat(geometry.fraction) * list.range
        if abs(target - list.offset) > 1 {
            scrollList?(target)
        }
    }
}

/// Three lanes (User / Model / Exec); one 13pt column per strip row, drawn in
/// a single `Canvas` (one view for the whole strip instead of thousands of
/// cell views). A cell is filled with the tag's lane colour only in the row's
/// own lane; rows that span all lanes fill all three. TOOL calls are list-only
/// (the caller filters them out): the Exec lane shows results, so a call and
/// its result do not take two columns. The strip scrolls in step with the
/// list (and the list with the strip).
private struct SessionActivityTimeline: View {
    private static let cellSize = AgentStatusDesign.Layout.laneCellSize
    private static let spacing = AgentStatusDesign.Layout.laneCellSpacing
    private static var pitch: CGFloat { cellSize + spacing }

    let activities: [SessionActivityPresentation]
    let mode: ActivityTimelineMode
    let sync: ActivityScrollSync
    let onSelect: (SessionActivityPresentation) -> Void

    @State private var stripPosition = ScrollPosition(edge: .leading)
    @State private var hoveredIndex: Int?

    private var stripHeight: CGFloat {
        mode == .lanes ? Self.cellSize * 3 + Self.spacing * 2 : Self.cellSize
    }

    private var contentWidth: CGFloat {
        max(0, CGFloat(activities.count) * Self.pitch - Self.spacing)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: Self.spacing) {
                if mode == .lanes {
                    ForEach(TimelineLane.allCases, id: \.rawValue) { lane in
                        laneLabel(lane.title)
                    }
                } else {
                    laneLabel("Timeline")
                }
            }
            .frame(width: AgentStatusDesign.Layout.laneNameWidth, alignment: .trailing)

            ScrollView(.horizontal, showsIndicators: false) {
                canvas
                    .frame(width: contentWidth, height: stripHeight)
            }
            .scrollPosition($stripPosition)
            .onScrollGeometryChange(for: ActivityScrollSync.Geometry.self) { geometry in
                ActivityScrollSync.Geometry(
                    offset: geometry.contentOffset.x,
                    content: geometry.contentSize.width,
                    viewport: geometry.containerSize.width
                )
            } action: { _, geometry in
                sync.stripDidScroll(geometry)
            }
            .onAppear {
                sync.scrollStrip = { offset in
                    stripPosition.scrollTo(x: offset)
                }
            }
            .frame(height: stripHeight)
        }
        .frame(height: stripHeight)
    }

    private var canvas: some View {
        // `TimelineView` is not needed: the canvas redraws when the strip
        // scrolls (clip rect changes) and when activities change.
        Canvas(rendersAsynchronously: false) { context, size in
            let clip = context.clipBoundingRect
            let first = max(0, Int(clip.minX / Self.pitch))
            let last = min(activities.count - 1, Int(clip.maxX / Self.pitch) + 1)
            guard first <= last else { return }
            for index in first ... last {
                let activity = activities[index]
                let x = CGFloat(index) * Self.pitch
                let color = activity.tag.laneCellColor
                if mode == .lanes {
                    for (laneIndex, lane) in TimelineLane.allCases.enumerated()
                    where activity.lane == nil || activity.lane == lane {
                        let y = CGFloat(laneIndex) * Self.pitch
                        context.fill(cellPath(x: x, y: y), with: .color(color))
                    }
                } else {
                    context.fill(cellPath(x: x, y: 0), with: .color(color))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { location in
            guard let activity = activity(at: location) else { return }
            onSelect(activity)
        }
        .onContinuousHover { phase in
            switch phase {
            case let .active(location):
                let index = Int(location.x / Self.pitch)
                hoveredIndex = activities.indices.contains(index) ? index : nil
            case .ended:
                hoveredIndex = nil
            }
        }
        .help(hoveredIndex.map { "\(activities[$0].label): \(activities[$0].content)" } ?? "")
        .accessibilityLabel("Activity timeline, \(activities.count) items")
    }

    private func cellPath(x: CGFloat, y: CGFloat) -> Path {
        Path(
            roundedRect: CGRect(x: x, y: y, width: Self.cellSize, height: Self.cellSize),
            cornerRadius: 3,
            style: .continuous
        )
    }

    private func activity(at location: CGPoint) -> SessionActivityPresentation? {
        let index = Int(location.x / Self.pitch)
        guard activities.indices.contains(index) else { return nil }
        return activities[index]
    }

    private func laneLabel(_ title: String) -> some View {
        Text(title)
            .font(AgentStatusDesign.Font.UI.laneName)
            .foregroundStyle(AgentStatusDesign.Color.UI.inkTertiary)
            .frame(height: Self.cellSize)
    }
}

/// `[time 56] [tag 82] [content] [chevron]`, 40pt tall (32 for markers that
/// span all lanes), 12pt column gap, hairline bottom.
private struct SessionActivityRow: View {
    let activity: SessionActivityPresentation
    let isHighlighted: Bool
    let isPairHighlighted: Bool
    let onHover: (Bool) -> Void
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Text(activity.occurredAt)
                    .font(AgentStatusDesign.Font.UI.monoSmall)
                    .foregroundStyle(AgentStatusDesign.Color.UI.inkQuaternary)
                    .lineLimit(1)
                    .frame(width: AgentStatusDesign.Layout.activityTimestampWidth, alignment: .leading)

                TimelineTagChip(tag: activity.tag, label: activity.label)
                    .frame(width: AgentStatusDesign.Layout.activityTagWidth)

                Text(activity.content)
                    .font(AgentStatusDesign.Font.UI.body)
                    .foregroundStyle(AgentStatusDesign.Color.UI.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AgentStatusDesign.Color.UI.chevron)
                    .frame(width: 7, height: 11)
            }
            .padding(.horizontal, AgentStatusDesign.Layout.activityHorizontalInset)
            .frame(height: activity.lane == nil
                ? AgentStatusDesign.Layout.activityMarkerRowHeight
                : AgentStatusDesign.Layout.activityRowHeight)
            .background(rowBackground)
            .overlay(alignment: .bottom) {
                AgentStatusDesign.Color.UI.activityHairline.frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .accessibilityLabel("\(activity.label), \(activity.content), \(activity.occurredAt)")
        .animation(.easeOut(duration: 0.2), value: isHighlighted)
        .animation(.easeOut(duration: 0.12), value: isPairHighlighted)
    }

    private var rowBackground: Color {
        if isHighlighted { return Color.accentColor.opacity(0.12) }
        if isPairHighlighted { return activity.tag.accentColor.opacity(0.08) }
        return .clear
    }
}

/// 82pt chip, `padding 3px 0` (height 17), radius 5, 9/700/.04em, coloured by
/// attention level (see `TimelineTagStyle`). `compact` is the Notch's 60pt
/// variant: `padding 2px 0`, `.03em`.
struct TimelineTagChip: View {
    let tag: TimelineTag
    let label: String
    var dark = false
    var compact = false

    var body: some View {
        let style = TimelineTagStyle.style(for: tag, dark: dark)
        Text(label)
            .font(AgentStatusDesign.Font.UI.tag)
            .kerning(compact ? 0.27 : 0.36)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(style.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 2 : 3)
            .background(
                style.fill,
                in: RoundedRectangle(cornerRadius: AgentStatusDesign.Layout.activityTagCornerRadius, style: .continuous)
            )
            .overlay {
                if let ring = style.ring {
                    RoundedRectangle(cornerRadius: AgentStatusDesign.Layout.activityTagCornerRadius, style: .continuous)
                        .strokeBorder(ring, lineWidth: 0.5)
                }
            }
    }
}
