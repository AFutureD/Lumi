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

struct SessionSummaryFieldPresentation: Equatable, Sendable {
    let label: String
    let value: String
}

struct SessionSummarySectionPresentation: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case overview
        case lineage
        case modelConfiguration
        case usage
    }

    let kind: Kind
    let title: String
    let fields: [SessionSummaryFieldPresentation]
}

enum SessionActivityCategory: String, Equatable, Sendable {
    case system
    case context
    case user
    case assistantReasoning
    case assistant
    case tool
    case subagent
    case other

    var tag: String {
        switch self {
        case .system: "SYSTEM"
        case .context: "CONTEXT"
        case .user: "USER"
        case .assistantReasoning: "REASONING"
        case .assistant: "ASSISTANT"
        case .tool: "TOOL"
        case .subagent: "SUBAGENT"
        case .other: "OTHER"
        }
    }
}

struct SessionActivityPresentation: Equatable, Sendable {
    let id: String
    let category: SessionActivityCategory
    let content: String
    let occurredAt: String
    let rawItem: TimelineItem
}

struct SessionPagePresentation: Equatable, Sendable {
    let sessionID: SessionID
    let title: String
    let summarySections: [SessionSummarySectionPresentation]
    let activities: [SessionActivityPresentation]
}

struct SessionActivityWindow: Equatable, Sendable {
    let activities: [SessionActivityPresentation]
    let hiddenCount: Int

    var totalCount: Int { activities.count + hiddenCount }
}

enum SessionActivityWindowPolicy {
    static let initialLimit = 10
    static let batchSize = 50

    static func window(
        activities: [SessionActivityPresentation],
        limit: Int
    ) -> SessionActivityWindow {
        let visibleLimit = min(activities.count, max(0, limit))
        return SessionActivityWindow(
            activities: Array(activities.suffix(visibleLimit)),
            hiddenCount: activities.count - visibleLimit
        )
    }
}

actor SessionPagePresentationRenderer {
    private var cache = SessionPagePresentationBuilder.Cache()

    func presentation(for detail: SessionDetail) -> SessionPagePresentation? {
        guard !Task.isCancelled else { return nil }
        let presentation = cache.presentation(for: detail)
        return Task.isCancelled ? nil : presentation
    }
}

enum SessionPagePresentationBuilder {
    struct Cache {
        private struct CachedActivity {
            let item: TimelineItem
            let presentation: SessionActivityPresentation
        }

        private var sessionID: SessionID?
        private var activitiesByID: [TimelineItemID: CachedActivity] = [:]

        mutating func presentation(for detail: SessionDetail) -> SessionPagePresentation {
            if sessionID != detail.summary.id {
                sessionID = detail.summary.id
                activitiesByID.removeAll(keepingCapacity: true)
            }

            let timeline = detail.timeline.sorted {
                if $0.occurredAt == $1.occurredAt { return $0.id.rawValue < $1.id.rawValue }
                return $0.occurredAt < $1.occurredAt
            }
            var retainedActivityIDs: Set<TimelineItemID> = []
            var activities: [SessionActivityPresentation] = []
            for item in timeline {
                guard SessionPagePresentationBuilder.isActivity(item.payload) else { continue }
                retainedActivityIDs.insert(item.id)
                if let cached = activitiesByID[item.id], cached.item == item {
                    activities.append(cached.presentation)
                } else if let presentation = SessionPagePresentationBuilder.activityPresentation(for: item) {
                    activitiesByID[item.id] = CachedActivity(item: item, presentation: presentation)
                    activities.append(presentation)
                }
            }
            activitiesByID = activitiesByID.filter { retainedActivityIDs.contains($0.key) }

            return SessionPagePresentation(
                sessionID: detail.summary.id,
                title: SessionListRowPresentation(session: detail.summary).title,
                summarySections: SessionPagePresentationBuilder.summarySections(
                    for: detail.summary,
                    timeline: timeline
                ),
                activities: activities
            )
        }
    }

    static func presentation(for detail: SessionDetail) -> SessionPagePresentation {
        var cache = Cache()
        return cache.presentation(for: detail)
    }

    private static func summarySections(
        for summary: SessionSummary,
        timeline: [TimelineItem]
    ) -> [SessionSummarySectionPresentation] {
        var sections = [overviewSection(summary)]
        if let lineage = lineageSection(summary.lineage) {
            sections.append(lineage)
        }
        sections.append(modelConfigurationSection(timeline))
        sections.append(usageSection(timeline))
        return sections
    }

    private static func overviewSection(
        _ summary: SessionSummary
    ) -> SessionSummarySectionPresentation {
        let agent = summary.agent.displayName == summary.agent.rawValue
            ? summary.agent.rawValue
            : "\(summary.agent.displayName) (\(summary.agent.rawValue))"
        return SessionSummarySectionPresentation(
            kind: .overview,
            title: "Overview",
            fields: [
                field("Title", summary.title),
                field("Session ID", summary.id.rawValue),
                field("Agent", agent),
                field("Lifecycle", displayName(summary.lifecycle.displayName, rawValue: summary.lifecycle.rawValue)),
                field("Turn Phase", displayName(summary.phase.displayName, rawValue: summary.phase.rawValue)),
                field("Needs Attention", summary.needsAttention ? "Yes" : "No"),
                field("Workspace", summary.workspace),
                field("Started", date(summary.startedAt)),
                field("Updated", date(summary.updatedAt)),
                field("Last Activity", date(summary.lastActivityAt)),
            ]
        )
    }

    private static func lineageSection(
        _ lineage: SessionLineage?
    ) -> SessionSummarySectionPresentation? {
        guard let lineage else { return nil }
        let fields = [
            lineage.threadSource.map { field("Thread Source", $0) },
            lineage.parentSessionID.map { field("Parent Session ID", $0.rawValue) },
            lineage.subagentDepth.map { field("Subagent Depth", String($0)) },
            lineage.agentNickname.map { field("Agent Nickname", $0) },
            lineage.agentRole.map { field("Agent Role", $0) },
            lineage.agentPath.map { field("Agent Path", $0) },
            lineage.subagentKind.map { field("Subagent Kind", $0) },
        ].compactMap { $0 }
        guard !fields.isEmpty else { return nil }
        return SessionSummarySectionPresentation(kind: .lineage, title: "Lineage", fields: fields)
    }

    private static func modelConfigurationSection(
        _ timeline: [TimelineItem]
    ) -> SessionSummarySectionPresentation {
        let configurations = timeline.compactMap { item -> ModelConfigurationTimelinePayload? in
            guard case let .modelConfiguration(payload) = item.payload else { return nil }
            return payload
        }
        let latest = configurations.last
        let usageContextWindow = timeline.reversed().compactMap { item -> Int64? in
            guard case let .usageMetrics(payload) = item.payload else { return nil }
            return payload.modelContextWindow
        }.first
        return SessionSummarySectionPresentation(
            kind: .modelConfiguration,
            title: "Model Configuration",
            fields: [
                field("Source", latest?.source),
                field("Model", latestNonNil(configurations, \.model)),
                field("Provider", latestNonNil(configurations, \.provider)),
                field(
                    "Context Window",
                    (latestNonNil(configurations, \.contextWindow) ?? usageContextWindow)?.grouped
                ),
                field("Reasoning Effort", latestNonNil(configurations, \.reasoningEffort)),
                field("Client Version", latestNonNil(configurations, \.clientVersion)),
            ]
        )
    }

    private static func usageSection(
        _ timeline: [TimelineItem]
    ) -> SessionSummarySectionPresentation {
        let latest = timeline.reversed().compactMap { item -> UsageMetricsTimelinePayload? in
            guard case let .usageMetrics(payload) = item.payload else { return nil }
            return payload
        }.first
        let usage = latest?.total ?? latest?.last
        return SessionSummarySectionPresentation(
            kind: .usage,
            title: "Usage",
            fields: [
                field("Input", usage?.inputTokens.grouped),
                field("Cached Input", usage?.cachedInputTokens.grouped),
                field("Cache-write", usage?.cacheWriteInputTokens.grouped),
                field("Output", usage?.outputTokens.grouped),
                field("Reasoning Output", usage?.reasoningOutputTokens.grouped),
                field("Total Tokens", usage?.totalTokens.grouped),
            ]
        )
    }

    private static func isActivity(_ payload: TimelinePayload) -> Bool {
        switch payload {
        case .modelConfiguration, .usageMetrics: false
        case .message, .tool, .plan, .subagent, .error, .internalContext, .unknown: true
        }
    }

    private static func activityPresentation(
        for item: TimelineItem
    ) -> SessionActivityPresentation? {
        let category: SessionActivityCategory
        let content: String
        switch item.payload {
        case let .message(payload):
            category = payload.role == .user ? .user : .assistant
            content = payload.text
        case let .tool(payload):
            category = .tool
            content = [payload.name, payload.status.rawValue, payload.summary]
                .compactMap { $0 }
                .joined(separator: " · ")
        case let .subagent(payload):
            category = .subagent
            content = [payload.name, payload.status.rawValue, payload.agentSessionID]
                .compactMap { $0 }
                .joined(separator: " · ")
        case let .internalContext(payload):
            category = contextCategory(for: payload.kind)
            content = "\(humanized(payload.kind)) · \(jsonSummary(payload.content))"
        case let .plan(payload):
            category = .other
            content = payload.explanation ?? "\(payload.steps.count) plan steps"
        case let .error(payload):
            category = .other
            content = "\(payload.title) · \(payload.message)"
        case let .unknown(payload):
            category = .other
            content = payload.summary ?? payload.kind
        case .modelConfiguration, .usageMetrics:
            return nil
        }
        return SessionActivityPresentation(
            id: "activity:\(item.sessionID.rawValue):\(item.id.rawValue)",
            category: category,
            content: oneLine(content, maximumCharacters: 320),
            occurredAt: item.occurredAt.formatted(date: .omitted, time: .standard),
            rawItem: item
        )
    }

    static func rawData(for item: TimelineItem) -> String {
        prettyJSON(item)
    }

    private static func contextCategory(for kind: String) -> SessionActivityCategory {
        let normalized = kind.lowercased()
        if normalized.contains("reasoning") { return .assistantReasoning }
        if normalized.contains("instruction") || normalized == "system" { return .system }
        return .context
    }

    private static func jsonSummary(_ value: JSONValue) -> String {
        switch value {
        case let .string(value): return value
        case let .object(value):
            for key in ["text", "message", "summary", "type", "kind"] {
                if case let .string(candidate)? = value[key] { return candidate }
            }
            return value.keys.sorted().prefix(6).joined(separator: ", ")
        case let .array(value): return "\(value.count) items"
        case let .number(value): return String(describing: value)
        case let .boolean(value): return value ? "true" : "false"
        case .null: return "null"
        }
    }

    private static func oneLine(_ value: String, maximumCharacters: Int) -> String {
        var result = ""
        result.reserveCapacity(min(value.count, maximumCharacters))
        var previousWasWhitespace = false
        var didTruncate = false
        for character in value {
            if character.isWhitespace {
                if !previousWasWhitespace && !result.isEmpty { result.append(" ") }
                previousWasWhitespace = true
            } else {
                result.append(character)
                previousWasWhitespace = false
            }
            if result.count >= maximumCharacters {
                didTruncate = true
                break
            }
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return didTruncate ? trimmed + "…" : trimmed
    }

    private static func prettyJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let result = String(data: data, encoding: .utf8) else {
            return "Unable to render raw data"
        }
        return result
    }

    private static func latestNonNil<Value>(
        _ configurations: [ModelConfigurationTimelinePayload],
        _ keyPath: KeyPath<ModelConfigurationTimelinePayload, Value?>
    ) -> Value? {
        configurations.reversed().compactMap { $0[keyPath: keyPath] }.first
    }

    private static func field(_ label: String, _ value: String?) -> SessionSummaryFieldPresentation {
        SessionSummaryFieldPresentation(label: label, value: value ?? "Not available")
    }

    private static func displayName(_ displayName: String, rawValue: String) -> String {
        displayName.lowercased() == rawValue.lowercased()
            ? displayName
            : "\(displayName) (\(rawValue))"
    }

    private static func humanized(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func date(_ value: Date) -> String {
        value.formatted(date: .abbreviated, time: .standard)
    }
}

private extension Int64 {
    var grouped: String { formatted(.number.grouping(.automatic)) }
}
