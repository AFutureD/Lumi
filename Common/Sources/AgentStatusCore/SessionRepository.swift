import AgentStatusTransport
import Foundation

public typealias RolloutCursor = AgentStatusTransport.RolloutCursor

public protocol SessionRepository: Sendable {
    @discardableResult
    func apply(_ event: AgentIngressEvent) async throws -> Bool
    func listSessions(limit: Int) async throws -> [SessionSummary]
    func sessionDetail(id: SessionID, cursor: PaginationCursor?, limit: Int) async throws -> SessionDetail?
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
    /// and must not outlive it. Each member is tombstoned. Returns whether
    /// the root session existed.
    func deleteSession(id: SessionID) async throws -> Bool
    func deleteAllSessions() async throws -> Int
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
    /// The human opened the session: clear `SessionSummary.needsReview`.
    func markSessionReviewed(_ sessionID: SessionID) async throws
    /// The human archived the session from the Notch: set
    /// `SessionSummary.hiddenInNotch`. Only re-engaging the session (a new
    /// prompt or a restart) clears it, via `SessionReduction`.
    func markSessionHiddenInNotch(_ sessionID: SessionID) async throws
    func isRolloutBaselineInitialized() async throws -> Bool
    func markRolloutBaselineInitialized() async throws
}

public enum SessionReduction {
    public static func summary(
        applying event: AgentIngressEvent,
        to current: SessionSummary?
    ) -> SessionSummary {
        let advancesVisibleActivity = event.advancesVisibleActivity
        let shouldUpdateVisibleState = current == nil
            || (advancesVisibleActivity && event.occurredAt >= current!.updatedAt)
        let lifecycle = shouldUpdateVisibleState
            ? (event.lifecycle ?? current?.lifecycle ?? .starting)
            : (current?.lifecycle ?? .starting)
        let phase = shouldUpdateVisibleState
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
        let agent = if isIdentityOnly {
            event.agent
        } else if shouldUpdateVisibleState {
            if event.lineage == nil,
               event.agent == .codex,
               current?.agent == .codexSubagent {
                current!.agent
            } else {
                event.agent
            }
        } else {
            current?.agent ?? event.agent
        }
        let agentName = agent.rawValue
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        let title = if isIdentityOnly || shouldUpdateVisibleState {
            event.title ?? current?.title ?? "\(agentName) Session"
        } else {
            current?.title ?? "\(agentName) Session"
        }
        // The first turn-scoped event marks the session as used for good;
        // backfill may only move the mark earlier, never clear it.
        let turnAt: Date? = (event.turnID ?? event.turn?.id) != nil ? event.occurredAt : nil
        let firstTurnAt = [current?.firstTurnAt, turnAt].compactMap { $0 }.min()

        return SessionSummary(
            id: event.sessionID,
            agent: agent,
            title: title,
            workspace: shouldUpdateVisibleState
                ? (event.workspace ?? current?.workspace)
                : current?.workspace,
            lifecycle: lifecycle,
            phase: phase,
            startedAt: min(current?.startedAt ?? event.occurredAt, event.occurredAt),
            updatedAt: advancesVisibleActivity
                ? max(current?.updatedAt ?? event.occurredAt, event.occurredAt)
                : (current?.updatedAt ?? event.occurredAt),
            lastActivityAt: advancesVisibleActivity
                ? max(current?.lastActivityAt ?? event.occurredAt, event.occurredAt)
                : (current?.lastActivityAt ?? event.occurredAt),
            needsAttention: needsAttention,
            needsReview: needsReview,
            hiddenInNotch: hiddenInNotch,
            lineage: event.lineage ?? current?.lineage,
            firstTurnAt: firstTurnAt
        )
    }
}

/// Folds one ingress event into the Turn aggregate it belongs to. Works for
/// helpers that send an explicit `turn` and for bare events that only carry
/// `turnID` + a timeline item (phase, prompt, counters are derived).
public enum TurnReduction {
    public static func summary(
        applying event: AgentIngressEvent,
        to current: TurnSummary?
    ) -> TurnSummary? {
        guard let turnID = event.turnID ?? event.turn?.id else { return nil }
        var base = current ?? TurnSummary(
            id: turnID,
            sessionID: event.sessionID,
            phase: event.phase ?? .idle,
            startedAt: event.occurredAt
        )
        if let explicit = event.turn {
            base = base.merging(explicit)
        }

        var phase = event.turn?.phase ?? event.phase ?? base.phase
        var prompt = base.prompt
        var endedAt = base.endedAt
        var outcome = base.outcome
        var toolCalls = base.toolCallCount
        var subagents = base.subagentCount
        var lastAssistant = base.lastAssistantMessage

        if let payload = event.timelineItem?.payload {
            switch payload {
            case let .message(message):
                if message.role == .user, prompt == nil { prompt = message.text }
                if message.role == .assistant { lastAssistant = message.text }
            case let .tool(tool):
                if tool.status == .started { toolCalls += 1 }
            case let .subagent(subagent):
                if subagent.status == .started { subagents += 1 }
            case let .turnEnd(end):
                endedAt = endedAt ?? event.occurredAt
                outcome = outcome ?? end.outcome
                if let message = end.message { lastAssistant = message }
                phase = .idle
            case let .error(error):
                if outcome == nil, !error.recoverable {
                    outcome = .failed
                    endedAt = event.occurredAt
                }
            default:
                break
            }
        }
        // A closed turn never regresses to an in-flight phase from a late event.
        if outcome != nil, event.turn?.outcome == nil, event.timelineItem == nil {
            phase = base.phase
        }

        return TurnSummary(
            id: base.id,
            sessionID: base.sessionID,
            index: base.index,
            phase: phase,
            prompt: prompt,
            startedAt: min(base.startedAt, event.occurredAt),
            endedAt: endedAt,
            outcome: outcome,
            toolCallCount: toolCalls,
            subagentCount: subagents,
            lastAssistantMessage: lastAssistant
        )
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

private extension AgentIngressEvent {
    var advancesVisibleActivity: Bool {
        if workspace != nil || lifecycle != nil || phase != nil { return true }
        guard let payload = timelineItem?.payload else { return false }
        return switch payload {
        case .message, .reasoning, .tool, .plan, .subagent, .error, .sessionMarker, .turnEnd: true
        case .context, .modelConfiguration, .internalContext, .usageMetrics, .unknown: false
        }
    }
}

public actor InMemorySessionRepository: SessionRepository {
    private var sessions: [SessionID: SessionSummary] = [:]
    private var timeline: [SessionID: [TimelineItem]] = [:]
    private var turns: [SessionID: [TurnID: TurnSummary]] = [:]
    private var eventIDs: Set<EventID> = []
    private var cursors: [String: RolloutCursor] = [:]
    private var ignoredSessionIDs: Set<SessionID> = []
    private var rolloutBaselineInitialized = false

    public init() {}

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
            turns.removeValue(forKey: event.sessionID)
            eventIDs.insert(event.eventID)
            return true
        }
        if ignoredSessionIDs.contains(event.sessionID) {
            guard event.resurrectsHiddenSession else { return false }
            ignoredSessionIDs.remove(event.sessionID)
        }
        eventIDs.insert(event.eventID)

        sessions[event.sessionID] = SessionReduction.summary(
            applying: event,
            to: sessions[event.sessionID]
        )
        if let turnID = event.turnID ?? event.turn?.id,
           let turn = TurnReduction.summary(applying: event, to: turns[event.sessionID]?[turnID]) {
            turns[event.sessionID, default: [:]][turnID] = turn
        }
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
        (turns[id]?.values).map(Array.init)?.sorted {
            if $0.startedAt == $1.startedAt { return $0.id.rawValue < $1.id.rawValue }
            return $0.startedAt < $1.startedAt
        } ?? []
    }

    public func replaceSession(_ detail: SessionDetail) async throws {
        let id = detail.summary.id
        // The authoritative source brought the session back; a local
        // tombstone must not swallow its future events.
        ignoredSessionIDs.remove(id)
        sessions[id] = detail.summary
        timeline[id] = detail.timeline
        turns[id] = Dictionary(uniqueKeysWithValues: detail.turns.map { ($0.id, $0) })
    }

    @discardableResult
    public func pruneSessions(keeping ids: Set<SessionID>) async throws -> Int {
        let pruned = sessions.keys.filter { !ids.contains($0) }
        for id in pruned {
            sessions.removeValue(forKey: id)
            timeline.removeValue(forKey: id)
            turns.removeValue(forKey: id)
        }
        return pruned.count
    }

    public func deleteAllSessions() async throws -> Int {
        let count = sessions.count
        ignoredSessionIDs.formUnion(sessions.keys)
        sessions.removeAll()
        timeline.removeAll()
        turns.removeAll()
        eventIDs.removeAll()
        return count
    }

    public func deleteSession(id: SessionID) async throws -> Bool {
        let existed = sessions[id] != nil
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
        for member in doomed {
            ignoredSessionIDs.insert(member)
            sessions.removeValue(forKey: member)
            timeline.removeValue(forKey: member)
            turns.removeValue(forKey: member)
        }
        return existed
    }

    public func rolloutCursor(sessionID: SessionID) async throws -> RolloutCursor? {
        cursors.values
            .filter { $0.sessionID == sessionID }
            .max { $0.updatedAt < $1.updatedAt }
    }

    public func resetSession(id: SessionID) async throws -> Bool {
        timeline.removeValue(forKey: id)
        turns.removeValue(forKey: id)
        cursors = cursors.filter { $0.value.sessionID != id }
        return sessions.removeValue(forKey: id) != nil
    }

    public func markSessionIgnored(_ sessionID: SessionID) async throws {
        ignoredSessionIDs.insert(sessionID)
    }

    public func markSessionReviewed(_ sessionID: SessionID) async throws {
        guard let summary = sessions[sessionID] else { return }
        sessions[sessionID] = summary.reviewed
    }

    public func markSessionHiddenInNotch(_ sessionID: SessionID) async throws {
        guard let summary = sessions[sessionID] else { return }
        sessions[sessionID] = summary.withHiddenInNotch(true)
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
