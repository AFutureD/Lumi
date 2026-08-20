import AgentStatusRemote
import AgentStatusTransport
import Foundation

/// Splits one session into `.session` relay payloads that each stay inside
/// the relay's message budget after compression. Part 0 carries the turns;
/// later parts append timeline only. The last part has `nextCursor == nil`.
enum RelaySessionPartitioner {
    /// Compressed-plaintext budget per payload: sealed (+16B tag) and Base64
    /// (+33%) this stays well under the worker's 2 MiB message cap.
    static let maxCompressedBytes = 600_000
    /// A single item bigger than this is dropped from the relay copy only;
    /// the Mac and daemon keep it.
    static let singleItemHardCap = 1_500_000

    struct Part {
        let payload: RemoteSessionPayload
        let prepared: RelayPreparedPayload
    }

    static func parts(for detail: SessionDetail, generatedAt: Date) throws -> [Part] {
        // The common case: the whole session fits in one payload.
        if let single = try prepared(
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
        summary: SessionSummary,
        turns: [TurnSummary],
        timeline: [TimelineItem],
        part: Int,
        hasMore: Bool,
        generatedAt: Date,
        enforceBudget: Bool = true
    ) throws -> Part? {
        let payload = RemoteSessionPayload(
            kind: .session,
            generatedAt: generatedAt,
            session: SessionDetail(
                summary: summary,
                turns: turns,
                timeline: timeline,
                nextCursor: hasMore ? PaginationCursor(value: String(part + 1)) : nil
            ),
            part: part
        )
        let prepared = try RelayCryptography.prepare(payload)
        if enforceBudget, prepared.byteCount > maxCompressedBytes { return nil }
        return Part(payload: payload, prepared: prepared)
    }
}
