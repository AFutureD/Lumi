import Transport
import Foundation

/// The per-row content budget of the Relay copy. A row whose encoded form
/// exceeds it travels trimmed — tool output, injected context and
/// configuration lose their `content`, message / reasoning / error text is
/// cut to fit — and is marked `truncated`, so a mirror can ask for the whole
/// row (`fetch_timeline_items`) when someone opens it. The daemon's and the
/// Mac's own rows are never touched: this applies only to what leaves over
/// the Relay.
public enum RelayContentBudget {
    /// Encoded bytes a row may take on the wire before it is trimmed.
    public static let maxItemBytes = 64 * 1024
    /// Text kept of a long message / reasoning / error, leaving room for the
    /// row's other fields under `maxItemBytes`.
    static let maxTextBytes = 48 * 1024
    /// A one-line summary that alone overflows is cut to this.
    static let maxSummaryBytes = 4 * 1024

    /// The row as the Relay copy should carry it: unchanged when it fits.
    public static func trimmed(_ item: TimelineItem) -> TimelineItem {
        guard encodedSize(item) > maxItemBytes else { return item }
        let first = TimelineItem(
            id: item.id, sessionID: item.sessionID, turnID: item.turnID, occurredAt: item.occurredAt,
            payload: trimmedPayload(item.payload), truncated: true
        )
        guard encodedSize(first) > maxItemBytes else { return first }
        // Still over: the summary line itself is the bulk. Cut it too.
        return TimelineItem(
            id: item.id, sessionID: item.sessionID, turnID: item.turnID, occurredAt: item.occurredAt,
            payload: trimmedSummaries(first.payload), truncated: true
        )
    }

    /// The row's encoded size — what the packer budgets on.
    public static func encodedSize(_ item: TimelineItem) -> Int {
        (try? TransportCoding.makeEncoder().encode(item).count) ?? .max
    }

    private static func trimmedPayload(_ payload: TimelinePayload) -> TimelinePayload {
        switch payload {
        case let .tool(tool):
            .tool(ToolTimelinePayload(
                name: tool.name, summary: tool.summary, content: nil, status: tool.status,
                durationMilliseconds: tool.durationMilliseconds, toolUseID: tool.toolUseID
            ))
        case let .context(context):
            .context(ContextTimelinePayload(kind: context.kind, summary: context.summary, content: nil))
        case let .config(config):
            .config(ConfigTimelinePayload(kind: config.kind, summary: config.summary, content: nil))
        case let .internalContext(context):
            .internalContext(InternalContextTimelinePayload(kind: context.kind, content: .null))
        case let .modelConfiguration(configuration):
            .modelConfiguration(ModelConfigurationTimelinePayload(
                source: configuration.source, model: configuration.model, provider: configuration.provider,
                contextWindow: configuration.contextWindow, reasoningEffort: configuration.reasoningEffort,
                clientVersion: configuration.clientVersion, settings: .null
            ))
        case let .message(message):
            .message(MessageTimelinePayload(role: message.role, text: cut(message.text, to: maxTextBytes)))
        case let .reasoning(reasoning):
            .reasoning(ReasoningTimelinePayload(text: cut(reasoning.text, to: maxTextBytes)))
        case let .error(error):
            .error(ErrorTimelinePayload(title: cut(error.title, to: maxSummaryBytes), message: cut(error.message, to: maxTextBytes), recoverable: error.recoverable))
        case let .plan(plan):
            .plan(PlanTimelinePayload(
                explanation: plan.explanation.map { cut($0, to: maxTextBytes) },
                steps: plan.steps.map { PlanTimelinePayload.Step(text: cut($0.text, to: maxSummaryBytes), status: $0.status) }
            ))
        case let .usageMetrics(metrics):
            .usageMetrics(UsageMetricsTimelinePayload(last: metrics.last, total: metrics.total, modelContextWindow: metrics.modelContextWindow, rateLimits: nil))
        case let .turnEnd(end):
            .turnEnd(TurnEndTimelinePayload(outcome: end.outcome, message: end.message.map { cut($0, to: maxTextBytes) }))
        case .subagent, .sessionMarker:
            payload
        }
    }

    private static func trimmedSummaries(_ payload: TimelinePayload) -> TimelinePayload {
        switch payload {
        case let .tool(tool):
            .tool(ToolTimelinePayload(
                name: cut(tool.name, to: maxSummaryBytes), summary: tool.summary.map { cut($0, to: maxSummaryBytes) }, content: nil,
                status: tool.status, durationMilliseconds: tool.durationMilliseconds, toolUseID: tool.toolUseID
            ))
        case let .context(context):
            .context(ContextTimelinePayload(kind: context.kind, summary: context.summary.map { cut($0, to: maxSummaryBytes) }, content: nil))
        case let .config(config):
            .config(ConfigTimelinePayload(kind: config.kind, summary: config.summary.map { cut($0, to: maxSummaryBytes) }, content: nil))
        case let .subagent(subagent):
            .subagent(SubagentTimelinePayload(name: cut(subagent.name, to: maxSummaryBytes), agentSessionID: subagent.agentSessionID, status: subagent.status))
        case let .sessionMarker(marker):
            .sessionMarker(SessionMarkerTimelinePayload(kind: marker.kind, detail: marker.detail.map { cut($0, to: maxSummaryBytes) }, model: marker.model))
        default:
            payload
        }
    }

    /// The longest prefix within `bytes` of UTF-8, cut at a character
    /// boundary, with an ellipsis when anything was dropped.
    static func cut(_ text: String, to bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        // Decoding a byte prefix repairs a scalar cut in half with U+FFFD;
        // dropping that leaves a clean boundary.
        var prefix = String(decoding: text.utf8.prefix(max(0, bytes - 3)), as: UTF8.self)
        while prefix.last == "\u{FFFD}" { prefix.removeLast() }
        return prefix + "…"
    }
}
