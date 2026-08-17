import AgentStatusTransport
import Foundation

final class SessionListNode: NSObject {
    let summary: SessionSummary
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
        return SessionListHierarchy(roots: roots, nodesByID: nodesByID)
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
