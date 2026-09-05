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
    private var hookIngest: HookIngestService?
    private var filterEngine: SessionFilterEngine?
    private var usageStore: (any UsageStore)?
    private var usageScanner: UsageScanService?
    private var modelPrices: ModelPriceRefresher?
    public nonisolated let subscriptions: DaemonSubscriptionHub
    /// Longest `usage_report` range: a year and a day, so "this year" always fits.
    static let maximumUsageRangeDays = 366

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

    /// The pipeline `ingest_hook` frames are handed to.
    public func attachHookIngest(_ service: HookIngestService) {
        hookIngest = service
    }

    /// The live rules copy consulted at ingest; `set_session_filters` keeps
    /// it in step with the repository's stored rules.
    public func attachSessionFilters(_ engine: SessionFilterEngine) {
        filterEngine = engine
    }

    /// Usage: the bucket store `usage_report` reads, the scanner whose
    /// progress it reports, and the price table it prices with.
    public func attachUsage(store: any UsageStore, scanner: UsageScanService, prices: ModelPriceRefresher) {
        usageStore = store
        usageScanner = scanner
        modelPrices = prices
    }

    /// Streams a summary-only change (reviewed, archived) to local subscribers.
    private func publishSummary(_ id: SessionID) async {
        guard let summary = try? await repository.sessionSummary(id: id) else { return }
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
            case .ingestHook:
                guard let hookIngest else {
                    payload = failure(code: "hook_ingest_unavailable", message: "The daemon runs without a hook ingest pipeline.")
                    break
                }
                guard let data = envelope.payload.data, !data.isEmpty,
                      let agent = envelope.payload.agent else {
                    payload = failure(code: "missing_hook_frame", message: "The ingest_hook request needs data and agent.")
                    break
                }
                do {
                    let report = try await hookIngest.ingest(
                        data: data,
                        agent: agent,
                        environment: envelope.payload.env ?? [:],
                        createdAt: envelope.payload.createdAt ?? now
                    )
                    logHookIngested(report, bytes: data.count)
                    payload = IPCResponse(
                        status: report.eventsApplied > 0 ? .accepted : .ok,
                        acceptedCount: report.eventsApplied
                    )
                } catch let error as AgentAdapterError {
                    agentLog.error("hook_rejected", metadata: .fields([
                        "agent": agent.rawValue,
                        "error": String(describing: error),
                    ]))
                    payload = failure(code: "malformed_hook", message: "The hook payload could not be decoded: \(error)")
                }
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
                        // Synced iPhones get the rebuilt sessions whole. The
                        // Mac that asked gets only the completion signal
                        // (summary + turns) and pages the rebuilt timeline
                        // back itself: a whole session with full tool content
                        // does not fit one IPC frame.
                        await relay?.sessionsRebuilt(report.rebuiltSessionIDs)
                        payload = IPCResponse(status: .ok, session: SessionDetail(
                            summary: report.detail.summary,
                            turns: report.detail.turns,
                            timeline: []
                        ))
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
            case .usageReport:
                guard let usageStore, let usageScanner, let modelPrices else {
                    payload = failure(code: "usage_unavailable", message: "The daemon runs without a usage scanner.")
                    break
                }
                guard let since = envelope.payload.since, let until = envelope.payload.until else {
                    payload = failure(code: "missing_usage_range", message: "The usage request needs since and until (YYYY-MM-DD).")
                    break
                }
                guard since <= until, let days = since.days(until: until), days < Self.maximumUsageRangeDays else {
                    payload = failure(
                        code: "invalid_usage_range",
                        message: "The usage range must run forward and span at most \(Self.maximumUsageRangeDays) days."
                    )
                    break
                }
                let buckets = try await usageStore.buckets(since: since, until: until)
                let prices = await modelPrices.current()
                let report = UsageReportBuilder.build(
                    buckets: buckets,
                    prices: prices.table,
                    since: since,
                    until: until,
                    generatedAt: now,
                    pricing: prices.status,
                    scan: await usageScanner.status()
                )
                log.debug("usage_report_built", metadata: .fields([
                    "since": since.rawValue, "until": until.rawValue,
                    "buckets": buckets.count, "projects": report.byProject.count, "models": report.byModel.count,
                    "days": report.byDay.count, "trend": report.trend.count, "trend_unit": report.trendUnit.rawValue,
                ]))
                payload = IPCResponse(status: .ok, usage: report)
            case .getSessionFilters:
                payload = IPCResponse(status: .ok, filters: try await repository.sessionFilterRules())
            case .setSessionFilters:
                if let filters = envelope.payload.filters {
                    if filters.count > 100 {
                        payload = failure(code: "too_many_filters", message: "At most 100 filter rules are supported.")
                    } else if let invalid = filters.first(where: { rule in
                        rule.conditions.isEmpty
                            || rule.conditions.contains { !$0.field.allowedOperators.contains($0.op) }
                    }) {
                        payload = failure(
                            code: "invalid_filter",
                            message: "Rule \(invalid.id.rawValue) has no conditions or an operator its field does not support."
                        )
                    } else {
                        // Rule edits never touch existing sessions: verdicts
                        // are frozen, so nothing is published or relayed.
                        try await repository.setSessionFilterRules(filters)
                        filterEngine?.update(rules: filters)
                        dbLog.info("session_filters_updated", metadata: .fields([
                            "rules": filters.count,
                            "enabled": filters.count(where: \.isEnabled),
                        ]))
                        payload = IPCResponse(status: .ok, filters: filters)
                    }
                } else {
                    payload = failure(code: "missing_filters", message: "The set_session_filters request has no rule list.")
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
    private func logHookIngested(_ report: HookIngestService.Report, bytes: Int) {
        for warning in report.warnings {
            agentLog.warning("hook_ingest_warning", metadata: .fields([
                "session": report.sessionID?.rawValue,
                "hook": report.eventName,
                "detail": warning,
            ]))
        }
        for note in report.notes {
            agentLog.debug("hook_ingest_note", metadata: .fields([
                "session": report.sessionID?.rawValue,
                "hook": report.eventName,
                "detail": note,
            ]))
        }
        agentLog.info("hook_ingested", metadata: .fields([
            "provider": report.provider.rawValue,
            "session": report.sessionID?.rawValue,
            "hook": report.eventName,
            "rich": report.richSourcePath,
            "lines": report.richSourceLinesRead,
            "events": report.eventsApplied,
            "hook_bytes": bytes,
            "aaas": report.aaasKind,
            "aaas_agent": report.aaasAgentID,
            "aaas_term": report.aaasTerminalProgram,
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
