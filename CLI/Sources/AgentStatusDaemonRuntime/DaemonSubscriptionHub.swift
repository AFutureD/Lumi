import AgentStatusTransport
import Foundation

/// What the daemon's single local stream carries: Agent events as applied,
/// and summary-only changes that have no event (reviewed, archived) so every
/// mirror — the Mac window, the Notch — updates the moment another end acts.
public enum DaemonStreamMessage: Sendable {
    case event(AgentIngressEvent)
    case summary(SessionSummary)
}

/// In-process fan-out for the daemon's single local stream. Subscribers are
/// macOS app channels and the Relay host, never individual Sessions.
public final class DaemonSubscriptionHub: @unchecked Sendable {
    public typealias Handler = @Sendable (DaemonStreamMessage) -> Void

    private let lock = NSLock()
    private var handlers: [UUID: Handler] = [:]

    public init() {}

    @discardableResult
    public func subscribe(_ handler: @escaping Handler) -> UUID {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        return id
    }

    public func unsubscribe(_ id: UUID) {
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }

    public func publish(_ event: AgentIngressEvent) {
        publish(.event(event))
    }

    public func publish(summary: SessionSummary) {
        publish(.summary(summary))
    }

    public func publish(_ message: DaemonStreamMessage) {
        lock.lock()
        let current = Array(handlers.values)
        lock.unlock()
        current.forEach { $0(message) }
    }
}
