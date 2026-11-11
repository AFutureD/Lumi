import Transport
import Foundation

/// Splits one page of a session's timeline into `session_tail` /
/// `session_history` / `session_timeline` / `session_items` parts that each
/// stay inside the Relay's message budget. Every row is first trimmed to the
/// Relay content budget; parts are then filled greedily by encoded size.
///
/// Part 0 carries the summary and the turns; later parts append rows only.
/// Every part is added to the mirror's copy (nothing replaces), so the order
/// of the rows across parts is only the order the person sees them land:
/// `newestFirst` for a tail or an older page (the rows nearest the screen
/// first), `oldestFirst` for a since-tail. The last part has
/// `session.nextCursor == nil`, names the page's oldest row (`oldest`) and,
/// for a tail or an older page, says whether older rows remain (`hasOlder`).
public enum RelaySessionPartitioner {
    public enum Order: Sendable {
        case newestFirst
        case oldestFirst
    }

    public struct Part: Sendable {
        public let payload: RemoteSessionPayload
        public let prepared: RelayPreparedPayload
    }

    /// - Parameters:
    ///   - timeline: the page's rows in timeline order (oldest first).
    ///   - hasOlder: sent on the last part; `nil` for kinds that do not page.
    ///   - trimming: apply the content budget (`false` only for `session_items`).
    public static func parts(
        summary: SessionSummary,
        turns: [TurnSummary],
        timeline: [TimelineItem],
        hasOlder: Bool?,
        kind: RemotePayloadKind,
        order: Order,
        requestID: RequestID?,
        generatedAt: Date,
        trimming: Bool = true
    ) throws -> [Part] {
        // `session_items` answers a request for whole rows: they skip the
        // content budget, but a row that cannot fit a frame even alone is
        // trimmed after all rather than never arriving.
        let trimmed = timeline.map { item in
            trimming || TimelineContentBudget.encodedSize(item) > RelayPayloadBatcher.maxEncodedBytes
                ? TimelineContentBudget.trimmed(item)
                : item
        }
        let ordered = order == .newestFirst ? Array(trimmed.reversed()) : trimmed
        var chunks = try RelayPayloadBatcher.pack(ordered, size: TimelineContentBudget.encodedSize) { chunk in
            payload(kind: kind, requestID: requestID, summary: summary, turns: [], timeline: chunk, part: 0, hasMore: true, hasOlder: nil, oldest: nil, generatedAt: generatedAt)
        }
        if chunks.isEmpty { chunks = [[]] }
        var parts: [Part] = []
        parts.reserveCapacity(chunks.count)
        for (index, chunk) in chunks.enumerated() {
            let last = index == chunks.count - 1
            // Each chunk is already within budget without the turns; turns on
            // part 0 are the one addition, and a turn list that alone breaks
            // the ceiling is pathological — the chunk then goes without it
            // rather than failing the whole page.
            let oldest = last ? trimmed.first.map(TimelineCursor.init) : nil
            var payload = payload(kind: kind, requestID: requestID, summary: summary, turns: index == 0 ? turns : [], timeline: chunk, part: index, hasMore: !last, hasOlder: last ? hasOlder : nil, oldest: oldest, generatedAt: generatedAt)
            var prepared = try RelayCryptography.prepare(payload)
            if index == 0, !turns.isEmpty, prepared.byteCount > RelayPayloadBatcher.maxCompressedBytes {
                payload = self.payload(kind: kind, requestID: requestID, summary: summary, turns: [], timeline: chunk, part: index, hasMore: !last, hasOlder: last ? hasOlder : nil, oldest: oldest, generatedAt: generatedAt)
                prepared = try RelayCryptography.prepare(payload)
            }
            parts.append(Part(payload: payload, prepared: prepared))
        }
        return parts
    }

    private static func payload(
        kind: RemotePayloadKind,
        requestID: RequestID?,
        summary: SessionSummary,
        turns: [TurnSummary],
        timeline: [TimelineItem],
        part: Int,
        hasMore: Bool,
        hasOlder: Bool?,
        oldest: TimelineCursor?,
        generatedAt: Date
    ) -> RemoteSessionPayload {
        RemoteSessionPayload(
            kind: kind,
            generatedAt: generatedAt,
            requestID: requestID,
            part: part,
            hasOlder: hasOlder,
            oldest: oldest,
            session: SessionDetail(
                summary: summary,
                turns: turns,
                timeline: timeline,
                nextCursor: hasMore ? PaginationCursor(value: String(part + 1)) : nil
            )
        )
    }
}
