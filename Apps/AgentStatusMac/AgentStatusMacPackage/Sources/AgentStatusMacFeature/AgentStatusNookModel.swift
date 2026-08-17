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
    let updatedAt: Date

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
        details: [SessionDetail]
    ) -> [AgentStatusNookSession] {
        let detailsByID = Dictionary(uniqueKeysWithValues: details.map { ($0.summary.id, $0) })
        return summaries.map { summary in
            AgentStatusNookSession(
                id: summary.id,
                title: summary.title,
                lifecycle: summary.lifecycle,
                phase: summary.phase,
                currentUserMessage: detailsByID[summary.id].flatMap(currentTurnUserMessage),
                updatedAt: summary.updatedAt
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
                    ?? previousByID[summary.id]?.currentUserMessage,
                updatedAt: summary.updatedAt
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
            let old = previousByID[session.id]
            return old == nil
                || old?.lifecycle != session.lifecycle
                || old?.currentUserMessage != session.currentUserMessage
                || approvalPhaseChanged(from: old?.phase, to: session.phase)
        }
    }

    private static func approvalPhaseChanged(from old: TurnPhase?, to new: TurnPhase) -> Bool {
        old != new && (old == .waitingForApproval || new == .waitingForApproval)
    }
}

@MainActor
final class AgentStatusNookModel: ObservableObject {
    @Published private(set) var sessions: [AgentStatusNookSession] = []
    @Published private(set) var totalSessionCount = 0
    @Published private(set) var daemonAvailable = false

    var onSnapshot: ((_ previous: [AgentStatusNookSession], _ current: [AgentStatusNookSession], _ initial: Bool) -> Void)?

    private weak var store: MacSessionStore?
    private var refreshTask: Task<Void, Never>?
    private var hasLoaded = false
    private var lastObservedRevision: UInt64 = 0
    private var activitySessions: [AgentStatusNookSession] = []

    init(store: MacSessionStore) {
        self.store = store
        lastObservedRevision = store.dataRevision
        store.observe { [weak self, weak store] in
            guard let self, let store else { return }
            self.daemonAvailable = store.health != nil
            guard store.dataRevision != self.lastObservedRevision || !self.hasLoaded else { return }
            self.lastObservedRevision = store.dataRevision
            self.reload(from: store)
        }
    }

    func start() {
        guard let store else { return }
        daemonAvailable = store.health != nil
        reload(from: store)
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func reload(from store: MacSessionStore) {
        let allSummaries = store.sessions
        let summaries = AgentStatusNookSnapshot.visibleSummaries(from: allSummaries)
        totalSessionCount = AgentStatusNookSnapshot.eligibleSummaries(from: allSummaries).count
        refreshTask?.cancel()
        refreshTask = Task { [weak self, weak store] in
            guard let self, let store else { return }
            do {
                let details = try await store.cachedSessionDetails(ids: summaries.map(\.id))
                guard !Task.isCancelled else { return }
                let next = AgentStatusNookSnapshot.make(summaries: summaries, details: details)
                let previous = self.activitySessions
                let initial = !self.hasLoaded
                self.sessions = next
                let activitySessions = AgentStatusNookSnapshot.makeActivitySessions(
                    summaries: allSummaries,
                    displayed: next,
                    previous: previous
                )
                self.activitySessions = activitySessions
                self.hasLoaded = true
                self.onSnapshot?(previous, activitySessions, initial)
            } catch {
                guard !Task.isCancelled else { return }
                let previous = self.activitySessions
                let initial = !self.hasLoaded
                self.sessions = AgentStatusNookSnapshot.make(summaries: summaries, details: [])
                let activitySessions = AgentStatusNookSnapshot.makeActivitySessions(
                    summaries: allSummaries,
                    displayed: self.sessions,
                    previous: previous
                )
                self.activitySessions = activitySessions
                self.hasLoaded = true
                self.onSnapshot?(previous, activitySessions, initial)
            }
        }
    }
}

private extension TimelinePayload {
    var userMessage: String? {
        guard case let .message(message) = self, message.role == .user else { return nil }
        return message.text
    }
}
