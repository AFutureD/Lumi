import Core
import Transport
import AppKit
import Foundation

/// The figure columns of the Detail table, in the one order every grouping
/// follows: a grouping shows a subset of these after its name column.
enum UsageFigure: CaseIterable {
    case sessions, turns, input, cacheRead, cacheWrite, output, cacheRatio, tokens, cost, lastActive

    var column: UsageColumn {
        switch self {
        case .sessions: UsageColumn(title: "Sessions", width: 72)
        case .turns: UsageColumn(title: "Turns", width: 64)
        case .input: UsageColumn(title: "Input", width: 84)
        case .cacheRead: UsageColumn(title: "Cache read", width: 92)
        case .cacheWrite: UsageColumn(title: "Cache write", width: 92)
        case .output: UsageColumn(title: "Output", width: 84)
        case .cacheRatio: UsageColumn(title: "Cache ratio", width: 80)
        case .tokens: UsageColumn(title: "Tokens", width: 84)
        case .cost: UsageColumn(title: "Cost", width: 84)
        case .lastActive: UsageColumn(title: "Last active", width: 92)
        }
    }

    func cell(_ slice: UsageSlice) -> UsageCell {
        let tokens = slice.tokens
        switch self {
        case .sessions: return count(slice.sessions)
        case .turns: return count(slice.turns)
        case .input: return Self.tokens(tokens.input)
        case .cacheRead: return Self.tokens(tokens.cacheRead)
        case .cacheWrite: return Self.tokens(tokens.cacheWrite)
        case .output: return Self.tokens(tokens.output)
        case .tokens: return Self.tokens(tokens.total)
        case .cacheRatio:
            return UsageCell(
                text: UsageFormatting.cacheRatio(tokens), help: "Cache read ÷ total tokens", isDimmed: tokens.total == 0,
                sortKey: .number(tokens.total > 0 ? Double(tokens.cacheRead) / Double(tokens.total) : -1)
            )
        case .cost:
            // Unpriced sorts as −1: always last under a descending cost sort.
            return UsageCell(text: UsageFormatting.cost(slice.costUSD), isDimmed: slice.costUSD == nil, sortKey: .number(slice.costUSD ?? -1))
        case .lastActive:
            return UsageCell(
                text: slice.lastDay.map { UsageFormatting.dayLabel($0) } ?? UsageFormatting.dash,
                isDimmed: slice.lastDay == nil,
                sortKey: .text(slice.lastDay?.rawValue ?? "")
            )
        }
    }

    private func count(_ value: Int) -> UsageCell {
        UsageCell(text: UsageFormatting.count(value), sortKey: .number(Double(value)))
    }

    private static func tokens(_ value: Int64) -> UsageCell {
        UsageCell(text: UsageFormatting.tokens(value), help: UsageFormatting.exactTokens(value), sortKey: .number(Double(value)))
    }
}

/// Columns and rows of the Detail table for one grouping. Every figure
/// comes from the report's own slices; nothing is re-aggregated here except
/// the choice of which slices to show.
@MainActor
struct UsageDetailRows {
    let columns: [UsageColumn]
    let rows: [UsageTableRow]
    /// `32.9M tokens across 1 model have no published price …`, when any.
    let footnote: String?

    static func build(report: UsageReport, group: UsageDetailGroup, timeUnit: UsageDetailTimeUnit, calendar: Calendar) -> UsageDetailRows {
        let (name, figures, rows): (String, [UsageFigure], [UsageTableRow]) = switch group {
        case .project: ("Project", [.sessions, .turns, .cacheRatio, .tokens, .cost, .lastActive], project(report))
        case .agent: ("Agent · Model", [.input, .cacheRead, .cacheWrite, .output, .cacheRatio, .tokens, .cost], agent(report))
        case .time: (timeUnit.title, [.sessions, .turns, .input, .cacheRead, .output, .tokens, .cost], time(report, unit: timeUnit, calendar: calendar))
        case .model: ("Model", [.input, .cacheRead, .output, .cacheRatio, .tokens, .cost], model(report))
        }
        return UsageDetailRows(
            columns: [UsageColumn(title: name, width: nil)] + figures.map(\.column),
            rows: rows.map { row in
                var row = row
                row.cells = [row.cells[0]] + figures.map { $0.cell(row.slice) }
                return row
            },
            footnote: footnote(report)
        )
    }

    // MARK: Groupings — each yields rows with only their name cell; the figures follow the grouping's list.

    private static func project(_ report: UsageReport) -> [UsageTableRow] {
        report.byProject.map { slice in
            let workspace = slice.workspace ?? ""
            let name = UsageFormatting.projectName(workspace)
            return UsageTableRow(id: "project/\(workspace)", slice: slice, name: UsageCell(
                text: name,
                secondary: SessionPagePresentationBuilder.abbreviatedWorkspace(workspace),
                help: workspace.isEmpty ? nil : workspace,
                sortKey: .text(name.lowercased())
            ))
        }
    }

    private static func agent(_ report: UsageReport) -> [UsageTableRow] {
        var rows: [UsageTableRow] = []
        for agent in report.byAgent {
            guard let provider = agent.agent else { continue }
            let groupID = provider.rawValue
            let name = UsageSummaryAgent(provider).title
            rows.append(UsageTableRow(
                id: groupID, slice: agent,
                name: UsageCell(text: name, icon: AgentIcons.image(for: provider.kind, pointSize: 13), sortKey: .text(name.lowercased())),
                isEmphasized: true, isGroup: true
            ))
            for slice in report.byModel where slice.agent == provider {
                rows.append(UsageTableRow(id: "\(groupID)/\(slice.model ?? "")", slice: slice, name: modelName(slice), groupID: groupID))
            }
        }
        rows.append(UsageTableRow(id: "total", slice: report.totals, name: UsageCell(text: "Total"), isEmphasized: true, isPinned: true))
        return rows
    }

    private static func time(_ report: UsageReport, unit: UsageDetailTimeUnit, calendar: Calendar) -> [UsageTableRow] {
        let slices = switch unit {
        case .day: report.byDay
        case .week: report.byWeek
        case .month: report.byMonth
        }
        // Newest first; periods without a call never make a row.
        return slices.reversed().compactMap { slice in
            guard let period = slice.period else { return nil }
            return UsageTableRow(id: "time/\(UsageTrend.barID(period))", slice: slice, name: UsageCell(
                text: UsageFormatting.periodLabel(period, calendar: calendar), sortKey: .text(period.start.rawValue)
            ))
        }
    }

    private static func model(_ report: UsageReport) -> [UsageTableRow] {
        report.byModel.map { slice in
            var name = modelName(slice)
            name.icon = slice.agent.flatMap { AgentIcons.image(for: $0.kind, pointSize: 13) }
            return UsageTableRow(id: "model/\(slice.agent?.rawValue ?? "")/\(slice.model ?? "")", slice: slice, name: name)
        }
    }

    private static func modelName(_ slice: UsageSlice) -> UsageCell {
        let model = slice.model ?? ""
        return UsageCell(
            text: model.isEmpty ? "Unknown model" : model,
            help: slice.costUSD == nil ? "No published price for this model" : nil,
            sortKey: .text(model.lowercased())
        )
    }

    static func footnote(_ report: UsageReport) -> String? {
        guard report.totals.unpricedTokens > 0 else { return nil }
        let models = report.byModel.filter { $0.unpricedTokens > 0 }.count
        let tokens = UsageFormatting.tokens(report.totals.unpricedTokens)
        return "\(tokens) tokens across \(models) model\(models == 1 ? "" : "s") have no published price and are not in any cost."
    }
}

private extension UsageTableRow {
    /// A row with only its name cell; `UsageDetailRows.build` appends the grouping's figures.
    init(id: String, slice: UsageSlice, name: UsageCell, isEmphasized: Bool = false, isGroup: Bool = false, groupID: String? = nil, isPinned: Bool = false) {
        self.init(id: id, cells: [name], slice: slice, isEmphasized: isEmphasized, isGroup: isGroup, groupID: groupID, isPinned: isPinned)
    }
}
