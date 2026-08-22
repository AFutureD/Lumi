import Foundation
import Testing
import AgentStatusCore
import AgentStatusDesignSystem
import AgentStatusTransport
@testable import AgentStatusMacFeature

// Activity filter (Category × Importance FilterDropdowns) and its panels.

@Test func activityFilterDefaultsToAllAndIntersectsTheTwoDimensions() {
    var filter = SessionActivityFilter()
    #expect(!filter.isFiltering)
    #expect(TimelineTag.allCases.allSatisfy(filter.includes))

    // Category narrows; importance narrows further; a row needs both.
    filter.toggle(.reasoning)
    #expect(filter.isFiltering && filter.filtersCategories && !filter.filtersLevels)
    #expect(!filter.includes(.reasoning) && filter.includes(.user) && filter.includes(.tool))
    filter.toggle(.l1)
    #expect(filter.filtersLevels)
    #expect(!filter.includes(.tool) && !filter.includes(.session) && filter.includes(.user) && filter.includes(.result))
    // USER (L3) selected but L3 off → hidden.
    filter.toggle(.l3)
    #expect(!filter.includes(.user) && filter.includes(.result))

    filter.reset()
    #expect(filter == SessionActivityFilter())
}

@Test func activityFilterNeverEmptiesADimension() {
    var filter = SessionActivityFilter()
    // Keep only USER, then deselect it: the dimension snaps back to all.
    for tag in TimelineTag.allCases where tag != .user { filter.toggle(tag) }
    #expect(filter.categories == [.user])
    filter.toggle(.user)
    #expect(filter.categories == SessionActivityFilter.allCategories)

    filter.toggle(.l2)
    filter.toggle(.l1)
    #expect(filter.levels == [.l3])
    filter.toggle(.l3)
    #expect(filter.levels == SessionActivityFilter.allLevels)

    // Deselecting a whole group that is the last thing selected resets too.
    for tag in TimelineTag.allCases where ActivityCategoryGroup.group(of: tag) != .exec { filter.toggle(tag) }
    #expect(filter.categories == Set(ActivityCategoryGroup.exec.tags))
    filter.toggle(group: .exec)
    #expect(filter.categories == SessionActivityFilter.allCategories)

    // The memberwise init refuses an empty dimension as well.
    #expect(SessionActivityFilter(categories: [], levels: [.l3]).categories == SessionActivityFilter.allCategories)
}

@Test func activityFilterGroupHeaderIsTriState() {
    var filter = SessionActivityFilter()
    let counts = SessionActivityFilter.Counts(activities: [])
    func section(_ group: ActivityCategoryGroup) -> FilterPanelSection {
        filter.categoryPanel(counts: counts).sections.first { $0.id == group.rawValue }!
    }
    #expect(section(.model).selection == .on)

    // One off → mixed; the header selects the whole group again.
    filter.toggle(.plan)
    #expect(section(.model).selection == .mixed)
    filter.toggle(group: .model)
    #expect(section(.model).selection == .on && filter.categories.isSuperset(of: ActivityCategoryGroup.model.tags))

    // All on → the header deselects the whole group (others untouched).
    filter.toggle(group: .model)
    #expect(section(.model).selection == .off)
    #expect(section(.user).selection == .on && section(.exec).selection == .on && section(.session).selection == .on)
    #expect(filter.categories == SessionActivityFilter.allCategories.subtracting(ActivityCategoryGroup.model.tags))

    // Ids round-trip through the panel callbacks.
    filter.toggleSection(id: "model", in: .category)
    #expect(section(.model).selection == .on)
    filter.toggleOption(id: "tool", in: .category)
    #expect(!filter.categories.contains(.tool))
    filter.toggleOption(id: "2", in: .importance)
    #expect(!filter.levels.contains(.l2))
    filter.toggleSection(id: "model", in: .importance) // no sections there
    #expect(!filter.levels.contains(.l2) && filter.levels.contains(.l1))
}

@Test func activityFilterPanelsCountBeforeFilteringAndFollowFirstAppearance() {
    let activities = [
        activity(.session, 0), activity(.user, 1), activity(.contextGroup, 2), activity(.reasoning, 3),
        activity(.tool, 4), activity(.result, 5), activity(.assistant, 6), activity(.turnEnd, 7),
        activity(.user, 8), activity(.failed, 9), activity(.contextGroup, 10),
    ]
    var filter = SessionActivityFilter()
    filter.toggle(.user)
    filter.toggle(.l1)
    let counts = SessionActivityFilter.Counts(activities: activities)

    let category = filter.categoryPanel(counts: counts)
    #expect(category.title == "Category")
    #expect(category.sections.map(\.id) == ["session", "user", "model", "exec"])
    #expect(category.sections.map(\.title) == ["Session", "User", "Model", "Exec"])
    // Every tag is listed (15), zero counts included; counts are pre-filter.
    #expect(category.options.count == TimelineTag.allCases.count)
    let user = category.sections[1]
    #expect(user.options.map(\.id) == ["user", "contextGroup", "context"])   // CONTEXT ×N appeared before CONTEXT (never)
    #expect(user.options.map(\.count) == [2, 2, 0])
    #expect(user.count == 4)
    #expect(user.options[0].isSelected == false && user.options[1].isSelected == true)
    #expect(user.options[1].leading == .tag(label: "CONTEXT ×N", style: TimelineTag.contextGroup.tagStyle(.light)))
    #expect(user.options[1].name == "Session context")
    // Model: reasoning → assistant → turnEnd appeared; plan / subagent / turnFailed / aborted trail in table order.
    #expect(category.sections[2].options.map(\.id) == ["reasoning", "assistant", "turnEnd", "plan", "subagent", "turnFailed", "aborted"])
    #expect(category.sections[3].options.map(\.id) == ["tool", "result", "failed"])
    #expect(category.selectedCount == 14 && category.isFiltered)
    #expect(category.rowHeight == DesignSystem.FilterDropdown.Panel.rowHeight)
    // 24 header + 4 × 26 sub-group headers + 15 × 28 rows = 548 → capped at 420.
    #expect(category.contentHeight == 548 && category.panelHeight == 420)

    let importance = filter.importancePanel(counts: counts)
    #expect(importance.sections.count == 1 && importance.sections[0].title == nil)
    #expect(importance.options.map(\.id) == ["3", "2", "1"])
    #expect(importance.options.map(\.name) == ["Phase", "Process", "Detail"])
    #expect(importance.options.map(\.count) == [4, 2, 5])
    #expect(importance.options.map(\.isSelected) == [true, true, false])
    #expect(importance.options.allSatisfy { $0.description != nil })
    #expect(importance.rowHeight == DesignSystem.FilterDropdown.Panel.describedRowHeight)
    #expect(importance.contentHeight == 24 + 3 * 34 && importance.panelHeight == importance.contentHeight)
    #expect(importance.selectedCount == 2 && importance.isFiltered)

    // Unfiltered panels report "all" (no badge).
    #expect(!SessionActivityFilter().categoryPanel(counts: counts).isFiltered)
}

@Test func activityScrollMapKeepsHiddenRowsColumnsAtZeroHeight() {
    // Rows: item, two hidden items (height 0, cells kept), item. Top inset 6, gap 4.
    let map = ActivityScrollMap(
        rows: [(40, 13), (0, 13), (0, 13), (40, 13)],
        topInset: 6, spacing: 4
    )
    #expect(map.rowCount == 4 && map.columnCount == 4)
    // Row tops: 6, 46, 46, 46; bottom 86. Column lefts: 0, 17, 34, 51; next 68.
    #expect(map.rowOfColumn == [0, 1, 2, 3])
    // A hidden row's column maps onto where the next visible row starts.
    #expect(map.listOffset(forStripOffset: 17) == 46)
    #expect(map.listOffset(forStripOffset: 34) == 46)
    // Past the first row the list is on the last visible row → its column.
    #expect(map.stripOffset(forListOffset: 46) == 51)
    #expect(map.stripOffset(forListOffset: 66) == 51 + 8.5)
    #expect(map.rowIndex(at: 46) == 3)
}

private func activity(_ tag: TimelineTag, _ index: Int) -> SessionActivityPresentation {
    let session = SessionID("filter")
    let item = TimelineItem(
        id: TimelineItemID("item-\(index)"),
        sessionID: session,
        occurredAt: Date(timeIntervalSince1970: Double(index)),
        payload: .message(MessageTimelinePayload(role: .user, text: "row \(index)"))
    )
    let row = TimelineRow(
        id: "row-\(index)",
        sessionID: session,
        turnID: nil,
        occurredAt: item.occurredAt,
        tag: tag,
        status: .info,
        text: "row \(index)",
        items: [item]
    )
    return SessionPagePresentationBuilder.activityPresentation(for: row)
}
