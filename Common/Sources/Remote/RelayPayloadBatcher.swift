import Transport
import Foundation

/// Cuts host → device payloads into parts that each stay inside the Relay's
/// message budget. Shared by every multi-item payload (index parts, event
/// batches, summary batches); `RelaySessionPartitioner` does the same for a
/// page of one session's timeline.
///
/// Parts are filled greedily in item order by encoded size — each part takes
/// items until the next one would push it past the budget — so a page comes
/// out as few, evenly filled parts instead of the halving that used to leave
/// a trail of near-empty ones next to oversized ones.
public enum RelayPayloadBatcher {
    /// Encoded-plaintext budget per part. Deflate never grows JSON by more
    /// than a fraction of a percent and the sealed frame adds a header, a
    /// nonce and a 16-byte tag, so a part this size stays well under the
    /// Relay's 2 MiB message cap even when its content does not compress.
    public static let maxEncodedBytes = 1_000_000
    /// A part whose *compressed* size still exceeds this is split again:
    /// the hard ceiling under the Relay's message cap.
    public static let maxCompressedBytes = 1_400_000

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
        let chunks = try pack(entries, size: { try encodedSize($0) }) { chunk in
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

    /// Live events in arrival order, each timeline row trimmed to the Relay
    /// content budget (`RelayContentBudget`).
    public static func eventBatches(
        _ events: [AgentIngressEvent],
        generatedAt: Date
    ) throws -> [Batch] {
        let trimmed = events.map { event -> AgentIngressEvent in
            guard let item = event.timelineItem else { return event }
            var copy = event
            copy.timelineItem = RelayContentBudget.trimmed(item)
            return copy
        }
        let chunks = try pack(trimmed, size: { try encodedSize($0) }) { chunk in
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
        let chunks = try pack(summaries, size: { try encodedSize($0) }) { chunk in
            RemoteSessionPayload(kind: .sessionInfo, generatedAt: generatedAt, summaries: chunk)
        }
        return try chunks.map { chunk in
            let payload = RemoteSessionPayload(kind: .sessionInfo, generatedAt: generatedAt, summaries: chunk)
            return Batch(payload: payload, prepared: try RelayCryptography.prepare(payload))
        }
    }

    /// Greedy fill by encoded size, then a compressed-size check of each
    /// part. A single item over the budget still travels alone — callers
    /// trim rows first (`RelayContentBudget`), so this is the exception.
    static func pack<Item>(
        _ items: [Item],
        size: (Item) throws -> Int,
        make: ([Item]) -> RemoteSessionPayload
    ) throws -> [[Item]] {
        guard !items.isEmpty else { return [] }
        var chunks: [[Item]] = []
        var current: [Item] = []
        var currentBytes = 0
        for item in items {
            let bytes = try size(item) + 1 // the separator
            if !current.isEmpty, currentBytes + bytes > maxEncodedBytes {
                chunks.append(current)
                current = []
                currentBytes = 0
            }
            current.append(item)
            currentBytes += bytes
        }
        if !current.isEmpty { chunks.append(current) }
        // The compressed ceiling: a chunk that still overflows is halved
        // until it fits or is a single item.
        var checked: [[Item]] = []
        var pending = chunks
        while !pending.isEmpty {
            let chunk = pending.removeFirst()
            let withinCeiling = try chunk.count <= 1 || fits(make(chunk))
            if withinCeiling {
                checked.append(chunk)
            } else {
                let middle = chunk.count / 2
                pending.insert(Array(chunk[middle...]), at: 0)
                pending.insert(Array(chunk[..<middle]), at: 0)
            }
        }
        return checked
    }

    /// Whether one payload ships as a single frame under the Relay's cap.
    public static func fits(_ payload: RemoteSessionPayload) throws -> Bool {
        try RelayCryptography.prepare(payload).byteCount <= maxCompressedBytes
    }

    static func encodedSize<Item: Encodable>(_ item: Item) throws -> Int {
        try TransportCoding.makeEncoder().encode(item).count
    }
}
