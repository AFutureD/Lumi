import Core
import DesignSystem
import Transport
import Foundation

/// Stable identity of a row across Macs: two Macs may reuse a session id.
struct SessionListItemID: Hashable, Sendable {
    let hostID: HostID
    let sessionID: SessionID
}

/// The newest Activity row of a session, shown under the title while the
/// session is not in the Completed tier.
struct SessionListLatest: Hashable, Sendable {
    let tag: TimelineTag
    let label: String
    let text: String
}

/// A subagent (child session) folded into its parent's row as a chip.
struct SubagentChipItem: Hashable, Sendable, Identifiable {
    let id: SessionID
    let name: String
    let tone: SessionStatusTone
    /// Newest turn start / end (nil while live) — the chip's duration ticks.
    let startedAt: Date
    let endedAt: Date?

    func durationText(now: Date) -> String {
        CompactDurationText.string(from: (endedAt ?? now).timeIntervalSince(startedAt))
    }
}

struct SessionListItem: Hashable, Sendable, Identifiable {
    let id: SessionListItemID
    let deviceName: String
    let title: String
    let tone: SessionStatusTone
    /// Pill text: `Running` / `Waiting` / `Completed` / `Failed` (lifecycle only).
    let statusLabel: String
    let agentName: String
    let workspace: String?
    let lastActivityAt: Date
    let latest: SessionListLatest?
    /// Ordered running → waiting → failed → done (the summary bar's dot order).
    let subagents: [SubagentChipItem]

    var hostID: HostID { id.hostID }
    var sessionID: SessionID { id.sessionID }
    var statusGroup: SessionStatusGroup { SessionStatusGroup(tone: tone) }

    /// `3 subagents · 2 running · 1 done` — only the non-zero buckets
    /// (shared wording with the Notch: `SubagentGroupSummary`).
    var subagentSummary: String {
        SubagentGroupSummary.label(tones: subagents.map(\.tone))
    }
    func timeText(now: Date) -> String { SessionRelativeTimeFormatter.string(from: lastActivityAt, now: now) }
}

/// Status filter groups (L3 §3.4 `Status`): the five tones fold into three.
enum SessionStatusGroup: String, CaseIterable, Hashable, Sendable {
    case running
    case waiting
    case completed

    var title: String {
        switch self {
        case .running: "Running"
        case .waiting: "Waiting"
        case .completed: "Completed"
        }
    }

    /// Running ← Running tier; Waiting ← needs-a-human (approval); everything
    /// ended (unreviewed, completed, failed) ← Completed.
    init(tone: SessionStatusTone) {
        switch tone {
        case .blue: self = .running
        case .orange: self = .waiting
        case .green, .gray, .red: self = .completed
        }
    }

    /// Tile dot hue in the filter panel — the same hue as the row pill it
    /// filters for (`SessionStatusTone`): Running blue, Waiting orange,
    /// Completed neutral.
    var hue: DesignHue {
        switch self {
        case .running: .blue
        case .waiting: .orange
        case .completed: .neutral
        }
    }
}

/// The two Dropdown filter groups (L3 §3.4); at most one panel is open.
enum FilterGroup: Hashable, Sendable, CaseIterable {
    case macs
    case status

    var title: String {
        switch self {
        case .macs: "Macs"
        case .status: "Status"
        }
    }
}

/// What an option's icon tile shows: the laptop glyph on a neutral tile, or
/// a status dot on the hue's tint.
enum FilterOptionGlyph: Hashable, Sendable {
    case laptop
    case dot(DesignHue)
}

/// One option of a filter group (a Mac, or a status), with its session count.
struct FilterOption: Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let count: Int
    let isSelected: Bool
    let glyph: FilterOptionGlyph
}

enum FilterPanelPlacement {
    /// Panel left edge: aligned to its trigger, pulled back so the panel never
    /// crosses the right edge inset (393 − 268 − 20 = 105 for `Status`).
    static func left(triggerMinX: Double, containerWidth: Double, panelWidth: Double, edgeInset: Double) -> Double {
        max(edgeInset, min(triggerMinX, containerWidth - edgeInset - panelWidth))
    }
}

enum SessionListPresentation {
    /// Every Mac's visible sessions merged into one list, newest activity
    /// first. Subagents (every descendant by lineage, `SessionHierarchy`)
    /// become chips on their top-level ancestor's row; a child whose parent
    /// is not visible gets a row of its own.
    static func items(from channels: [MacChannelState]) -> [SessionListItem] {
        var items: [SessionListItem] = []
        for channel in channels {
            let visible = Set(SessionSummary.visible(channel.visibleSessions.map(\.summary)).map(\.id))
            let details = channel.visibleSessions.filter { visible.contains($0.summary.id) }
            let detailsByID = Dictionary(details.map { ($0.summary.id, $0) }, uniquingKeysWith: { first, _ in first })
            for group in SessionHierarchy.groups(details.map(\.summary)) {
                guard let parent = detailsByID[group.parent.id] else { continue }
                let children = group.descendants.compactMap { detailsByID[$0.id] }
                items.append(item(for: parent, children: children, channel: channel))
            }
        }
        return items.sorted {
            if $0.lastActivityAt == $1.lastActivityAt { return $0.id.sessionID.rawValue < $1.id.sessionID.rawValue }
            return $0.lastActivityAt > $1.lastActivityAt
        }
    }

    /// Mac and status multi-select, then a case-insensitive title / agent /
    /// workspace search. A child's name also matches so a row can be found by
    /// its subagent.
    static func filter(
        _ items: [SessionListItem],
        excludingHosts deselected: Set<HostID>,
        excludingStatuses deselectedStatuses: Set<SessionStatusGroup> = [],
        query: String
    ) -> [SessionListItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            guard !deselected.contains(item.hostID) else { return false }
            guard !deselectedStatuses.contains(item.statusGroup) else { return false }
            guard !trimmed.isEmpty else { return true }
            return item.title.localizedCaseInsensitiveContains(trimmed)
                || item.agentName.localizedCaseInsensitiveContains(trimmed)
                || item.workspace?.localizedCaseInsensitiveContains(trimmed) == true
                || item.subagents.contains { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    /// `Macs` group: one option per paired Mac with its row count.
    static func macOptions(
        channels: [MacChannelState],
        items: [SessionListItem],
        deselected: Set<HostID>
    ) -> [FilterOption] {
        channels.map { channel in
            FilterOption(
                id: channel.hostID.rawValue,
                name: channel.displayName,
                count: items.count { $0.hostID == channel.hostID },
                isSelected: !deselected.contains(channel.hostID),
                glyph: .laptop
            )
        }
    }

    /// `Status` group: Running / Waiting / Completed with their row counts.
    static func statusOptions(items: [SessionListItem], deselected: Set<SessionStatusGroup>) -> [FilterOption] {
        SessionStatusGroup.allCases.map { group in
            FilterOption(
                id: group.rawValue,
                name: group.title,
                count: items.count { $0.statusGroup == group },
                isSelected: !deselected.contains(group),
                glyph: .dot(group.hue)
            )
        }
    }

    /// Toggling one option never empties a group (the list would be blank):
    /// the last selected option stays selected.
    static func toggling<Option: Hashable>(_ option: Option, in deselected: Set<Option>, all: [Option]) -> Set<Option> {
        var next = deselected
        if next.contains(option) {
            next.remove(option)
        } else if all.filter({ !next.contains($0) }).count > 1 {
            next.insert(option)
        }
        return next
    }

    // MARK: - Row building

    private static func item(
        for detail: SessionDetail,
        children: [SessionDetail],
        channel: MacChannelState
    ) -> SessionListItem {
        let summary = detail.summary
        let tone = summary.statusTone
        let latest: SessionListLatest? = tone == .gray ? nil : TimelineProjection.rows(from: detail.timeline).last.map {
            SessionListLatest(tag: $0.tag, label: $0.label, text: TextShaping.firstLine($0.text))
        }
        return SessionListItem(
            id: SessionListItemID(hostID: channel.hostID, sessionID: summary.id),
            deviceName: channel.displayName,
            title: normalizedTitle(summary.title),
            tone: tone,
            statusLabel: summary.displayLifecycle == .waitingForInput ? "Waiting" : summary.displayLifecycle.displayName,
            agentName: summary.agent.displayName,
            workspace: summary.workspace,
            lastActivityAt: summary.lastActivityAt,
            latest: latest,
            subagents: children.map { child in
                let span = SessionTiming.span(of: child)
                return SubagentChipItem(
                    id: child.summary.id,
                    name: normalizedTitle(child.summary.title),
                    tone: child.summary.statusTone,
                    startedAt: span.start,
                    endedAt: span.end
                )
            }
        )
    }

    static func normalizedTitle(_ title: String) -> String {
        SessionListRowPresentation.normalizedTitle(title)
    }
}

enum SessionTiming {
    /// Start of the newest turn (or the session when no turn is known) and
    /// its end — `nil` while the session is live, so the duration keeps ticking.
    static func span(of detail: SessionDetail) -> (start: Date, end: Date?) {
        let turn = detail.turns.last(where: { $0.isOpen }) ?? detail.turns.last
        let start = turn?.startedAt ?? detail.summary.startedAt
        let end = turn?.endedAt ?? (detail.summary.lifecycle.isLive ? nil : detail.summary.lastActivityAt)
        return (start, end)
    }
}
