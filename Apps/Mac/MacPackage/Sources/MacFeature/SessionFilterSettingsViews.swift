import Core
import DesignSystem
import Transport
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Settings › Agents › Filters (handoff page 5): the rules card with in-place
// editing. View rows show wrapping condition chips; the pencil swaps the row
// for an inline editor (no sheet), one editor at a time. The multi-select
// value panel reuses the FilterDropdown chrome (§3.4 macOS tier) with the
// panel width following the value control.

// MARK: - Group

struct SessionFiltersGroup: View {
    @ObservedObject var model: SessionFilterRulesModel
    @State private var presenter = FilterDropdownPresenter()
    @State private var anchors = SessionFilterAnchorStore()
    @State private var draggedRuleID: SessionFilterRuleID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            SettingsCard {
                if model.rules.isEmpty {
                    Text("No filters. Every Session shows up.")
                        .font(Design.Font.UI.body)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                } else {
                    ForEach(model.rules) { rule in
                        if rule.id != model.rules.first?.id {
                            Divider()
                        }
                        if model.editingRuleID == rule.id {
                            SessionFilterRuleEditor(model: model, rule: rule, presenter: presenter, anchors: anchors)
                        } else {
                            SessionFilterRuleRow(model: model, rule: rule)
                                .onDrag {
                                    draggedRuleID = rule.id
                                    return NSItemProvider(object: rule.id.rawValue as NSString)
                                }
                                .onDrop(of: [.text], delegate: SessionFilterDropDelegate(
                                    model: model,
                                    targetID: rule.id,
                                    draggedRuleID: $draggedRuleID
                                ))
                        }
                    }
                }
                Divider()
                SettingsFootnote(text: "Filters apply once, when a Session's first turn starts — existing Sessions keep their state, and the history is still recorded. Disabled rules are kept but not applied.")
            }
        }
        .frame(maxWidth: Design.Layout.settingsWideCardMaximumWidth, alignment: .leading)
        .onChange(of: model.openPopupIndex) { _, index in
            if index == nil { presenter.dismissAll() }
        }
        .onChange(of: model.editingRuleID) { _, _ in
            presenter.dismissAll()
        }
        .onDisappear { presenter.dismissAll() }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Filters")
                    .font(Design.Font.UI.section)
                Text("Every Session shows by default; one that matches any enabled rule is hidden.")
                    .font(Design.Font.UI.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("+ Add Filter…") { model.addFilter() }
        }
    }
}

/// Stable `FilterAnchorBox` per condition row, so the panel window can track
/// its trigger across SwiftUI re-renders.
@MainActor
final class SessionFilterAnchorStore {
    private var boxes: [Int: FilterAnchorBox] = [:]

    func box(for index: Int) -> FilterAnchorBox {
        if let box = boxes[index] { return box }
        let box = FilterAnchorBox()
        boxes[index] = box
        return box
    }
}

// MARK: - View row

private struct SessionFilterRuleRow: View {
    @ObservedObject var model: SessionFilterRulesModel
    let rule: SessionFilterRule

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SessionFilterDragHandle()
            Toggle("Rule enabled", isOn: Binding(
                get: { rule.isEnabled },
                set: { _ in model.toggleEnabled(rule.id) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            SessionFilterChipFlow(spacing: 6) {
                ForEach(Array(rule.conditions.enumerated()), id: \.offset) { index, condition in
                    SessionFilterConditionChip(condition: condition, isFirst: index == 0)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                iconButton("pencil", label: "Edit rule") { model.beginEditing(rule.id) }
                iconButton("xmark", label: "Delete rule") { model.delete(rule.id) }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(minHeight: Design.Layout.settingsRowMinimumHeight)
        .opacity(rule.isEnabled ? 1 : 0.45)
        .contentShape(Rectangle())
    }

    private func iconButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct SessionFilterDragHandle: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.quaternary)
            .frame(width: 16)
            .accessibilityHidden(true)
    }
}

/// `Agent is codex`-style chip: field · operator · mono value, with a
/// leading `and` between chips. A chip never wraps internally.
private struct SessionFilterConditionChip: View {
    let condition: SessionFilterCondition
    let isFirst: Bool

    var body: some View {
        HStack(spacing: 6) {
            if !isFirst {
                Text("and")
                    .font(Design.Font.UI.caption)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 5) {
                Text(condition.field.displayName)
                    .font(Design.Font.UI.caption.weight(.semibold))
                    .foregroundStyle(Design.Color.UI.inkPrimary)
                Text(condition.op.displayName)
                    .font(Design.Font.UI.caption)
                    .foregroundStyle(.tertiary)
                Text(condition.displayValue)
                    .font(Design.Font.UI.monoSmall)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Design.Color.UI.chipFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Design.Color.UI.chipStroke, lineWidth: 0.5)
            }
        }
        .fixedSize()
    }
}

// MARK: - Drag reorder

private struct SessionFilterDropDelegate: DropDelegate {
    let model: SessionFilterRulesModel
    let targetID: SessionFilterRuleID
    @Binding var draggedRuleID: SessionFilterRuleID?

    func dropEntered(info: DropInfo) {
        guard let draggedRuleID, draggedRuleID != targetID else { return }
        model.reorder(draggedRuleID, before: targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard draggedRuleID != nil else { return false }
        draggedRuleID = nil
        model.finishReorder()
        return true
    }
}

// MARK: - Inline editor

private struct SessionFilterRuleEditor: View {
    @ObservedObject var model: SessionFilterRulesModel
    let rule: SessionFilterRule
    let presenter: FilterDropdownPresenter
    let anchors: SessionFilterAnchorStore

    private static let prefixWidth: CGFloat = 34
    private static let fieldWidth: CGFloat = 132
    private static let operatorWidth: CGFloat = 112
    private static let rowHeight: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rule.conditions.enumerated()), id: \.offset) { index, condition in
                conditionRow(index: index, condition: condition)
            }
            bottomBar
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Color.UI.accent.opacity(0.05))
    }

    private func conditionRow(index: Int, condition: SessionFilterCondition) -> some View {
        HStack(spacing: 8) {
            Text(index == 0 ? "Where" : "and")
                .font(Design.Font.UI.caption)
                .foregroundStyle(.tertiary)
                .frame(width: Self.prefixWidth, alignment: .leading)
            Picker("Field", selection: Binding(
                get: { condition.field },
                set: { model.setField(at: index, $0) }
            )) {
                ForEach([SessionFilterField.agent, .application, .message, .folder], id: \.self) { field in
                    Text(field.displayName).tag(field)
                }
            }
            .labelsHidden()
            .frame(width: Self.fieldWidth)
            if condition.field.allowedOperators.count > 1 {
                Picker("Operator", selection: Binding(
                    get: { condition.op },
                    set: { model.setOperator(at: index, $0) }
                )) {
                    ForEach(condition.field.allowedOperators, id: \.self) { op in
                        Text(op.displayName).tag(op)
                    }
                }
                .labelsHidden()
                .frame(width: Self.operatorWidth)
            }
            valueControl(index: index, condition: condition)
                .frame(maxWidth: .infinity)
            Button {
                model.removeCondition(at: index)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canRemoveCondition)
            .opacity(model.canRemoveCondition ? 1 : 0.25)
            .accessibilityLabel("Remove condition")
        }
        .frame(height: Self.rowHeight)
    }

    @ViewBuilder
    private func valueControl(index: Int, condition: SessionFilterCondition) -> some View {
        switch condition.field {
        case .message:
            TextField("Text to match", text: Binding(
                get: { if case .text(let value) = condition.value { value } else { "" } },
                set: { model.setTextValue(at: index, $0) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(Design.Font.UI.monoSmall)
        case .folder:
            HStack(spacing: 8) {
                Text(condition.displayValue)
                    .font(Design.Font.UI.monoSmall)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…") { chooseFolder(index: index, condition: condition) }
            }
        case .agent, .application:
            SessionFilterValueTrigger(
                condition: condition,
                isOpen: model.openPopupIndex == index,
                anchor: anchors.box(for: index)
            ) {
                togglePanel(index: index)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button {
                model.addCondition()
            } label: {
                Text("+ Add condition")
                    .font(.system(size: 12))
                    .foregroundStyle(Design.Color.UI.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Design.Color.UI.accent.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            Text(rule.summaryLine)
                .font(Design.Font.UI.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel") { model.cancel() }
            Button("Done") { model.commit() }
                .buttonStyle(.borderedProminent)
        }
        .frame(height: 24)
        .padding(.leading, Self.prefixWidth + 8)
    }

    // MARK: Value panel

    private func togglePanel(index: Int) {
        if model.openPopupIndex == index {
            model.openPopupIndex = nil
            return
        }
        model.openPopupIndex = index
        presentPanel(index: index)
    }

    private func presentPanel(index: Int) {
        guard let condition = rule.conditions.indices.contains(index) ? rule.conditions[index] : nil else { return }
        let anchor = anchors.box(for: index)
        presenter.present(
            id: panelID(index: index),
            content: panelContent(index: index, condition: condition, anchor: anchor),
            anchor: anchor
        ) { [weak model] in
            model?.openPopupIndex = nil
        }
    }

    private func panelContent(index: Int, condition: SessionFilterCondition, anchor: FilterAnchorBox) -> FilterDropdownPanel {
        let isSingle = condition.op == .is
        let selected: Set<String> = switch condition.value {
        case .text(let value): [value]
        case .options(let values): Set(values)
        }
        let options = SessionFilterRulesModel.candidates(for: condition.field).map { candidate in
            FilterPanelOption(id: candidate.value, name: candidate.name, isSelected: selected.contains(candidate.value))
        }
        let width = max(190, anchor.view?.bounds.width ?? 190)
        return FilterDropdownPanel(
            model: FilterPanelModel(
                title: condition.field.displayName,
                sections: [FilterPanelSection(id: "values", title: nil, options: options)]
            ),
            width: width,
            selectionStyle: isSingle ? .checkmark : .checkbox,
            onToggleOption: { value in
                if isSingle {
                    model.selectOption(at: index, value)
                    model.openPopupIndex = nil
                } else {
                    model.toggleOption(at: index, value)
                    refreshPanel(index: index)
                }
            },
            onToggleSection: { _ in }
        )
    }

    /// Multi-select keeps the panel open; its checkmarks follow the model.
    private func refreshPanel(index: Int) {
        guard let condition = rule.conditions.indices.contains(index) ? model.editedRule(rule.id)?.conditions[index] : nil else { return }
        presenter.update(
            id: panelID(index: index),
            content: panelContent(index: index, condition: condition, anchor: anchors.box(for: index))
        )
    }

    private func panelID(index: Int) -> String {
        "session-filter-\(rule.id.rawValue)-\(index)"
    }

    private func chooseFolder(index: Int, condition: SessionFilterCondition) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if case .text(let value) = condition.value, !value.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: value)
        }
        if panel.runModal() == .OK, let url = panel.url {
            model.setTextValue(at: index, url.path)
        }
    }
}

/// The pop-up-shaped trigger for enum values: 28 tall, radius 8, joined
/// values (count-badged while multi-selected), blue chevron circle.
private struct SessionFilterValueTrigger: View {
    let condition: SessionFilterCondition
    let isOpen: Bool
    let anchor: FilterAnchorBox
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(condition.displayValue)
                    .font(Design.Font.UI.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if case .options(let values) = condition.value, values.count > 1 {
                    Text("\(values.count)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14)
                        .frame(height: 14)
                        .background(Design.Color.UI.accent.opacity(0.9), in: Capsule())
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Design.Color.UI.accent, in: Circle())
            }
            .padding(.leading, 10)
            .padding(.trailing, 5)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(.background.opacity(0.9), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Design.Color.UI.cardStroke, lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(FilterAnchor(box: anchor))
        .accessibilityLabel("\(condition.field.displayName) value")
        .accessibilityValue(condition.displayValue)
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}

// MARK: - Chip flow layout

/// Left-to-right wrapping layout for condition chips: chips never split, a
/// chip wider than the remaining space starts the next line (which also gives
/// long Folder / User message chips their own line, by real measurement).
struct SessionFilterChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x = x == 0 ? size.width : x + spacing + size.width
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x)
        }
        return CGSize(width: width.isFinite ? width : maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > bounds.width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            let originX = x == 0 ? 0 : x + spacing
            subview.place(
                at: CGPoint(x: bounds.minX + originX, y: bounds.minY + y),
                proposal: ProposedViewSize(size)
            )
            x = originX + size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}
