import Adapters
import Core
import Diagnostics
import Logging
import Transport
import Foundation

private let log = Logger(label: "ipc")
private let agentLog = Logger(label: "agent")
private let convertLog = Logger(label: "convert")
private let dbLog = Logger(label: "db")

public actor DaemonService {
    public static let version = "0.1.0"

    private let repository: any SessionRepository
    private let reingester: SessionReingester
    private let socketPath: String
    private let startedAt: Date
    private let executableHash: String
    private var relayConnected = false
    private var relay: RelayHostService?
    public nonisolated let subscriptions: DaemonSubscriptionHub

    public init(
        repository: any SessionRepository,
        socketPath: String,
        executableHash: String,
        startedAt: Date = Date(),
        subscriptions: DaemonSubscriptionHub = DaemonSubscriptionHub(),
        reingester: SessionReingester? = nil
    ) {
        self.repository = repository
        self.reingester = reingester ?? SessionReingester(repository: repository)
        self.socketPath = socketPath
        self.executableHash = executableHash
        self.startedAt = startedAt
        self.subscriptions = subscriptions
    }

    public func setRelayConnected(_ connected: Bool) {
        relayConnected = connected
    }

    /// The Relay host living in this daemon: summary-only changes and
    /// removals made through IPC are forwarded to paired iPhones, and the
    /// `relay_*` operations are served from it.
    public func attachRelay(_ relay: RelayHostService) {
        self.relay = relay
    }

    /// The same health the `health` IPC answers with.
    /// Streams a summary-only change (reviewed, archived) to local subscribers.
    private func publishSummary(_ id: SessionID) async {
        guard let summary = try? await repository.sessionDetail(id: id, cursor: nil, limit: 1)?.summary else { return }
        subscriptions.publish(summary: summary)
    }

    public func currentHealth(now: Date = Date()) async -> DaemonHealth? {
        try? await health(now: now).health
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
                    logIngested([event], accepted: inserted ? 1 : 0)
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
                logIngested(events, accepted: accepted)
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
                    let removed = try await repository.deleteSession(id: id)
                    dbLog.info("session_deleted", metadata: .fields(["session": id.rawValue, "removed": removed.count]))
                    await relay?.sessionsRemoved(removed)
                    payload = IPCResponse(status: .ok)
                } else {
                    payload = failure(code: "missing_session_id", message: "The delete request has no id.")
                }
            case .markSessionReviewed:
                if let id = envelope.payload.sessionID {
                    try await repository.markSessionReviewed(id)
                    await publishSummary(id)
                    await relay?.summariesChanged([id])
                    payload = IPCResponse(status: .ok)
                } else {
                    payload = failure(code: "missing_session_id", message: "The review request has no id.")
                }
            case .markSessionHiddenInNotch:
                if let id = envelope.payload.sessionID {
                    try await repository.markSessionHiddenInNotch(id)
                    await publishSummary(id)
                    await relay?.summariesChanged([id])
                    payload = IPCResponse(status: .ok)
                } else {
                    payload = failure(code: "missing_session_id", message: "The archive request has no id.")
                }
            case .subscribe:
                let currentHealth = try await health(now: now)
                payload = IPCResponse(status: .accepted, health: currentHealth.health)
            case .health:
                payload = try await health(now: now)
            case .clearHistory:
                let retained = try await repository.listSessions(limit: 10_000).map(\.id)
                _ = try await repository.deleteAllSessions()
                dbLog.info("history_cleared", metadata: .fields(["sessions": retained.count]))
                await relay?.sessionsRemoved(retained)
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
                        // returned detail (or reconcile per session) instead.
                        let report = try await reingester.reingest(
                            sessionID: id,
                            generation: String(Int64(now.timeIntervalSince1970 * 1000))
                        )
                        // Synced iPhones get the rebuilt sessions whole; the
                        // Mac that asked takes `report.detail` from this reply.
                        await relay?.sessionsRebuilt(report.rebuiltSessionIDs)
                        payload = IPCResponse(status: .ok, session: report.detail)
                    } catch SessionReingestError.sessionNotFound {
                        payload = failure(code: "session_not_found", message: "The session is no longer retained.")
                    } catch SessionReingestError.richSourceUnavailable {
                        convertLog.warning("session_reingest_unavailable", metadata: .fields(["session": id.rawValue]))
                        payload = failure(
                            code: "rich_source_unavailable",
                            message: "No readable transcript or rollout is known for the session."
                        )
                    }
                } else {
                    payload = failure(code: "missing_session_id", message: "The reingest request has no id.")
                }
            case .relayStatus:
                payload = IPCResponse(status: .ok, relay: await relayStatus())
            case .relayRefreshDevices:
                await relay?.refreshDevices()
                payload = IPCResponse(status: .ok, relay: await relayStatus())
            case .relayPairingStart:
                if let relay {
                    do {
                        let pairing = try await relay.startPairing()
                        payload = IPCResponse(status: .ok, relay: await relay.status(), pairing: pairing)
                    } catch {
                        // Most commonly: the Relay this daemon points at does
                        // not serve the pairing endpoints (not deployed yet).
                        payload = failure(
                            code: "pairing_start_failed",
                            message: "The Relay could not create a pairing session: \(error)",
                            retryable: true
                        )
                    }
                } else {
                    payload = failure(code: "relay_unavailable", message: "The daemon runs without a Relay connection.")
                }
            case .relayPairingState:
                if let relay {
                    payload = IPCResponse(status: .ok, relay: await relay.status(), pairing: await relay.pairingSession())
                } else {
                    payload = failure(code: "relay_unavailable", message: "The daemon runs without a Relay connection.")
                }
            case .relayPairingDecide:
                if let relay, let approved = envelope.payload.approved {
                    do {
                        let pairing = try await relay.decidePairing(approved: approved)
                        payload = IPCResponse(status: .ok, relay: await relay.status(), pairing: pairing)
                    } catch RelayPairingError.noPendingDevice {
                        payload = failure(code: "no_pending_device", message: "No iPhone is waiting on the pairing session.")
                    } catch {
                        payload = failure(
                            code: "pairing_decision_failed",
                            message: "The Relay did not accept the decision: \(error)",
                            retryable: true
                        )
                    }
                } else if relay == nil {
                    payload = failure(code: "relay_unavailable", message: "The daemon runs without a Relay connection.")
                } else {
                    payload = failure(code: "missing_decision", message: "The pairing decision has no `approved` value.")
                }
            case .relayPairingCancel:
                await relay?.cancelPairing()
                payload = IPCResponse(status: .ok, relay: await relayStatus())
            case .relayRevokeDevice:
                if let relay, let deviceID = envelope.payload.deviceID {
                    try await relay.revoke(deviceID: deviceID)
                    payload = IPCResponse(status: .ok, relay: await relay.status())
                } else if relay == nil {
                    payload = failure(code: "relay_unavailable", message: "The daemon runs without a Relay connection.")
                } else {
                    payload = failure(code: "missing_device_id", message: "The revoke request has no device id.")
                }
            case .relayRemoveDevice:
                if let relay, let deviceID = envelope.payload.deviceID {
                    try await relay.remove(deviceID: deviceID)
                    payload = IPCResponse(status: .ok, relay: await relay.status())
                } else if relay == nil {
                    payload = failure(code: "relay_unavailable", message: "The daemon runs without a Relay connection.")
                } else {
                    payload = failure(code: "missing_device_id", message: "The remove request has no device id.")
                }
            }
            return response(requestID: envelope.requestID, payload: payload)
        } catch {
            // The client only sees `internal_error`; the cause is recorded here.
            log.error("ipc_operation_failed", metadata: .fields([
                "op": envelope.payload.operation.rawValue,
                "session": envelope.payload.sessionID?.rawValue,
                "error": error,
            ]))
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

    /// One line per ingest call: how many events arrived, how many were new
    /// (the rest were replays the idempotency table swallowed), for which
    /// sessions. Per-event detail is on the stream's debug line.
    private func logIngested(_ events: [AgentIngressEvent], accepted: Int) {
        guard !events.isEmpty else { return }
        var sessions: [String] = []
        for event in events where !sessions.contains(event.sessionID.rawValue) {
            sessions.append(event.sessionID.rawValue)
        }
        agentLog.info("events_ingested", metadata: .fields([
            "received": events.count,
            "accepted": accepted,
            "duplicates": events.count - accepted,
            "sessions": sessions.joined(separator: ","),
        ]))
    }

    private func relayStatus() async -> RelayHostStatus {
        if let relay { return await relay.status() }
        return RelayHostStatus(connected: false, lastError: "The daemon runs without a Relay connection.")
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
                executableHash: executableHash,
                uptimeSeconds: Int64(max(0, now.timeIntervalSince(startedAt))),
                activeSessionCount: activeCount,
                retainedSessionCount: sessions.count,
                socketPath: socketPath,
                relayConnected: relayConnected
            )
        )
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
