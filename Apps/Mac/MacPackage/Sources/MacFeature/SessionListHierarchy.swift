import Core
import Transport
import Foundation

final class SessionListNode: NSObject {
    var summary: SessionSummary
    var children: [SessionListNode] = []

    init(summary: SessionSummary) {
        self.summary = summary
    }
}

struct SessionListHierarchy {
    let roots: [SessionListNode]
    let nodesByID: [SessionID: SessionListNode]

    static func build(from sessions: [SessionSummary]) -> SessionListHierarchy {
        let summariesByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let nodesByID = Dictionary(uniqueKeysWithValues: sessions.map {
            ($0.id, SessionListNode(summary: $0))
        })
        var roots: [SessionListNode] = []

        for summary in sessions {
            guard let node = nodesByID[summary.id] else { continue }
            if let parentID = summary.lineage?.parentSessionID,
               let parent = nodesByID[parentID],
               !wouldCreateCycle(
                   childID: summary.id,
                   parentID: parentID,
                   summariesByID: summariesByID
               ) {
                parent.children.append(node)
            } else {
                roots.append(node)
            }
        }
        // Children keep insertion order; the flat list re-sorts descendants
        // into spawn order (`SessionListModel.rows`).
        return SessionListHierarchy(roots: roots, nodesByID: nodesByID)
    }

    /// Case-insensitive title / agent match. Ancestors of a matching Session are
    /// kept so the child stays reachable in the outline; order is preserved.
    static func filtering(_ sessions: [SessionSummary], query: String) -> [SessionSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sessions }
        let summariesByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var retained: Set<SessionID> = []
        for summary in sessions where matches(summary, query: trimmed) {
            var current: SessionSummary? = summary
            var visited: Set<SessionID> = []
            while let session = current, visited.insert(session.id).inserted {
                retained.insert(session.id)
                current = session.lineage?.parentSessionID.flatMap { summariesByID[$0] }
            }
        }
        return sessions.filter { retained.contains($0.id) }
    }

    private static func matches(_ summary: SessionSummary, query: String) -> Bool {
        summary.title.localizedCaseInsensitiveContains(query)
            || summary.agent.displayName.localizedCaseInsensitiveContains(query)
            || summary.workspace?.localizedCaseInsensitiveContains(query) == true
    }

    private static func wouldCreateCycle(
        childID: SessionID,
        parentID: SessionID,
        summariesByID: [SessionID: SessionSummary]
    ) -> Bool {
        var visited: Set<SessionID> = [childID]
        var currentID: SessionID? = parentID
        while let id = currentID {
            guard visited.insert(id).inserted else { return true }
            currentID = summariesByID[id]?.lineage?.parentSessionID
        }
        return false
    }
}
