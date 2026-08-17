import AgentStatusTransport
import Foundation

/// In-process fan-out for the daemon's single local event stream. Subscribers
/// are macOS app channels, never individual Sessions.
public final class DaemonSubscriptionHub: @unchecked Sendable {
    public typealias Handler = @Sendable (AgentIngressEvent) -> Void

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
        lock.lock()
        let current = Array(handlers.values)
        lock.unlock()
        current.forEach { $0(event) }
    }
}
