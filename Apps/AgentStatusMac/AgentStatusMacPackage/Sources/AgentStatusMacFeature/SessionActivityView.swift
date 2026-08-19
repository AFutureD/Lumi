import AgentStatusDesignSystem
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
    let scrollLink = ActivityScrollLink()
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
                        .font(AgentStatusDesign.Font.UI.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AgentStatusDesign.Layout.activityHorizontalInset)
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
                    .padding(.top, DesignSystem.Spacing.s)
                    .padding(.bottom, AgentStatusDesign.Layout.activityHorizontalInset)
                }
            }
            .scrollPosition($listPosition)
            .onScrollGeometryChange(for: ActivityScrollLink.Geometry.self) { geometry in
                ActivityScrollLink.Geometry(
                    offset: geometry.contentOffset.y + geometry.contentInsets.top,
                    content: geometry.contentSize.height,
                    viewport: geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
                )
            } action: { _, geometry in
                state.followsBottom = geometry.offset + geometry.viewport >= geometry.content - 48
                state.scrollLink.listDidScroll(geometry)
            }
            .onScrollPhaseChange { _, phase in
                state.scrollLink.listPhaseChanged(isUserScrolling: phase.isUserDriven)
            }
            .onAppear {
                state.scrollLink.scrollList = { offset in
                    scrollInstantly { listPosition.scrollTo(y: offset) }
                }
            }
            .onChange(of: scrollMapKey, initial: true) { _, _ in
                state.scrollLink.map = scrollMap(for: activities)
            }
            .onChange(of: activities.count) { previous, current in
                guard current > previous, state.followsBottom, let last = activities.last else { return }
                proxy.scrollTo(sessionActivityRowID(for: last), anchor: .bottom)
                state.scrollLink.scrollStripToEnd()
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                header(activities: activities, proxy: proxy)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.colorScheme, .light)
    }

    /// The map only depends on row kinds, so rebuild it when the row set changes.
    private var scrollMapKey: ActivityScrollMapKey {
        ActivityScrollMapKey(count: visibleActivities.count, first: visibleActivities.first?.id, last: visibleActivities.last?.id)
    }

    private func scrollMap(for activities: [SessionActivityPresentation]) -> ActivityScrollMap {
        ActivityScrollMap(
            rows: activities.map { activity in
                (
                    height: activity.lane == nil
                        ? AgentStatusDesign.Layout.activityMarkerRowHeight
                        : AgentStatusDesign.Layout.activityRowHeight,
                    drawsCell: activity.appearsInLaneStrip
                )
            },
            topInset: DesignSystem.Spacing.s,
            pitch: AgentStatusDesign.Layout.laneCellSize + AgentStatusDesign.Layout.laneCellSpacing
        )
    }

    private func header(activities: [SessionActivityPresentation], proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.mPlus) {
            HStack(spacing: DesignSystem.Spacing.mPlus) {
                Text("Activity")
                    .font(AgentStatusDesign.Font.UI.section)
                    .fixedSize()
                Text("\(activities.count)")
                    .font(AgentStatusDesign.Font.UI.pill.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DesignSystem.Metrics.countPillHorizontalPadding)
                    .padding(.vertical, DesignSystem.Metrics.countPillVerticalPadding)
                    .background(AgentStatusDesign.Color.UI.chipFill, in: Capsule())
                Spacer(minLength: DesignSystem.Spacing.m)
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        state.timelineMode = state.timelineMode.toggled
                    }
                } label: {
                    Image(systemName: state.timelineMode == .lanes
                        ? "arrow.down.and.line.horizontal.and.arrow.up"
                        : "arrow.up.and.line.horizontal.and.arrow.down")
                        .font(AgentStatusDesign.Font.UI.caption)
                        .frame(width: DesignSystem.Icon.toolbar, height: DesignSystem.Spacing.l)
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
                    link: state.scrollLink
                ) { activity in
                    // Programmatic: the list goes to the row, the strip stays put.
                    withAnimation(.easeInOut(duration: 0.22)) {
                        proxy.scrollTo(sessionActivityRowID(for: activity), anchor: .center)
                    }
                    state.highlight(activity.id)
                }
            }
        }
        .padding(.horizontal, AgentStatusDesign.Layout.activityHorizontalInset)
        .padding(.vertical, DesignSystem.Spacing.l)
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

/// Follower / pan scrolls are instantaneous: an implicit animation here would
/// lag the driver and leave the two sides out of step mid-gesture.
private func scrollInstantly(_ body: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, body)
}

private struct ActivityScrollMapKey: Equatable {
    var count: Int
    var first: String?
    var last: String?
}

private extension ScrollPhase {
    /// The user's finger / wheel is moving this scroll view (or it is coasting
    /// from that); programmatic `scrollTo` reports `.animating` / `.idle`.
    var isUserDriven: Bool {
        switch self {
        case .tracking, .interacting, .decelerating: true
        case .idle, .animating: false
        @unknown default: false
        }
    }
}

private func sessionActivityRowID(for activity: SessionActivityPresentation) -> String {
    "activity-row:\(activity.id)"
}

/// Row ↔ column mapping between the Activity list and the lane strip.
///
/// Every list row has a fixed height (item 40 / marker 32) below a fixed top
/// inset, and every strip column sits on a fixed pitch, so the two scroll
/// offsets relate through indices, not proportions: the row at the list's top
/// edge is the column at the strip's left edge. Rows that have no strip cell
/// (TOOL, bookkeeping context) map onto the column of the next row that has
/// one, so the mapping stays monotonic. Within a row / column the offset is
/// interpolated, which keeps the follower moving smoothly. Pure value type —
/// unit-tested, no SwiftUI.
struct ActivityScrollMap: Equatable {
    /// Top edge of each list row, in list content coordinates; one trailing
    /// entry holds the content bottom.
    private(set) var rowTops: [CGFloat] = [0]
    /// Strip column that stands for each list row (the row's own cell, or the
    /// next row's when this row draws no cell); one trailing entry holds the
    /// column count.
    private(set) var columnOfRow: [Int] = [0]
    /// List row shown by each strip column.
    private(set) var rowOfColumn: [Int] = []
    var pitch: CGFloat = 1

    init() {}

    /// - Parameters:
    ///   - rows: per list row, `(height, drawsCell)`.
    ///   - topInset: list content padding above the first row.
    ///   - pitch: strip column pitch (cell + gap).
    init(rows: [(height: CGFloat, drawsCell: Bool)], topInset: CGFloat, pitch: CGFloat) {
        self.pitch = pitch
        rowTops.reserveCapacity(rows.count + 1)
        columnOfRow.reserveCapacity(rows.count + 1)
        rowTops = [topInset]
        columnOfRow = []
        var column = 0
        for (index, row) in rows.enumerated() {
            columnOfRow.append(column)
            if row.drawsCell {
                rowOfColumn.append(index)
                column += 1
            }
            rowTops.append(rowTops[index] + row.height)
        }
        columnOfRow.append(column)
    }

    var rowCount: Int { rowTops.count - 1 }
    var columnCount: Int { rowOfColumn.count }

    /// Strip offset whose left edge shows the column of the row at `listOffset`.
    func stripOffset(forListOffset listOffset: CGFloat) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        let row = rowIndex(at: listOffset)
        let top = rowTops[row], height = rowTops[row + 1] - top
        let progress = height > 0 ? min(max((listOffset - top) / height, 0), 1) : 0
        let column: CGFloat
        if columnOfRow[row + 1] > columnOfRow[row] {
            column = CGFloat(columnOfRow[row]) + progress // this row draws a cell
        } else {
            column = CGFloat(columnOfRow[row]) // parked on the next cell
        }
        return column * pitch
    }

    /// List offset whose top edge shows the row of the column at `stripOffset`.
    func listOffset(forStripOffset stripOffset: CGFloat) -> CGFloat {
        guard columnCount > 0 else { return 0 }
        let exact = max(stripOffset, 0) / pitch
        let column = min(Int(exact), columnCount - 1)
        let progress = min(exact - CGFloat(column), 1)
        let row = rowOfColumn[column]
        let top = rowTops[row], height = rowTops[row + 1] - top
        return top + progress * height
    }

    /// Index of the row containing `listOffset` (clamped to the first / last row).
    func rowIndex(at listOffset: CGFloat) -> Int {
        // Binary search over rowTops: largest row with rowTops[row] <= offset.
        var low = 0, high = rowCount - 1
        if listOffset < rowTops[0] { return 0 }
        while low < high {
            let mid = (low + high + 1) / 2
            if rowTops[mid] <= listOffset { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// Links the lane strip and the row list so they scroll in step, with an
/// explicit notion of **who is driving**.
///
/// - The side the user is actually scrolling (`ScrollPhase` tracking /
///   interacting / decelerating, or the strip's pan gesture) is the driver;
///   the other side follows through `ActivityScrollMap`. A follower never
///   steers, so there is no echo, no rounding loop, no jitter by construction.
/// - Programmatic scrolls (click-to-row, follow-bottom) do not propagate: the
///   caller decides explicitly whether the other side moves too.
///
/// Plain class on purpose: nothing here may trigger a SwiftUI re-render.
@MainActor
final class ActivityScrollLink {
    struct Geometry: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var viewport: CGFloat = 0

        var range: CGFloat { max(0, content - viewport) }
    }

    enum Driver { case none, list, strip }

    var scrollList: ((CGFloat) -> Void)?
    var scrollStrip: ((CGFloat) -> Void)?

    var map = ActivityScrollMap()
    private(set) var driver = Driver.none
    private(set) var list = Geometry()
    private(set) var strip = Geometry()

    // MARK: Who is driving

    func listPhaseChanged(isUserScrolling: Bool) {
        setDriver(.list, active: isUserScrolling)
    }

    func stripPhaseChanged(isUserScrolling: Bool) {
        setDriver(.strip, active: isUserScrolling)
    }

    /// The strip's pan gesture scrolls programmatically, so it declares itself.
    func beginStripPan() { setDriver(.strip, active: true) }
    func endStripPan() { setDriver(.strip, active: false) }

    private func setDriver(_ side: Driver, active: Bool) {
        if active {
            driver = side
        } else if driver == side {
            driver = .none
        }
    }

    // MARK: Geometry reports

    func listDidScroll(_ geometry: Geometry) {
        list = geometry
        guard driver == .list else { return }
        let target = min(max(map.stripOffset(forListOffset: geometry.offset), 0), strip.range)
        if abs(target - strip.offset) > 0.5 {
            scrollStrip?(target)
        }
    }

    func stripDidScroll(_ geometry: Geometry) {
        strip = geometry
        guard driver == .strip else { return }
        let target = min(max(map.listOffset(forStripOffset: geometry.offset), 0), list.range)
        if abs(target - list.offset) > 0.5 {
            scrollList?(target)
        }
    }

    // MARK: Explicit programmatic moves

    /// Follow-bottom: new rows arrived while pinned to the end; both sides show the end.
    func scrollStripToEnd() {
        scrollStrip?(strip.range)
    }
}

/// Pure geometry of the lane strip: column `index` along x, `lane` along y,
/// `cellSize` squares on a `cellSize + spacing` pitch. Hit-testing lands only
/// inside a square (never in the gaps) and only on a *filled* cell, so the
/// caller supplies the fill rule. Kept free of SwiftUI so it can be unit-tested.
struct LaneStripGeometry: Equatable {
    struct Cell: Equatable {
        var index: Int
        var lane: Int
    }

    var cellSize: CGFloat
    var spacing: CGFloat
    var laneCount: Int

    var pitch: CGFloat { cellSize + spacing }
    var height: CGFloat { cellSize * CGFloat(laneCount) + spacing * CGFloat(laneCount - 1) }

    func contentWidth(columns: Int) -> CGFloat {
        max(0, CGFloat(columns) * pitch - spacing)
    }

    func rect(index: Int, lane: Int) -> CGRect {
        CGRect(x: CGFloat(index) * pitch, y: CGFloat(lane) * pitch, width: cellSize, height: cellSize)
    }

    /// Columns intersecting `clip` (clamped to `columns`), for partial redraws.
    func visibleColumns(in clip: CGRect, columns: Int) -> ClosedRange<Int>? {
        guard columns > 0 else { return nil }
        let first = max(0, Int(clip.minX / pitch))
        let last = min(columns - 1, Int(clip.maxX / pitch) + 1)
        return first <= last ? first ... last : nil
    }

    /// The cell under `location`, or `nil` over a gap, outside the strip, or
    /// on a cell `isFilled` rejects.
    func cell(at location: CGPoint, columns: Int, isFilled: (Cell) -> Bool) -> Cell? {
        guard location.x >= 0, location.y >= 0 else { return nil }
        let cell = Cell(index: Int(location.x / pitch), lane: Int(location.y / pitch))
        guard cell.index < columns, cell.lane < laneCount,
              rect(index: cell.index, lane: cell.lane).contains(location),
              isFilled(cell)
        else { return nil }
        return cell
    }
}

/// Three lanes (User / Model / Exec); one 13pt column per strip row, drawn in
/// a single `Canvas` (one view for the whole strip instead of thousands of
/// cell views). A cell is filled with the tag's lane colour only in the row's
/// own lane; rows that span all lanes fill all three. TOOL calls are list-only
/// (the caller filters them out): the Exec lane shows results, so a call and
/// its result do not take two columns. The strip scrolls in step with the
/// list (and the list with the strip).
///
/// Interaction: only filled cells are targets — the pointer becomes a hand
/// and the cell gets a hover ring; clicking one scrolls the list to its row.
/// Empty cells and the gaps between columns are inert. Pressing and dragging
/// anywhere on the strip pans it (AppKit scroll views only pan with the
/// trackpad / wheel, so the drag is mapped onto the scroll position by hand).
private struct SessionActivityTimeline: View {
    /// A press that travels further than this is a pan, not a click.
    private static let dragThreshold: CGFloat = 3

    let activities: [SessionActivityPresentation]
    let mode: ActivityTimelineMode
    let link: ActivityScrollLink
    let onSelect: (SessionActivityPresentation) -> Void

    @State private var stripPosition = ScrollPosition(edge: .leading)
    /// Filled cell under the pointer (column + lane); `nil` over empty space.
    @State private var hoveredCell: LaneStripGeometry.Cell?
    /// Strip offset when the current pan began.
    @State private var panOrigin: CGFloat?

    private var geometry: LaneStripGeometry {
        LaneStripGeometry(
            cellSize: AgentStatusDesign.Layout.laneCellSize,
            spacing: AgentStatusDesign.Layout.laneCellSpacing,
            laneCount: mode == .lanes ? TimelineLane.allCases.count : 1
        )
    }

    private var stripHeight: CGFloat { geometry.height }
    private var contentWidth: CGFloat { geometry.contentWidth(columns: activities.count) }

    var body: some View {
        HStack(alignment: .top, spacing: AgentStatusDesign.Layout.activityColumnGap) {
            VStack(alignment: .trailing, spacing: geometry.spacing) {
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
            .onScrollGeometryChange(for: ActivityScrollLink.Geometry.self) { geometry in
                ActivityScrollLink.Geometry(
                    offset: geometry.contentOffset.x,
                    content: geometry.contentSize.width,
                    viewport: geometry.containerSize.width
                )
            } action: { _, geometry in
                link.stripDidScroll(geometry)
            }
            .onScrollPhaseChange { _, phase in
                link.stripPhaseChanged(isUserScrolling: phase.isUserDriven)
            }
            .onAppear {
                link.scrollStrip = { offset in
                    scrollInstantly { stripPosition.scrollTo(x: offset) }
                }
            }
            .frame(height: stripHeight)
        }
        .frame(height: stripHeight)
    }

    private var canvas: some View {
        // `TimelineView` is not needed: the canvas redraws when the strip
        // scrolls (clip rect changes), when activities change and on hover.
        Canvas(rendersAsynchronously: false) { context, _ in
            let geometry = geometry
            guard let columns = geometry.visibleColumns(in: context.clipBoundingRect, columns: activities.count) else { return }
            for index in columns {
                let activity = activities[index]
                let color = Color(activity.tag.laneCellColor)
                for lane in 0 ..< geometry.laneCount where isFilled(activity, lane: lane) {
                    context.fill(cellPath(index: index, lane: lane), with: .color(color))
                }
            }
            if let hoveredCell {
                context.stroke(
                    cellPath(index: hoveredCell.index, lane: hoveredCell.lane),
                    with: .color(Color(DesignSystem.Ink.hoverRing)),
                    lineWidth: DesignSystem.Stroke.separator
                )
            }
        }
        .contentShape(Rectangle())
        // Click on a filled cell → jump the list. Registered before the pan
        // gesture so a press that stays put is a click, not a zero-length pan.
        .onTapGesture { location in
            guard let cell = cell(at: location) else { return }
            onSelect(activities[cell.index])
        }
        .gesture(panGesture)
        .onContinuousHover { phase in
            switch phase {
            case let .active(location):
                let cell = panOrigin == nil ? cell(at: location) : nil
                if cell != hoveredCell {
                    hoveredCell = cell
                    (cell == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
                }
            case .ended:
                hoveredCell = nil
                NSCursor.arrow.set()
            }
        }
        .help(hoveredCell.map { "\(activities[$0.index].label): \(activities[$0.index].content)" } ?? "")
        .accessibilityLabel("Activity timeline, \(activities.count) items")
    }

    /// Press-and-drag pans the strip: the pointer stays glued to the content
    /// (drag right → content follows right), clamped to the scrollable range.
    /// The pan declares the strip as driver, so the list follows.
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: Self.dragThreshold, coordinateSpace: .local)
            .onChanged { value in
                if panOrigin == nil {
                    panOrigin = link.strip.offset
                    hoveredCell = nil
                    link.beginStripPan()
                    NSCursor.closedHand.set()
                }
                let origin = panOrigin ?? 0
                let target = min(max(origin - value.translation.width, 0), link.strip.range)
                scrollInstantly { stripPosition.scrollTo(x: target) }
            }
            .onEnded { _ in
                panOrigin = nil
                link.endStripPan()
                NSCursor.arrow.set()
            }
    }

    // MARK: Geometry

    private func isFilled(_ activity: SessionActivityPresentation, lane: Int) -> Bool {
        mode == .single || activity.lane == nil || activity.lane == TimelineLane.allCases[lane]
    }

    private func cellPath(index: Int, lane: Int) -> Path {
        Path(
            roundedRect: geometry.rect(index: index, lane: lane),
            cornerRadius: AgentStatusDesign.Layout.laneCellCornerRadius,
            style: .continuous
        )
    }

    /// The filled cell under `location`, or `nil` over an empty cell or a gap.
    private func cell(at location: CGPoint) -> LaneStripGeometry.Cell? {
        geometry.cell(at: location, columns: activities.count) { cell in
            isFilled(activities[cell.index], lane: cell.lane)
        }
    }

    private func laneLabel(_ title: String) -> some View {
        Text(title)
            .font(AgentStatusDesign.Font.UI.laneName)
            .foregroundStyle(AgentStatusDesign.Color.UI.inkTertiary)
            .frame(height: geometry.cellSize)
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
            HStack(spacing: AgentStatusDesign.Layout.activityColumnGap) {
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
                    .font(AgentStatusDesign.Font.UI.tag)
                    .foregroundStyle(AgentStatusDesign.Color.UI.chevron)
                    .frame(width: AgentStatusDesign.Layout.rowChevronSize.width, height: AgentStatusDesign.Layout.rowChevronSize.height)
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
        if isHighlighted { return Color(DesignSystem.Ink.accent.opacity(DesignSystem.Opacity.jumpHighlight)) }
        if isPairHighlighted { return Color(activity.tag.categoryColor.opacity(DesignSystem.Opacity.pairHighlight)) }
        return .clear
    }
}

/// 82pt chip, `padding 3px 0` (height 17), radius 5, 9/700/.04em, coloured by
/// attention level (see `TimelineTagStyle`). Every tier carries a `.5px`
/// inset ring. `compact` is the Notch's 60pt variant: `padding 2px 0`, `.03em`.
struct TimelineTagChip: View {
    let tag: TimelineTag
    let label: String
    var appearance: DesignAppearance = .light
    var compact = false

    var body: some View {
        let style = TimelineTagStyle.style(for: tag, appearance: appearance)
        let text = compact ? DesignSystem.Typography.notchTag : DesignSystem.Typography.tag
        let shape = RoundedRectangle(cornerRadius: AgentStatusDesign.Layout.activityTagCornerRadius, style: .continuous)
        Text(label)
            .designText(text)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(style.textColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact
                ? DesignSystem.Notch.activityTagVerticalPadding
                : AgentStatusDesign.Layout.activityTagVerticalPadding)
            .background(style.fillColor, in: shape)
            .overlay {
                shape.strokeBorder(style.ringColor, lineWidth: DesignSystem.Stroke.hairline)
            }
    }
}
