import AgentStatusTransport
import Foundation

public typealias RolloutCursor = AgentStatusTransport.RolloutCursor

public protocol SessionRepository: Sendable {
    @discardableResult
    func apply(_ event: AgentIngressEvent) async throws -> Bool
    func listSessions(limit: Int) async throws -> [SessionSummary]
    func sessionDetail(id: SessionID, cursor: PaginationCursor?, limit: Int) async throws -> SessionDetail?
    func replaceSnapshot(_ details: [SessionDetail]) async throws
    func deleteSession(id: SessionID) async throws -> Bool
    func deleteAllSessions() async throws -> Int
    func rolloutCursor(path: String) async throws -> RolloutCursor?
    func saveRolloutCursor(_ cursor: RolloutCursor) async throws
    func markSessionIgnored(_ sessionID: SessionID) async throws
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
        let needsAttention = switch lifecycle {
        case .waitingForInput, .failed, .interrupted: true
        default: false
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
            lineage: event.lineage ?? current?.lineage
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
        if ignoredSessionIDs.contains(event.sessionID) {
            guard event.resurrectsHiddenSession else { return false }
            ignoredSessionIDs.remove(event.sessionID)
        }
        guard eventIDs.insert(event.eventID).inserted else { return false }

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

    public func replaceSnapshot(_ details: [SessionDetail]) async throws {
        sessions = Dictionary(uniqueKeysWithValues: details.map { ($0.summary.id, $0.summary) })
        timeline = Dictionary(uniqueKeysWithValues: details.map { ($0.summary.id, $0.timeline) })
        turns = Dictionary(uniqueKeysWithValues: details.map { detail in
            (detail.summary.id, Dictionary(uniqueKeysWithValues: detail.turns.map { ($0.id, $0) }))
        })
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
        ignoredSessionIDs.insert(id)
        timeline.removeValue(forKey: id)
        turns.removeValue(forKey: id)
        return sessions.removeValue(forKey: id) != nil
    }

    public func markSessionIgnored(_ sessionID: SessionID) async throws {
        ignoredSessionIDs.insert(sessionID)
    }

    public func isRolloutBaselineInitialized() async throws -> Bool {
        rolloutBaselineInitialized
    }

    public func markRolloutBaselineInitialized() async throws {
        rolloutBaselineInitialized = true
    }

    public func sessionDetails(limit: Int = 500) async throws -> [SessionDetail] {
        var result: [SessionDetail] = []
        for summary in try await listSessions(limit: limit) {
            result.append(SessionDetail(
                summary: summary,
                turns: sortedTurns(summary.id),
                timeline: timeline[summary.id, default: []]
            ))
        }
        return result
    }

    public func rolloutCursor(path: String) async throws -> RolloutCursor? {
        cursors[path]
    }

    public func saveRolloutCursor(_ cursor: RolloutCursor) async throws {
        cursors[cursor.path] = cursor
    }
}
