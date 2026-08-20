import AgentStatusCore
import AgentStatusTransport
import Combine
import Foundation

/// One line of the Notch's "Recent activity" block: a projected `TimelineRow`
/// reduced to what the 22pt row needs.
struct AgentStatusNookActivityRow: Identifiable, Equatable, Sendable {
    let id: String
    let tag: TimelineTag
    let label: String
    let text: String
    let occurredAt: Date
    let status: TimelineRowStatus
    let toolUseID: String?

    var level: TimelineAttentionLevel { tag.level }

    init(row: TimelineRow) {
        id = row.id
        tag = row.tag
        label = row.label
        status = row.status
        toolUseID = row.toolUseID
        text = row.text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? row.text
        occurredAt = row.occurredAt
    }
}

/// Everything the Notch renders for one Session (list row, turn cards, detail).
struct AgentStatusNookSession: Identifiable, Equatable, Sendable {
    let id: SessionID
    let title: String
    let agent: AgentKind
    let workspace: String?
    let lifecycle: SessionLifecycle
    let phase: TurnPhase
    let needsReview: Bool
    let currentUserMessage: String?
    let lastActivityAt: Date
    let startedAt: Date
    let parentID: SessionID?
    let depth: Int
    /// The newest turn (open or just closed).
    let currentTurn: TurnSummary?
    let model: String?
    let totalTokens: Int64?
    let contextFraction: Double?
    /// Newest last; capped by `AgentStatusNookSnapshot.recentRowLimit`.
    let recentRows: [AgentStatusNookActivityRow]

    var statusText: String {
        "\(SessionStatusTone.displayLifecycle(lifecycle: lifecycle, phase: phase).displayName) · \(phase.displayName)"
    }

    var statusTone: SessionStatusTone {
        SessionStatusTone.resolve(lifecycle: lifecycle, phase: phase, needsReview: needsReview)
    }

    var isChild: Bool { parentID != nil }

    /// Archive affordance and "Turn complete" state: the newest turn is closed
    /// or the session itself is no longer running a turn.
    var turnEnded: Bool {
        if let currentTurn { return !currentTurn.isOpen }
        return !lifecycle.isLive || (lifecycle == .waitingForInput && phase == .idle)
    }

    var lastAssistantMessage: String? {
        currentTurn?.lastAssistantMessage
    }

    /// Tool calls / subagents still open among the recent rows.
    var stillRunningCount: Int {
        var openTools: Set<String> = []
        var runningSubagents = 0
        for row in recentRows {
            switch row.tag {
            case .tool:
                if let id = row.toolUseID { openTools.insert(id) }
            case .result, .failed:
                if let id = row.toolUseID { openTools.remove(id) }
            case .subagent:
                if row.status == .started || row.status == .running { runningSubagents += 1 }
            default:
                break
            }
        }
        return openTools.count + runningSubagents
    }

    /// Elapsed for the current turn (or the session when no turn is known).
    func elapsedText(now: Date) -> String {
        let start = currentTurn?.startedAt ?? startedAt
        let end = currentTurn?.endedAt ?? (lifecycle.isLive ? now : lastActivityAt)
        return SessionElapsedFormatter.string(from: max(0, end.timeIntervalSince(start)))
    }

    var totalTokensText: String {
        guard let totalTokens else { return "—" }
        if totalTokens >= 1_000_000 {
            return totalTokens.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        }
        if totalTokens >= 10_000 {
            return totalTokens.formatted(.number.notation(.compactName).precision(.fractionLength(0)))
        }
        return totalTokens.formatted(.number.grouping(.automatic))
    }

    var contextText: String {
        guard let contextFraction else { return "—" }
        return "\(Int((contextFraction * 100).rounded()))%"
    }
}

/// One row of the session list: a parent session plus the subagents its
/// card renders as pills (empty for flat rows).
struct AgentStatusNookListItem: Identifiable, Equatable, Sendable {
    let session: AgentStatusNookSession
    var children: [AgentStatusNookSession]

    var id: SessionID { session.id }
}

/// What the expanded Notch is showing.
enum AgentStatusNookRoute: Equatable, Sendable {
    case list
    case detail(SessionID)
    case turnStarted(SessionID)
    case turnEnded(SessionID)
}

/// Turn boundary transitions detected between two snapshots.
struct AgentStatusNookTurnEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case started
        case ended
        case failed
    }

    let sessionID: SessionID
    let kind: Kind
    /// The L3 row that triggered it.
    let row: AgentStatusNookActivityRow
}

enum AgentStatusNookSnapshot {
    static let recentRowLimit = 8
    static let maximumSessionAge: TimeInterval = 7 * 86_400

    /// Notch-worthy sessions: not archived from the Notch, a known lifecycle,
    /// and active within the last seven days. A session crossing the age
    /// boundary drops out on the next data change, not the moment it turns
    /// seven days old.
    static func eligibleSummaries(from summaries: [SessionSummary], now: Date) -> [SessionSummary] {
        summaries.filter { summary in
            guard !summary.hiddenInNotch else { return false }
            guard summary.lastActivityAt > now.addingTimeInterval(-maximumSessionAge) else { return false }
            if case .unknown = summary.lifecycle { return false }
            return true
        }
    }

    /// Parents in the store's order (newest activity first), each followed
    /// by its children. Subagent rows are listed only while the parent's turn
    /// is running; once the turn ends they disappear.
    static func visibleSummaries(from summaries: [SessionSummary], now: Date) -> [SessionSummary] {
        let eligible = eligibleSummaries(from: summaries, now: now)
        let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        var ordered: [SessionSummary] = []
        var seen: Set<SessionID> = []
        let parents = eligible.filter { $0.lineage?.parentSessionID.flatMap { byID[$0] } == nil }
        for parent in parents {
            guard seen.insert(parent.id).inserted else { continue }
            ordered.append(parent)
            guard parent.statusTone == .blue else { continue }
            for child in eligible where child.lineage?.parentSessionID == parent.id {
                if seen.insert(child.id).inserted { ordered.append(child) }
            }
        }
        return ordered
    }

    /// The list renders parents; a parent whose turn is running with
    /// subagents becomes a card that carries them as pills. Children follow
    /// their parent in `sessions`; a child whose parent is not listed (the
    /// store promoted it to top level) gets a flat row of its own.
    static func listItems(from sessions: [AgentStatusNookSession]) -> [AgentStatusNookListItem] {
        var items: [AgentStatusNookListItem] = []
        for session in sessions {
            if let parentID = session.parentID, parentID == items.last?.session.id {
                items[items.count - 1].children.append(session)
            } else {
                items.append(AgentStatusNookListItem(session: session, children: []))
            }
        }
        return items
    }

    static func make(
        summaries: [SessionSummary],
        details: [SessionID: SessionDetail]
    ) -> [AgentStatusNookSession] {
        summaries.map { summary in
            let detail = details[summary.id]
            let turns = detail?.turns ?? []
            let currentTurn = turns.last(where: { $0.isOpen }) ?? turns.last
            let rows = detail.map { TimelineProjection.rows(from: $0.timeline) } ?? []
            let usage = detail?.timeline.reversed().compactMap { item -> UsageMetricsTimelinePayload? in
                guard case let .usageMetrics(payload) = item.payload else { return nil }
                return payload
            }.first
            let configuredWindow = detail?.timeline.reversed().compactMap { item -> ModelConfigurationTimelinePayload? in
                guard case let .modelConfiguration(payload) = item.payload else { return nil }
                return payload
            }.first
            let window = usage?.modelContextWindow ?? configuredWindow?.contextWindow
            let used = usage?.last ?? usage?.total
            let fraction: Double? = if let window, window > 0, let used {
                min(1, Double(used.totalTokens) / Double(window))
            } else {
                nil
            }
            let prompt = currentTurn?.prompt
                ?? detail.flatMap(currentTurnUserMessage(in:))
            return AgentStatusNookSession(
                id: summary.id,
                title: summary.title,
                agent: summary.agent,
                workspace: summary.workspace,
                lifecycle: summary.lifecycle,
                phase: summary.phase,
                needsReview: summary.needsReview,
                currentUserMessage: prompt.map(normalized),
                lastActivityAt: summary.lastActivityAt,
                startedAt: summary.startedAt,
                parentID: summary.lineage?.parentSessionID,
                depth: summary.lineage?.subagentDepth ?? (summary.lineage?.parentSessionID == nil ? 0 : 1),
                currentTurn: currentTurn,
                model: configuredWindow?.model,
                totalTokens: (usage?.total ?? usage?.last)?.totalTokens,
                contextFraction: fraction,
                recentRows: rows.suffix(recentRowLimit).map(AgentStatusNookActivityRow.init(row:))
            )
        }
    }

    static func currentTurnUserMessage(in detail: SessionDetail) -> String? {
        if let turn = detail.turns.last(where: { $0.isOpen }) ?? detail.turns.last, let prompt = turn.prompt {
            return normalized(prompt)
        }
        let newestFirst = detail.timeline.reversed()
        if let currentTurnID = newestFirst.compactMap(\.turnID).first,
           let message = newestFirst.first(where: {
               $0.turnID == currentTurnID && $0.payload.userMessage != nil
           })?.payload.userMessage {
            return normalized(message)
        }
        return newestFirst.compactMap(\.payload.userMessage).first.map(normalized)
    }

    private static func normalized(_ message: String) -> String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Only L3 rows (USER / TURN END / FAILED / ABORTED) may reach the Notch.
enum AgentStatusNookActivityDiff {
    static func turnEvents(
        previous: [AgentStatusNookSession],
        current: [AgentStatusNookSession]
    ) -> [AgentStatusNookTurnEvent] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let listedIDs = Set(current.map(\.id))
        var events: [AgentStatusNookTurnEvent] = []
        for session in current {
            // Subagents render as pills inside their parent's card; their turn
            // boundaries are the parent's internal progress, not notifications.
            // An orphan promoted to top level still notifies.
            if let parentID = session.parentID, listedIDs.contains(parentID) { continue }
            // A session whose rows appear in bulk — its detail cache just
            // loaded — is a backfill: diffing against the empty window would
            // replay old turn ends as fresh notifications.
            guard let old = previousByID[session.id], !old.recentRows.isEmpty else { continue }
            let seen = Set(old.recentRows.map(\.id))
            for row in session.recentRows where !seen.contains(row.id) && row.level == .l3 {
                switch row.tag {
                case .user:
                    events.append(.init(sessionID: session.id, kind: .started, row: row))
                case .turnEnd:
                    events.append(.init(sessionID: session.id, kind: .ended, row: row))
                case .failed, .aborted:
                    // A failed row carrying a toolUseID is one tool call going
                    // wrong mid-turn — routine, recoverable noise. Only
                    // turn-level failures and aborts notify.
                    guard row.toolUseID == nil else { break }
                    events.append(.init(sessionID: session.id, kind: .failed, row: row))
                default:
                    break
                }
            }
        }
        return events
    }
}

@MainActor
final class AgentStatusNookCompactModel: ObservableObject {
    @Published private(set) var statusTone: SessionStatusTone = .gray
    @Published private(set) var sessionCount = 0

    func update(statusTone: SessionStatusTone? = nil, sessionCount: Int? = nil) {
        if let statusTone, self.statusTone != statusTone {
            self.statusTone = statusTone
        }
        if let sessionCount, self.sessionCount != sessionCount {
            self.sessionCount = sessionCount
        }
    }
}

@MainActor
final class AgentStatusNookModel: ObservableObject {
    @Published private(set) var sessions: [AgentStatusNookSession] = []
    /// Parent sessions in the list — the footer text and the compact badge.
    @Published private(set) var listedSessionCount = 0
    @Published private(set) var daemonAvailable = false
    @Published var route: AgentStatusNookRoute = .list
    let compactModel = AgentStatusNookCompactModel()

    var onSnapshot: ((_ previous: [AgentStatusNookSession], _ current: [AgentStatusNookSession], _ initial: Bool) -> Void)?

    private weak var store: MacSessionStore?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private let refreshClock = ContinuousClock()
    private var nextRefreshAt: ContinuousClock.Instant?
    private var hasLoaded = false
    private var lastObservedRevision: UInt64 = 0
    private var cardDismissTask: Task<Void, Never>?

    init(store: MacSessionStore) {
        self.store = store
        lastObservedRevision = store.dataRevision
        store.observe { [weak self, weak store] in
            guard let self, let store else { return }
            let daemonAvailable = store.health != nil
            if self.daemonAvailable != daemonAvailable {
                self.daemonAvailable = daemonAvailable
            }
            guard store.dataRevision != self.lastObservedRevision || !self.hasLoaded else { return }
            self.lastObservedRevision = store.dataRevision
            self.reload(from: store, immediate: self.requiresImmediateRefresh(from: store))
        }
    }

    func start() {
        guard let store else { return }
        daemonAvailable = store.health != nil
        reload(from: store, immediate: true)
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        cardDismissTask?.cancel()
    }

    func session(_ id: SessionID) -> AgentStatusNookSession? {
        sessions.first { $0.id == id }
    }

    // MARK: - Navigation

    func showList() {
        cardDismissTask?.cancel()
        route = .list
    }

    func showDetail(_ id: SessionID) {
        cardDismissTask?.cancel()
        route = .detail(id)
        store?.markSessionReviewed(id)
    }

    /// Turn cards replace the list briefly and fall back to it.
    func showTurnCard(_ route: AgentStatusNookRoute, dwell: Duration = .seconds(6)) {
        if case .detail = self.route { return }   // never interrupt an open detail
        cardDismissTask?.cancel()
        self.route = route
        cardDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: dwell)
            guard let self, !Task.isCancelled, self.route == route else { return }
            self.route = .list
        }
    }

    // MARK: - Actions

    /// Archive is Notch-only: the session is hidden here but stays in the
    /// Mac window and on iOS. A new prompt or a restart brings it back.
    func archive(_ id: SessionID) {
        store?.markSessionHiddenInNotch(id)
        if route == .detail(id) { route = .list }
    }

    // MARK: - Loading

    private func reload(from store: MacSessionStore, immediate: Bool = false) {
        let summaries = AgentStatusNookSnapshot.visibleSummaries(from: store.sessions, now: Date())
        let nextListedSessionCount = Self.parentCount(of: summaries)
        if listedSessionCount != nextListedSessionCount {
            listedSessionCount = nextListedSessionCount
            compactModel.update(sessionCount: nextListedSessionCount)
        }
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let now = refreshClock.now
        let deadline = immediate ? now : (nextRefreshAt ?? now)
        refreshTask = Task { [weak self, weak store] in
            guard let self, let store else { return }
            let delay = self.refreshClock.now.duration(to: deadline)
            if delay > .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            var details: [SessionID: SessionDetail] = [:]
            if let loaded = try? await store.cachedSessionDetails(ids: summaries.map(\.id)) {
                details = Dictionary(uniqueKeysWithValues: loaded.map { ($0.summary.id, $0) })
            }
            guard !Task.isCancelled, generation == self.refreshGeneration else { return }
            let next = AgentStatusNookSnapshot.make(summaries: summaries, details: details)
            let previous = self.sessions
            let initial = !self.hasLoaded
            if self.sessions != next { self.sessions = next }
            self.compactModel.update(statusTone: next.first?.statusTone ?? .gray)
            self.hasLoaded = true
            if case let .detail(id) = self.route {
                if let shown = next.first(where: { $0.id == id }) {
                    // The detail is on screen, so a turn that just ended is
                    // being looked at right now.
                    if shown.needsReview { self.store?.markSessionReviewed(id) }
                } else {
                    self.route = .list
                }
            }
            if initial || previous != next {
                self.onSnapshot?(previous, next, initial)
            }
            if generation == self.refreshGeneration {
                self.nextRefreshAt = self.refreshClock.now.advanced(by: .seconds(2))
                self.refreshTask = nil
            }
        }
    }

    /// Top-level rows among the visible summaries — a child only counts as
    /// nested while its parent is in the list.
    private static func parentCount(of summaries: [SessionSummary]) -> Int {
        let ids = Set(summaries.map(\.id))
        return summaries.count { summary in
            guard let parentID = summary.lineage?.parentSessionID else { return true }
            return !ids.contains(parentID)
        }
    }

    private func requiresImmediateRefresh(from store: MacSessionStore) -> Bool {
        let summaries = AgentStatusNookSnapshot.visibleSummaries(from: store.sessions, now: Date())
        guard Self.parentCount(of: summaries) == listedSessionCount, summaries.count == sessions.count else { return true }
        let currentByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        return summaries.contains { summary in
            guard let current = currentByID[summary.id] else { return true }
            return current.title != summary.title
                || current.lifecycle != summary.lifecycle
                || current.statusTone != summary.statusTone
                || (current.phase == .waitingForApproval) != (summary.phase == .waitingForApproval)
        }
    }
}

private extension TimelinePayload {
    var userMessage: String? {
        guard case let .message(message) = self, message.role == .user else { return nil }
        return message.text
    }
}
