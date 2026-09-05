import Core
import Transport
import AppKit
import SwiftUI

/// The Usage page body: four metric cards, then two tables — by agent
/// (each agent's models as child rows) and by project (working directory).
/// Everything shown comes from one `UsageReport`; the view holds only sort
/// and collapse state.
struct UsageReportView: View {
    @ObservedObject var model: UsageModel

    static let contentMaximumWidth: CGFloat = 1_040

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .padding(.top, DetailLayout.topInset)
            .padding(.horizontal, DetailLayout.horizontalInset)
            .padding(.bottom, DetailLayout.bottomInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage {
            UsageNotice(text: error, isError: true)
        }
        if let report = model.report {
            if report.scan.isScanning || report.scan.pendingFiles > 0 {
                UsageNotice(
                    text: report.scan.pendingFiles > 0
                        ? "Scanning transcripts · \(UsageFormatting.count(report.scan.pendingFiles)) files left"
                        : "Scanning transcripts…",
                    isError: false
                )
            }
            UsageMetricsRow(totals: report.totals)
            if report.totals.calls == 0 {
                UsageEmptyText(text: "No usage in this range")
            } else {
                UsageAgentSection(report: report)
                UsageProjectSection(report: report)
            }
        } else if model.isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading usage…")
                    .font(Design.Font.UI.body)
                    .foregroundStyle(.secondary)
            }
        } else if model.errorMessage == nil {
            UsageEmptyText(text: "No usage yet")
        }
    }
}

// MARK: - Pieces

private struct UsageNotice: View {
    let text: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle" : "clock.arrow.circlepath")
                .foregroundStyle(isError ? Design.Color.UI.destructiveText : Color.secondary)
            Text(text)
                .font(Design.Font.UI.body)
                .foregroundStyle(isError ? Design.Color.UI.destructiveText : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: UsageReportView.contentMaximumWidth, alignment: .leading)
    }
}

private struct UsageEmptyText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Design.Font.UI.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: UsageReportView.contentMaximumWidth, alignment: .leading)
    }
}

private struct UsageMetricsRow: View {
    let totals: UsageSlice

    var body: some View {
        HStack(spacing: 8) {
            MetricCardView(label: "Cost") {
                Text(UsageFormatting.cost(totals.costUSD))
            }
            MetricCardView(label: "Tokens") {
                Text(UsageFormatting.tokens(totals.tokens.total))
                    .help(UsageFormatting.exactTokens(totals.tokens.total))
            }
            MetricCardView(label: "Sessions") {
                Text(UsageFormatting.count(totals.sessions))
            }
            MetricCardView(label: "Turns") {
                Text(UsageFormatting.count(totals.turns))
            }
        }
        .frame(maxWidth: UsageReportView.contentMaximumWidth)
    }
}

/// One table: an agent per group row, its models as child rows underneath
/// (collapsible), and a pinned Total row.
private struct UsageAgentSection: View {
    let report: UsageReport

    var body: some View {
        SettingsSection(title: "By agent", maxWidth: UsageReportView.contentMaximumWidth) {
            SettingsCard {
                UsageTable(
                    columns: [
                        UsageColumn(title: "Agent · Model", width: nil),
                        UsageColumn(title: "Cost"),
                        UsageColumn(title: "Input"),
                        UsageColumn(title: "Cache read"),
                        UsageColumn(title: "Cache write"),
                        UsageColumn(title: "Output"),
                        UsageColumn(title: "Total"),
                        UsageColumn(title: "Cache ratio", width: 78),
                        UsageColumn(title: "Sessions", width: 68),
                    ],
                    rows: rows,
                    sortable: true
                )
                if report.totals.unpricedTokens > 0 {
                    Divider()
                    SettingsFootnote(text: Self.unpricedFootnote(report))
                }
            }
        }
    }

    private var rows: [UsageTableRow] {
        var rows: [UsageTableRow] = []
        for agent in report.byAgent {
            guard let provider = agent.agent else { continue }
            let groupID = provider.rawValue
            rows.append(UsageTableRow(
                id: groupID,
                cells: [UsageCell(text: Self.name(provider), icon: Self.icon(provider))] + Self.figureCells(agent),
                sortKeys: [.text(Self.name(provider).lowercased())] + Self.figureKeys(agent),
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
                    )] + Self.figureCells(slice),
                    sortKeys: [.text(model.lowercased())] + Self.figureKeys(slice),
                    groupID: groupID
                ))
            }
        }
        rows.append(UsageTableRow(
            id: "total",
            cells: [UsageCell(text: "Total")] + Self.figureCells(report.totals),
            sortKeys: [],
            isEmphasized: true,
            isPinned: true
        ))
        return rows
    }

    static func name(_ agent: AgentProvider) -> String {
        AgentKind.forProvider(agent).providerName
    }

    static func icon(_ agent: AgentProvider) -> NSImage? {
        AgentIcons.image(for: AgentKind.forProvider(agent), pointSize: 13)
    }

    static func figureCells(_ slice: UsageSlice) -> [UsageCell] {
        let tokens = slice.tokens
        return [
            UsageCell(text: UsageFormatting.cost(slice.costUSD), isNumeric: true, isDimmed: slice.costUSD == nil),
            UsageCell(text: UsageFormatting.tokens(tokens.input), help: UsageFormatting.exactTokens(tokens.input), isNumeric: true),
            UsageCell(text: UsageFormatting.tokens(tokens.cacheRead), help: UsageFormatting.exactTokens(tokens.cacheRead), isNumeric: true),
            UsageCell(text: UsageFormatting.tokens(tokens.cacheWrite), help: UsageFormatting.exactTokens(tokens.cacheWrite), isNumeric: true),
            UsageCell(text: UsageFormatting.tokens(tokens.output), help: UsageFormatting.exactTokens(tokens.output), isNumeric: true),
            UsageCell(text: UsageFormatting.tokens(tokens.total), help: UsageFormatting.exactTokens(tokens.total), isNumeric: true),
            UsageCell(text: UsageFormatting.cacheRatio(tokens), help: "Cache read ÷ total tokens", isNumeric: true),
            UsageCell(text: UsageFormatting.count(slice.sessions), isNumeric: true),
        ]
    }

    static func figureKeys(_ slice: UsageSlice) -> [UsageSortKey] {
        let tokens = slice.tokens
        return [
            .number(slice.costUSD ?? -1),
            .number(Double(tokens.input)),
            .number(Double(tokens.cacheRead)),
            .number(Double(tokens.cacheWrite)),
            .number(Double(tokens.output)),
            .number(Double(tokens.total)),
            .number(tokens.total > 0 ? Double(tokens.cacheRead) / Double(tokens.total) : -1),
            .number(Double(slice.sessions)),
        ]
    }

    static func unpricedFootnote(_ report: UsageReport) -> String {
        let models = report.byModel.filter { $0.unpricedTokens > 0 }.count
        let tokens = UsageFormatting.tokens(report.totals.unpricedTokens)
        return "\(tokens) tokens across \(models) model\(models == 1 ? "" : "s") have no published price and are not in any cost."
    }
}

private struct UsageProjectSection: View {
    let report: UsageReport

    var body: some View {
        SettingsSection(title: "By project", maxWidth: UsageReportView.contentMaximumWidth) {
            SettingsCard {
                UsageTable(
                    columns: [
                        UsageColumn(title: "Project", width: nil),
                        UsageColumn(title: "Sessions", width: 72),
                        UsageColumn(title: "Turns", width: 64),
                        UsageColumn(title: "Tokens"),
                        UsageColumn(title: "Cache ratio", width: 78),
                        UsageColumn(title: "Cost"),
                        UsageColumn(title: "Last active", width: 96),
                    ],
                    rows: report.byProject.map { slice in
                        let workspace = slice.workspace ?? ""
                        return UsageTableRow(
                            id: workspace,
                            cells: [
                                UsageCell(
                                    text: UsageFormatting.projectName(workspace),
                                    secondary: UsageFormatting.projectPath(workspace),
                                    help: workspace.isEmpty ? nil : workspace
                                ),
                                UsageCell(text: UsageFormatting.count(slice.sessions), isNumeric: true),
                                UsageCell(text: UsageFormatting.count(slice.turns), isNumeric: true),
                                UsageCell(text: UsageFormatting.tokens(slice.tokens.total), help: UsageFormatting.exactTokens(slice.tokens.total), isNumeric: true),
                                UsageCell(text: UsageFormatting.cacheRatio(slice.tokens), help: "Cache read ÷ total tokens", isNumeric: true),
                                UsageCell(text: UsageFormatting.cost(slice.costUSD), isNumeric: true, isDimmed: slice.costUSD == nil),
                                UsageCell(text: slice.lastDay?.rawValue ?? "—", isNumeric: true, isDimmed: true),
                            ],
                            sortKeys: [
                                .text(UsageFormatting.projectName(workspace).lowercased()),
                                .number(Double(slice.sessions)),
                                .number(Double(slice.turns)),
                                .number(Double(slice.tokens.total)),
                                .number(slice.tokens.total > 0 ? Double(slice.tokens.cacheRead) / Double(slice.tokens.total) : -1),
                                .number(slice.costUSD ?? -1),
                                .text(slice.lastDay?.rawValue ?? ""),
                            ]
                        )
                    },
                    sortable: true
                )
            }
        }
    }
}

// MARK: - Table

struct UsageColumn {
    let title: String
    /// `nil` = the flexible leading column.
    var width: CGFloat? = 88
}

enum UsageSortKey: Comparable {
    case number(Double)
    case text(String)

    static func < (lhs: UsageSortKey, rhs: UsageSortKey) -> Bool {
        switch (lhs, rhs) {
        case let (.number(l), .number(r)): l < r
        case let (.text(l), .text(r)): l < r
        case (.number, .text): true
        case (.text, .number): false
        }
    }
}

struct UsageCell {
    let text: String
    var secondary: String? = nil
    var icon: NSImage? = nil
    var help: String? = nil
    var isNumeric = false
    var isDimmed = false
}

struct UsageTableRow: Identifiable {
    let id: String
    let cells: [UsageCell]
    /// One key per column; empty when the row does not sort (pinned rows).
    let sortKeys: [UsageSortKey]
    var isEmphasized = false
    /// A group row: its children follow it and fold under it.
    var isGroup = false
    /// The group row this row belongs under (indented, collapsible).
    var groupID: String? = nil
    /// Kept last whatever the sort (a Total row).
    var isPinned = false
}

/// A card-shaped table: header row, hairlines between rows, numeric
/// columns right-aligned in monospaced digits. Sorting is a header click
/// (again to flip) and applies to group rows and, within each group, to
/// its children; a pinned row stays last. Group rows fold their children.
struct UsageTable: View {
    let columns: [UsageColumn]
    let rows: [UsageTableRow]
    let sortable: Bool

    @State private var sortColumn: Int?
    @State private var sortAscending = false
    @State private var collapsed: Set<String> = []

    private static let horizontalInset: CGFloat = 16
    private static let columnSpacing: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                UsageTableRowView(
                    row: row,
                    columns: columns,
                    hasChildren: row.isGroup && rows.contains { $0.groupID == row.id },
                    isCollapsed: collapsed.contains(row.id),
                    toggle: { toggle(row.id) }
                )
            }
        }
    }

    private var header: some View {
        HStack(spacing: Self.columnSpacing) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                let isSorted = sortColumn == index
                Button {
                    guard sortable else { return }
                    if sortColumn == index {
                        sortAscending.toggle()
                    } else {
                        sortColumn = index
                        sortAscending = column.width == nil
                    }
                } label: {
                    HStack(spacing: 3) {
                        if column.width != nil { Spacer(minLength: 0) }
                        Text(column.title)
                            .font(Design.Font.UI.caption)
                            .foregroundStyle(isSorted ? Color.primary : Color.secondary)
                            .lineLimit(1)
                        if isSorted {
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: column.width == nil ? .leading : .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!sortable)
                .frame(width: column.width)
            }
        }
        .padding(.horizontal, Self.horizontalInset)
        .frame(height: 30)
    }

    private func toggle(_ groupID: String) {
        if collapsed.contains(groupID) { collapsed.remove(groupID) } else { collapsed.insert(groupID) }
    }

    /// Rows in display order: top-level rows sorted, each followed by its
    /// (sorted) children unless folded, pinned rows last.
    private var visibleRows: [UsageTableRow] {
        let pinned = rows.filter(\.isPinned)
        let topLevel = sorted(rows.filter { !$0.isPinned && $0.groupID == nil })
        var result: [UsageTableRow] = []
        for row in topLevel {
            result.append(row)
            guard row.isGroup, !collapsed.contains(row.id) else { continue }
            result.append(contentsOf: sorted(rows.filter { $0.groupID == row.id }))
        }
        return result + pinned
    }

    private func sorted(_ rows: [UsageTableRow]) -> [UsageTableRow] {
        guard sortable, let sortColumn else { return rows }
        return rows.sorted { lhs, rhs in
            guard sortColumn < lhs.sortKeys.count, sortColumn < rhs.sortKeys.count else { return false }
            let l = lhs.sortKeys[sortColumn]
            let r = rhs.sortKeys[sortColumn]
            if l == r { return lhs.id < rhs.id }
            return sortAscending ? l < r : l > r
        }
    }
}

private struct UsageTableRowView: View {
    let row: UsageTableRow
    let columns: [UsageColumn]
    let hasChildren: Bool
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                let cell = index < row.cells.count ? row.cells[index] : UsageCell(text: "")
                cellView(cell, column: column)
                    .frame(width: column.width)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 36)
        .padding(.vertical, 6)
        .background(row.groupID != nil ? Design.Color.UI.zebra.opacity(0.5) : Color.clear)
    }

    @ViewBuilder
    private func cellView(_ cell: UsageCell, column: UsageColumn) -> some View {
        if column.width == nil {
            HStack(spacing: 8) {
                if hasChildren {
                    Button(action: toggle) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Design.Color.UI.chevron)
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    .help(isCollapsed ? "Show models" : "Hide models")
                } else if row.groupID != nil {
                    Spacer().frame(width: 12)
                }
                if let icon = cell.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 13, height: 13)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(cell.text)
                        .font(row.isEmphasized ? Design.Font.UI.rowTitle : Design.Font.UI.body)
                        .foregroundStyle(row.groupID != nil ? Color.primary.opacity(0.85) : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let secondary = cell.secondary {
                        Text(secondary)
                            .font(Design.Font.UI.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(cell.help ?? cell.text)
        } else {
            Text(cell.text)
                .font(row.isEmphasized ? Design.Font.UI.rowTitle.monospacedDigit() : Design.Font.UI.body.monospacedDigit())
                .foregroundStyle(cell.isDimmed ? Color.secondary : Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(cell.help ?? cell.text)
        }
    }
}

private extension AgentKind {
    static func forProvider(_ provider: AgentProvider) -> AgentKind {
        switch provider {
        case .claude: .claude
        case .codex: .codex
        }
    }
}
