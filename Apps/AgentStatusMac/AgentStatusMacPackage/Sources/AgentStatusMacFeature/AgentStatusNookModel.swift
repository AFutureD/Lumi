import AgentStatusCore
import AgentStatusTransport
import Combine
import Foundation

struct AgentStatusNookSession: Identifiable, Equatable, Sendable {
    let id: SessionID
    let title: String
    let lifecycle: SessionLifecycle
    let phase: TurnPhase
    let currentUserMessage: String?

    var statusText: String {
        "\(lifecycle.displayName) · \(phase.displayName)"
    }

    var statusTone: SessionStatusTone {
        SessionStatusTone.resolve(lifecycle: lifecycle, phase: phase)
    }
}

enum AgentStatusNookSnapshot {
    static let maximumVisibleSessions = 4

    static func eligibleSummaries(from summaries: [SessionSummary]) -> [SessionSummary] {
        summaries.filter { summary in
            switch summary.lifecycle {
            case .starting, .running, .waitingForInput, .failed, .interrupted:
                true
            case .completed, .unknown:
                false
            }
        }
    }

    static func visibleSummaries(from summaries: [SessionSummary]) -> [SessionSummary] {
        Array(eligibleSummaries(from: summaries).prefix(maximumVisibleSessions))
    }

    static func make(
        summaries: [SessionSummary],
        currentUserMessages: [SessionID: String]
    ) -> [AgentStatusNookSession] {
        return summaries.map { summary in
            AgentStatusNookSession(
                id: summary.id,
                title: summary.title,
                lifecycle: summary.lifecycle,
                phase: summary.phase,
                currentUserMessage: currentUserMessages[summary.id].map(normalized)
            )
        }
    }

    static func currentTurnUserMessage(in detail: SessionDetail) -> String? {
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

    static func makeActivitySessions(
        summaries: [SessionSummary],
        displayed: [AgentStatusNookSession],
        previous: [AgentStatusNookSession]
    ) -> [AgentStatusNookSession] {
        let displayedByID = Dictionary(uniqueKeysWithValues: displayed.map { ($0.id, $0) })
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        return summaries.map { summary in
            AgentStatusNookSession(
                id: summary.id,
                title: summary.title,
                lifecycle: summary.lifecycle,
                phase: summary.phase,
                currentUserMessage: displayedByID[summary.id]?.currentUserMessage
                    ?? previousByID[summary.id]?.currentUserMessage
            )
        }
    }
}

enum AgentStatusNookActivityDiff {
    static func changedSessions(
        previous: [AgentStatusNookSession],
        current: [AgentStatusNookSession]
    ) -> [AgentStatusNookSession] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        return current.filter { session in
            if case .unknown = session.lifecycle { return false }
            guard let old = previousByID[session.id] else { return false }
            return old.currentUserMessage != session.currentUserMessage
                || terminalLifecycleChanged(from: old.lifecycle, to: session.lifecycle)
                || approvalPhaseChanged(from: old.phase, to: session.phase)
        }
    }

    private static func terminalLifecycleChanged(
        from old: SessionLifecycle?,
        to new: SessionLifecycle
    ) -> Bool {
        guard old != new else { return false }
        return switch new {
        case .completed, .failed, .interrupted:
            true
        case .starting, .running, .waitingForInput, .unknown:
            false
        }
    }

    private static func approvalPhaseChanged(from old: TurnPhase?, to new: TurnPhase) -> Bool {
        old != new && (old == .waitingForApproval || new == .waitingForApproval)
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
    @Published private(set) var daemonAvailable = false
    let compactModel = AgentStatusNookCompactModel()

    var onSnapshot: ((_ previous: [AgentStatusNookSession], _ current: [AgentStatusNookSession], _ initial: Bool) -> Void)?

    private weak var store: MacSessionStore?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private let refreshClock = ContinuousClock()
    private var nextRefreshAt: ContinuousClock.Instant?
    private var hasLoaded = false
    private var lastObservedRevision: UInt64 = 0
    private var totalSessionCount = 0
    private var activitySessions: [AgentStatusNookSession] = []

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
    }

    private func reload(from store: MacSessionStore, immediate: Bool = false) {
        let allSummaries = store.sessions
        let summaries = AgentStatusNookSnapshot.visibleSummaries(from: allSummaries)
        let nextTotalSessionCount = AgentStatusNookSnapshot.eligibleSummaries(from: allSummaries).count
        if totalSessionCount != nextTotalSessionCount {
            totalSessionCount = nextTotalSessionCount
            compactModel.update(sessionCount: nextTotalSessionCount)
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
            do {
                let currentUserMessages = try await store.cachedCurrentTurnUserMessages(
                    ids: summaries.map(\.id)
                )
                guard !Task.isCancelled, generation == self.refreshGeneration else { return }
                let next = AgentStatusNookSnapshot.make(
                    summaries: summaries,
                    currentUserMessages: currentUserMessages
                )
                let previous = self.activitySessions
                let initial = !self.hasLoaded
                if self.sessions != next { self.sessions = next }
                self.compactModel.update(statusTone: next.first?.statusTone ?? .gray)
                let activitySessions = AgentStatusNookSnapshot.makeActivitySessions(
                    summaries: allSummaries,
                    displayed: next,
                    previous: previous
                )
                self.activitySessions = activitySessions
                self.hasLoaded = true
                if initial || previous != activitySessions {
                    self.onSnapshot?(previous, activitySessions, initial)
                }
            } catch {
                guard !Task.isCancelled, generation == self.refreshGeneration else { return }
                let previous = self.activitySessions
                let initial = !self.hasLoaded
                let next = AgentStatusNookSnapshot.make(
                    summaries: summaries,
                    currentUserMessages: [:]
                )
                if self.sessions != next { self.sessions = next }
                self.compactModel.update(statusTone: next.first?.statusTone ?? .gray)
                let activitySessions = AgentStatusNookSnapshot.makeActivitySessions(
                    summaries: allSummaries,
                    displayed: next,
                    previous: previous
                )
                self.activitySessions = activitySessions
                self.hasLoaded = true
                if initial || previous != activitySessions {
                    self.onSnapshot?(previous, activitySessions, initial)
                }
            }
            if generation == self.refreshGeneration {
                self.nextRefreshAt = self.refreshClock.now.advanced(by: .seconds(5))
                self.refreshTask = nil
            }
        }
    }

    private func requiresImmediateRefresh(from store: MacSessionStore) -> Bool {
        let summaries = AgentStatusNookSnapshot.visibleSummaries(from: store.sessions)
        let eligibleCount = AgentStatusNookSnapshot.eligibleSummaries(from: store.sessions).count
        guard eligibleCount == totalSessionCount, summaries.count == sessions.count else { return true }
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
