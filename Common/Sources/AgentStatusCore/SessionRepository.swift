import AgentStatusTransport
import Foundation

public struct RolloutCursor: Codable, Hashable, Sendable {
    public let path: String
    public let byteOffset: UInt64
    public let fileSize: UInt64
    public let sessionID: SessionID?
    public let updatedAt: Date

    public init(
        path: String,
        byteOffset: UInt64,
        fileSize: UInt64,
        sessionID: SessionID? = nil,
        updatedAt: Date = Date()
    ) {
        self.path = path
        self.byteOffset = byteOffset
        self.fileSize = fileSize
        self.sessionID = sessionID
        self.updatedAt = updatedAt
    }
}

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

private extension AgentIngressEvent {
    var advancesVisibleActivity: Bool {
        if workspace != nil || lifecycle != nil || phase != nil { return true }
        guard let payload = timelineItem?.payload else { return false }
        return switch payload {
        case .message, .tool, .plan, .subagent, .error: true
        case .modelConfiguration, .internalContext, .usageMetrics, .unknown: false
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

    public init() {}

    @discardableResult
    public func apply(_ event: AgentIngressEvent) async throws -> Bool {
        guard !ignoredSessionIDs.contains(event.sessionID) else { return false }
        guard eventIDs.insert(event.eventID).inserted else { return false }

        sessions[event.sessionID] = SessionReduction.summary(
            applying: event,
            to: sessions[event.sessionID]
        )
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
        return SessionDetail(summary: summary, timeline: page, nextCursor: nextCursor)
    }

    public func replaceSnapshot(_ details: [SessionDetail]) async throws {
        sessions = Dictionary(uniqueKeysWithValues: details.map { ($0.summary.id, $0.summary) })
        timeline = Dictionary(uniqueKeysWithValues: details.map { ($0.summary.id, $0.timeline) })
    }

    public func deleteAllSessions() async throws -> Int {
        let count = sessions.count
        ignoredSessionIDs.formUnion(sessions.keys)
        sessions.removeAll()
        timeline.removeAll()
        eventIDs.removeAll()
        return count
    }

    public func deleteSession(id: SessionID) async throws -> Bool {
        ignoredSessionIDs.insert(id)
        timeline.removeValue(forKey: id)
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
            result.append(SessionDetail(summary: summary, timeline: timeline[summary.id, default: []]))
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
