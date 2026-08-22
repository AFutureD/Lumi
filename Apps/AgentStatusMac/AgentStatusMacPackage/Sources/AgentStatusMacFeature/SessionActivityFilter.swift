import AgentStatusCore
import AgentStatusDesignSystem
import AgentStatusTransport
import Foundation

// Activity filter (macOS handoff `design_handoff_macos_activity_filter`): two
// FilterDropdowns in the Activity header — **Category** (the 14 message tags,
// grouped by lane Session / User / Model / Exec) and **Importance** (L3 / L2 /
// L1). A row shows when its tag is selected *and* its level is selected
// (intersection); inside a dimension the selection is a union. A dimension
// can never be emptied: deselecting its last item snaps it back to all.
// Filtering is view-layer only — the lane strip and every count read the
// full row set; the filter lives in the Activity UI state and resets when
// the session changes.

/// The two filter dimensions, one trigger / panel each.
enum ActivityFilterDimension: String, Hashable, Sendable, CaseIterable {
    case category
    case importance

    var title: String {
        switch self {
        case .category: "Category"
        case .importance: "Importance"
        }
    }
}

/// Category panel sub-groups = lanes, in strip order; `session` is the
/// cross-lane marker group.
enum ActivityCategoryGroup: String, Hashable, Sendable, CaseIterable {
    case session
    case user
    case model
    case exec

    var title: String {
        switch self {
        case .session: "Session"
        case .user: "User"
        case .model: "Model"
        case .exec: "Exec"
        }
    }

    var lane: TimelineLane? {
        switch self {
        case .session: nil
        case .user: .user
        case .model: .model
        case .exec: .exec
        }
    }

    /// Tags of the group in the handoff's table order (the fallback order for
    /// tags that have not appeared in the timeline yet).
    var tags: [TimelineTag] {
        switch self {
        case .session: [.session, .compact]
        case .user: [.user, .context, .contextGroup]
        case .model: [.reasoning, .assistant, .plan, .subagent, .turnEnd, .aborted]
        case .exec: [.tool, .result, .failed]
        }
    }

    static func group(of tag: TimelineTag) -> ActivityCategoryGroup {
        switch tag.lane {
        case nil: .session
        case .user: .user
        case .model: .model
        case .exec: .exec
        }
    }
}

/// Selection state of both dimensions. Defaults to everything selected
/// (= unfiltered).
struct SessionActivityFilter: Hashable, Sendable {
    static let allCategories = Set(TimelineTag.allCases)
    static let allLevels: Set<TimelineAttentionLevel> = [.l1, .l2, .l3]

    var categories: Set<TimelineTag> = allCategories
    var levels: Set<TimelineAttentionLevel> = allLevels

    init() {}

    init(categories: Set<TimelineTag>, levels: Set<TimelineAttentionLevel>) {
        self.categories = categories.isEmpty ? Self.allCategories : categories
        self.levels = levels.isEmpty ? Self.allLevels : levels
    }

    var filtersCategories: Bool { categories != Self.allCategories }
    var filtersLevels: Bool { levels != Self.allLevels }
    var isFiltering: Bool { filtersCategories || filtersLevels }

    /// Both dimensions must admit the tag.
    func includes(_ tag: TimelineTag) -> Bool {
        categories.contains(tag) && levels.contains(tag.level)
    }

    func includes(_ activity: SessionActivityPresentation) -> Bool {
        includes(activity.tag)
    }

    // MARK: Mutations

    mutating func toggle(_ tag: TimelineTag) {
        Self.toggle(tag, in: &categories, all: Self.allCategories)
    }

    mutating func toggle(_ level: TimelineAttentionLevel) {
        Self.toggle(level, in: &levels, all: Self.allLevels)
    }

    /// Tri-state header: any unselected in the group → select the whole
    /// group; all selected → deselect the whole group (snapping back to all
    /// if that would empty the dimension).
    mutating func toggle(group: ActivityCategoryGroup) {
        let tags = Set(group.tags)
        if tags.isSubset(of: categories) {
            categories.subtract(tags)
            if categories.isEmpty { categories = Self.allCategories }
        } else {
            categories.formUnion(tags)
        }
    }

    mutating func reset() {
        self = SessionActivityFilter()
    }

    /// Remove if present, insert otherwise; removing the last member snaps
    /// the set back to `all` (a dimension never filters everything out).
    private static func toggle<Member: Hashable>(_ member: Member, in selection: inout Set<Member>, all: Set<Member>) {
        if selection.contains(member) {
            selection.remove(member)
            if selection.isEmpty { selection = all }
        } else {
            selection.insert(member)
        }
    }
}

// MARK: - Display

extension TimelineTag {
    /// Option name in the Category panel. Short on purpose: the name column
    /// is what is left of 232 after the box, the 72pt pill and the count.
    var filterName: String {
        switch self {
        case .session: "Start / end"
        case .compact: "Compaction"
        case .user: "User input"
        case .context: "Turn context"
        case .contextGroup: "Session context"
        case .reasoning: "Thinking"
        case .assistant: "Reply"
        case .plan: "Plan"
        case .subagent: "Subagent"
        case .turnEnd: "Turn end"
        case .aborted: "Interrupted"
        case .tool: "Tool call"
        case .result: "Tool result"
        case .failed: "Failure"
        }
    }

    /// Chip label in the Category panel; the merged row is listed as `CONTEXT ×N`.
    var filterLabel: String {
        self == .contextGroup ? "CONTEXT ×N" : label
    }
}

extension TimelineAttentionLevel {
    var filterCode: String { "L\(rawValue)" }

    var filterName: String {
        switch self {
        case .l3: "Phase"
        case .l2: "Process"
        case .l1: "Detail"
        }
    }

    var filterDescription: String {
        switch self {
        case .l3: "Input · turn end · failure"
        case .l2: "Reply · result · plan · agent"
        case .l1: "Thinking · context · tool call"
        }
    }
}

// MARK: - Panel models

extension SessionActivityFilter {
    /// Pre-filter counts of the current session, per tag and per level.
    struct Counts: Hashable, Sendable {
        var tags: [TimelineTag: Int] = [:]
        var levels: [TimelineAttentionLevel: Int] = [:]
        /// Order in which each tag first appeared in the timeline.
        var firstAppearance: [TimelineTag: Int] = [:]

        init(activities: [SessionActivityPresentation]) {
            for (index, activity) in activities.enumerated() {
                tags[activity.tag, default: 0] += 1
                levels[activity.tag.level, default: 0] += 1
                if firstAppearance[activity.tag] == nil { firstAppearance[activity.tag] = index }
            }
        }

        /// A group's tags in timeline order of first appearance; tags that
        /// never appeared follow in the handoff's table order.
        func orderedTags(of group: ActivityCategoryGroup) -> [TimelineTag] {
            group.tags.enumerated().sorted { lhs, rhs in
                let lhsFirst = firstAppearance[lhs.element] ?? Int.max
                let rhsFirst = firstAppearance[rhs.element] ?? Int.max
                if lhsFirst != rhsFirst { return lhsFirst < rhsFirst }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
    }

    func panelModel(_ dimension: ActivityFilterDimension, counts: Counts) -> FilterPanelModel {
        switch dimension {
        case .category: categoryPanel(counts: counts)
        case .importance: importancePanel(counts: counts)
        }
    }

    /// Category: four lane sub-groups with tri-state headers, each row a tag
    /// pill + name + count.
    func categoryPanel(counts: Counts) -> FilterPanelModel {
        FilterPanelModel(
            title: ActivityFilterDimension.category.title,
            sections: ActivityCategoryGroup.allCases.map { group in
                FilterPanelSection(
                    id: group.rawValue,
                    title: group.title,
                    options: counts.orderedTags(of: group).map { tag in
                        FilterPanelOption(
                            id: tag.rawValue,
                            leading: .tag(label: tag.filterLabel, style: tag.tagStyle(.light)),
                            name: tag.filterName,
                            count: counts.tags[tag] ?? 0,
                            isSelected: categories.contains(tag)
                        )
                    }
                )
            }
        )
    }

    /// Importance: one ungrouped list L3 → L1, each row a level chip + name +
    /// description + count.
    func importancePanel(counts: Counts) -> FilterPanelModel {
        FilterPanelModel(
            title: ActivityFilterDimension.importance.title,
            sections: [
                FilterPanelSection(
                    id: ActivityFilterDimension.importance.rawValue,
                    title: nil,
                    options: [TimelineAttentionLevel.l3, .l2, .l1].map { level in
                        FilterPanelOption(
                            id: String(level.rawValue),
                            leading: .chip(label: level.filterCode, style: DesignSystem.FilterDropdown.levelChipStyle(level)),
                            name: level.filterName,
                            description: level.filterDescription,
                            count: counts.levels[level] ?? 0,
                            isSelected: levels.contains(level)
                        )
                    }
                ),
            ]
        )
    }

    /// Option / section ids of the panels, back to the filter mutation.
    mutating func toggleOption(id: String, in dimension: ActivityFilterDimension) {
        switch dimension {
        case .category:
            if let tag = TimelineTag(rawValue: id) { toggle(tag) }
        case .importance:
            if let raw = Int(id), let level = TimelineAttentionLevel(rawValue: raw) { toggle(level) }
        }
    }

    mutating func toggleSection(id: String, in dimension: ActivityFilterDimension) {
        guard dimension == .category, let group = ActivityCategoryGroup(rawValue: id) else { return }
        toggle(group: group)
    }
}
