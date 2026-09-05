import Core
import Transport
import AppKit
import Foundation

/// Columns and rows of the Detail table for one grouping. Every figure
/// comes from the report's own slices; nothing is re-aggregated here except
/// the choice of which slices to show. Every grouping shows a subset of one
/// column order: Sessions · Turns · Input · Cache read · Cache write ·
/// Output · Cache ratio · Tokens · Cost · Last active.
@MainActor
struct UsageDetailRows {
    let columns: [UsageColumn]
    let rows: [UsageTableRow]
    /// `32.9M tokens across 1 model have no published price …`, when any.
    let footnote: String?

    static let dash = "—"

    static func build(report: UsageReport, group: UsageDetailGroup, timeUnit: UsageDetailTimeUnit, calendar: Calendar) -> UsageDetailRows {
        let (columns, rows) = switch group {
        case .project: project(report)
        case .agent: agent(report)
        case .time: time(report, unit: timeUnit, calendar: calendar)
        case .model: model(report)
        }
        return UsageDetailRows(columns: columns, rows: rows, footnote: footnote(report))
    }

    // MARK: Groupings

    private static func project(_ report: UsageReport) -> ([UsageColumn], [UsageTableRow]) {
        let columns = [
            UsageColumn(title: "Project", width: nil),
            UsageColumn(title: "Sessions", width: 72),
            UsageColumn(title: "Turns", width: 64),
            UsageColumn(title: "Cache ratio", width: 80),
            UsageColumn(title: "Tokens", width: 84),
            UsageColumn(title: "Cost", width: 84),
            UsageColumn(title: "Last active", width: 92),
        ]
        let rows = report.byProject.map { slice in
            let workspace = slice.workspace ?? ""
            return UsageTableRow(
                id: "project/\(workspace)",
                cells: [
                    UsageCell(
                        text: UsageFormatting.projectName(workspace),
                        secondary: UsageFormatting.projectPath(workspace),
                        help: workspace.isEmpty ? nil : workspace
                    ),
                    count(slice.sessions),
                    count(slice.turns),
                    cacheRatio(slice.tokens),
                    tokens(slice.tokens.total),
                    cost(slice.costUSD),
                    UsageCell(text: slice.lastDay.map { UsageFormatting.dayLabel($0) } ?? dash, isDimmed: slice.lastDay == nil),
                ],
                sortKeys: [
                    .text(UsageFormatting.projectName(workspace).lowercased()),
                    .number(Double(slice.sessions)),
                    .number(Double(slice.turns)),
                    ratioKey(slice.tokens),
                    .number(Double(slice.tokens.total)),
                    costKey(slice.costUSD),
                    .text(slice.lastDay?.rawValue ?? ""),
                ]
            )
        }
        return (columns, rows)
    }

    private static func agent(_ report: UsageReport) -> ([UsageColumn], [UsageTableRow]) {
        let columns = [
            UsageColumn(title: "Agent · Model", width: nil),
            UsageColumn(title: "Input", width: 84),
            UsageColumn(title: "Cache read", width: 92),
            UsageColumn(title: "Cache write", width: 92),
            UsageColumn(title: "Output", width: 84),
            UsageColumn(title: "Cache ratio", width: 80),
            UsageColumn(title: "Tokens", width: 84),
            UsageColumn(title: "Cost", width: 84),
        ]
        func figures(_ slice: UsageSlice) -> [UsageCell] {
            let tokens = slice.tokens
            return [
                Self.tokens(tokens.input), Self.tokens(tokens.cacheRead), Self.tokens(tokens.cacheWrite), Self.tokens(tokens.output),
                cacheRatio(tokens),
                Self.tokens(tokens.total),
                cost(slice.costUSD),
            ]
        }
        func keys(_ slice: UsageSlice) -> [UsageSortKey] {
            let tokens = slice.tokens
            return [
                .number(Double(tokens.input)), .number(Double(tokens.cacheRead)), .number(Double(tokens.cacheWrite)), .number(Double(tokens.output)),
                ratioKey(tokens),
                .number(Double(tokens.total)),
                costKey(slice.costUSD),
            ]
        }
        var rows: [UsageTableRow] = []
        for agent in report.byAgent {
            guard let provider = agent.agent else { continue }
            let groupID = provider.rawValue
            let name = UsageSummaryAgent(provider).title
            rows.append(UsageTableRow(
                id: groupID,
                cells: [UsageCell(text: name, icon: AgentIcons.image(for: AgentKind.forProvider(provider), pointSize: 13))] + figures(agent),
                sortKeys: [.text(name.lowercased())] + keys(agent),
                isEmphasized: true,
                isGroup: true
            ))
            for slice in report.byModel where slice.agent == provider {
                let model = slice.model ?? ""
                rows.append(UsageTableRow(
                    id: "\(groupID)/\(model)",
                    cells: [UsageCell(
                        text: model.isEmpty ? "Unknown model" : model,
                        help: slice.costUSD == nil ? "No published price for this model" : nil
                    )] + figures(slice),
                    sortKeys: [.text(model.lowercased())] + keys(slice),
                    groupID: groupID
                ))
            }
        }
        rows.append(UsageTableRow(
            id: "total",
            cells: [UsageCell(text: "Total")] + figures(report.totals),
            sortKeys: [],
            isEmphasized: true,
            isPinned: true
        ))
        return (columns, rows)
    }

    private static func time(_ report: UsageReport, unit: UsageDetailTimeUnit, calendar: Calendar) -> ([UsageColumn], [UsageTableRow]) {
        let columns = [
            UsageColumn(title: unit.title, width: nil),
            UsageColumn(title: "Sessions", width: 72),
            UsageColumn(title: "Turns", width: 64),
            UsageColumn(title: "Input", width: 84),
            UsageColumn(title: "Cache read", width: 92),
            UsageColumn(title: "Output", width: 84),
            UsageColumn(title: "Tokens", width: 84),
            UsageColumn(title: "Cost", width: 84),
        ]
        let slices = switch unit {
        case .day: report.byDay
        case .week: report.byWeek
        case .month: report.byMonth
        }
        // Newest first; periods without a call never make a row.
        let rows = slices.reversed().compactMap { slice -> UsageTableRow? in
            guard let period = slice.period else { return nil }
            let tokens = slice.tokens
            return UsageTableRow(
                id: "time/\(UsageTrend.barID(period))",
                cells: [
                    UsageCell(text: UsageFormatting.periodLabel(period, calendar: calendar)),
                    count(slice.sessions), count(slice.turns),
                    Self.tokens(tokens.input), Self.tokens(tokens.cacheRead), Self.tokens(tokens.output), Self.tokens(tokens.total),
                    cost(slice.costUSD),
                ],
                sortKeys: [
                    .text(period.start.rawValue),
                    .number(Double(slice.sessions)), .number(Double(slice.turns)),
                    .number(Double(tokens.input)), .number(Double(tokens.cacheRead)), .number(Double(tokens.output)), .number(Double(tokens.total)),
                    costKey(slice.costUSD),
                ]
            )
        }
        return (columns, rows)
    }

    private static func model(_ report: UsageReport) -> ([UsageColumn], [UsageTableRow]) {
        let columns = [
            UsageColumn(title: "Model", width: nil),
            UsageColumn(title: "Input", width: 84),
            UsageColumn(title: "Cache read", width: 92),
            UsageColumn(title: "Output", width: 84),
            UsageColumn(title: "Cache ratio", width: 80),
            UsageColumn(title: "Tokens", width: 84),
            UsageColumn(title: "Cost", width: 84),
        ]
        let rows = report.byModel.map { slice in
            let model = slice.model ?? ""
            let tokens = slice.tokens
            let provider = slice.agent.map { AgentKind.forProvider($0) }
            return UsageTableRow(
                id: "model/\(slice.agent?.rawValue ?? "")/\(model)",
                cells: [
                    UsageCell(
                        text: model.isEmpty ? "Unknown model" : model,
                        icon: provider.flatMap { AgentIcons.image(for: $0, pointSize: 13) },
                        help: slice.costUSD == nil ? "No published price for this model" : nil
                    ),
                    Self.tokens(tokens.input), Self.tokens(tokens.cacheRead), Self.tokens(tokens.output),
                    cacheRatio(tokens),
                    Self.tokens(tokens.total),
                    cost(slice.costUSD),
                ],
                sortKeys: [
                    .text(model.lowercased()),
                    .number(Double(tokens.input)), .number(Double(tokens.cacheRead)), .number(Double(tokens.output)),
                    ratioKey(tokens),
                    .number(Double(tokens.total)),
                    costKey(slice.costUSD),
                ]
            )
        }
        return (columns, rows)
    }

    // MARK: Cells

    static func footnote(_ report: UsageReport) -> String? {
        guard report.totals.unpricedTokens > 0 else { return nil }
        let models = report.byModel.filter { $0.unpricedTokens > 0 }.count
        let tokens = UsageFormatting.tokens(report.totals.unpricedTokens)
        return "\(tokens) tokens across \(models) model\(models == 1 ? "" : "s") have no published price and are not in any cost."
    }

    private static func count(_ value: Int) -> UsageCell {
        UsageCell(text: UsageFormatting.count(value))
    }

    private static func tokens(_ value: Int64) -> UsageCell {
        UsageCell(text: UsageFormatting.tokens(value), help: UsageFormatting.exactTokens(value))
    }

    private static func cost(_ value: Double?) -> UsageCell {
        UsageCell(text: UsageFormatting.cost(value), isDimmed: value == nil)
    }

    private static func cacheRatio(_ tokens: UsageTokens) -> UsageCell {
        UsageCell(text: UsageFormatting.cacheRatio(tokens), help: "Cache read ÷ total tokens", isDimmed: tokens.total == 0)
    }

    /// Unpriced sorts as −1: always last under a descending cost sort.
    private static func costKey(_ value: Double?) -> UsageSortKey { .number(value ?? -1) }

    private static func ratioKey(_ tokens: UsageTokens) -> UsageSortKey {
        .number(tokens.total > 0 ? Double(tokens.cacheRead) / Double(tokens.total) : -1)
    }
}
