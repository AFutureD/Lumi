import AgentStatusCodex
import AgentStatusCore
import AgentStatusTransport
import Foundation

public actor DaemonService {
    public static let version = "0.1.0"

    private let repository: any SessionRepository
    private let reingester: SessionReingester
    private let socketPath: String
    private let startedAt: Date
    private var relayConnected = false
    public nonisolated let subscriptions: DaemonSubscriptionHub

    public init(
        repository: any SessionRepository,
        socketPath: String,
        startedAt: Date = Date(),
        subscriptions: DaemonSubscriptionHub = DaemonSubscriptionHub(),
        reingester: SessionReingester? = nil
    ) {
        self.repository = repository
        self.reingester = reingester ?? SessionReingester(repository: repository)
        self.socketPath = socketPath
        self.startedAt = startedAt
        self.subscriptions = subscriptions
    }

    public func setRelayConnected(_ connected: Bool) {
        relayConnected = connected
    }

    public func handle(
        _ envelope: TransportEnvelope<IPCRequest>,
        now: Date = Date()
    ) async -> TransportEnvelope<IPCResponse> {
        guard envelope.version.isCompatible(with: .current) else {
            return response(
                requestID: envelope.requestID,
                payload: IPCResponse(
                    status: .error,
                    failure: IPCFailure(
                        code: "incompatible_protocol",
                        message: "Protocol major \(envelope.version.major) is not supported.",
                        retryable: false
                    )
                )
            )
        }

        do {
            let payload: IPCResponse
            switch envelope.payload.operation {
            case .ingest:
                if let event = envelope.payload.event {
                    let inserted = try await repository.apply(event)
                    if inserted { subscriptions.publish(event) }
                    payload = IPCResponse(status: inserted ? .accepted : .ok, event: event)
                } else {
                    payload = failure(code: "missing_event", message: "The ingest request has no event.")
                }
            case .ingestBatch:
                let events = envelope.payload.events ?? []
                var accepted = 0
                for event in events {
                    if try await repository.apply(event) {
                        accepted += 1
                        subscriptions.publish(event)
                    }
                }
                payload = IPCResponse(status: accepted > 0 ? .accepted : .ok, acceptedCount: accepted)
            case .listSessions:
                payload = IPCResponse(
                    status: .ok,
                    sessions: try await repository.listSessions(limit: envelope.payload.limit ?? 100)
                )
            case .getSession:
                if let id = envelope.payload.sessionID {
                    if let session = try await repository.sessionDetail(
                        id: id,
                        cursor: envelope.payload.cursor,
                        limit: envelope.payload.limit ?? 200
                    ) {
                        payload = IPCResponse(status: .ok, session: session)
                    } else {
                        payload = failure(code: "session_not_found", message: "The session is no longer retained.")
                    }
                } else {
                    payload = failure(code: "missing_session_id", message: "The session request has no id.")
                }
            case .deleteSession:
                if let id = envelope.payload.sessionID {
                    _ = try await repository.deleteSession(id: id)
                    payload = IPCResponse(status: .ok)
                } else {
                    payload = failure(code: "missing_session_id", message: "The delete request has no id.")
                }
            case .markSessionReviewed:
                if let id = envelope.payload.sessionID {
                    try await repository.markSessionReviewed(id)
                    payload = IPCResponse(status: .ok)
                } else {
                    payload = failure(code: "missing_session_id", message: "The review request has no id.")
                }
            case .snapshotSessions:
                payload = IPCResponse(
                    status: .ok,
                    sessionDetails: try await snapshotSessions(limit: envelope.payload.limit ?? 10_000),
                    health: try await health(now: now).health
                )
            case .subscribe:
                let currentHealth = try await health(now: now)
                payload = IPCResponse(status: .accepted, health: currentHealth.health)
            case .health:
                payload = try await health(now: now)
            case .clearHistory:
                _ = try await repository.deleteAllSessions()
                payload = IPCResponse(status: .ok)
            case .getRolloutCursor:
                if let path = envelope.payload.path {
                    payload = IPCResponse(
                        status: .ok,
                        rolloutCursor: try await repository.rolloutCursor(path: path)
                    )
                } else {
                    payload = failure(code: "missing_path", message: "The cursor request has no path.")
                }
            case .saveRolloutCursor:
                if let cursor = envelope.payload.rolloutCursor {
                    try await repository.saveRolloutCursor(cursor)
                    payload = IPCResponse(status: .ok, rolloutCursor: cursor)
                } else {
                    payload = failure(code: "missing_cursor", message: "The cursor request has no cursor.")
                }
            case .reingestSession:
                if let id = envelope.payload.sessionID {
                    do {
                        // The rebuild is not streamed: subscribers cannot
                        // express "this session was wiped", so they take the
                        // returned detail (or a fresh snapshot) instead.
                        let report = try await reingester.reingest(
                            sessionID: id,
                            generation: String(Int64(now.timeIntervalSince1970 * 1000))
                        )
                        payload = IPCResponse(status: .ok, session: report.detail)
                    } catch SessionReingestError.sessionNotFound {
                        payload = failure(code: "session_not_found", message: "The session is no longer retained.")
                    } catch SessionReingestError.richSourceUnavailable {
                        payload = failure(
                            code: "rich_source_unavailable",
                            message: "No readable transcript or rollout is known for the session."
                        )
                    }
                } else {
                    payload = failure(code: "missing_session_id", message: "The reingest request has no id.")
                }
            case let .unknown(operation):
                payload = failure(code: "unknown_operation", message: "Unknown operation: \(operation)")
            }
            return response(requestID: envelope.requestID, payload: payload)
        } catch {
            return response(
                requestID: envelope.requestID,
                payload: failure(
                    code: "internal_error",
                    message: "The daemon could not complete the request.",
                    retryable: true
                )
            )
        }
    }

    private func health(now: Date) async throws -> IPCResponse {
        let sessions = try await repository.listSessions(limit: 10_000)
        // Provisional sessions (no Turn yet) are invisible to the UI; keep the
        // health counters on the same footing.
        let activeCount = sessions.filter {
            guard !$0.isProvisional else { return false }
            return switch $0.lifecycle {
            case .starting, .running, .waitingForInput, .compacting: true
            default: false
            }
        }.count
        return IPCResponse(
            status: .ok,
            health: DaemonHealth(
                daemonVersion: Self.version,
                uptimeSeconds: Int64(max(0, now.timeIntervalSince(startedAt))),
                activeSessionCount: activeCount,
                retainedSessionCount: sessions.count,
                socketPath: socketPath,
                relayConnected: relayConnected
            )
        )
    }

    /// Builds one transport snapshot inside the daemon. The caller uses a single
    /// NIO channel for the request regardless of the number of sessions.
    private func snapshotSessions(limit: Int) async throws -> [SessionDetail] {
        let summaries = try await repository.listSessions(limit: limit)
        var result: [SessionDetail] = []
        result.reserveCapacity(summaries.count)

        for summary in summaries {
            var cursor: PaginationCursor?
            var timeline: [TimelineItem] = []
            var turns: [TurnSummary] = []
            repeat {
                guard let page = try await repository.sessionDetail(
                    id: summary.id,
                    cursor: cursor,
                    limit: 500
                ) else { break }
                timeline.append(contentsOf: page.timeline)
                turns = page.turns
                cursor = page.nextCursor
            } while cursor != nil
            result.append(SessionDetail(summary: summary, turns: turns, timeline: timeline))
        }

        return result
    }

    private func failure(code: String, message: String, retryable: Bool = false) -> IPCResponse {
        IPCResponse(
            status: .error,
            failure: IPCFailure(code: code, message: message, retryable: retryable)
        )
    }

    private func response(
        requestID: RequestID,
        payload: IPCResponse
    ) -> TransportEnvelope<IPCResponse> {
        TransportEnvelope(requestID: requestID, payload: payload)
    }
}
