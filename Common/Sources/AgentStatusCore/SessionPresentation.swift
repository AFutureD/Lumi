import AgentStatusTransport
import Foundation

// Session presentation shared by the Mac window, the Notch and the iPhone:
// display names, relative / elapsed time, the detail page (metrics, Info
// groups, Activity rows). Pure; built from one `SessionDetail`. Surfaces add
// only their own layout on top.

// MARK: - Display names

public extension AgentKind {
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .codexSubagent: "Codex Subagent"
        case .claude: "Claude"
        case .claudeSubagent: "Claude Subagent"
        }
    }

    /// Short chip label ("Codex" / "Claude"), same for parent and subagent.
    var providerName: String {
        switch provider {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

public extension SessionLifecycle {
    var displayName: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

public extension TurnPhase {
    var displayName: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

// MARK: - Time

/// `now` / `12s` / `4m` / `1h` / `3d` — one unit, no words, for session lists.
public enum SessionRelativeTimeFormatter {
    public static func string(from date: Date, now: Date = .now) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 10 { return "now" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }
}

public enum SessionElapsedFormatter {
    /// `12s` / `3m 43s` / `1h 02m` / `2d 03h`.
    public static func string(from interval: TimeInterval) -> String {
        let total = Int(max(0, interval).rounded(.down))
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

// MARK: - List row

public struct SessionListRowPresentation: Equatable, Sendable {
    public let title: String
    public let agent: String
    /// `Running · Responding` — display lifecycle · phase.
    public let status: String
    /// Part of the row diff: `needsReview` changes the tone without changing
    /// the status text (green ⇄ gray), so text alone under-reports changes.
    public let tone: SessionStatusTone

    public init(session: SessionSummary) {
        title = SessionListRowPresentation.normalizedTitle(session.title)
        agent = session.agent.displayName
        status = "\(session.displayLifecycle.displayName) · \(session.phase.displayName)"
        tone = session.statusTone
    }

    /// Whitespace runs collapsed to one space.
    public static func normalizedTitle(_ title: String) -> String {
        title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - Detail page

public struct SessionSummaryFieldPresentation: Hashable, Sendable {
    public let label: String
    public let value: String
    public var isMonospaced = false

    public init(label: String, value: String, isMonospaced: Bool = false) {
        self.label = label
        self.value = value
        self.isMonospaced = isMonospaced
    }
}

public struct SessionSummarySectionPresentation: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case overview
        case lineage
        case modelConfiguration
        case usage
    }

    public let kind: Kind
    public let title: String
    public let fields: [SessionSummaryFieldPresentation]

    public init(kind: Kind, title: String, fields: [SessionSummaryFieldPresentation]) {
        self.kind = kind
        self.title = title
        self.fields = fields
    }

    public var id: String { kind.rawValue }
}

/// Header metrics derived from usage and timing; no extra data source.
public struct SessionMetricsPresentation: Equatable, Sendable {
    public let totalTokens: Int64?
    public let contextFraction: Double?
    public let startedAt: Date
    /// `nil` while the Session is still live; the elapsed value keeps ticking.
    public let endedAt: Date?

    public init(totalTokens: Int64?, contextFraction: Double?, startedAt: Date, endedAt: Date?) {
        self.totalTokens = totalTokens
        self.contextFraction = contextFraction
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public var totalTokensText: String {
        guard let totalTokens else { return "—" }
        if totalTokens >= 1_000_000 {
            return totalTokens.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        }
        return totalTokens.formatted(.number.grouping(.automatic))
    }

    public var contextText: String {
        guard let contextFraction else { return "—" }
        return "\(Int((contextFraction * 100).rounded()))%"
    }

    public func elapsedText(now: Date) -> String {
        SessionElapsedFormatter.string(from: max(0, (endedAt ?? now).timeIntervalSince(startedAt)))
    }
}

/// Row-level presentation is `TimelineRow` (Transport) plus display strings.
/// Tag / level / lane / status all come from the projection.
public struct SessionActivityPresentation: Hashable, Sendable, Identifiable {
    public let id: String
    public let row: TimelineRow
    /// One-lined, capped body text for the row.
    public let content: String
    /// `10:02:11`.
    public let occurredAt: String

    public init(id: String, row: TimelineRow, content: String, occurredAt: String) {
        self.id = id
        self.row = row
        self.content = content
        self.occurredAt = occurredAt
    }

    public var tag: TimelineTag { row.tag }
    public var label: String { row.label }
    public var level: TimelineAttentionLevel { row.level }
    public var lane: TimelineLane? { row.lane }
    public var status: TimelineRowStatus { row.status }
    public var toolUseID: String? { row.toolUseID }
    public var turnID: TurnID? { row.turnID }
    /// Anchor item for the raw-JSON inspector; merged rows expose all items.
    public var rawItem: TimelineItem { row.anchor }
    public var rawItems: [TimelineItem] { row.items }
    public var isFailed: Bool { row.tag == .failed || row.tag == .turnFailed || row.tag == .aborted }
}

public struct SessionPagePresentation: Equatable, Sendable {
    public let sessionID: SessionID
    public let title: String
    public let summarySections: [SessionSummarySectionPresentation]
    public let metrics: SessionMetricsPresentation
    public let activities: [SessionActivityPresentation]

    public init(
        sessionID: SessionID,
        title: String,
        summarySections: [SessionSummarySectionPresentation],
        metrics: SessionMetricsPresentation,
        activities: [SessionActivityPresentation]
    ) {
        self.sessionID = sessionID
        self.title = title
        self.summarySections = summarySections
        self.metrics = metrics
        self.activities = activities
    }
}

/// Off-main-thread renderer with a per-session row cache.
public actor SessionPagePresentationRenderer {
    private var cache = SessionPagePresentationBuilder.Cache()

    public init() {}

    public func presentation(for detail: SessionDetail) -> SessionPagePresentation? {
        guard !Task.isCancelled else { return nil }
        let presentation = cache.presentation(for: detail)
        return Task.isCancelled ? nil : presentation
    }
}

public enum SessionPagePresentationBuilder {
    public struct Cache: Sendable {
        private struct CachedActivity: Sendable {
            let row: TimelineRow
            let presentation: SessionActivityPresentation
        }

        private var sessionID: SessionID?
        private var activitiesByID: [String: CachedActivity] = [:]

        public init() {}

        public mutating func presentation(for detail: SessionDetail) -> SessionPagePresentation {
            if sessionID != detail.summary.id {
                sessionID = detail.summary.id
                activitiesByID.removeAll(keepingCapacity: true)
            }

            let timeline = SessionPagePresentationBuilder.sortedTimeline(detail.timeline)
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
                summarySections: SessionPagePresentationBuilder.summarySections(for: detail.summary, timeline: timeline),
                metrics: SessionPagePresentationBuilder.metrics(for: detail.summary, timeline: timeline),
                activities: activities
            )
        }
    }

    public static func presentation(for detail: SessionDetail) -> SessionPagePresentation {
        var cache = Cache()
        return cache.presentation(for: detail)
    }

    static func sortedTimeline(_ timeline: [TimelineItem]) -> [TimelineItem] {
        timeline.sorted {
            if $0.occurredAt == $1.occurredAt { return $0.id.rawValue < $1.id.rawValue }
            return $0.occurredAt < $1.occurredAt
        }
    }

    // MARK: Info groups

    public static func summarySections(
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

    private static func overviewSection(_ summary: SessionSummary) -> SessionSummarySectionPresentation {
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

    private static func lineageSection(_ lineage: SessionLineage?) -> SessionSummarySectionPresentation? {
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

    private static func modelConfigurationSection(_ timeline: [TimelineItem]) -> SessionSummarySectionPresentation {
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

    private static func usageSection(_ timeline: [TimelineItem]) -> SessionSummarySectionPresentation {
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

    // MARK: Metrics

    public static func metrics(for summary: SessionSummary, timeline: [TimelineItem]) -> SessionMetricsPresentation {
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
        return SessionMetricsPresentation(
            totalTokens: (latestUsage?.total ?? latestUsage?.last)?.totalTokens,
            contextFraction: fraction,
            startedAt: summary.startedAt,
            endedAt: summary.lifecycle.isLive ? nil : summary.lastActivityAt
        )
    }

    // MARK: Rows

    public static func activityPresentation(for row: TimelineRow) -> SessionActivityPresentation {
        SessionActivityPresentation(
            id: "activity:\(row.id)",
            row: row,
            content: oneLine(row.text, maximumCharacters: 320),
            occurredAt: row.occurredAt.formatted(date: .omitted, time: .standard)
        )
    }

    public static func rawData(for item: TimelineItem) -> String {
        prettyJSON(item)
    }

    public static func rawData(for items: [TimelineItem]) -> String {
        items.count == 1 ? prettyJSON(items[0]) : prettyJSON(items)
    }

    /// Whitespace-collapsed, capped one-liner.
    public static func oneLine(_ value: String, maximumCharacters: Int) -> String {
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

    /// `~/dev/agent-status` style workspace for headers. With `home` the
    /// exact home directory is folded; without it any `/Users/<name>` prefix
    /// is (the iPhone cannot know the Mac's home).
    public static func abbreviatedWorkspace(_ workspace: String?, home: String? = nil) -> String? {
        guard let workspace, !workspace.isEmpty else { return nil }
        if let home {
            if workspace == home { return "~" }
            if workspace.hasPrefix(home + "/") { return "~" + workspace.dropFirst(home.count) }
            return workspace
        }
        let parts = workspace.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].isEmpty, parts[1] == "Users", !parts[2].isEmpty else {
            return workspace
        }
        let rest = parts.dropFirst(3)
        return rest.isEmpty ? "~" : "~/" + rest.joined(separator: "/")
    }

    // MARK: Helpers

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

    private static func field(_ label: String, _ value: String?, monospaced: Bool = false) -> SessionSummaryFieldPresentation {
        SessionSummaryFieldPresentation(
            label: label,
            value: value ?? "Not available",
            isMonospaced: monospaced && value != nil
        )
    }

    private static func date(_ value: Date) -> String {
        value.formatted(date: .abbreviated, time: .standard)
    }
}

private extension Int64 {
    var grouped: String { formatted(.number.grouping(.automatic)) }
}
