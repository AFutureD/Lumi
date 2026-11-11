import Foundation

/// The per-row content budget of every mirror copy. Only the daemon keeps
/// whole rows; what it sends to a mirror — the Mac over IPC (`get_session`,
/// the event stream), an iPhone over the Relay — is trimmed by this one
/// rule. A row whose encoded form exceeds the budget keeps its shape and
/// loses its bulk: inside `content` every long string is cut short (tool
/// output, a screenshot, an injected prompt), message / reasoning / error
/// text is cut to fit. The row is marked `truncated`, so the mirror asks for
/// the whole row when someone opens it (`get_timeline_items` on the Mac,
/// `fetch_timeline_items` on an iPhone).
///
/// The shape stays because a row's Activity line is read from its content
/// (`TimelineLineText`): a trimmed row must still say which command ran or
/// which file was read.
public enum TimelineContentBudget {
    /// Encoded bytes a mirror row may take before it is trimmed.
    public static let maxItemBytes = 64 * 1024
    /// Text kept of a long message / reasoning / error, leaving room for the
    /// row's other fields under `maxItemBytes`.
    static let maxTextBytes = 48 * 1024
    /// A short field (a name, a title, a plan step) that alone overflows is
    /// cut to this.
    static let maxShortTextBytes = 4 * 1024
    /// Longest string kept inside a trimmed `content`, tried in turn until
    /// the row fits. A row that still overflows at the last one loses its
    /// content whole.
    static let contentStringByteSteps = [4 * 1024, 1024, 256]

    /// The row as a mirror should hold it: unchanged when it fits.
    public static func trimmed(_ item: TimelineItem) -> TimelineItem {
        guard encodedSize(item) > maxItemBytes else { return item }
        var candidate = item
        for payload in trimmedForms(of: item.payload) {
            candidate = TimelineItem(
                id: item.id, sessionID: item.sessionID, turnID: item.turnID, occurredAt: item.occurredAt,
                payload: payload, truncated: true
            )
            if encodedSize(candidate) <= maxItemBytes { break }
        }
        return candidate
    }

    /// A live event as a mirror should receive it: its row, if any, trimmed.
    public static func trimmed(_ event: AgentIngressEvent) -> AgentIngressEvent {
        guard let item = event.timelineItem else { return event }
        var copy = event
        copy.timelineItem = trimmed(item)
        return copy
    }

    /// The row's encoded size — what the packer budgets on.
    public static func encodedSize(_ item: TimelineItem) -> Int {
        (try? TransportCoding.makeEncoder().encode(item).count) ?? .max
    }

    /// Ever smaller forms of an over-budget payload, most complete first.
    /// The last one always fits: it holds short fields only.
    private static func trimmedForms(of payload: TimelinePayload) -> [TimelinePayload] {
        switch payload {
        case let .tool(tool):
            contentForms(tool.content).map { .tool(tool.withContent($0)) } + [
                .tool(ToolTimelinePayload(
                    name: cut(tool.name, to: maxShortTextBytes), content: nil, status: tool.status,
                    durationMilliseconds: tool.durationMilliseconds, toolUseID: tool.toolUseID
                )),
            ]
        case let .context(context):
            contentForms(context.content).map { .context(ContextTimelinePayload(kind: context.kind, content: $0)) }
        case let .config(config):
            contentForms(config.content).map { .config(ConfigTimelinePayload(kind: config.kind, content: $0)) }
        case let .internalContext(context):
            [.internalContext(InternalContextTimelinePayload(kind: context.kind, content: .null))]
        case let .modelConfiguration(configuration):
            [.modelConfiguration(ModelConfigurationTimelinePayload(
                source: configuration.source, model: configuration.model, provider: configuration.provider,
                contextWindow: configuration.contextWindow, reasoningEffort: configuration.reasoningEffort,
                clientVersion: configuration.clientVersion, settings: .null
            ))]
        case let .message(message):
            [.message(MessageTimelinePayload(role: message.role, text: cut(message.text, to: maxTextBytes)))]
        case let .reasoning(reasoning):
            [.reasoning(ReasoningTimelinePayload(text: cut(reasoning.text, to: maxTextBytes)))]
        case let .error(error):
            [.error(ErrorTimelinePayload(title: cut(error.title, to: maxShortTextBytes), message: cut(error.message, to: maxTextBytes), recoverable: error.recoverable))]
        case let .plan(plan):
            [.plan(PlanTimelinePayload(
                explanation: plan.explanation.map { cut($0, to: maxTextBytes) },
                steps: plan.steps.map { PlanTimelinePayload.Step(text: cut($0.text, to: maxShortTextBytes), status: $0.status) }
            ))]
        case let .usageMetrics(metrics):
            [.usageMetrics(UsageMetricsTimelinePayload(last: metrics.last, total: metrics.total, modelContextWindow: metrics.modelContextWindow, rateLimits: nil))]
        case let .turnEnd(end):
            [.turnEnd(TurnEndTimelinePayload(outcome: end.outcome, message: end.message.map { cut($0, to: maxTextBytes) }))]
        case let .subagent(subagent):
            [.subagent(SubagentTimelinePayload(name: cut(subagent.name, to: maxShortTextBytes), agentSessionID: subagent.agentSessionID, status: subagent.status))]
        case let .sessionMarker(marker):
            [.sessionMarker(SessionMarkerTimelinePayload(kind: marker.kind, detail: marker.detail.map { cut($0, to: maxShortTextBytes) }, model: marker.model))]
        }
    }

    /// `content` with its long strings cut at each step, then without it.
    private static func contentForms(_ content: JSONValue?) -> [JSONValue?] {
        guard let content else { return [nil] }
        return contentStringByteSteps.map { cuttingStrings(in: content, to: $0) } + [nil]
    }

    /// The same value with every string longer than `bytes` cut to it.
    /// Object keys and the shape are untouched.
    static func cuttingStrings(in value: JSONValue, to bytes: Int) -> JSONValue {
        switch value {
        case let .string(text): .string(cut(text, to: bytes))
        case let .array(values): .array(values.map { cuttingStrings(in: $0, to: bytes) })
        case let .object(fields): .object(fields.mapValues { cuttingStrings(in: $0, to: bytes) })
        case .number, .boolean, .null: value
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
