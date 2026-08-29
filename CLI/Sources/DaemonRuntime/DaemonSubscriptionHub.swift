import Diagnostics
import Logging
import Synchronization
import Transport
import Foundation

private let log = Logger(label: "agent")

/// What the daemon's single local stream carries: Agent events as applied,
/// and summary-only changes that have no event (reviewed, archived) so every
/// mirror — the Mac window, the Notch — updates the moment another end acts.
public enum DaemonStreamMessage: Sendable {
    case event(AgentIngressEvent)
    case summary(SessionSummary)
}

/// In-process fan-out for the daemon's single local stream. Subscribers are
/// macOS app channels and the Relay host, never individual Sessions.
///
/// Deliberately synchronous: every handler is a non-suspending closure (a
/// yield into a connection's or the Relay's stream), so publishing from any
/// isolation never reorders deliveries across publishers.
public final class DaemonSubscriptionHub: Sendable {
    public typealias Handler = @Sendable (DaemonStreamMessage) -> Void

    private let handlers = Mutex<[UUID: Handler]>([:])

    public init() {}

    @discardableResult
    public func subscribe(_ handler: @escaping Handler) -> UUID {
        let id = UUID()
        let count = handlers.withLock {
            $0[id] = handler
            return $0.count
        }
        log.debug("stream_subscribed", metadata: .fields(["subscriber": id.uuidString.prefix(8), "subscribers": count]))
        return id
    }

    public func unsubscribe(_ id: UUID) {
        let (removed, count) = handlers.withLock {
            ($0.removeValue(forKey: id) != nil, $0.count)
        }
        if removed {
            log.debug("stream_unsubscribed", metadata: .fields(["subscriber": id.uuidString.prefix(8), "subscribers": count]))
        }
    }

    public func publish(_ event: AgentIngressEvent) {
        publish(.event(event))
    }

    public func publish(summary: SessionSummary) {
        publish(.summary(summary))
    }

    public func publish(_ message: DaemonStreamMessage) {
        let current = handlers.withLock { Array($0.values) }
        if log.logLevel <= .debug {
            switch message {
            case let .event(event):
                log.debug("stream_publish", metadata: .fields([
                    "kind": "event",
                    "session": event.sessionID.rawValue,
                    "event": event.eventID.rawValue,
                    "subscribers": current.count,
                ]))
            case let .summary(summary):
                log.debug("stream_publish", metadata: .fields([
                    "kind": "summary",
                    "session": summary.id.rawValue,
                    "subscribers": current.count,
                ]))
            }
        }
        current.forEach { $0(message) }
    }
}
