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
    var isMonospaced = false
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

/// Row-level presentation is `TimelineRow` (Transport) plus display strings.
/// Tag / level / lane / status all come from the projection.
/// Activity timeline density: three lanes or one line.
enum ActivityTimelineMode: String, Equatable, Sendable {
    case lanes
    case single

    var toggled: ActivityTimelineMode { self == .lanes ? .single : .lanes }
}

/// Header metrics derived from usage and timing; no extra data source.
struct SessionMetricsPresentation: Equatable, Sendable {
    let totalTokens: Int64?
    let contextFraction: Double?
    let startedAt: Date
    /// `nil` while the Session is still live; the elapsed value keeps ticking.
    let endedAt: Date?

    var totalTokensText: String {
        guard let totalTokens else { return "—" }
        if totalTokens >= 1_000_000 {
            return totalTokens.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        }
        return totalTokens.formatted(.number.grouping(.automatic))
    }

    var contextText: String {
        guard let contextFraction else { return "—" }
        return "\(Int((contextFraction * 100).rounded()))%"
    }

    func elapsedText(now: Date) -> String {
        SessionElapsedFormatter.string(from: max(0, (endedAt ?? now).timeIntervalSince(startedAt)))
    }
}

/// `now` / `12s` / `4m` / `1h` / `yesterday` / `3d` for the Sessions list.
enum SessionRelativeTimeFormatter {
    static func string(from date: Date, now: Date = .now) -> String {
        let interval = max(0, now.timeIntervalSince(date))
        let seconds = Int(interval)
        if seconds < 10 { return "now" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        if seconds < 172_800 { return "yesterday" }
        return "\(seconds / 86_400)d"
    }
}

enum SessionElapsedFormatter {
    /// `12s` / `3m 43s` / `1h 02m` / `2d 03h`.
    static func string(from interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.down))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if days > 0 { return String(format: "%dd %02dh", days, hours) }
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}

struct SessionActivityPresentation: Equatable, Sendable, Identifiable {
    let id: String
    let row: TimelineRow
    /// One-lined, capped body text for the row.
    let content: String
    let occurredAt: String

    var tag: TimelineTag { row.tag }
    var label: String { row.label }
    var level: TimelineAttentionLevel { row.level }
    var lane: TimelineLane? { row.lane }
    var status: TimelineRowStatus { row.status }
    var toolUseID: String? { row.toolUseID }
    var turnID: TurnID? { row.turnID }
    /// Anchor item for the raw-JSON inspector; merged rows expose all items.
    var rawItem: TimelineItem { row.anchor }
    var rawItems: [TimelineItem] { row.items }
}

struct SessionPagePresentation: Equatable, Sendable {
    let sessionID: SessionID
    let title: String
    let summarySections: [SessionSummarySectionPresentation]
    let metrics: SessionMetricsPresentation
    let activities: [SessionActivityPresentation]
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
            let row: TimelineRow
            let presentation: SessionActivityPresentation
        }

        private var sessionID: SessionID?
        private var activitiesByID: [String: CachedActivity] = [:]

        mutating func presentation(for detail: SessionDetail) -> SessionPagePresentation {
            if sessionID != detail.summary.id {
                sessionID = detail.summary.id
                activitiesByID.removeAll(keepingCapacity: true)
            }

            let timeline = detail.timeline.sorted {
                if $0.occurredAt == $1.occurredAt { return $0.id.rawValue < $1.id.rawValue }
                return $0.occurredAt < $1.occurredAt
            }
            let rows = TimelineProjection.rows(from: timeline)
            var retainedIDs: Set<String> = []
            var activities: [SessionActivityPresentation] = []
            activities.reserveCapacity(rows.count)
            for row in rows {
                retainedIDs.insert(row.id)
                if let cached = activitiesByID[row.id], cached.row == row {
                    activities.append(cached.presentation)
                } else {
                    let presentation = SessionPagePresentationBuilder.activityPresentation(for: row)
                    activitiesByID[row.id] = CachedActivity(row: row, presentation: presentation)
                    activities.append(presentation)
                }
            }
            activitiesByID = activitiesByID.filter { retainedIDs.contains($0.key) }

            return SessionPagePresentation(
                sessionID: detail.summary.id,
                title: SessionListRowPresentation(session: detail.summary).title,
                summarySections: SessionPagePresentationBuilder.summarySections(
                    for: detail.summary,
                    timeline: timeline
                ),
                metrics: SessionPagePresentationBuilder.metrics(for: detail.summary, timeline: timeline),
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
                field("Session ID", summary.id.rawValue, monospaced: true),
                field("Agent", agent),
                field("Lifecycle", summary.lifecycle.displayName),
                field("Turn Phase", summary.phase.displayName),
                field("Needs Attention", summary.needsAttention ? "Yes" : "No"),
                field("Started", date(summary.startedAt), monospaced: true),
            ]
        )
    }

    private static func lineageSection(
        _ lineage: SessionLineage?
    ) -> SessionSummarySectionPresentation? {
        guard let lineage else { return nil }
        let fields = [
            lineage.threadSource.map { field("Thread Source", $0) },
            lineage.subagentDepth.map { field("Subagent Depth", String($0), monospaced: true) },
            lineage.agentNickname.map { field("Agent Nickname", $0) },
            lineage.agentRole.map { field("Agent Role", $0) },
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
        let usageContextWindow = timeline.reversed().compactMap { item -> Int64? in
            guard case let .usageMetrics(payload) = item.payload else { return nil }
            return payload.modelContextWindow
        }.first
        return SessionSummarySectionPresentation(
            kind: .modelConfiguration,
            title: "Model",
            fields: [
                field("Model", latestNonNil(configurations, \.model)),
                field("Provider", latestNonNil(configurations, \.provider)),
                field(
                    "Context Window",
                    (latestNonNil(configurations, \.contextWindow) ?? usageContextWindow)?.grouped,
                    monospaced: true
                ),
                field("Reasoning Effort", latestNonNil(configurations, \.reasoningEffort)),
                field("Client Version", latestNonNil(configurations, \.clientVersion), monospaced: true),
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
                field("Input", usage?.inputTokens.grouped, monospaced: true),
                field("Cached Input", usage?.cachedInputTokens.grouped, monospaced: true),
                field("Cache-write", usage?.cacheWriteInputTokens.grouped, monospaced: true),
                field("Output", usage?.outputTokens.grouped, monospaced: true),
                field("Reasoning Output", usage?.reasoningOutputTokens.grouped, monospaced: true),
                field("Total Tokens", usage?.totalTokens.grouped, monospaced: true),
            ]
        )
    }

    static func metrics(
        for summary: SessionSummary,
        timeline: [TimelineItem]
    ) -> SessionMetricsPresentation {
        let latestUsage = timeline.reversed().compactMap { item -> UsageMetricsTimelinePayload? in
            guard case let .usageMetrics(payload) = item.payload else { return nil }
            return payload
        }.first
        let configuredWindow = timeline.reversed().compactMap { item -> Int64? in
            guard case let .modelConfiguration(payload) = item.payload else { return nil }
            return payload.contextWindow
        }.first
        let contextWindow = latestUsage?.modelContextWindow ?? configuredWindow
        let contextUsage = latestUsage?.last ?? latestUsage?.total
        let fraction: Double? = if let contextWindow, contextWindow > 0, let used = contextUsage?.totalTokens {
            min(1, Double(used) / Double(contextWindow))
        } else {
            nil
        }
        let endedAt: Date? = summary.lifecycle.isLive ? nil : summary.lastActivityAt
        return SessionMetricsPresentation(
            totalTokens: (latestUsage?.total ?? latestUsage?.last)?.totalTokens,
            contextFraction: fraction,
            startedAt: summary.startedAt,
            endedAt: endedAt
        )
    }

    static func activityPresentation(for row: TimelineRow) -> SessionActivityPresentation {
        SessionActivityPresentation(
            id: "activity:\(row.id)",
            row: row,
            content: oneLine(row.text, maximumCharacters: 320),
            occurredAt: row.occurredAt.formatted(date: .omitted, time: .standard)
        )
    }

    static func rawData(for item: TimelineItem) -> String {
        prettyJSON(item)
    }

    static func rawData(for items: [TimelineItem]) -> String {
        items.count == 1 ? prettyJSON(items[0]) : prettyJSON(items)
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

    private static func field(
        _ label: String,
        _ value: String?,
        monospaced: Bool = false
    ) -> SessionSummaryFieldPresentation {
        SessionSummaryFieldPresentation(
            label: label,
            value: value ?? "Not available",
            isMonospaced: monospaced && value != nil
        )
    }

    private static func humanized(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func date(_ value: Date) -> String {
        value.formatted(date: .abbreviated, time: .standard)
    }

    /// `~/dev/agent-status` style workspace for the header.
    static func abbreviatedWorkspace(_ workspace: String?) -> String? {
        guard let workspace, !workspace.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if workspace == home { return "~" }
        if workspace.hasPrefix(home + "/") {
            return "~" + workspace.dropFirst(home.count)
        }
        return workspace
    }
}

private extension Int64 {
    var grouped: String { formatted(.number.grouping(.automatic)) }
}
