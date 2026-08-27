import Core
import Transport
import Foundation

/// One block of the flat Sessions list (§4.4b): the two-line session row plus
/// every subagent line under it. Pure value — the view controller diffs
/// consecutive builds on it and only touches rows that changed.
struct SessionListRowModel: Equatable {
    struct SubagentLine: Equatable {
        let id: SessionID
        let title: String
        let tone: SessionStatusTone
        /// Dot tooltip: `Running · Responding`.
        let status: String
        let startedAt: Date
        /// `nil` while the subagent is still live; the duration keeps ticking.
        let endedAt: Date?
    }

    let id: SessionID
    let title: String
    let agent: AgentKind
    let agentName: String
    let tone: SessionStatusTone
    /// Dot tooltip: `Running · Responding` — display lifecycle · phase.
    let status: String
    let lastActivityAt: Date
    /// Raw CLI-reported values, unmapped; nil hides the segment (and the
    /// `·` separator goes with a missing effort).
    let model: String?
    let reasoningEffort: String?
    /// Spawn order (earliest started first — the run's execution trace);
    /// all of them — the view never paginates.
    let subagents: [SubagentLine]
    var isExpanded: Bool

    /// Stacked-dot tooltip: `3 subagents · 2 running · 1 done`.
    var subagentSummaryLabel: String {
        SubagentGroupSummary.label(tones: subagents.map(\.tone))
    }

    /// Stacked-dot tones for the collapsed cluster. The cluster is a summary,
    /// so it keeps bucket order (running → waiting → failed → done) and active
    /// dots stay visible ahead of the cap, unlike the spawn-ordered lines.
    var clusterTones: [SessionStatusTone] {
        subagents.map(\.tone).sorted {
            SubagentSummaryBucket(tone: $0) < SubagentSummaryBucket(tone: $1)
        }
    }
}

enum SessionListModel {
    /// List order: newest created first. Creation time is stable, so rows
    /// don't shuffle as activity arrives; ties break on id for determinism.
    static func ordered(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    /// Roots keep the caller's order (newest created first); every
    /// descendant of a root — regardless of depth — becomes one subagent
    /// line of that root, in spawn order.
    static func rows(
        sessions: [SessionSummary],
        filter: String,
        modelStamps: [SessionID: SessionModelStamp],
        isExpanded: (SessionID, SessionStatusTone) -> Bool
    ) -> [SessionListRowModel] {
        let filtered = SessionListHierarchy.filtering(sessions, query: filter)
        let hierarchy = SessionListHierarchy.build(from: filtered)
        return hierarchy.roots.map { root in
            let summary = root.summary
            let presentation = SessionListRowPresentation(session: summary)
            var descendants: [SessionSummary] = []
            collectDescendants(of: root, into: &descendants)
            descendants.sort {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.id.rawValue < $1.id.rawValue
            }
            let stamp = modelStamps[summary.id]
            return SessionListRowModel(
                id: summary.id,
                title: presentation.title,
                agent: summary.agent,
                agentName: presentation.agent,
                tone: summary.statusTone,
                status: presentation.status,
                lastActivityAt: summary.displayActivityAt,
                model: stamp?.model,
                reasoningEffort: stamp?.reasoningEffort,
                subagents: descendants.map { child in
                    SessionListRowModel.SubagentLine(
                        id: child.id,
                        title: SessionListRowPresentation.normalizedTitle(child.title),
                        tone: child.statusTone,
                        status: SessionListRowPresentation(session: child).status,
                        startedAt: child.startedAt,
                        // `displayLifecycle`: a subagent parked at its prompt
                        // (waitingForInput · idle) shows a done dot — its
                        // duration must freeze with it.
                        endedAt: child.displayLifecycle.isLive ? nil : child.displayActivityAt
                    )
                },
                isExpanded: !descendants.isEmpty && isExpanded(summary.id, summary.statusTone)
            )
        }
    }

    /// Default disclosure of a subagent group: tiers that still want the
    /// human (Running / Waiting / Failed) open, ended tiers closed.
    static func expandsByDefault(_ tone: SessionStatusTone) -> Bool {
        switch tone {
        case .blue, .orange, .red: true
        case .green, .gray: false
        }
    }

    /// Whether the tier-default disclosure differs across a tone change —
    /// only then does a manual override reset. Green ⇄ gray (the review flag
    /// clearing when the human opens the session) stays within the collapsed
    /// default, so a click never collapses a group the user just opened.
    static func defaultDisclosureChanged(from old: SessionStatusTone, to new: SessionStatusTone) -> Bool {
        expandsByDefault(old) != expandsByDefault(new)
    }

    private static func collectDescendants(of node: SessionListNode, into result: inout [SessionSummary]) {
        for child in node.children {
            result.append(child.summary)
            collectDescendants(of: child, into: &result)
        }
    }
}
