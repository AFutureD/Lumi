import Transport
import AppKit
import Foundation
import Testing
@testable import MacFeature

// MARK: - Scripted daemon

/// Answers `get/set_session_filters` from an in-memory list, like the daemon.
private final class ScriptedFilterDaemon: MacDaemonClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var stored: [SessionFilterRule]
    private(set) var requests: [IPCRequest] = []
    var failNextSave = false

    init(stored: [SessionFilterRule] = []) {
        self.stored = stored
    }

    func request(_ request: IPCRequest, socketPath: String, timeoutSeconds: Int64) throws -> IPCResponse {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        switch request.operation {
        case .getSessionFilters:
            return IPCResponse(status: .ok, filters: stored)
        case .setSessionFilters:
            guard let filters = request.filters else {
                return IPCResponse(status: .error, failure: IPCFailure(code: "missing_filters", message: "no list", retryable: false))
            }
            if failNextSave {
                failNextSave = false
                return IPCResponse(status: .error, failure: IPCFailure(code: "internal_error", message: "boom", retryable: true))
            }
            stored = filters
            return IPCResponse(status: .ok, filters: filters)
        default:
            return IPCResponse(status: .ok)
        }
    }

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count { $0.operation == .setSessionFilters }
    }
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func makeModel(stored: [SessionFilterRule] = []) -> (SessionFilterRulesModel, ScriptedFilterDaemon) {
    let daemon = ScriptedFilterDaemon(stored: stored)
    let model = SessionFilterRulesModel(client: SessionFilterClient(client: daemon, socketPath: "/tmp/none.sock"))
    return (model, daemon)
}

private func storedRule(_ field: SessionFilterField = .agent) -> SessionFilterRule {
    SessionFilterRule(conditions: [SessionFilterRulesModel.defaultCondition(for: field)])
}

// MARK: - Client

@Test @MainActor func filterClientLoadsAndSavesTheWholeList() async throws {
    let rules = [storedRule(), storedRule(.folder)]
    let daemon = ScriptedFilterDaemon(stored: rules)
    let client = SessionFilterClient(client: daemon, socketPath: "/tmp/none.sock")
    #expect(try await client.load() == rules)

    let reversed = Array(rules.reversed())
    #expect(try await client.save(reversed) == reversed)
    #expect(daemon.stored == reversed)
    #expect(daemon.requests.map(\.operation) == [.getSessionFilters, .setSessionFilters])
}

// MARK: - Editor semantics (handoff 5h)

@Test @MainActor func addFilterAppendsTheDefaultRuleAndDiscardsAnOpenNewRow() async {
    let (model, daemon) = makeModel()
    model.load()
    await waitUntil { model.isLoaded }

    model.addFilter()
    #expect(model.rules.count == 1)
    #expect(model.editingRuleID == model.rules[0].id)
    #expect(model.rules[0].isEnabled)
    #expect(model.rules[0].conditions == [SessionFilterRulesModel.defaultCondition(for: .agent)])

    // A second Add Filter while the new row is uncommitted replaces it.
    let firstID = model.rules[0].id
    model.addFilter()
    #expect(model.rules.count == 1)
    #expect(model.rules[0].id != firstID)
    // Nothing was saved yet — new rows only persist on Done.
    #expect(daemon.saveCount == 0)
}

@Test @MainActor func cancelDeletesANewRowAndRollsBackAnExistingOne() async {
    let existing = storedRule()
    let (model, daemon) = makeModel(stored: [existing])
    model.load()
    await waitUntil { model.isLoaded }

    // New row: Cancel removes it outright.
    model.addFilter()
    model.cancel()
    #expect(model.rules == [existing])
    #expect(model.editingRuleID == nil)

    // Existing row: edits roll back to the entry snapshot.
    model.beginEditing(existing.id)
    model.setTextValue(at: 0, "claude")
    model.setField(at: 0, .message)
    model.cancel()
    #expect(model.rules == [existing])
    #expect(daemon.saveCount == 0)
}

@Test @MainActor func switchingRowsCommitsTheOpenEditor() async {
    let first = storedRule()
    let second = storedRule(.folder)
    let (model, daemon) = makeModel(stored: [first, second])
    model.load()
    await waitUntil { model.isLoaded }

    model.beginEditing(first.id)
    model.setOperator(at: 0, .contains)
    // Opening the second row commits the first silently — no confirmation.
    model.beginEditing(second.id)
    #expect(model.editingRuleID == second.id)
    #expect(model.rules[0].conditions[0].op == .contains)
    await waitUntil { daemon.saveCount == 1 }
    #expect(daemon.stored.first?.conditions.first?.op == .contains)
}

@Test @MainActor func fieldChangeResetsOperatorAndValue() async {
    let (model, _) = makeModel(stored: [storedRule()])
    model.load()
    await waitUntil { model.isLoaded }
    let id = model.rules[0].id
    model.beginEditing(id)

    model.setField(at: 0, .message)
    #expect(model.rules[0].conditions[0] == SessionFilterCondition(field: .message, op: .contains, value: .text("")))

    model.setField(at: 0, .folder)
    let folder = model.rules[0].conditions[0]
    #expect(folder.field == .folder)
    #expect(folder.op == .is)
    if case .text(let path) = folder.value {
        #expect(!path.isEmpty)
    } else {
        Issue.record("folder default should be a text path")
    }
}

@Test @MainActor func isContainsSwitchConvertsTheValueShape() async {
    let (model, _) = makeModel(stored: [storedRule()])
    model.load()
    await waitUntil { model.isLoaded }
    model.beginEditing(model.rules[0].id)

    model.setOperator(at: 0, .contains)
    #expect(model.rules[0].conditions[0].value == .options(["codex"]))
    model.toggleOption(at: 0, "claude")
    #expect(model.rules[0].conditions[0].value == .options(["codex", "claude"]))
    // Back to `is`: the list collapses to its first element.
    model.setOperator(at: 0, .is)
    #expect(model.rules[0].conditions[0].value == .text("codex"))
}

@Test @MainActor func multiSelectNeverDropsTheLastValueAndConditionsNeverEmpty() async {
    let (model, _) = makeModel(stored: [storedRule()])
    model.load()
    await waitUntil { model.isLoaded }
    model.beginEditing(model.rules[0].id)

    model.setOperator(at: 0, .contains)
    model.toggleOption(at: 0, "codex")
    #expect(model.rules[0].conditions[0].value == .options(["codex"]))

    // The only condition cannot be removed; a second one can.
    #expect(!model.canRemoveCondition)
    model.removeCondition(at: 0)
    #expect(model.rules[0].conditions.count == 1)
    model.addCondition()
    #expect(model.rules[0].conditions.count == 2)
    #expect(model.rules[0].conditions[1] == SessionFilterCondition(field: .message, op: .contains, value: .text("")))
    #expect(model.canRemoveCondition)
    model.removeCondition(at: 1)
    #expect(model.rules[0].conditions.count == 1)
}

@Test @MainActor func toggleDeleteAndReorderSaveAtOnce() async {
    let first = storedRule()
    let second = storedRule(.folder)
    let (model, daemon) = makeModel(stored: [first, second])
    model.load()
    await waitUntil { model.isLoaded }

    model.toggleEnabled(first.id)
    await waitUntil { daemon.saveCount == 1 }
    #expect(daemon.stored.first?.isEnabled == false)

    model.reorder(second.id, before: first.id)
    #expect(model.rules.map(\.id) == [second.id, first.id])
    model.finishReorder()
    await waitUntil { daemon.saveCount == 2 }
    #expect(daemon.stored.map(\.id) == [second.id, first.id])

    model.delete(second.id)
    await waitUntil { daemon.saveCount == 3 }
    #expect(daemon.stored.map(\.id) == [first.id])
}

@Test @MainActor func summaryLineReadsLikeTheHandoff() {
    let rule = SessionFilterRule(conditions: [
        SessionFilterCondition(field: .agent, op: .is, value: .text("codex")),
        SessionFilterCondition(field: .folder, op: .is, value: .text("/private/var/unknown-root/tmp")),
        SessionFilterCondition(field: .message, op: .contains, value: .text("")),
    ])
    #expect(rule.summaryLine == "Hide a Session when Agent is “Codex” and Folder is “/private/var/unknown-root/tmp” and User message contains “—”")
}

// MARK: - Store hiding

@Test @MainActor func macStoreHidesFilterVerdictSessionsTransitively() async throws {
    let (store, directory) = try macFilterStoreFixture()
    defer { try? FileManager.default.removeItem(at: directory) }

    // A parent with a first turn and its subagent child, plus a bystander.
    store.enqueueAgentEvent(filterPromptEvent("ghost", event: "g-p1", at: 100))
    store.enqueueAgentEvent(filterChildEvent("ghost-child", parent: "ghost", event: "c-p1", at: 101))
    store.enqueueAgentEvent(filterPromptEvent("loud", event: "l-p1", at: 102))
    await store.flushPendingEventsForTesting()
    #expect(Set(store.sessions.map(\.id)) == [SessionID("ghost"), SessionID("ghost-child"), SessionID("loud")])

    // The daemon streams the frozen verdict: the whole group disappears from
    // the visible list, but stays in the cache.
    let ghost = try #require(store.sessions.first { $0.id == SessionID("ghost") })
    store.applyStreamedSummary(ghost.withHiddenByFilter(true))
    await waitUntil { store.sessions.map(\.id) == [SessionID("loud")] }
    #expect(store.sessions.map(\.id) == [SessionID("loud")])
    let cached = try await store.cachedSessionDetails(ids: [SessionID("ghost"), SessionID("ghost-child")])
    #expect(cached.count == 2)
}

@MainActor
private func macFilterStoreFixture() throws -> (MacSessionStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumi-filter-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = MacSessionStore(
        socketPath: directory.appendingPathComponent("missing.sock").path,
        cachePath: directory.appendingPathComponent("cache.sqlite3").path
    )
    return (store, directory)
}

private func filterPromptEvent(_ id: String, event: String, at: TimeInterval) -> AgentIngressEvent {
    let sessionID = SessionID(id)
    return AgentIngressEvent(
        eventID: EventID(event), sessionID: sessionID, turnID: TurnID("turn-\(event)"), agent: .claude,
        occurredAt: Date(timeIntervalSince1970: at), lifecycle: .running, phase: .thinking,
        turn: TurnSummary(id: TurnID("turn-\(event)"), sessionID: sessionID, phase: .thinking, prompt: "hi", startedAt: Date(timeIntervalSince1970: at))
    )
}

private func filterChildEvent(_ id: String, parent: String, event: String, at: TimeInterval) -> AgentIngressEvent {
    let sessionID = SessionID(id)
    return AgentIngressEvent(
        eventID: EventID(event), sessionID: sessionID, turnID: TurnID("turn-\(event)"), agent: .claudeSubagent,
        occurredAt: Date(timeIntervalSince1970: at), lifecycle: .running, phase: .thinking,
        turn: TurnSummary(id: TurnID("turn-\(event)"), sessionID: sessionID, phase: .thinking, prompt: "hi", startedAt: Date(timeIntervalSince1970: at)),
        lineage: SessionLineage(parentSessionID: SessionID(parent))
    )
}
