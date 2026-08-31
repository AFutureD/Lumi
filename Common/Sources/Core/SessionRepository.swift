import Transport
import Foundation

public typealias RolloutCursor = Transport.RolloutCursor

public protocol SessionRepository: Sendable {
    @discardableResult
    func apply(_ event: AgentIngressEvent) async throws -> Bool
    func listSessions(limit: Int) async throws -> [SessionSummary]
    func sessionDetail(id: SessionID, cursor: PaginationCursor?, limit: Int) async throws -> SessionDetail?
    /// The summary alone — for summary-only broadcasts and checks. Skips the
    /// timeline read and the turn projection entirely.
    func sessionSummary(id: SessionID) async throws -> SessionSummary?
    /// Atomically installs one authoritative session: clears its tombstone,
    /// then replaces summary, turns and timeline wholesale. Never touches
    /// processed events — client-side event dedupe must survive.
    func replaceSession(_ detail: SessionDetail) async throws
    /// Drops local sessions absent from an authoritative index. Writes no
    /// tombstones: the authoritative side may resurrect any of them later.
    @discardableResult
    func pruneSessions(keeping ids: Set<SessionID>) async throws -> Int
    /// Deletes the session and, transitively, every session whose lineage
    /// names it as parent — a subagent session is part of its parent's story
    /// and must not outlive it. Each member is tombstoned. Returns the ids
    /// that actually existed (empty when nothing was retained).
    @discardableResult
    func deleteSession(id: SessionID) async throws -> [SessionID]
    func deleteAllSessions() async throws -> Int
    /// The authoritative index a mirror reconciles against: every session in
    /// latest-activity order with its raw timeline facts (`COUNT`, `MAX(occurred_at)`).
    func sessionIndex(limit: Int) async throws -> [SessionIndexEntry]
    /// Writes only the summary of a retained session (no-op when the session
    /// is not retained). For summary-only changes relayed as `session_info`.
    func updateSummary(_ summary: SessionSummary) async throws
    /// Folds a partial copy (summary, turns, a slice of the timeline) into the
    /// retained session: upserts by id under the same `occurredAt` rule as
    /// `apply`, never deletes rows, never touches processed events, clears
    /// the tombstone. For `session_timeline` tails.
    func mergeSession(_ detail: SessionDetail) async throws
    /// The session's summary, every turn, and the timeline rows with
    /// `occurredAt >= since`, paged like `sessionDetail` (`cursor` is the
    /// offset inside the filtered rows).
    func timelineSince(id: SessionID, since: Date, cursor: PaginationCursor?, limit: Int) async throws -> SessionDetail?
    /// The turn a transcript increment continues: the turnID of the newest
    /// turn-scoped timeline item (`TurnProjection.currentTurnID`).
    func currentTurnID(sessionID: SessionID) async throws -> TurnID?
    func rolloutCursor(path: String) async throws -> RolloutCursor?
    /// Newest cursor recorded for the session, i.e. where its transcript /
    /// rollout lives.
    func rolloutCursor(sessionID: SessionID) async throws -> RolloutCursor?
    func saveRolloutCursor(_ cursor: RolloutCursor) async throws
    /// Drops the session's summary, turns, timeline and cursors so it can be
    /// rebuilt from its rich source. Unlike `deleteSession` this leaves no
    /// tombstone. Returns whether the session existed.
    func resetSession(id: SessionID) async throws -> Bool
    func markSessionIgnored(_ sessionID: SessionID) async throws
    /// True while the id carries a tombstone (deleted by the user, no row).
    func isSessionIgnored(_ sessionID: SessionID) async throws -> Bool
    /// The human opened the session: clear `SessionSummary.needsReview`.
    func markSessionReviewed(_ sessionID: SessionID) async throws
    /// The human archived the session from the Notch: set
    /// `SessionSummary.hiddenInNotch`. Only re-engaging the session (a new
    /// prompt or a restart) clears it, via `SessionReduction`.
    func markSessionHiddenInNotch(_ sessionID: SessionID) async throws
    /// Overwrites the frozen filter verdict and its latch, in either
    /// direction. Only the reingester calls this — a rebuild replays events
    /// against the current rules, and the previous verdict must win over
    /// that re-evaluation.
    func setSessionFilterVerdict(_ sessionID: SessionID, hiddenByFilter: Bool, filterEvaluated: Bool) async throws
    /// The stored filter rules, in user order. Settings, not history:
    /// `deleteAllSessions` (clear history) must leave them untouched.
    func sessionFilterRules() async throws -> [SessionFilterRule]
    /// Replaces the whole rule list (the write model of the Settings editor).
    func setSessionFilterRules(_ rules: [SessionFilterRule]) async throws
    func isRolloutBaselineInitialized() async throws -> Bool
    func markRolloutBaselineInitialized() async throws
}

public enum SessionReduction {
    public static func summary(
        applying event: AgentIngressEvent,
        to current: SessionSummary?
    ) -> SessionSummary {
        // Two clocks, one rule: an event may only gate the fields it asserts.
        //
        // `lastActivityAt` is the state clock: it moves only when the agent
        // asserts its state (the event carries lifecycle or phase), and it is
        // the only guard on lifecycle/phase. A metadata-only event — config
        // touch, title, diagnostic — can never freeze an earlier state
        // assertion out, no matter how new its timestamp is.
        //
        // `updatedAt` is the record clock: every accepted event advances it,
        // and it guards metadata (title / workspace / agent) so a stale
        // straggler does not overwrite a newer value.
        let assertsState = event.lifecycle != nil || event.phase != nil
        let shouldUpdateState = current == nil
            || (assertsState && event.occurredAt >= current!.lastActivityAt)
        let shouldUpdateMetadata = current == nil || event.occurredAt >= current!.updatedAt
        let lifecycle = shouldUpdateState
            ? (event.lifecycle ?? current?.lifecycle ?? .starting)
            : (current?.lifecycle ?? .starting)
        let phase = shouldUpdateState
            ? (event.phase ?? current?.phase ?? .idle)
            : (current?.phase ?? .idle)
        // Sticky until the human opens the session; `markSessionReviewed`
        // is the only thing that clears it.
        let endsTurn = if case .turnEnd = event.timelineItem?.payload { true } else { false }
        let needsReview = endsTurn || (current?.needsReview ?? false)
        // Sticky until the human engages the session again, under the same
        // predicate that resurrects a deleted one.
        let hiddenInNotch = event.resurrectsHiddenSession
            ? false
            : (current?.hiddenInNotch ?? false)
        // The frozen filter verdict and its once-only latch: stamped by the
        // daemon repository when the session's first user message arrives,
        // then carried forever. Never recomputed here — mirrors replay this
        // reduction without the rules — and unlike hiddenInNotch,
        // resurrection does not clear either.
        let hiddenByFilter = current?.hiddenByFilter ?? false
        let filterEvaluated = current?.filterEvaluated ?? false
        // The tiers a human should act on: approval orange, unreviewed green,
        // failure red.
        let needsAttention = switch SessionStatusTone.resolve(
            lifecycle: lifecycle,
            phase: phase,
            needsReview: needsReview
        ) {
        case .orange, .green, .red: true
        case .blue, .gray: false
        }
        let isIdentityOnly = event.title != nil
            && event.workspace == nil
            && event.lifecycle == nil
            && event.phase == nil
            && event.timelineItem == nil
        // A `.codex` event with no lineage cannot demote a session already
        // known to be a subagent thread — only lineage carries that verdict.
        // Identity-only events (subagent meta, wrapper titles) get the same
        // guard: they update the agent but never flip subagent → codex.
        // An all-nil lineage carries no fact and must behave like an absent
        // one — both for the demotion guard and the merge below.
        let eventLineage = event.lineage.flatMap { $0.isEmpty ? nil : $0 }
        let demotesSubagent = eventLineage == nil
            && event.agent == .codex
            && current?.agent == .codexSubagent
        let agent = if isIdentityOnly || shouldUpdateMetadata {
            demotesSubagent ? current!.agent : event.agent
        } else {
            current?.agent ?? event.agent
        }
        let agentName = agent.rawValue
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        // The owning AaaS is the authority on the title. When the owner does
        // not title through the agent's native channels (Paseo / Raft), only
        // hook-path events — the ones that carry the ownership stamp — may
        // retitle; native titles riding on watcher / replay events (adapters
        // stamp the thread name on every rollout event) are ignored.
        let ownerBlocksTitle = current?.aaas?.allowsNativeTitle == false && event.aaas == nil
        let title = if (isIdentityOnly || shouldUpdateMetadata) && !ownerBlocksTitle {
            event.title ?? current?.title ?? "\(agentName) Session"
        } else {
            current?.title ?? "\(agentName) Session"
        }
        // The first turn-scoped event marks the session as used for good;
        // backfill may only move the mark earlier, never clear it.
        let turnAt: Date? = (event.turnID ?? event.turn?.id) != nil ? event.occurredAt : nil
        let firstTurnAt = [current?.firstTurnAt, turnAt].compactMap { $0 }.min()
        // AaaS ownership: asserted by hook-path events, sticky otherwise —
        // watcher / replay / reingest events carry nil and never clear it.
        // A session resumed under another host flips to the newest assertion.
        let aaas = (isIdentityOnly || shouldUpdateMetadata)
            ? (event.aaas ?? current?.aaas)
            : current?.aaas

        return SessionSummary(
            id: event.sessionID,
            agent: agent,
            title: title,
            workspace: shouldUpdateMetadata
                ? (event.workspace ?? current?.workspace)
                : current?.workspace,
            lifecycle: lifecycle,
            phase: phase,
            startedAt: min(current?.startedAt ?? event.occurredAt, event.occurredAt),
            updatedAt: max(current?.updatedAt ?? event.occurredAt, event.occurredAt),
            // A session created by a metadata-only event has no activity yet:
            // seeding the state clock at `.distantPast` keeps the door open
            // for the backfilled history (older timestamps) to assert the
            // real state.
            lastActivityAt: assertsState
                ? max(current?.lastActivityAt ?? .distantPast, event.occurredAt)
                : (current?.lastActivityAt ?? .distantPast),
            needsAttention: needsAttention,
            needsReview: needsReview,
            hiddenInNotch: hiddenInNotch,
            hiddenByFilter: hiddenByFilter,
            filterEvaluated: filterEvaluated,
            lineage: eventLineage ?? current?.lineage,
            firstTurnAt: firstTurnAt,
            aaas: aaas
        )
    }

    /// Whether this event is the one the filter verdict is evaluated on: the
    /// session's first user-classified message — a timeline item whose
    /// payload is `.message(role: .user)` — judged by classification, never
    /// by `event.turn?.prompt` or raw hook fields. Once per session (the
    /// `filterEvaluated` latch), and never for subagent threads, which
    /// inherit the parent's fate (`SessionSummary.filterHiddenIDs`).
    public static func startsFilterEvaluation(
        _ summary: SessionSummary,
        from current: SessionSummary?,
        event: AgentIngressEvent
    ) -> Bool {
        guard current?.filterEvaluated != true else { return false }
        guard case let .message(message)? = event.timelineItem?.payload,
              message.role == .user else { return false }
        return summary.lineage?.parentSessionID == nil && !summary.agent.isSubagent
    }
}

public extension AgentIngressEvent {
    /// A hidden (deleted / archived) session comes back only when the human
    /// engages it again: a new prompt or a (re)start — never on passive
    /// backfill or a straggling tool event.
    var resurrectsHiddenSession: Bool {
        if turn?.prompt != nil { return true }
        switch timelineItem?.payload {
        case let .message(message)?: return message.role == .user
        case let .sessionMarker(marker)?: return marker.kind == .sessionStarted
        default: return false
        }
    }
}

public actor InMemorySessionRepository: SessionRepository {
    private var sessions: [SessionID: SessionSummary] = [:]
    private var timeline: [SessionID: [TimelineItem]] = [:]
    private var eventIDs: Set<EventID> = []
    private var cursors: [String: RolloutCursor] = [:]
    private var ignoredSessionIDs: Set<SessionID> = []
    private var rolloutBaselineInitialized = false
    private var filterRules: [SessionFilterRule] = []
    private let sessionFilter: (any SessionFilterEvaluating)?

    public init(sessionFilter: (any SessionFilterEvaluating)? = nil) {
        self.sessionFilter = sessionFilter
    }

    @discardableResult
    public func apply(_ event: AgentIngressEvent) async throws -> Bool {
        // Dedupe first: a replayed event must never un-ignore a session.
        guard !eventIDs.contains(event.eventID) else { return false }
        if event.disposition == .discard {
            // Delete + tombstone, then report success so the event is
            // published and every mirror runs the same deletion.
            ignoredSessionIDs.insert(event.sessionID)
            sessions.removeValue(forKey: event.sessionID)
            timeline.removeValue(forKey: event.sessionID)
            eventIDs.insert(event.eventID)
            return true
        }
        if ignoredSessionIDs.contains(event.sessionID) {
            guard event.resurrectsHiddenSession else { return false }
            ignoredSessionIDs.remove(event.sessionID)
        }
        eventIDs.insert(event.eventID)

        let current = sessions[event.sessionID]
        var summary = SessionReduction.summary(applying: event, to: current)
        if SessionReduction.startsFilterEvaluation(summary, from: current, event: event) {
            // Latch first — even without an evaluator installed — so every
            // mirror converges; the parked verdict frame must carry it too.
            summary = summary.withFilterEvaluated(true)
            if let sessionFilter, sessionFilter.shouldHide(summary: summary, event: event) {
                summary = summary.withHiddenByFilter(true)
            }
        }
        sessions[event.sessionID] = summary
        if let item = event.timelineItem {
            var items = timeline[event.sessionID, default: []]
            if let existingIndex = items.firstIndex(where: { $0.id == item.id }) {
                if item.occurredAt >= items[existingIndex].occurredAt {
                    items[existingIndex] = item
                }
            } else {
                items.append(item)
            }
            items.sort { lhs, rhs in
                if lhs.occurredAt == rhs.occurredAt {
                    return lhs.id.rawValue < rhs.id.rawValue
                }
                return lhs.occurredAt < rhs.occurredAt
            }
            timeline[event.sessionID] = items
        }
        return true
    }

    public func listSessions(limit: Int) async throws -> [SessionSummary] {
        Array(
            sessions.values
                .sorted { $0.lastActivityAt > $1.lastActivityAt }
                .prefix(max(0, min(limit, 10_000)))
        )
    }

    public func sessionSummary(id: SessionID) async throws -> SessionSummary? {
        sessions[id]
    }

    public func sessionDetail(
        id: SessionID,
        cursor: PaginationCursor?,
        limit: Int
    ) async throws -> SessionDetail? {
        guard let summary = sessions[id] else { return nil }
        let offset = max(0, Int(cursor?.value ?? "0") ?? 0)
        let pageSize = max(1, min(limit, 500))
        let items = timeline[id, default: []]
        let page = Array(items.dropFirst(offset).prefix(pageSize))
        let nextOffset = offset + page.count
        let nextCursor = nextOffset < items.count
            ? PaginationCursor(value: String(nextOffset))
            : nil
        return SessionDetail(
            summary: summary,
            turns: sortedTurns(id),
            timeline: page,
            nextCursor: nextCursor
        )
    }

    private func sortedTurns(_ id: SessionID) -> [TurnSummary] {
        TurnProjection.turns(from: timeline[id, default: []], sessionID: id)
    }

    public func currentTurnID(sessionID: SessionID) async throws -> TurnID? {
        TurnProjection.currentTurnID(in: timeline[sessionID, default: []])
    }

    public func replaceSession(_ detail: SessionDetail) async throws {
        let id = detail.summary.id
        // The authoritative source brought the session back; a local
        // tombstone must not swallow its future events.
        ignoredSessionIDs.remove(id)
        sessions[id] = detail.summary
        timeline[id] = detail.timeline
    }

    @discardableResult
    public func pruneSessions(keeping ids: Set<SessionID>) async throws -> Int {
        let pruned = sessions.keys.filter { !ids.contains($0) }
        for id in pruned {
            sessions.removeValue(forKey: id)
            timeline.removeValue(forKey: id)
        }
        return pruned.count
    }

    public func deleteAllSessions() async throws -> Int {
        let count = sessions.count
        ignoredSessionIDs.formUnion(sessions.keys)
        sessions.removeAll()
        timeline.removeAll()
        eventIDs.removeAll()
        return count
    }

    @discardableResult
    public func deleteSession(id: SessionID) async throws -> [SessionID] {
        var doomed: Set<SessionID> = [id]
        var frontier: Set<SessionID> = [id]
        while !frontier.isEmpty {
            frontier = Set(sessions.values
                .filter { summary in
                    guard let parent = summary.lineage?.parentSessionID else { return false }
                    return frontier.contains(parent) && !doomed.contains(summary.id)
                }
                .map(\.id))
            doomed.formUnion(frontier)
        }
        let existed = doomed.filter { sessions[$0] != nil }
        for member in doomed {
            ignoredSessionIDs.insert(member)
            sessions.removeValue(forKey: member)
            timeline.removeValue(forKey: member)
        }
        return existed.sorted { $0.rawValue < $1.rawValue }
    }

    public func sessionIndex(limit: Int) async throws -> [SessionIndexEntry] {
        try await listSessions(limit: limit).map { summary in
            let items = timeline[summary.id, default: []]
            return SessionIndexEntry(
                summary: summary,
                timelineItemCount: items.count,
                lastItemAt: items.map(\.occurredAt).max()
            )
        }
    }

    public func updateSummary(_ summary: SessionSummary) async throws {
        guard sessions[summary.id] != nil else { return }
        sessions[summary.id] = summary
    }

    public func mergeSession(_ detail: SessionDetail) async throws {
        let id = detail.summary.id
        ignoredSessionIDs.remove(id)
        sessions[id] = detail.summary
        var items = timeline[id, default: []]
        for item in detail.timeline {
            if let existingIndex = items.firstIndex(where: { $0.id == item.id }) {
                if item.occurredAt >= items[existingIndex].occurredAt {
                    items[existingIndex] = item
                }
            } else {
                items.append(item)
            }
        }
        items.sort { lhs, rhs in
            if lhs.occurredAt == rhs.occurredAt {
                return lhs.id.rawValue < rhs.id.rawValue
            }
            return lhs.occurredAt < rhs.occurredAt
        }
        timeline[id] = items
    }

    public func timelineSince(
        id: SessionID,
        since: Date,
        cursor: PaginationCursor?,
        limit: Int
    ) async throws -> SessionDetail? {
        guard let summary = sessions[id] else { return nil }
        let offset = max(0, Int(cursor?.value ?? "0") ?? 0)
        let pageSize = max(1, min(limit, 500))
        let items = timeline[id, default: []].filter { $0.occurredAt >= since }
        let page = Array(items.dropFirst(offset).prefix(pageSize))
        let nextOffset = offset + page.count
        return SessionDetail(
            summary: summary,
            turns: sortedTurns(id),
            timeline: page,
            nextCursor: nextOffset < items.count ? PaginationCursor(value: String(nextOffset)) : nil
        )
    }

    public func rolloutCursor(sessionID: SessionID) async throws -> RolloutCursor? {
        cursors.values
            .filter { $0.sessionID == sessionID }
            .max { $0.updatedAt < $1.updatedAt }
    }

    public func resetSession(id: SessionID) async throws -> Bool {
        timeline.removeValue(forKey: id)
        cursors = cursors.filter { $0.value.sessionID != id }
        return sessions.removeValue(forKey: id) != nil
    }

    public func markSessionIgnored(_ sessionID: SessionID) async throws {
        ignoredSessionIDs.insert(sessionID)
    }

    public func isSessionIgnored(_ sessionID: SessionID) async throws -> Bool {
        ignoredSessionIDs.contains(sessionID)
    }

    public func markSessionReviewed(_ sessionID: SessionID) async throws {
        guard let summary = sessions[sessionID] else { return }
        sessions[sessionID] = summary.reviewed
    }

    public func markSessionHiddenInNotch(_ sessionID: SessionID) async throws {
        guard let summary = sessions[sessionID] else { return }
        sessions[sessionID] = summary.withHiddenInNotch(true)
    }

    public func setSessionFilterVerdict(_ sessionID: SessionID, hiddenByFilter: Bool, filterEvaluated: Bool) async throws {
        guard let summary = sessions[sessionID] else { return }
        sessions[sessionID] = summary.withHiddenByFilter(hiddenByFilter).withFilterEvaluated(filterEvaluated)
    }

    public func sessionFilterRules() async throws -> [SessionFilterRule] {
        filterRules
    }

    public func setSessionFilterRules(_ rules: [SessionFilterRule]) async throws {
        filterRules = rules
    }

    public func isRolloutBaselineInitialized() async throws -> Bool {
        rolloutBaselineInitialized
    }

    public func markRolloutBaselineInitialized() async throws {
        rolloutBaselineInitialized = true
    }

    public func rolloutCursor(path: String) async throws -> RolloutCursor? {
        cursors[path]
    }

    public func saveRolloutCursor(_ cursor: RolloutCursor) async throws {
        cursors[cursor.path] = cursor
    }
}
