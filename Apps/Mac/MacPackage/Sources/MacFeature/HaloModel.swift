import Core
import Transport
import Combine
import Logging
import Foundation

private let log = Logger(label: "ui")

/// One line of the Notch's "Recent activity" block: a projected `TimelineRow`
/// reduced to what the 22pt row needs.
struct HaloActivityRow: Identifiable, Equatable, Sendable {
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
struct HaloSession: Identifiable, Equatable, Sendable {
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
    /// The top-level session this one folds under as a subagent (any depth,
    /// `SessionHierarchy`); nil for a top-level row.
    let groupID: SessionID?
    let depth: Int
    /// The newest turn (open or just closed).
    let currentTurn: TurnSummary?
    let model: String?
    let totalTokens: Int64?
    let contextFraction: Double?
    /// Newest last; capped by `HaloSnapshot.recentRowLimit`.
    let recentRows: [HaloActivityRow]
    /// Whether this snapshot was built from the session's whole detail
    /// (`HaloSnapshot.detailIDs`) or from its summary alone. A summary-only
    /// session has no rows and no current turn; when it later enters the
    /// working set its rows arrive all at once, and the diff must not read
    /// that backfill as fresh activity.
    let detailLoaded: Bool

    var statusText: String {
        "\(SessionStatusTone.displayLifecycle(lifecycle: lifecycle, phase: phase).displayName) · \(phase.displayName)"
    }

    var statusTone: SessionStatusTone {
        SessionStatusTone.resolve(lifecycle: lifecycle, phase: phase, needsReview: needsReview)
    }

    var isChild: Bool { groupID != nil }

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

/// One row of the session list: a parent session plus its subagent group
/// (empty for flat rows). Children are ordered running → waiting → failed →
/// done, newest first inside a bucket — the order of the count strip's
/// stacked dots and of the expanded pills.
struct HaloListItem: Identifiable, Equatable, Sendable {
    let session: HaloSession
    var children: [HaloSession]

    var id: SessionID { session.id }

    var subagentTones: [SessionStatusTone] { children.map(\.statusTone) }

    /// `3 subagents · 2 running · 1 done` — shared wording with iOS.
    var subagentSummary: String {
        SubagentGroupSummary.label(tones: subagentTones)
    }
}

/// Which rows show their subagent pills. The default follows the parent's
/// lifecycle — Running (blue tier) expanded, everything else collapsed — and
/// a row the user toggled keeps that choice until its tier changes, at which
/// point it falls back to the default again.
struct HaloSubagentDisclosure: Equatable, Sendable {
    private struct Override: Equatable, Sendable {
        let expanded: Bool
        /// The parent's tone when the user toggled; a different tone now
        /// means the lifecycle moved on and the override is spent.
        let tone: SessionStatusTone
    }

    private var overrides: [SessionID: Override] = [:]

    static func defaultExpanded(for tone: SessionStatusTone) -> Bool {
        tone == .blue
    }

    func isExpanded(_ item: HaloListItem) -> Bool {
        isExpanded(id: item.id, tone: item.session.statusTone)
    }

    func isExpanded(id: SessionID, tone: SessionStatusTone) -> Bool {
        if let override = overrides[id], override.tone == tone {
            return override.expanded
        }
        return Self.defaultExpanded(for: tone)
    }

    mutating func toggle(id: SessionID, tone: SessionStatusTone) {
        overrides[id] = Override(expanded: !isExpanded(id: id, tone: tone), tone: tone)
    }

    /// Drops overrides for rows that left the list or whose tier changed.
    mutating func prune(keeping items: [HaloListItem]) {
        let tones = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.session.statusTone) })
        overrides = overrides.filter { id, override in tones[id] == override.tone }
    }
}

/// What the expanded Notch is showing.
enum HaloRoute: Equatable, Sendable {
    case list
    case detail(SessionID)
    case turnStarted(SessionID)
    case turnEnded(SessionID)

    /// The session the route is about, if any.
    var sessionID: SessionID? {
        switch self {
        case .list: nil
        case let .detail(id), let .turnStarted(id), let .turnEnded(id): id
        }
    }
}

/// Turn boundary transitions detected between two snapshots.
struct HaloTurnEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case started
        case ended
        case failed
    }

    let sessionID: SessionID
    let kind: Kind
    /// The L3 row that triggered it.
    let row: HaloActivityRow
}

enum HaloSnapshot {
    static let recentRowLimit = 8
    static let maximumSessionAge: TimeInterval = 7 * 86_400
    /// How many whole session details one Notch pass may hold at once.
    static let detailLimit = 6
    /// A finished session stays in the working set this long after its last
    /// activity, so the turn end that finished it still produces its card.
    static let recentDetailWindow: TimeInterval = 5 * 60

    /// The sessions whose whole detail this pass reads. Two groups are
    /// required whatever their number: the routed session (a turn card
    /// reads its `currentTurn` for the whole dwell) and every top-level
    /// session that stopped working within `recentDetailWindow` and whose
    /// stopped state has not yet been seen with its rows — the turn end or
    /// failure that stopped it is still to be noticed, and the diff can
    /// only notice it from rows. Once such a session is `settled` (its
    /// stopped state was in the previous snapshot with rows) it needs no
    /// detail. Working (blue) and waiting (orange) top-level sessions then
    /// fill the remaining slots up to `detailLimit`, newest first, for the
    /// activity line under their row. Every other listed session renders
    /// from its summary alone. Subagents of a listed parent never need a
    /// detail: their pill reads the summary and they never notify.
    static func detailIDs(
        summaries: [SessionSummary],
        route: HaloRoute,
        now: Date,
        settled: Set<SessionID> = []
    ) -> [SessionID] {
        let byID = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let topLevel = summaries
            .filter { SessionHierarchy.rootID(of: $0, in: byID) == $0.id }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        let cutoff = now.addingTimeInterval(-recentDetailWindow)
        var required: [SessionID] = []
        var seen: Set<SessionID> = []
        func claim(_ id: SessionID, into list: inout [SessionID]) {
            if seen.insert(id).inserted { list.append(id) }
        }
        if let routed = route.sessionID, byID[routed] != nil { claim(routed, into: &required) }
        for summary in topLevel
        where !summary.isWorkingInNotch && summary.lastActivityAt > cutoff && !settled.contains(summary.id) {
            claim(summary.id, into: &required)
        }
        var working: [SessionID] = []
        for summary in topLevel where summary.isWorkingInNotch {
            claim(summary.id, into: &working)
        }
        return required + working.prefix(max(0, detailLimit - required.count))
    }

    /// Sessions whose stopped state the previous snapshot already showed
    /// with rows: their turn end or failure has been noticed, so they no
    /// longer need a detail once they leave the working set.
    static func settledIDs(in previous: [HaloSession]) -> Set<SessionID> {
        Set(previous.filter { $0.detailLoaded && !$0.isWorkingInNotch }.map(\.id))
    }

    /// Sessions active within the last seven days. A session crossing the
    /// age boundary drops out on the next data change, not the moment it
    /// turns seven days old.
    static func recentSummaries(from summaries: [SessionSummary], now: Date) -> [SessionSummary] {
        summaries.filter { $0.lastActivityAt > now.addingTimeInterval(-maximumSessionAge) }
    }

    /// Parents in the store's order (newest activity first), each followed
    /// by its recent subagents — every descendant, already in strip order
    /// (`SessionHierarchy`, the same grouping as the iPhone list). Children
    /// stay with their parent through every lifecycle: the list folds them
    /// into a count strip, so a finished session still shows how its
    /// subagents ended. Archiving follows the same grouping: the parent's
    /// `hiddenInNotch` flag hides the whole group — descendants at any
    /// depth leave with it rather than being promoted to top level, and
    /// they all return together when a new request clears the parent's flag.
    static func visibleSummaries(from summaries: [SessionSummary], now: Date) -> [SessionSummary] {
        SessionHierarchy.groups(recentSummaries(from: summaries, now: now))
            .filter { !$0.parent.hiddenInNotch }
            .flatMap { [$0.parent] + $0.descendants }
    }

    /// The list renders top-level sessions; one with subagents carries them
    /// as a collapsible group under its title. Subagents follow their group's
    /// session in `sessions` (running → waiting → failed → done); a child
    /// whose parent is not listed (the store promoted it to top level) gets
    /// a flat row of its own.
    static func listItems(from sessions: [HaloSession]) -> [HaloListItem] {
        var items: [HaloListItem] = []
        for session in sessions {
            if let groupID = session.groupID, groupID == items.last?.session.id {
                items[items.count - 1].children.append(session)
            } else {
                items.append(HaloListItem(session: session, children: []))
            }
        }
        for index in items.indices where items[index].children.count > 1 {
            items[index].children.sort { lhs, rhs in
                SubagentGroupSummary.precedes(
                    (lhs.statusTone, lhs.lastActivityAt),
                    (rhs.statusTone, rhs.lastActivityAt)
                )
            }
        }
        return items
    }

    /// One `HaloSession` per summary. A summary with a detail carries its
    /// recent rows, current turn and metrics; one without renders from the
    /// summary alone, its model coming from the store's stamps.
    static func make(
        summaries: [SessionSummary],
        details: [SessionID: SessionDetail],
        modelStamps: [SessionID: SessionModelStamp] = [:]
    ) -> [HaloSession] {
        let byID = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return summaries.map { summary in
            let rootID = SessionHierarchy.rootID(of: summary, in: byID)
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
            return HaloSession(
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
                groupID: rootID == summary.id ? nil : rootID,
                depth: summary.lineage?.subagentDepth ?? (summary.lineage?.parentSessionID == nil ? 0 : 1),
                currentTurn: currentTurn,
                model: configuredWindow?.model ?? modelStamps[summary.id]?.model,
                totalTokens: (usage?.total ?? usage?.last)?.totalTokens,
                contextFraction: fraction,
                recentRows: rows.suffix(recentRowLimit).map(HaloActivityRow.init(row:)),
                detailLoaded: detail != nil
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

extension SessionSummary {
    /// Working (blue) or waiting for a human (orange): the row carries an
    /// activity line, so the session belongs in the Notch's working set.
    var isWorkingInNotch: Bool {
        statusTone == .blue || statusTone == .orange
    }
}

extension HaloSession {
    var isWorkingInNotch: Bool {
        statusTone == .blue || statusTone == .orange
    }
}

/// Only L3 rows (USER / TURN END / FAILED / ABORTED) may reach the Notch.
enum HaloActivityDiff {
    static func turnEvents(
        previous: [HaloSession],
        current: [HaloSession]
    ) -> [HaloTurnEvent] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let listedIDs = Set(current.map(\.id))
        var events: [HaloTurnEvent] = []
        for session in current {
            // Subagents render inside their group's count strip; their turn
            // boundaries are the parent's internal progress, not notifications.
            // An orphan promoted to top level still notifies.
            if let groupID = session.groupID, listedIDs.contains(groupID) { continue }
            guard let old = previousByID[session.id] else { continue }
            let seen = Set(old.recentRows.map(\.id))
            for row in session.recentRows where !seen.contains(row.id) && row.level == .l3 {
                // A session entering the working set arrives with its whole
                // recent window at once. Rows no newer than the last activity
                // its summary already reported are that backfill, not news;
                // a prompt and turn end that landed since still notify.
                if !old.detailLoaded, row.occurredAt <= old.lastActivityAt { continue }
                switch row.tag {
                case .user:
                    events.append(.init(sessionID: session.id, kind: .started, row: row))
                case .turnEnd:
                    events.append(.init(sessionID: session.id, kind: .ended, row: row))
                case .turnFailed, .aborted:
                    // A failed tool call (`.failed`, Exec lane) is routine,
                    // recoverable mid-turn noise; only turn-level failures
                    // and aborts notify.
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
final class HaloCompactModel: ObservableObject {
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
final class HaloModel: ObservableObject {
    @Published private(set) var sessions: [HaloSession] = []
    /// Parent sessions in the list — the footer text and the compact badge.
    @Published private(set) var listedSessionCount = 0
    @Published private(set) var daemonAvailable = false
    @Published var route: HaloRoute = .list
    /// Per-row subagent group disclosure (lifecycle default + user toggles).
    @Published private(set) var subagentDisclosure = HaloSubagentDisclosure()
    let compactModel = HaloCompactModel()

    var onSnapshot: ((_ previous: [HaloSession], _ current: [HaloSession], _ initial: Bool) -> Void)?

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

    func session(_ id: SessionID) -> HaloSession? {
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
        // An idle, already reviewed session renders from its summary alone:
        // no rows, no token or context figures. The route claims its detail
        // on the next pass, and nothing else would start one (clearing a
        // review flag that is already clear changes no data), so start it.
        if let store, session(id)?.detailLoaded != true {
            reload(from: store, immediate: true)
        }
    }

    /// Turn cards replace the list briefly and fall back to it.
    func showTurnCard(_ route: HaloRoute, dwell: Duration = .seconds(6)) {
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

    /// The count strip was clicked: flip that row's subagent group. The
    /// choice sticks until the row's lifecycle tier changes.
    func toggleSubagents(of item: HaloListItem) {
        subagentDisclosure.toggle(id: item.id, tone: item.session.statusTone)
    }

    /// Archive is Notch-only: the session is hidden here but stays in the
    /// Mac window and on iOS. A new prompt or a restart brings it back.
    func archive(_ id: SessionID) {
        store?.markSessionHiddenInNotch(id)
        if route == .detail(id) { route = .list }
    }

    // MARK: - Loading

    private func reload(from store: MacSessionStore, immediate: Bool = false) {
        let summaries = HaloSnapshot.visibleSummaries(from: store.sessions, now: Date())
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
            let wanted = HaloSnapshot.detailIDs(
                summaries: summaries,
                route: self.route,
                now: Date(),
                settled: HaloSnapshot.settledIDs(in: self.sessions)
            )
            var details: [SessionID: SessionDetail] = [:]
            do {
                let loaded = try await store.cachedSessionDetails(ids: wanted)
                details = Dictionary(loaded.map { ($0.summary.id, $0) }, uniquingKeysWith: { first, _ in first })
            } catch {
                // The list still renders from summaries; the rows and cards
                // of these sessions wait for the next pass.
                log.error("notch_details_unavailable", metadata: .fields([
                    "wanted": wanted.count,
                    "error": error,
                ]))
            }
            guard !Task.isCancelled, generation == self.refreshGeneration else { return }
            let next = HaloSnapshot.make(summaries: summaries, details: details, modelStamps: store.modelStamps)
            let previous = self.sessions
            let initial = !self.hasLoaded
            if self.sessions != next { self.sessions = next }
            var disclosure = self.subagentDisclosure
            disclosure.prune(keeping: HaloSnapshot.listItems(from: next))
            if disclosure != self.subagentDisclosure { self.subagentDisclosure = disclosure }
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
        SessionHierarchy.groups(summaries).count
    }

    private func requiresImmediateRefresh(from store: MacSessionStore) -> Bool {
        let summaries = HaloSnapshot.visibleSummaries(from: store.sessions, now: Date())
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
