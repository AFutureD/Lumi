import Transport
import Foundation

/// Parent / subagent grouping shared by the Mac window, the Notch and the
/// iPhone list, so a subagent lands in the same group on every end.
///
/// A subagent belongs to the top-most *listed* ancestor of its lineage:
/// subagents of subagents fold into the same group as their parent (the
/// daemon allows any depth; the lists show one level). A session whose
/// parent is not listed — or whose lineage loops — is a top-level session
/// itself.
public enum SessionHierarchy {
    public struct Group: Hashable, Sendable {
        public let parent: SessionSummary
        /// Every descendant, sorted running → waiting → failed → done, newest
        /// activity first inside a bucket (`SubagentGroupSummary.precedes`).
        public let descendants: [SessionSummary]

        public init(parent: SessionSummary, descendants: [SessionSummary]) {
            self.parent = parent
            self.descendants = descendants
        }
    }

    /// Groups in the order their parents appear in `summaries`.
    public static func groups(_ summaries: [SessionSummary]) -> [Group] {
        let byID = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var descendantsByRoot: [SessionID: [SessionSummary]] = [:]
        var roots: [SessionSummary] = []
        var seen: Set<SessionID> = []
        for summary in summaries where seen.insert(summary.id).inserted {
            let root = rootID(of: summary, in: byID)
            if root == summary.id {
                roots.append(summary)
            } else {
                descendantsByRoot[root, default: []].append(summary)
            }
        }
        return roots.map { root in
            let descendants = (descendantsByRoot[root.id] ?? []).sorted { lhs, rhs in
                SubagentGroupSummary.precedes(
                    (lhs.statusTone, lhs.lastActivityAt),
                    (rhs.statusTone, rhs.lastActivityAt)
                )
            }
            return Group(parent: root, descendants: descendants)
        }
    }

    /// The sessions with a subagent still at work: every ancestor, at any
    /// depth, of a subagent thread whose own agent is at work
    /// (`SessionSummary.isAtWork`). A session parked at its prompt among
    /// these is not finished — the request it was given is still running.
    ///
    /// Read off the given sessions alone: the subagent sessions are the one
    /// record of what the subagents are doing, so nothing here is stored.
    /// A lineage that loops back on itself is walked once.
    public static func sessionsWithWorkingSubagents(_ summaries: [SessionSummary]) -> Set<SessionID> {
        var parents: [SessionID: SessionID] = [:]
        for summary in summaries {
            if let parent = summary.lineage?.parentSessionID { parents[summary.id] = parent }
        }
        var result: Set<SessionID> = []
        for summary in summaries where parents[summary.id] != nil && summary.isAtWork {
            var visited: Set<SessionID> = [summary.id]
            var cursor = summary.id
            while let parent = parents[cursor], visited.insert(parent).inserted {
                result.insert(parent)
                cursor = parent
            }
        }
        return result
    }

    /// The same sessions, each carrying whether its subagents are still at
    /// work (`SessionSummary.hasWorkingSubagents`). The one way that mark is
    /// set: an end calls this where it produces its session list, on every
    /// session it holds — a subagent outside the list cannot keep its parent
    /// running.
    public static func markingWorkingSubagents(_ summaries: [SessionSummary]) -> [SessionSummary] {
        let working = sessionsWithWorkingSubagents(summaries)
        return summaries.map { summary in
            let marked = working.contains(summary.id)
            return summary.hasWorkingSubagents == marked ? summary : summary.withWorkingSubagents(marked)
        }
    }

    /// The same marking for an end that holds whole sessions (the iPhone's
    /// channel cache): each detail's summary takes the mark.
    public static func markingWorkingSubagents(_ details: [SessionDetail]) -> [SessionDetail] {
        let working = sessionsWithWorkingSubagents(details.map(\.summary))
        return details.map { detail in
            let marked = working.contains(detail.summary.id)
            guard detail.summary.hasWorkingSubagents != marked else { return detail }
            return SessionDetail(
                summary: detail.summary.withWorkingSubagents(marked),
                turns: detail.turns,
                timeline: detail.timeline,
                nextCursor: detail.nextCursor
            )
        }
    }

    /// The top-most listed ancestor (the session itself when its parent is
    /// not listed or the lineage loops back on itself).
    public static func rootID(of summary: SessionSummary, in byID: [SessionID: SessionSummary]) -> SessionID {
        var visited: Set<SessionID> = [summary.id]
        var current = summary
        while let parentID = current.lineage?.parentSessionID, let parent = byID[parentID] {
            guard visited.insert(parentID).inserted else { return summary.id }
            current = parent
        }
        return current.id
    }
}
