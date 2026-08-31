import Core
import Diagnostics
import Logging
import Transport
import Foundation

private let log = Logger(label: "ui")

/// Editor state and semantics for the Filters group in Settings › Agents.
/// Pure logic over `SessionFilterRule` values — the views only render it.
///
/// The in-place editor's rules (handoff 5h): one editor at a time; opening
/// another row commits the current one (no confirmation); `Cancel` rolls an
/// existing rule back to the snapshot taken on entry and deletes a new row
/// outright; a rule keeps at least one condition; changing a field resets
/// operator and value; `is ↔ contains` converts the value shape. Toggling,
/// deleting and reordering act on the view state directly and save at once.
@MainActor
final class SessionFilterRulesModel: ObservableObject {
    @Published private(set) var rules: [SessionFilterRule] = []
    @Published private(set) var editingRuleID: SessionFilterRuleID?
    /// Which condition's value panel is open; any field/op change, outside
    /// click or Esc closes it (the view drives the presenter from this).
    @Published var openPopupIndex: Int?
    @Published private(set) var isLoaded = false

    private var snapshot: SessionFilterRule?
    private var isNewRule = false
    private let client: SessionFilterClient
    var presentError: (Error) -> Void = { _ in }

    init(client: SessionFilterClient = SessionFilterClient()) {
        self.client = client
    }

    var isEditing: Bool { editingRuleID != nil }

    func editedRule(_ id: SessionFilterRuleID) -> SessionFilterRule? {
        rules.first { $0.id == id }
    }

    // MARK: - Loading

    func load() {
        Task {
            do {
                rules = try await client.load()
                isLoaded = true
            } catch {
                // The panel still renders (empty list); the daemon row above
                // already tells the user the daemon is unreachable.
                log.warning("session_filters_load_failed", metadata: .fields(["error": error]))
                isLoaded = false
            }
        }
    }

    // MARK: - Rule list actions (view state, saved at once)

    func toggleEnabled(_ id: SessionFilterRuleID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].isEnabled.toggle()
        persist()
    }

    func delete(_ id: SessionFilterRuleID) {
        if editingRuleID == id {
            editingRuleID = nil
            snapshot = nil
            isNewRule = false
            openPopupIndex = nil
        }
        rules.removeAll { $0.id == id }
        persist()
    }

    /// Live reorder while a drag hovers rows; `finishReorder` saves the
    /// order once on drop. Order is organizational only — rules OR together.
    func reorder(_ id: SessionFilterRuleID, before targetID: SessionFilterRuleID) {
        guard id != targetID,
              let from = rules.firstIndex(where: { $0.id == id }),
              let to = rules.firstIndex(where: { $0.id == targetID }) else { return }
        rules.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    func finishReorder() {
        persist()
    }

    // MARK: - Editor lifecycle

    /// Appends the default rule (`Agent is Codex`, enabled) and opens its
    /// editor. An uncommitted new row still open is discarded first.
    func addFilter() {
        if isNewRule, let editingRuleID {
            rules.removeAll { $0.id == editingRuleID }
        }
        let rule = SessionFilterRule(conditions: [Self.defaultCondition(for: .agent)])
        rules.append(rule)
        editingRuleID = rule.id
        snapshot = nil
        isNewRule = true
        openPopupIndex = nil
    }

    /// Opens an existing rule. A different open editor commits silently.
    func beginEditing(_ id: SessionFilterRuleID) {
        guard editingRuleID != id else { return }
        if editingRuleID != nil { commit() }
        guard let rule = rules.first(where: { $0.id == id }) else { return }
        editingRuleID = id
        snapshot = rule
        isNewRule = false
        openPopupIndex = nil
    }

    /// Existing rule: roll back to the entry snapshot. New row: delete it.
    func cancel() {
        guard let editingRuleID else { return }
        if isNewRule {
            rules.removeAll { $0.id == editingRuleID }
        } else if let snapshot, let index = rules.firstIndex(where: { $0.id == editingRuleID }) {
            rules[index] = snapshot
        }
        closeEditor()
    }

    /// `Done`: keep the edited values and save. An empty value stays — the
    /// matcher treats it as never matching.
    func commit() {
        guard editingRuleID != nil else { return }
        closeEditor()
        persist()
    }

    private func closeEditor() {
        editingRuleID = nil
        snapshot = nil
        isNewRule = false
        openPopupIndex = nil
    }

    // MARK: - Condition edits (on the rule being edited)

    func addCondition() {
        mutateEditedRule { $0.conditions.append(Self.defaultCondition(for: .message)) }
        openPopupIndex = nil
    }

    var canRemoveCondition: Bool {
        editingRuleID.flatMap(editedRule)?.conditions.count ?? 0 > 1
    }

    func removeCondition(at index: Int) {
        guard canRemoveCondition else { return }
        mutateEditedRule {
            guard $0.conditions.indices.contains(index) else { return }
            $0.conditions.remove(at: index)
        }
        openPopupIndex = nil
    }

    /// A new field gets its first operator and a fresh default value.
    func setField(at index: Int, _ field: SessionFilterField) {
        mutateEditedRule {
            guard $0.conditions.indices.contains(index), $0.conditions[index].field != field else { return }
            $0.conditions[index] = Self.defaultCondition(for: field)
        }
        openPopupIndex = nil
    }

    /// `is ↔ contains` converts the value: single → one-element list, list →
    /// its first element. Text fields keep their text.
    func setOperator(at index: Int, _ op: SessionFilterOperator) {
        mutateEditedRule {
            guard $0.conditions.indices.contains(index) else { return }
            var condition = $0.conditions[index]
            guard condition.op != op, condition.field.allowedOperators.contains(op) else { return }
            switch (condition.field, op, condition.value) {
            case (.agent, .contains, .text(let value)), (.application, .contains, .text(let value)):
                condition.value = .options([value])
            case (.agent, .is, .options(let values)), (.application, .is, .options(let values)):
                condition.value = .text(values.first ?? "")
            default:
                break
            }
            condition.op = op
            $0.conditions[index] = condition
        }
        openPopupIndex = nil
    }

    func setTextValue(at index: Int, _ text: String) {
        mutateEditedRule {
            guard $0.conditions.indices.contains(index) else { return }
            $0.conditions[index].value = .text(text)
        }
    }

    /// Single-select (`is`): writes the value; the view closes the panel.
    func selectOption(at index: Int, _ value: String) {
        mutateEditedRule {
            guard $0.conditions.indices.contains(index) else { return }
            $0.conditions[index].value = .text(value)
        }
    }

    /// Multi-select (`contains`): toggles membership, never below one value.
    func toggleOption(at index: Int, _ value: String) {
        mutateEditedRule {
            guard $0.conditions.indices.contains(index),
                  case .options(var values) = $0.conditions[index].value else { return }
            if let existing = values.firstIndex(of: value) {
                guard values.count > 1 else { return }
                values.remove(at: existing)
            } else {
                values.append(value)
            }
            $0.conditions[index].value = .options(values)
        }
    }

    private func mutateEditedRule(_ mutate: (inout SessionFilterRule) -> Void) {
        guard let editingRuleID, let index = rules.firstIndex(where: { $0.id == editingRuleID }) else { return }
        mutate(&rules[index])
    }

    // MARK: - Defaults & candidates

    nonisolated static func defaultCondition(for field: SessionFilterField) -> SessionFilterCondition {
        switch field {
        case .agent:
            SessionFilterCondition(field: .agent, op: .is, value: .text(AgentProvider.codex.rawValue))
        case .application:
            SessionFilterCondition(field: .application, op: .is, value: .text(AaaSKind.allCases[0].rawValue))
        case .message:
            SessionFilterCondition(field: .message, op: .contains, value: .text(""))
        case .folder:
            SessionFilterCondition(field: .folder, op: .is, value: .text(FileManager.default.homeDirectoryForCurrentUser.path))
        }
    }

    /// Canonical enum candidates: stored raw value → shown name. Application
    /// deliberately offers the six known AaaS, not a "recently seen" list.
    nonisolated static func candidates(for field: SessionFilterField) -> [(value: String, name: String)] {
        switch field {
        case .agent:
            [(AgentProvider.codex.rawValue, "Codex"), (AgentProvider.claude.rawValue, "Claude")]
        case .application:
            AaaSKind.allCases.map { ($0.rawValue, $0.displayName) }
        case .message, .folder:
            []
        }
    }

    nonisolated static func candidateName(for field: SessionFilterField, value: String) -> String {
        candidates(for: field).first { $0.value == value }?.name ?? value
    }

    // MARK: - Persistence

    private func persist() {
        let rules = rules
        Task {
            do {
                try await client.save(rules)
            } catch {
                presentError(error)
                load()
            }
        }
    }
}

// MARK: - Display

extension SessionFilterField {
    var displayName: String {
        switch self {
        case .agent: "Agent"
        case .application: "Application"
        case .message: "User message"
        case .folder: "Folder"
        }
    }
}

extension SessionFilterOperator {
    var displayName: String {
        switch self {
        case .is: "is"
        case .contains: "contains"
        case .startsWith: "starts with"
        }
    }
}

extension SessionFilterCondition {
    /// The value as shown in chips and the live summary: candidate names for
    /// enum fields, `~`-abbreviated paths for folders, `—` when empty.
    var displayValue: String {
        switch value {
        case .text(let text) where text.isEmpty:
            "—"
        case .options(let values) where values.allSatisfy(\.isEmpty):
            "—"
        case .text(let text):
            field == .folder
                ? (SessionPagePresentationBuilder.abbreviatedWorkspace(text) ?? text)
                : SessionFilterRulesModel.candidateName(for: field, value: text)
        case .options(let values):
            values.map { SessionFilterRulesModel.candidateName(for: field, value: $0) }
                .joined(separator: ", ")
        }
    }
}

extension SessionFilterRule {
    /// `Hide a Session when Agent is “Codex” and Folder is “~/tmp”`.
    var summaryLine: String {
        let clauses = conditions.map { condition in
            "\(condition.field.displayName) \(condition.op.displayName) “\(condition.displayValue)”"
        }
        return "Hide a Session when " + clauses.joined(separator: " and ")
    }
}
