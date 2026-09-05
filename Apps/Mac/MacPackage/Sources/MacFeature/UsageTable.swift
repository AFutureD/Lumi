import Core
import DesignSystem
import Transport
import AppKit
import SwiftUI

// MARK: - Model

struct UsageColumn {
    let title: String
    /// `nil` = the flexible leading column; fixed columns are right-aligned SF Mono figures.
    var width: CGFloat? = 84
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
    /// Drawn in the tertiary colour: dashes, paths, unpriced costs.
    var isDimmed = false
    /// What a header click on this column sorts by; `nil` on rows that do not sort.
    var sortKey: UsageSortKey? = nil
}

struct UsageTableRow: Identifiable {
    let id: String
    var cells: [UsageCell]
    /// The slice the row's figure cells are read from (`UsageDetailRows`).
    var slice = UsageSlice()
    /// Group rows and the Total row read in Semibold.
    var isEmphasized = false
    /// A group row: its children follow it and fold under it.
    var isGroup = false
    /// The group row this row belongs under (indented, collapsible).
    var groupID: String? = nil
    /// Kept last whatever the sort (the Total row).
    var isPinned = false
}

// MARK: - Table

/// The Detail card's table: a 30pt header over 44pt rows, numeric columns
/// right-aligned in SF Mono. A header click sorts (numbers descending
/// first, names ascending first; again to flip) group rows among
/// themselves and children within their group; a pinned row stays last.
/// Group rows fold their children; the folded set lives with the caller so
/// it survives a range change.
struct UsageTable: View {
    typealias DS = DesignSystem

    let columns: [UsageColumn]
    let rows: [UsageTableRow]
    @Binding var collapsed: Set<String>

    @State private var sortColumn: Int?
    @State private var sortAscending = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if rows.isEmpty {
                Text("No usage in this range")
                    .font(Font(DS.Typography.body))
                    .foregroundStyle(Color(DS.Usage.tertiaryText))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Usage.rowInset)
                    .frame(minHeight: DS.Usage.rowMinimumHeight)
            }
            ForEach(visibleRows) { row in
                UsageTableRowView(
                    row: row,
                    columns: columns,
                    hasChildren: row.isGroup && rows.contains { $0.groupID == row.id },
                    isCollapsed: collapsed.contains(row.id),
                    toggle: { toggle(row.id) }
                )
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color(DS.Usage.rowSeparator)).frame(height: DS.Stroke.separator)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: DS.Usage.columnSpacing) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                let isSorted = sortColumn == index
                Button {
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
                            .designText(DS.Typography.usageTableHeader)
                            .lineLimit(1)
                        if isSorted {
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .semibold))
                        }
                    }
                    .foregroundStyle(Color(isSorted ? DS.Usage.primaryText : DS.Usage.tertiaryText))
                    .frame(maxWidth: .infinity, alignment: column.width == nil ? .leading : .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: column.width)
            }
        }
        .padding(.horizontal, DS.Usage.rowInset)
        .frame(height: DS.Usage.tableHeaderHeight)
        .background(Color(DS.Usage.tableHeaderFill))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(DS.Usage.tableHeaderSeparator)).frame(height: DS.Stroke.separator)
        }
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
        guard let sortColumn else { return rows }
        return rows.sorted { lhs, rhs in
            guard let l = lhs.cells[sortColumn].sortKey, let r = rhs.cells[sortColumn].sortKey else { return false }
            if l == r { return lhs.id < rhs.id }
            return sortAscending ? l < r : l > r
        }
    }
}

private struct UsageTableRowView: View {
    typealias DS = DesignSystem

    let row: UsageTableRow
    let columns: [UsageColumn]
    let hasChildren: Bool
    let isCollapsed: Bool
    let toggle: () -> Void

    private var isChild: Bool { row.groupID != nil }

    var body: some View {
        HStack(spacing: DS.Usage.columnSpacing) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                let cell = index < row.cells.count ? row.cells[index] : UsageCell(text: "")
                cellView(cell, column: column)
                    .frame(width: column.width)
            }
        }
        .padding(.leading, DS.Usage.rowInset + (isChild ? DS.Usage.childIndent : 0))
        .padding(.trailing, DS.Usage.rowInset)
        .frame(minHeight: DS.Usage.rowMinimumHeight)
    }

    private var textColor: Color {
        Color(isChild ? DS.Usage.childText : DS.Usage.primaryText)
    }

    private var nameFont: Font {
        Font(row.isEmphasized ? DS.Typography.bodyEmphasized : DS.Typography.body)
    }

    @ViewBuilder
    private func cellView(_ cell: UsageCell, column: UsageColumn) -> some View {
        if column.width == nil {
            HStack(spacing: DS.Spacing.m) {
                if hasChildren {
                    Button(action: toggle) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color(DS.Usage.chevron))
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                            .frame(width: DS.Usage.chevronWidth + DS.Spacing.xs, height: DS.Usage.chevronHeight)
                    }
                    .buttonStyle(.plain)
                    .help(isCollapsed ? "Show models" : "Hide models")
                }
                if let icon = cell.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 13, height: 13)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(cell.text)
                        .font(nameFont)
                        .foregroundStyle(cell.isDimmed ? Color(DS.Usage.tertiaryText) : textColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let secondary = cell.secondary {
                        Text(secondary)
                            .font(Font(DS.Typography.subheadline))
                            .foregroundStyle(Color(DS.Usage.tertiaryText))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(cell.help ?? cell.text)
        } else {
            Text(cell.text)
                .font(figureFont)
                .foregroundStyle(cell.isDimmed ? Color(DS.Usage.tertiaryText) : textColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(cell.help ?? cell.text)
        }
    }

    private var figureFont: Font {
        Font((row.isEmphasized ? DS.Typography.bodyEmphasized : DS.Typography.body).mono)
    }
}
