import AgentStatusTransport
import Foundation

/// Pure reduction over multi-part relay payloads.
public enum RelayFrameReduction {
    /// One session arrives as ordered `session_full` / `session_timeline`
    /// parts; part 0 carries the summary and turns, later parts append
    /// timeline. `nil` when the buffer is empty or carries no detail.
    public static func assemble(parts: [RemoteSessionPayload]) -> SessionDetail? {
        let ordered = parts.sorted { ($0.part ?? 0) < ($1.part ?? 0) }
        guard let first = ordered.first?.session else { return nil }
        let timeline = ordered.compactMap(\.session).flatMap(\.timeline)
        return SessionDetail(summary: first.summary, turns: first.turns, timeline: timeline)
    }

    /// The index arrives as `partCount` parts; `nil` until every part is in.
    public static func assembleIndex(parts: [RemoteSessionPayload]) -> [SessionIndexEntry]? {
        guard let partCount = parts.first?.partCount, partCount > 0 else { return nil }
        let byPart = Dictionary(parts.compactMap { part in part.part.map { ($0, part) } }, uniquingKeysWith: { _, last in last })
        guard byPart.count == partCount, (0..<partCount).allSatisfy({ byPart[$0] != nil }) else { return nil }
        return (0..<partCount).flatMap { byPart[$0]?.index ?? [] }
    }
}
