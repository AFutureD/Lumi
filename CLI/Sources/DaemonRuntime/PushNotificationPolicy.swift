import Core
import CryptoKit
import Remote
import Transport
import Foundation

/// Decides which just-ingested events deserve an APNs alert on paired
/// iPhones. Mirrors what the Mac's Notch actually notifies for: of the L3
/// tags, `turnEnd` / `turnFailed` / `aborted` alert and `.user` does not
/// (the Notch handles a turn start as an explicit no-op).
///
/// Pure functions over data the caller hands in, so every rule is testable
/// without a repository or a Relay.
public enum PushNotificationPolicy {
    /// Events older than this never alert. Catches the two replay floods the
    /// Mac's `HaloActivityDiff` guards against by other means: transcript
    /// backfill re-publishing old items, and watchers catching up after the
    /// Mac slept.
    public static let freshnessWindow: TimeInterval = 120
    /// At most one alert per session inside this window; APNs collapses the
    /// rest through `collapseID`.
    public static let cooldown: TimeInterval = 5
    /// The Relay refuses titles over 120 UTF-16 units (a JS string length),
    /// so the bound is enforced here in the same units — a long session title
    /// degrades to a truncated alert instead of a permanently refused one.
    static let maxTitleUTF16 = 120

    /// An event whose timeline item classifies as an alerting L3 row.
    public struct NotableEvent: Hashable, Sendable {
        public let sessionID: SessionID
        public let tag: TimelineTag
        public let occurredAt: Date
    }

    public struct Candidate: Hashable, Sendable {
        public let sessionID: SessionID
        /// The session's title.
        public let title: String
        /// The session's state word, same vocabulary as the status capsules.
        public let subtitle: String
        public let occurredAt: Date
    }

    /// Stage one, synchronous: classification and freshness. The caller looks
    /// up summaries for the surviving sessions and comes back for stage two.
    public static func notableEvents(_ events: [AgentIngressEvent], now: Date) -> [NotableEvent] {
        events.compactMap { event in
            guard now.timeIntervalSince(event.occurredAt) <= freshnessWindow,
                  let item = event.timelineItem,
                  let row = TimelineProjection.rows(from: [item]).first,
                  row.tag == .turnEnd || row.tag == .turnFailed || row.tag == .aborted else {
                return nil
            }
            return NotableEvent(
                sessionID: event.sessionID,
                tag: row.tag,
                occurredAt: event.occurredAt
            )
        }
    }

    /// Stage two: one candidate per session (the latest notable event wins),
    /// suppressing subagents whose parent is still retained (their turn ends
    /// are the parent's process noise), provisional sessions (never shown in
    /// any UI), and sessions inside their cooldown window.
    public static func candidates(
        notable: [NotableEvent],
        summaries: [SessionID: SessionSummary],
        retainedParents: Set<SessionID>,
        lastPushAt: [SessionID: Date],
        now: Date
    ) -> [Candidate] {
        var latest: [SessionID: NotableEvent] = [:]
        for event in notable {
            if let current = latest[event.sessionID], current.occurredAt > event.occurredAt { continue }
            latest[event.sessionID] = event
        }
        return latest.values.compactMap { event in
            guard let summary = summaries[event.sessionID], !summary.isProvisional else { return nil }
            if let parent = summary.lineage?.parentSessionID, retainedParents.contains(parent) { return nil }
            if let last = lastPushAt[event.sessionID], now.timeIntervalSince(last) < cooldown { return nil }
            return Candidate(
                sessionID: event.sessionID,
                title: Self.boundedTitle(summary.title),
                subtitle: Self.subtitle(for: event.tag),
                occurredAt: event.occurredAt
            )
        }.sorted { $0.occurredAt < $1.occurredAt }
    }

    /// The state word for an alerting tag. Deliberately pinned to the EVENT,
    /// not to the session's state at send time: the alert says what this turn
    /// did, and the session may already be running again when it goes out.
    /// The vocabulary comes from `SessionLifecycle.displayName` so the words
    /// match the status capsules; the tag→lifecycle mapping itself lives here
    /// (and in the test that locks the three words) — update both if the
    /// capsule wording rules in `SessionStatusTone` ever change.
    public static func subtitle(for tag: TimelineTag) -> String {
        switch tag {
        case .turnFailed: SessionLifecycle.failed.displayName
        case .aborted: SessionLifecycle.interrupted.displayName
        default: SessionLifecycle.completed.displayName
        }
    }

    /// Trims to the Relay's title bound without splitting a grapheme; the
    /// ellipsis fits inside the bound.
    public static func boundedTitle(_ title: String) -> String {
        guard title.utf16.count > maxTitleUTF16 else { return title }
        var trimmed = title
        while trimmed.utf16.count > maxTitleUTF16 - 1 { trimmed.removeLast() }
        return trimmed + "…"
    }

    /// The Relay caps collapse IDs at 64 header-safe characters; a session ID
    /// that does not fit collapses under a stable hash of itself instead.
    public static func collapseID(for sessionID: SessionID) -> String {
        let raw = sessionID.rawValue
        let safe = !raw.isEmpty && raw.count <= 64
            && raw.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0)) }
        if safe { return raw }
        return SHA256.hash(data: Data(raw.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
