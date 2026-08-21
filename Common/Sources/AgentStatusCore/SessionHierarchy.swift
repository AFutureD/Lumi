import AgentStatusTransport
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
