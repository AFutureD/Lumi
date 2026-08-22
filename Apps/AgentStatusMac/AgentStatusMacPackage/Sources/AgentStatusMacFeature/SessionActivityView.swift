import AgentStatusCore
import AgentStatusDesignSystem
import AgentStatusTransport
import AppKit
import SwiftUI

/// UI state that must survive `rootView` replacement: the lane strip mode,
/// the Activity filter and its open panel, the transient jump highlight, the
/// hovered tool pair, and whether the list is pinned to the bottom.
@MainActor
final class SessionActivityState: ObservableObject {
    private static let timelineModeKey = "AgentStatus.Activity.TimelineMode"

    /// Lanes vs single line; a user preference, so it survives session changes.
    @Published var timelineMode: ActivityTimelineMode {
        didSet { UserDefaults.standard.set(timelineMode.rawValue, forKey: Self.timelineModeKey) }
    }
    /// Category × Importance filter of the list; per session (reset on switch).
    @Published var filter = SessionActivityFilter()
    /// The FilterDropdown panel that is open, if any (at most one).
    @Published var openFilterPanel: ActivityFilterDimension?
    @Published var highlightedID: String?
    /// `toolUseID` under the pointer; its TOOL and RESULT rows light up together.
    @Published var hoveredToolUseID: String?
    var followsBottom = false
    /// Keeps the lane strip and the row list scrolled in step (not published:
    /// it is driven from scroll callbacks and must not re-render the list).
    let scrollLink = ActivityScrollLink()
    /// The one open filter panel window and the triggers it drops under.
    let filterPresenter = FilterDropdownPresenter()
    private let filterAnchors: [ActivityFilterDimension: FilterAnchorBox]
    private var highlightTask: Task<Void, Never>?

    init() {
        timelineMode = UserDefaults.standard.string(forKey: Self.timelineModeKey)
            .flatMap(ActivityTimelineMode.init(rawValue:)) ?? .lanes
        filterAnchors = Dictionary(uniqueKeysWithValues: ActivityFilterDimension.allCases.map { ($0, FilterAnchorBox()) })
        for anchor in filterAnchors.values {
            // The trigger left the window (session cleared, sidebar switched):
            // the panel must not outlive it.
            anchor.onDetach = { [weak self] in
                guard let self, self.openFilterPanel != nil else { return }
                self.filterPresenter.dismissAll()
                Task { @MainActor [weak self] in self?.openFilterPanel = nil }
            }
        }
    }

    func anchor(for dimension: ActivityFilterDimension) -> FilterAnchorBox {
        filterAnchors[dimension]!
    }

    func reset() {
        highlightedID = nil
        hoveredToolUseID = nil
        followsBottom = false
        highlightTask?.cancel()
        filter.reset()
        openFilterPanel = nil
        filterPresenter.dismissAll()
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

/// Activity: pinned header (title · count · Category / Importance filters ·
/// lane strip toggle · User/Model/Exec lane strip) over a chronological list
/// of `TimelineRow`s. Turn boundaries read from the rows themselves (USER …
/// TURN END); there is no turn header. The filters narrow the list only —
/// the strip always draws every row, so what is hidden stays visible as
/// context. Clicking a lane cell jumps to its row; clicking a row reveals
/// its detail.
@MainActor
struct SessionActivityView: View {
    let presentation: SessionPagePresentation?
    @ObservedObject var state: SessionActivityState
    let onPreview: (SessionActivityPresentation) -> Void

    private var allActivities: [SessionActivityPresentation] {
        presentation?.activities ?? []
    }

    private var visibleActivities: [SessionActivityPresentation] {
        state.filter.isFiltering ? allActivities.filter(state.filter.includes) : allActivities
    }

    @State private var listPosition = ScrollPosition(edge: .top)

    var body: some View {
        let all = allActivities
        let activities = visibleActivities
        ScrollViewReader { proxy in
            ScrollView {
                if all.isEmpty {
                    Text(presentation == nil ? "" : "No Activity")
                        .font(AgentStatusDesign.Font.UI.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AgentStatusDesign.Layout.activityHorizontalInset)
                } else if activities.isEmpty {
                    ActivityFilterEmptyState { state.filter.reset() }
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
                state.scrollLink.map = scrollMap(for: all)
            }
            .onChange(of: activities.count) { previous, current in
                guard current > previous, state.followsBottom, let last = activities.last else { return }
                proxy.scrollTo(sessionActivityRowID(for: last), anchor: .bottom)
                state.scrollLink.scrollStripToEnd()
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                header(all: all, visible: activities, proxy: proxy)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.colorScheme, .light)
    }

    /// The map only depends on row kinds and on which rows the filter hides,
    /// so rebuild it when the row set or the filter changes.
    private var scrollMapKey: ActivityScrollMapKey {
        ActivityScrollMapKey(
            count: allActivities.count,
            first: allActivities.first?.id,
            last: allActivities.last?.id,
            filter: state.filter
        )
    }

    /// Every row of the session is a map row and a strip column; a row the
    /// filter hides keeps its strip column but takes no list height, so the
    /// two sides stay in step around it.
    private func scrollMap(for activities: [SessionActivityPresentation]) -> ActivityScrollMap {
        let filter = state.filter
        return ActivityScrollMap(
            rows: activities.map { activity in
                (
                    height: !filter.includes(activity) ? 0
                        : activity.lane == nil
                        ? AgentStatusDesign.Layout.activityMarkerRowHeight
                        : AgentStatusDesign.Layout.activityRowHeight,
                    columnWidth: activity.laneStripColumnWidth
                )
            },
            topInset: DesignSystem.Spacing.s,
            spacing: AgentStatusDesign.Layout.laneCellSpacing
        )
    }

    private func header(all: [SessionActivityPresentation], visible: [SessionActivityPresentation], proxy: ScrollViewProxy) -> some View {
        let counts = SessionActivityFilter.Counts(activities: all)
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.mPlus) {
            HStack(spacing: DesignSystem.Spacing.m) {
                Text("Activity")
                    .font(AgentStatusDesign.Font.UI.section)
                    .fixedSize()
                Text(state.filter.isFiltering ? "\(visible.count) / \(all.count)" : "\(all.count)")
                    .font(AgentStatusDesign.Font.UI.pill.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DesignSystem.Metrics.countPillHorizontalPadding)
                    .padding(.vertical, DesignSystem.Metrics.countPillVerticalPadding)
                    .background(AgentStatusDesign.Color.UI.chipFill, in: Capsule())
                    .accessibilityLabel(state.filter.isFiltering ? "\(visible.count) of \(all.count) shown" : "\(all.count) items")
                Spacer(minLength: DesignSystem.Spacing.m)
                ForEach(ActivityFilterDimension.allCases, id: \.self) { dimension in
                    ActivityFilterTrigger(
                        dimension: dimension,
                        model: state.filter.panelModel(dimension, counts: counts),
                        state: state
                    )
                }
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

            if !all.isEmpty {
                // The strip always shows the full session, filter or not.
                SessionActivityTimeline(
                    activities: all,
                    mode: state.timelineMode,
                    link: state.scrollLink
                ) { activity in
                    // Programmatic: the list goes to the row, the strip stays put.
                    // A hidden row's cell lands on the nearest visible row,
                    // without the highlight (that row is not the one clicked).
                    guard let target = jumpTarget(for: activity, in: all) else { return }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        proxy.scrollTo(sessionActivityRowID(for: target), anchor: .center)
                    }
                    if target.id == activity.id { state.highlight(activity.id) }
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

    /// The clicked row if the filter shows it; else the next visible row
    /// after it, else the last visible one before it.
    private func jumpTarget(
        for activity: SessionActivityPresentation,
        in all: [SessionActivityPresentation]
    ) -> SessionActivityPresentation? {
        let filter = state.filter
        if filter.includes(activity) { return activity }
        guard let index = all.firstIndex(where: { $0.id == activity.id }) else { return nil }
        return all[index...].first(where: filter.includes) ?? all[..<index].last(where: filter.includes)
    }
}

/// One FilterDropdown trigger of the Activity header. Owns nothing: the
/// open-panel state and the filter live in `SessionActivityState`; this view
/// mirrors them into the presenter (present / refresh / dismiss) and hands
/// its AppKit anchor over so the panel drops under it.
private struct ActivityFilterTrigger: View {
    let dimension: ActivityFilterDimension
    let model: FilterPanelModel
    @ObservedObject var state: SessionActivityState

    private var isOpen: Bool { state.openFilterPanel == dimension }

    private var panel: FilterDropdownPanel {
        FilterDropdownPanel(
            model: model,
            onToggleOption: { [state, dimension] id in state.filter.toggleOption(id: id, in: dimension) },
            onToggleSection: { [state, dimension] id in state.filter.toggleSection(id: id, in: dimension) }
        )
    }

    var body: some View {
        FilterTriggerButton(
            title: dimension.title,
            selectedCount: model.selectedCount,
            isFiltered: model.isFiltered,
            isOpen: isOpen
        ) {
            state.openFilterPanel = isOpen ? nil : dimension
        }
        .background(FilterAnchor(box: state.anchor(for: dimension)))
        .onChange(of: isOpen) { _, open in
            if open {
                present()
            } else {
                state.filterPresenter.dismiss(id: dimension.rawValue)
            }
        }
        .onChange(of: model) { _, _ in
            guard isOpen else { return }
            state.filterPresenter.update(id: dimension.rawValue, content: panel)
        }
        .help("Filter by \(dimension.title.lowercased())")
    }

    private func present() {
        state.filterPresenter.present(
            id: dimension.rawValue,
            content: panel,
            anchor: state.anchor(for: dimension)
        ) { [state, dimension] in
            if state.openFilterPanel == dimension { state.openFilterPanel = nil }
        }
    }
}

/// The list when Category × Importance leaves nothing: 320 tall, centred
/// copy and a capsule Reset that restores both dimensions.
private struct ActivityFilterEmptyState: View {
    let onReset: () -> Void

    private typealias E = DesignSystem.FilterDropdown.EmptyState
    private typealias F = DesignSystem.FilterDropdown

    var body: some View {
        VStack(spacing: E.gap) {
            Text("No messages match the Category and Importance filters")
                .font(AgentStatusDesign.Font.UI.body)
                .foregroundStyle(Color(F.emptyText))
                .multilineTextAlignment(.center)
            Button(action: onReset) {
                Text("Reset")
                    .designText(DesignSystem.Typography.subheadlineEmphasized)
                    .foregroundStyle(Color(F.resetText))
                    .padding(.horizontal, E.resetHorizontalPadding)
                    .frame(height: E.resetHeight)
                    .background(Color(F.resetFill), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reset filters")
        }
        .frame(maxWidth: .infinity)
        .frame(height: E.height)
    }
}

private extension SessionActivityPresentation {
    /// Strip column width: a 13pt cell, or the 4pt bar of a cross-lane marker.
    var laneStripColumnWidth: CGFloat {
        lane == nil ? AgentStatusDesign.Layout.laneMarkerWidth : AgentStatusDesign.Layout.laneCellSize
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
    var filter: SessionActivityFilter
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
/// inset, and every strip column has a known left edge (13pt cells, 4pt
/// marker bars, 4pt gaps), so the two scroll offsets relate through indices,
/// not proportions: the row at the list's top edge is the column at the
/// strip's left edge. Every row draws a column, so rows and columns pair by
/// index. Within a row / column the offset is interpolated, which keeps the
/// follower moving smoothly. Pure value type — unit-tested, no SwiftUI.
struct ActivityScrollMap: Equatable {
    /// Top edge of each list row, in list content coordinates; one trailing
    /// entry holds the content bottom.
    private(set) var rowTops: [CGFloat] = [0]
    /// Strip column of each list row; one trailing entry holds the column
    /// count.
    private(set) var columnOfRow: [Int] = [0]
    /// List row shown by each strip column.
    private(set) var rowOfColumn: [Int] = []
    /// Left edge of each strip column; one trailing entry holds the left edge
    /// the next column would have (column pitch includes the gap).
    private(set) var columnLefts: [CGFloat] = [0]

    init() {}

    /// - Parameters:
    ///   - rows: per list row, `(height, columnWidth)` — 13pt cell or 4pt
    ///     marker bar.
    ///   - topInset: list content padding above the first row.
    ///   - spacing: gap between strip columns.
    init(rows: [(height: CGFloat, columnWidth: CGFloat)], topInset: CGFloat, spacing: CGFloat) {
        rowTops.reserveCapacity(rows.count + 1)
        columnOfRow.reserveCapacity(rows.count + 1)
        rowTops = [topInset]
        columnOfRow = []
        columnLefts = [0]
        for (index, row) in rows.enumerated() {
            columnOfRow.append(index)
            rowOfColumn.append(index)
            columnLefts.append(columnLefts[index] + row.columnWidth + spacing)
            rowTops.append(rowTops[index] + row.height)
        }
        columnOfRow.append(rows.count)
    }

    var rowCount: Int { rowTops.count - 1 }
    var columnCount: Int { rowOfColumn.count }

    /// Strip offset whose left edge shows the column of the row at `listOffset`.
    func stripOffset(forListOffset listOffset: CGFloat) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        let row = rowIndex(at: listOffset)
        let top = rowTops[row], height = rowTops[row + 1] - top
        let progress = height > 0 ? min(max((listOffset - top) / height, 0), 1) : 0
        let column = columnOfRow[row]
        return columnLefts[column] + progress * (columnLefts[column + 1] - columnLefts[column])
    }

    /// List offset whose top edge shows the row of the column at `stripOffset`.
    func listOffset(forStripOffset stripOffset: CGFloat) -> CGFloat {
        guard columnCount > 0 else { return 0 }
        let offset = max(stripOffset, 0)
        let column = min(columnIndex(at: offset), columnCount - 1)
        let left = columnLefts[column], width = columnLefts[column + 1] - left
        let progress = width > 0 ? min((offset - left) / width, 1) : 0
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

    /// Index of the column whose pitch contains `stripOffset` (clamped).
    func columnIndex(at stripOffset: CGFloat) -> Int {
        var low = 0, high = columnCount - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if columnLefts[mid] <= stripOffset { low = mid } else { high = mid - 1 }
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

/// Pure geometry of the lane strip: column `index` along x, `lane` along y.
/// Item columns are `cellSize` squares; cross-lane markers are `markerWidth`
/// bars (the column narrows with them) — both on a `spacing` gap. Hit-testing
/// lands only inside a cell (never in the gaps) and only on a *filled* cell,
/// so the caller supplies the fill rule. Kept free of SwiftUI so it can be
/// unit-tested.
struct LaneStripGeometry: Equatable {
    struct Cell: Equatable {
        var index: Int
        var lane: Int
    }

    var cellSize: CGFloat
    var spacing: CGFloat
    var laneCount: Int
    /// Width of each column: `cellSize` for items, `markerWidth` for markers.
    private(set) var columnWidths: [CGFloat]
    /// Left edge of each column plus one trailing entry (the next column's
    /// left edge, i.e. content width + spacing).
    private(set) var columnLefts: [CGFloat]

    init(cellSize: CGFloat, spacing: CGFloat, laneCount: Int, columnWidths: [CGFloat]) {
        self.cellSize = cellSize
        self.spacing = spacing
        self.laneCount = laneCount
        self.columnWidths = columnWidths
        var lefts: [CGFloat] = [0]
        lefts.reserveCapacity(columnWidths.count + 1)
        for width in columnWidths {
            lefts.append(lefts[lefts.count - 1] + width + spacing)
        }
        columnLefts = lefts
    }

    /// Uniform item columns.
    init(cellSize: CGFloat, spacing: CGFloat, laneCount: Int, columns: Int) {
        self.init(cellSize: cellSize, spacing: spacing, laneCount: laneCount,
                  columnWidths: Array(repeating: cellSize, count: columns))
    }

    var columns: Int { columnWidths.count }
    var lanePitch: CGFloat { cellSize + spacing }
    var height: CGFloat { cellSize * CGFloat(laneCount) + spacing * CGFloat(laneCount - 1) }
    var contentWidth: CGFloat { max(0, columnLefts[columns] - spacing) }

    func width(ofColumn index: Int) -> CGFloat { columnWidths[index] }
    /// A marker column (narrower than a cell).
    func isMarker(_ index: Int) -> Bool { columnWidths[index] < cellSize }

    func rect(index: Int, lane: Int) -> CGRect {
        CGRect(x: columnLefts[index], y: CGFloat(lane) * lanePitch, width: columnWidths[index], height: cellSize)
    }

    /// Columns intersecting `clip`, padded by one on the right for partial redraws.
    func visibleColumns(in clip: CGRect) -> ClosedRange<Int>? {
        guard columns > 0 else { return nil }
        let first = max(0, columnIndex(at: clip.minX))
        let last = min(columns - 1, columnIndex(at: clip.maxX) + 1)
        return first <= last ? first ... last : nil
    }

    /// The cell under `location`, or `nil` over a gap, outside the strip, or
    /// on a cell `isFilled` rejects.
    func cell(at location: CGPoint, isFilled: (Cell) -> Bool) -> Cell? {
        guard location.x >= 0, location.y >= 0, columns > 0 else { return nil }
        let cell = Cell(index: columnIndex(at: location.x), lane: Int(location.y / lanePitch))
        guard cell.index < columns, cell.lane < laneCount,
              rect(index: cell.index, lane: cell.lane).contains(location),
              isFilled(cell)
        else { return nil }
        return cell
    }

    /// Index of the column whose pitch contains `x` (clamped to the last column).
    func columnIndex(at x: CGFloat) -> Int {
        var low = 0, high = columns - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if columnLefts[mid] <= x { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// Three lanes (User / Model / Exec); one 13pt column per strip row, drawn in
/// a single `Canvas` (one view for the whole strip instead of thousands of
/// cell views). A cell is filled with the tag's lane colour only in the row's
/// own lane; rows that span all lanes do not occupy a lane — each lane draws a
/// 13×4 bar (radius 2) and the column narrows to 4. Every list row has a
/// column (a TOOL call and its RESULT are two Exec cells). The strip scrolls
/// in step with the list (and the list with the strip).
///
/// Interaction: only filled cells are targets — the pointer becomes a hand
/// and the cell gets a hover ring; clicking one scrolls the list to its row.
/// Empty cells and the gaps between columns are inert. Pressing and dragging
/// anywhere on the strip pans it (AppKit scroll views only pan with the
/// trackpad / wheel, so the drag is mapped onto the scroll position by hand).
private struct SessionActivityTimeline: View {
    /// A press that travels further than this is a pan, not a click.
    private static let dragThreshold: CGFloat = 3
    /// Coordinate space of the strip's scroll *container*. The pan gesture
    /// must measure its translation here: content-local coordinates move with
    /// the pan's own scrolling and would feed back into the translation.
    private static let panSpace = "activityLaneStripPan"

    let activities: [SessionActivityPresentation]
    let mode: ActivityTimelineMode
    let link: ActivityScrollLink
    let onSelect: (SessionActivityPresentation) -> Void

    @State private var stripPosition = ScrollPosition(edge: .leading)
    /// Filled cell under the pointer (column + lane); `nil` over empty space.
    @State private var hoveredCell: LaneStripGeometry.Cell?
    /// Strip offset when the current pan began.
    @State private var panOrigin: CGFloat?
    /// Gesture translation when the pan began: the pointer has already moved
    /// `dragThreshold` by the first `onChanged`, and gluing to the raw
    /// translation would make the content hop that far on grab.
    @State private var panBaseline: CGFloat = 0
    /// Post-release momentum glide; cancelled by any new user input.
    @State private var decelerationTask: Task<Void, Never>?

    private var geometry: LaneStripGeometry {
        LaneStripGeometry(
            cellSize: AgentStatusDesign.Layout.laneCellSize,
            spacing: AgentStatusDesign.Layout.laneCellSpacing,
            laneCount: mode == .lanes ? TimelineLane.allCases.count : 1,
            columnWidths: activities.map(\.laneStripColumnWidth)
        )
    }

    private var stripHeight: CGFloat { geometry.height }
    private var contentWidth: CGFloat { geometry.contentWidth }

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
                if phase.isUserDriven { stopDeceleration() }
                link.stripPhaseChanged(isUserScrolling: phase.isUserDriven)
            }
            .onAppear {
                link.scrollStrip = { offset in
                    scrollInstantly { stripPosition.scrollTo(x: offset) }
                }
            }
            .coordinateSpace(name: Self.panSpace)
            .frame(height: stripHeight)
        }
        .frame(height: stripHeight)
    }

    private var canvas: some View {
        // `TimelineView` is not needed: the canvas redraws when the strip
        // scrolls (clip rect changes), when activities change and on hover.
        Canvas(rendersAsynchronously: false) { context, _ in
            let geometry = geometry
            guard let columns = geometry.visibleColumns(in: context.clipBoundingRect) else { return }
            // Batch the rounded rects into one path per tag: one fill per tag
            // (a handful) instead of one per cell (hundreds while panning).
            var fills: [TimelineTag: Path] = [:]
            for index in columns {
                let activity = activities[index]
                let radius = geometry.isMarker(index)
                    ? AgentStatusDesign.Layout.laneMarkerCornerRadius
                    : AgentStatusDesign.Layout.laneCellCornerRadius
                for lane in 0 ..< geometry.laneCount where isFilled(activity, lane: lane) {
                    fills[activity.tag, default: Path()].addRoundedRect(
                        in: geometry.rect(index: index, lane: lane),
                        cornerSize: CGSize(width: radius, height: radius),
                        style: .continuous
                    )
                }
            }
            for (tag, path) in fills {
                context.fill(path, with: .color(Color(tag.laneCellColor)))
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
            // A click anywhere stops a momentum glide, like grabbing a
            // coasting scroll view.
            if decelerationTask != nil {
                stopDeceleration()
                link.endStripPan()
            }
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
    /// The pan declares the strip as driver, so the list follows. Measured in
    /// the scroll container's coordinate space — never the content's, whose
    /// movement under the pointer would contaminate the translation and make
    /// consecutive events fight each other (visible as jitter).
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: Self.dragThreshold, coordinateSpace: .named(Self.panSpace))
            .onChanged { value in
                if panOrigin == nil {
                    stopDeceleration()
                    panOrigin = link.strip.offset
                    panBaseline = value.translation.width
                    hoveredCell = nil
                    link.beginStripPan()
                    NSCursor.closedHand.set()
                }
                scrollInstantly { stripPosition.scrollTo(x: panTarget(for: value.translation.width)) }
            }
            .onEnded { value in
                let released = panTarget(for: value.translation.width)
                let projected = panTarget(for: value.predictedEndTranslation.width)
                panOrigin = nil
                NSCursor.arrow.set()
                decelerate(from: released, to: projected)
            }
    }

    /// Strip offset that keeps the grab point under the pointer, clamped to
    /// the scrollable range.
    private func panTarget(for translation: CGFloat) -> CGFloat {
        let origin = panOrigin ?? link.strip.offset
        return min(max(origin - (translation - panBaseline), 0), link.strip.range)
    }

    /// Trackpad-style momentum: glide from `offset` towards `target` with an
    /// ease-out curve. The strip stays registered as driver for the whole
    /// glide, so the list keeps following; the glide runs as instant scrolls
    /// (like the pan itself) and any new user input cancels it.
    private func decelerate(from offset: CGFloat, to target: CGFloat) {
        let distance = target - offset
        guard abs(distance) > 1 else {
            link.endStripPan()
            return
        }
        let duration = min(0.45, max(0.2, abs(distance) / 1_500))
        decelerationTask = Task { @MainActor in
            defer { decelerationTask = nil }
            let clock = ContinuousClock()
            let start = clock.now
            let total = Duration.seconds(duration)
            while !Task.isCancelled, link.driver == .strip {
                let t = min(1, start.duration(to: clock.now) / total)
                let eased = 1 - pow(1 - t, 3) // ease-out cubic
                scrollInstantly { stripPosition.scrollTo(x: offset + distance * eased) }
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(8))
            }
            if !Task.isCancelled { link.endStripPan() }
        }
    }

    /// Cancellation sites own the driver hand-off: a new pan re-declares it,
    /// a wheel scroll keeps it through the phase change, a click ends it.
    private func stopDeceleration() {
        decelerationTask?.cancel()
        decelerationTask = nil
    }

    // MARK: Geometry

    private func isFilled(_ activity: SessionActivityPresentation, lane: Int) -> Bool {
        mode == .single || activity.lane == nil || activity.lane == TimelineLane.allCases[lane]
    }

    private func cellPath(index: Int, lane: Int) -> Path {
        Path(
            roundedRect: geometry.rect(index: index, lane: lane),
            cornerRadius: geometry.isMarker(index)
                ? AgentStatusDesign.Layout.laneMarkerCornerRadius
                : AgentStatusDesign.Layout.laneCellCornerRadius,
            style: .continuous
        )
    }

    /// The filled cell under `location`, or `nil` over an empty cell or a gap.
    private func cell(at location: CGPoint) -> LaneStripGeometry.Cell? {
        geometry.cell(at: location) { cell in
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

                DesignTag(activity.label, style: activity.tag.tagStyle(.light))
                    .frame(width: AgentStatusDesign.Layout.activityTagWidth)

                Text(activity.content)
                    .font(AgentStatusDesign.Font.UI.body)
                    .foregroundStyle(AgentStatusDesign.Color.UI.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: DesignSystem.Typography.tag.size, weight: .semibold))
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
