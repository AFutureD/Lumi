import Transport
import Foundation

/// Cuts host → device payloads into pieces that each stay inside the relay's
/// message budget after compression. Shared by every multi-item payload
/// (index parts, event batches, summary batches); `RelaySessionPartitioner`
/// does the same for one session's timeline.
public enum RelayPayloadBatcher {
    /// Compressed-plaintext budget per payload: sealed (+16B tag) and Base64
    /// (+33%) this stays well under the worker's 2 MiB message cap.
    public static let maxCompressedBytes = 600_000

    public struct Batch: Sendable {
        public let payload: RemoteSessionPayload
        public let prepared: RelayPreparedPayload
    }

    /// The index as ordered parts; every part carries `part` / `partCount`
    /// and echoes the request. An empty index is one empty part.
    public static func indexParts(
        _ entries: [SessionIndexEntry],
        requestID: RequestID?,
        generatedAt: Date
    ) throws -> [Batch] {
        let chunks = try split(entries, oversizedSingle: { _ in nil }) { chunk in
            RemoteSessionPayload(kind: .sessionIndex, generatedAt: generatedAt, requestID: requestID, index: chunk, part: 0, partCount: 1)
        }
        let normalized = chunks.isEmpty ? [[]] : chunks
        return try normalized.enumerated().map { offset, chunk in
            let payload = RemoteSessionPayload(
                kind: .sessionIndex,
                generatedAt: generatedAt,
                requestID: requestID,
                index: chunk,
                part: offset,
                partCount: normalized.count
            )
            return Batch(payload: payload, prepared: try RelayCryptography.prepare(payload))
        }
    }

    /// Live events in arrival order. An event that alone overflows the budget
    /// goes out without its timeline item (its lifecycle / phase / turn still
    /// land); the mirror heals the missing row on its next index reconcile.
    public static func eventBatches(
        _ events: [AgentIngressEvent],
        generatedAt: Date
    ) throws -> [Batch] {
        let chunks = try split(events, oversizedSingle: { event in
            guard event.timelineItem != nil else { return nil }
            return AgentIngressEvent(
                eventID: event.eventID,
                sessionID: event.sessionID,
                turnID: event.turnID,
                agent: event.agent,
                occurredAt: event.occurredAt,
                title: event.title,
                workspace: event.workspace,
                lifecycle: event.lifecycle,
                phase: event.phase,
                turn: event.turn,
                timelineItem: nil,
                lineage: event.lineage,
                disposition: event.disposition
            )
        }) { chunk in
            RemoteSessionPayload(kind: .sessionMessage, generatedAt: generatedAt, events: chunk)
        }
        return try chunks.map { chunk in
            let payload = RemoteSessionPayload(kind: .sessionMessage, generatedAt: generatedAt, events: chunk)
            return Batch(payload: payload, prepared: try RelayCryptography.prepare(payload))
        }
    }

    /// Summary-only changes (`session_info`).
    public static func summaryBatches(
        _ summaries: [SessionSummary],
        generatedAt: Date
    ) throws -> [Batch] {
        let chunks = try split(summaries, oversizedSingle: { _ in nil }) { chunk in
            RemoteSessionPayload(kind: .sessionInfo, generatedAt: generatedAt, summaries: chunk)
        }
        return try chunks.map { chunk in
            let payload = RemoteSessionPayload(kind: .sessionInfo, generatedAt: generatedAt, summaries: chunk)
            return Batch(payload: payload, prepared: try RelayCryptography.prepare(payload))
        }
    }

    /// Halves `items` until every chunk's payload fits. A single item that
    /// still overflows is replaced by `oversizedSingle` (or dropped when that
    /// returns `nil` or the replacement overflows too).
    static func split<Item>(
        _ items: [Item],
        oversizedSingle: (Item) -> Item?,
        make: ([Item]) -> RemoteSessionPayload
    ) throws -> [[Item]] {
        guard !items.isEmpty else { return [] }
        var chunks: [[Item]] = []
        var pending: [[Item]] = [items]
        while let candidate = pending.first {
            pending.removeFirst()
            if try fits(make(candidate)) {
                chunks.append(candidate)
                continue
            }
            if candidate.count <= 1 {
                if let item = candidate.first,
                   let replacement = oversizedSingle(item),
                   try fits(make([replacement])) {
                    chunks.append([replacement])
                }
                continue
            }
            let middle = candidate.count / 2
            pending.insert(Array(candidate[middle...]), at: 0)
            pending.insert(Array(candidate[..<middle]), at: 0)
        }
        return chunks
    }

    static func fits(_ payload: RemoteSessionPayload) throws -> Bool {
        try RelayCryptography.prepare(payload).byteCount <= maxCompressedBytes
    }
}
