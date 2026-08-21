import AgentStatusTransport
import Foundation

/// Splits one session into `session_full` / `session_timeline` payloads that
/// each stay inside the relay's message budget after compression. Part 0
/// carries the turns; later parts append timeline only. The last part has
/// `session.nextCursor == nil`.
public enum RelaySessionPartitioner {
    public static let maxCompressedBytes = RelayPayloadBatcher.maxCompressedBytes
    /// A single item bigger than this is dropped from the relay copy only;
    /// the daemon and the Mac keep it.
    public static let singleItemHardCap = 1_500_000

    public struct Part: Sendable {
        public let payload: RemoteSessionPayload
        public let prepared: RelayPreparedPayload
    }

    public static func parts(
        for detail: SessionDetail,
        kind: RemotePayloadKind = .sessionFull,
        requestID: RequestID?,
        generatedAt: Date
    ) throws -> [Part] {
        // The common case: the whole session fits in one payload.
        if let single = try prepared(
            kind: kind,
            requestID: requestID,
            summary: detail.summary,
            turns: detail.turns,
            timeline: detail.timeline,
            part: 0,
            hasMore: false,
            generatedAt: generatedAt
        ) {
            return [single]
        }

        // Split the timeline; turns ride only on part 0. Chunks halve until
        // they fit, single oversized items are dropped from the relay copy.
        var chunks: [[TimelineItem]] = []
        var pending: [[TimelineItem]] = [detail.timeline]
        while let candidate = pending.first {
            pending.removeFirst()
            if try prepared(
                kind: kind,
                requestID: requestID,
                summary: detail.summary,
                turns: chunks.isEmpty ? detail.turns : [],
                timeline: candidate,
                part: 0,
                hasMore: true,
                generatedAt: generatedAt
            ) != nil {
                chunks.append(candidate)
                continue
            }
            if candidate.count <= 1 {
                // One item alone still overflows: keep it only if it clears
                // the hard cap check below, otherwise omit it from the relay.
                if let item = candidate.first,
                   (try? TransportCoding.makeEncoder().encode(item).count) ?? .max <= singleItemHardCap {
                    chunks.append(candidate)
                }
                continue
            }
            let middle = candidate.count / 2
            pending.insert(Array(candidate[middle...]), at: 0)
            pending.insert(Array(candidate[..<middle]), at: 0)
        }
        if chunks.isEmpty { chunks = [[]] }

        var parts: [Part] = []
        parts.reserveCapacity(chunks.count)
        for (index, chunk) in chunks.enumerated() {
            let hasMore = index < chunks.count - 1
            guard let part = try prepared(
                kind: kind,
                requestID: requestID,
                summary: detail.summary,
                turns: index == 0 ? detail.turns : [],
                timeline: chunk,
                part: index,
                hasMore: hasMore,
                generatedAt: generatedAt
            ) else {
                // Turns alone overflowing the budget is pathological; drop
                // them from the relay copy rather than fail the publish.
                let fallback = try prepared(
                    kind: kind,
                    requestID: requestID,
                    summary: detail.summary,
                    turns: [],
                    timeline: chunk,
                    part: index,
                    hasMore: hasMore,
                    generatedAt: generatedAt,
                    enforceBudget: false
                )
                if let fallback { parts.append(fallback) }
                continue
            }
            parts.append(part)
        }
        return parts
    }

    private static func prepared(
        kind: RemotePayloadKind,
        requestID: RequestID?,
        summary: SessionSummary,
        turns: [TurnSummary],
        timeline: [TimelineItem],
        part: Int,
        hasMore: Bool,
        generatedAt: Date,
        enforceBudget: Bool = true
    ) throws -> Part? {
        let payload = RemoteSessionPayload(
            kind: kind,
            generatedAt: generatedAt,
            requestID: requestID,
            part: part,
            session: SessionDetail(
                summary: summary,
                turns: turns,
                timeline: timeline,
                nextCursor: hasMore ? PaginationCursor(value: String(part + 1)) : nil
            )
        )
        let prepared = try RelayCryptography.prepare(payload)
        if enforceBudget, prepared.byteCount > maxCompressedBytes { return nil }
        return Part(payload: payload, prepared: prepared)
    }
}
