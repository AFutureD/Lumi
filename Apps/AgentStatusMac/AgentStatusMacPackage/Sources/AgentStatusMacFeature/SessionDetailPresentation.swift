import AgentStatusTransport
import Foundation

struct SessionListRowPresentation: Equatable {
    let title: String
    let agent: String
    let status: String

    init(session: SessionSummary) {
        title = session.title
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        agent = session.agent.displayName
        status = "\(session.lifecycle.displayName) · \(session.phase.displayName)"
    }
}

enum SessionDetailModuleKind: String, CaseIterable, Equatable {
    case overview
    case modelConfiguration
    case usage
    case internalContext
    case activity

    var title: String {
        switch self {
        case .overview: "Overview"
        case .modelConfiguration: "Model Configuration"
        case .usage: "Usage"
        case .internalContext: "Internal Context"
        case .activity: "Activity"
        }
    }
}

struct SessionDetailRowPresentation: Equatable {
    let symbolName: String
    let title: String
    let body: String
    let metadata: String?
    let usesStructuredText: Bool
}

struct SessionDetailModulePresentation: Equatable {
    let kind: SessionDetailModuleKind
    let rows: [SessionDetailRowPresentation]

    var title: String { kind.title }
}

enum SessionDetailPresentationBuilder {
    static func modules(for detail: SessionDetail) -> [SessionDetailModulePresentation] {
        let timeline = detail.timeline.sorted {
            if $0.occurredAt == $1.occurredAt { return $0.id.rawValue < $1.id.rawValue }
            return $0.occurredAt < $1.occurredAt
        }

        let modelItems = timeline.compactMap { item -> SessionDetailRowPresentation? in
            guard case let .modelConfiguration(payload) = item.payload else { return nil }
            return modelConfigurationRow(payload, item: item)
        }
        let usageItems = timeline.compactMap { item -> SessionDetailRowPresentation? in
            guard case let .usageMetrics(payload) = item.payload else { return nil }
            return usageRow(payload, item: item)
        }
        let contextItems = timeline.compactMap { item -> SessionDetailRowPresentation? in
            guard case let .internalContext(payload) = item.payload else { return nil }
            return internalContextRow(payload, item: item)
        }
        let activityItems = timeline.compactMap { item -> SessionDetailRowPresentation? in
            switch item.payload {
            case .message, .tool, .plan, .subagent, .error, .unknown:
                activityRow(item)
            case .modelConfiguration, .internalContext, .usageMetrics:
                nil
            }
        }

        return [
            SessionDetailModulePresentation(kind: .overview, rows: overviewRows(detail)),
            SessionDetailModulePresentation(
                kind: .modelConfiguration,
                rows: modelItems.orPlaceholder(
                    title: "No model configuration",
                    body: "This Session has not reported model configuration data."
                )
            ),
            SessionDetailModulePresentation(
                kind: .usage,
                rows: usageItems.orPlaceholder(
                    title: "No usage data",
                    body: "This Session has not reported token or rate-limit data."
                )
            ),
            SessionDetailModulePresentation(
                kind: .internalContext,
                rows: contextItems.orPlaceholder(
                    title: "No internal context",
                    body: "This Session has not retained internal context data."
                )
            ),
            SessionDetailModulePresentation(
                kind: .activity,
                rows: activityItems.orPlaceholder(
                    title: "No activity",
                    body: "This Session has no supported activity events."
                )
            ),
        ]
    }

    private static func overviewRows(_ detail: SessionDetail) -> [SessionDetailRowPresentation] {
        let summary = detail.summary
        let agentValue = summary.agent.displayName == summary.agent.rawValue
            ? summary.agent.rawValue
            : "\(summary.agent.displayName) (\(summary.agent.rawValue))"
        var rows = [
            valueRow(title: "Title", value: summary.title, symbol: "text.quote"),
            valueRow(title: "Session ID", value: summary.id.rawValue, symbol: "number"),
            valueRow(title: "Agent", value: agentValue, symbol: "terminal"),
            valueRow(
                title: "Lifecycle",
                value: displayName(summary.lifecycle.displayName, rawValue: summary.lifecycle.rawValue),
                symbol: "circle.dotted"
            ),
            valueRow(
                title: "Turn Phase",
                value: displayName(summary.phase.displayName, rawValue: summary.phase.rawValue),
                symbol: "arrow.triangle.2.circlepath"
            ),
            valueRow(title: "Needs Attention", value: summary.needsAttention ? "Yes" : "No", symbol: "bell"),
            valueRow(title: "Workspace", value: summary.workspace ?? "Not available", symbol: "folder"),
            valueRow(title: "Started", value: detailDate(summary.startedAt), symbol: "clock.arrow.circlepath"),
            valueRow(title: "Updated", value: detailDate(summary.updatedAt), symbol: "clock"),
            valueRow(title: "Last Activity", value: detailDate(summary.lastActivityAt), symbol: "waveform.path.ecg"),
            valueRow(
                title: "Next Cursor",
                value: detail.nextCursor?.value ?? "Not available",
                symbol: "arrow.right.to.line"
            ),
        ]
        if let lineage = summary.lineage {
            rows.append(contentsOf: [
                valueRow(
                    title: "Thread Source",
                    value: lineage.threadSource ?? "Not available",
                    symbol: "point.3.connected.trianglepath.dotted"
                ),
                valueRow(
                    title: "Parent Session ID",
                    value: lineage.parentSessionID?.rawValue ?? "Not available",
                    symbol: "arrow.turn.up.left"
                ),
                valueRow(
                    title: "Subagent Depth",
                    value: lineage.subagentDepth.map(String.init) ?? "Not available",
                    symbol: "arrow.down.right"
                ),
                valueRow(
                    title: "Agent Nickname",
                    value: lineage.agentNickname ?? "Not available",
                    symbol: "person.text.rectangle"
                ),
                valueRow(
                    title: "Agent Role",
                    value: lineage.agentRole ?? "Not available",
                    symbol: "person.badge.key"
                ),
                valueRow(
                    title: "Agent Path",
                    value: lineage.agentPath ?? "Not available",
                    symbol: "point.bottomleft.forward.to.point.topright.scurvepath"
                ),
                valueRow(
                    title: "Subagent Kind",
                    value: lineage.subagentKind ?? "Not available",
                    symbol: "person.2"
                ),
            ])
        }
        return rows
    }

    private static func valueRow(title: String, value: String, symbol: String) -> SessionDetailRowPresentation {
        SessionDetailRowPresentation(
            symbolName: symbol,
            title: title,
            body: value,
            metadata: nil,
            usesStructuredText: false
        )
    }

    private static func modelConfigurationRow(
        _ payload: ModelConfigurationTimelinePayload,
        item: TimelineItem
    ) -> SessionDetailRowPresentation {
        let lines = [
            "Source: \(payload.source)",
            "Model: \(payload.model ?? "Not available")",
            "Provider: \(payload.provider ?? "Not available")",
            "Context window: \(payload.contextWindow.map(String.init) ?? "Not available")",
            "Reasoning effort: \(payload.reasoningEffort ?? "Not available")",
            "Client version: \(payload.clientVersion ?? "Not available")",
            "Settings:",
            prettyJSON(payload.settings),
            itemIdentity(item),
        ]
        return SessionDetailRowPresentation(
            symbolName: "cpu",
            title: payload.model ?? "Configuration · \(humanized(payload.source))",
            body: lines.joined(separator: "\n"),
            metadata: detailDate(item.occurredAt),
            usesStructuredText: true
        )
    }

    private static func usageRow(
        _ payload: UsageMetricsTimelinePayload,
        item: TimelineItem
    ) -> SessionDetailRowPresentation {
        var lines = ["Last usage:", tokenUsage(payload.last)]
        lines.append(contentsOf: ["", "Total usage:", tokenUsage(payload.total)])
        lines.append(contentsOf: [
            "",
            "Model context window: \(payload.modelContextWindow.map(String.init) ?? "Not available")",
            "Rate limits:",
            payload.rateLimits.map(prettyJSON) ?? "Not available",
            itemIdentity(item),
        ])
        let total = payload.total?.totalTokens ?? payload.last?.totalTokens
        return SessionDetailRowPresentation(
            symbolName: "gauge.with.dots.needle.67percent",
            title: total.map { "\($0) total tokens" } ?? "Usage snapshot",
            body: lines.joined(separator: "\n"),
            metadata: detailDate(item.occurredAt),
            usesStructuredText: true
        )
    }

    private static func internalContextRow(
        _ payload: InternalContextTimelinePayload,
        item: TimelineItem
    ) -> SessionDetailRowPresentation {
        SessionDetailRowPresentation(
            symbolName: "lock.doc",
            title: humanized(payload.kind),
            body: [prettyJSON(payload.content), itemIdentity(item)].joined(separator: "\n\n"),
            metadata: detailDate(item.occurredAt),
            usesStructuredText: true
        )
    }

    private static func activityRow(_ item: TimelineItem) -> SessionDetailRowPresentation {
        SessionDetailRowPresentation(
            symbolName: item.payload.symbolName,
            title: item.payload.title,
            body: [item.payload.body, itemIdentity(item)].joined(separator: "\n\n"),
            metadata: detailDate(item.occurredAt),
            usesStructuredText: false
        )
    }

    private static func tokenUsage(_ usage: TokenUsage?) -> String {
        guard let usage else { return "Not available" }
        return [
            "Input tokens: \(usage.inputTokens)",
            "Cached input tokens: \(usage.cachedInputTokens)",
            "Cache-write input tokens: \(usage.cacheWriteInputTokens)",
            "Output tokens: \(usage.outputTokens)",
            "Reasoning output tokens: \(usage.reasoningOutputTokens)",
            "Total tokens: \(usage.totalTokens)",
        ].joined(separator: "\n")
    }

    private static func itemIdentity(_ item: TimelineItem) -> String {
        [
            "Timeline ID: \(item.id.rawValue)",
            "Turn ID: \(item.turnID?.rawValue ?? "Not available")",
        ].joined(separator: "\n")
    }

    private static func prettyJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "Unable to render structured data"
        }
        return string
    }

    private static func humanized(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func displayName(_ displayName: String, rawValue: String) -> String {
        displayName.lowercased() == rawValue.lowercased()
            ? displayName
            : "\(displayName) (\(rawValue))"
    }

    private static func detailDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}

private extension Array where Element == SessionDetailRowPresentation {
    func orPlaceholder(title: String, body: String) -> [SessionDetailRowPresentation] {
        guard isEmpty else { return self }
        return [SessionDetailRowPresentation(
            symbolName: "minus.circle",
            title: title,
            body: body,
            metadata: nil,
            usesStructuredText: false
        )]
    }
}

private extension TimelinePayload {
    var symbolName: String {
        switch self {
        case let .message(value): value.role == .user ? "person" : "sparkles"
        case .tool: "hammer"
        case .plan: "checklist"
        case .subagent: "person.2"
        case .error: "exclamationmark.triangle"
        case .modelConfiguration: "cpu"
        case .internalContext: "lock.doc"
        case .usageMetrics: "gauge.with.dots.needle.67percent"
        case .unknown: "questionmark.circle"
        }
    }

    var title: String {
        switch self {
        case let .message(value): value.role == .user ? "User" : "Assistant"
        case let .tool(value): "Tool · \(value.name) · \(value.status.rawValue.capitalized)"
        case .plan: "Plan"
        case let .subagent(value): "Sub-agent · \(value.name)"
        case .error: "Error"
        case .modelConfiguration: "Model Configuration"
        case let .internalContext(value): "Internal Context · \(value.kind)"
        case .usageMetrics: "Usage Metrics"
        case let .unknown(value): value.kind
        }
    }

    var body: String {
        switch self {
        case let .message(value):
            [
                "Role: \(value.role.rawValue)",
                "Text: \(value.text)",
            ].joined(separator: "\n")
        case let .tool(value):
            [
                "Name: \(value.name)",
                "Status: \(value.status.rawValue)",
                "Summary: \(value.summary ?? "Not available")",
                "Duration: \(value.durationMilliseconds.map { "\($0) ms" } ?? "Not available")",
            ].joined(separator: "\n")
        case let .plan(value):
            [
                "Explanation: \(value.explanation ?? "Not available")",
                "Steps:",
                value.steps.map { "[\($0.status.rawValue)] \($0.text)" }.joined(separator: "\n"),
            ].joined(separator: "\n")
        case let .subagent(value):
            [
                "Name: \(value.name)",
                "Agent Session ID: \(value.agentSessionID ?? "Not available")",
                "Status: \(value.status.rawValue)",
            ].joined(separator: "\n")
        case let .error(value):
            [
                "Title: \(value.title)",
                "Message: \(value.message)",
                "Recoverable: \(value.recoverable ? "Yes" : "No")",
            ].joined(separator: "\n")
        case let .modelConfiguration(value): value.model ?? value.source
        case let .internalContext(value): value.kind
        case let .usageMetrics(value): "\(value.total?.totalTokens ?? value.last?.totalTokens ?? 0) tokens"
        case let .unknown(value):
            [
                "Kind: \(value.kind)",
                "Summary: \(value.summary ?? "Not available")",
            ].joined(separator: "\n")
        }
    }
}
