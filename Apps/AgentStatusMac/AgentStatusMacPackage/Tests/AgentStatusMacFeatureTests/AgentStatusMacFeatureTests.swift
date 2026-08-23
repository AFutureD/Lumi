import Foundation
import Testing
import AgentStatusCore
import AgentStatusDesignSystem
import AgentStatusTransport
import NookApp
@testable import AgentStatusMacFeature

@Test func hookMergePreservesExistingIntegrationAndIsIdempotent() throws {
    let existing = Data("""
    {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"vibe-island-helper"}]}]},"custom":true}
    """.utf8)
    let once = try CodexHookInstaller.merging(existing, helperCommand: "'/tmp/Lumi/bin/Spark'")
    let twice = try CodexHookInstaller.merging(once, helperCommand: "'/tmp/Lumi/bin/Spark'")
    let root = try #require(JSONSerialization.jsonObject(with: twice) as? [String: Any])
    let hooks = try #require(root["hooks"] as? [String: Any])
    let stop = try #require(hooks["Stop"] as? [[String: Any]])

    #expect(root["custom"] as? Bool == true)
    #expect(stop.count == 2)
    #expect(Set(hooks.keys).isSuperset(of: CodexHookInstaller.supportedEvents))

    let removed = try CodexHookInstaller.removingAgentStatus(from: twice)
    let removedRoot = try #require(JSONSerialization.jsonObject(with: removed) as? [String: Any])
    let removedHooks = try #require(removedRoot["hooks"] as? [String: Any])
    let removedStop = try #require(removedHooks["Stop"] as? [[String: Any]])
    #expect(removedRoot["custom"] as? Bool == true)
    #expect(removedStop.count == 1)
    #expect(!String(data: removed, encoding: .utf8)!.contains("Lumi/bin/Spark"))
}

@Test func claudeSettingsMergeKeepsOtherSettingsAndRefreshesCommand() throws {
    let existing = Data("""
    {"permissions":{"allow":["Bash(ls:*)"]},"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"other-tool"}]}]}}
    """.utf8)
    let once = try ClaudeHookInstaller.merging(existing, helperCommand: "'/old/Lumi/bin/Spark' --agent claude")
    // Reinstalling with a new path refreshes the command instead of appending.
    let twice = try ClaudeHookInstaller.merging(once, helperCommand: "'/new/Lumi/bin/Spark' --agent claude")
    let root = try #require(JSONSerialization.jsonObject(with: twice) as? [String: Any])
    #expect((root["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls:*)"])
    #expect(root["model"] as? String == "opus")
    let hooks = try #require(root["hooks"] as? [String: Any])
    #expect(Set(hooks.keys).isSuperset(of: ClaudeHookInstaller.supportedEvents))
    let pre = try #require(hooks["PreToolUse"] as? [[String: Any]])
    #expect(pre.count == 2)
    let text = String(data: twice, encoding: .utf8)!
    #expect(text.contains("/new/Lumi/bin/Spark") && !text.contains("/old/Lumi/bin/Spark"))
    #expect(text.contains("other-tool"))

    let removed = try AgentHookConfigInstaller.removingAgentStatus(from: twice)
    let removedRoot = try #require(JSONSerialization.jsonObject(with: removed) as? [String: Any])
    let removedHooks = try #require(removedRoot["hooks"] as? [String: Any])
    #expect(removedHooks.keys.sorted() == ["PreToolUse"])
    #expect(removedRoot["model"] as? String == "opus")
}

@Test func hookRefreshReplacesStaleHelperAndSkipsFreshInstall() throws {
    let manager = FileManager.default
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: dir) }
    let config = dir.appendingPathComponent("settings.json")
    let installed = dir.appendingPathComponent("Lumi/bin/Spark")
    let bundled = dir.appendingPathComponent("bundled-helper")
    try Data("new-build".utf8).write(to: bundled)
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
    let installer = AgentHookConfigInstaller(
        configURL: config,
        installedHelperURL: installed,
        supportedEvents: ["Stop"],
        helperArguments: ["--agent", "claude"]
    )

    // Never installed: refresh must not create anything.
    try installer.refreshIfStale(helperSourceURL: bundled)
    #expect(!manager.fileExists(atPath: config.path))
    #expect(!manager.fileExists(atPath: installed.path))

    // Stale binary after an app update is replaced.
    try installer.install(helperSourceURL: bundled)
    try Data("old-build".utf8).write(to: installed)
    try installer.refreshIfStale(helperSourceURL: bundled)
    #expect(try Data(contentsOf: installed) == Data("new-build".utf8))

    // Nothing stale: the config is not rewritten (a rewrite leaves a backup).
    let backup = config.appendingPathExtension("lumi-backup")
    try? manager.removeItem(at: backup)
    try installer.refreshIfStale(helperSourceURL: bundled)
    #expect(!manager.fileExists(atPath: backup.path))

    // A newly supported event re-merges the hook config.
    let widened = AgentHookConfigInstaller(
        configURL: config,
        installedHelperURL: installed,
        supportedEvents: ["Stop", "SubagentStart"],
        helperArguments: ["--agent", "claude"]
    )
    try widened.refreshIfStale(helperSourceURL: bundled)
    let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
    let hooks = try #require(root["hooks"] as? [String: Any])
    #expect(hooks["SubagentStart"] != nil)
    #expect(manager.fileExists(atPath: backup.path))
}

/// Replays scripted `hooks/list` answers and records every request, so a test
/// can assert exactly what the authorizer asked Codex to write.
private final class StubCodexAppServer: CodexAppServerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var listResponses: [String]
    private(set) var sent: [(method: String, params: Any)] = []
    /// Thrown instead of answering; scoped to one method when `failingMethod` is set.
    var failure: Error?
    var failingMethod: String?

    init(listResponses: [String], failure: Error? = nil, failingMethod: String? = nil) {
        self.listResponses = listResponses
        self.failure = failure
        self.failingMethod = failingMethod
    }

    var batchWrites: [[[String: String]]] {
        lock.lock()
        defer { lock.unlock() }
        return sent
            .filter { $0.method == "config/batchWrite" }
            .compactMap { (($0.params as? [String: Any])?["edits"] as? [[String: String]]) }
    }

    func send(method: String, params: Data) throws -> Data {
        if let failure, failingMethod == nil || failingMethod == method { throw failure }
        lock.lock()
        sent.append((method, (try? JSONSerialization.jsonObject(with: params)) ?? [:]))
        let next = method == "hooks/list" ? (listResponses.isEmpty ? nil : listResponses.removeFirst()) : nil
        lock.unlock()
        return Data((next ?? "{}").utf8)
    }
}

private func codexHooksList(_ hooks: [(key: String, command: String, hash: String, status: String)]) -> String {
    let entries = hooks.map {
        """
        {"key":"\($0.key)","command":"\($0.command)","currentHash":"\($0.hash)","trustStatus":"\($0.status)"}
        """
    }
    return #"{"data":[{"cwd":"/tmp","hooks":[\#(entries.joined(separator: ","))]}]}"#
}

private let lumiCommand = "'/Users/me/Library/Application Support/Lumi/bin/Spark'"

@Test func codexHookTrustAuthorizesOnlyOurOwnUntrustedHandlers() {
    let untrustedKey = "/Users/me/.codex/hooks.json:pre_tool_use:0:0"
    let stub = StubCodexAppServer(listResponses: [
        codexHooksList([
            (untrustedKey, lumiCommand, "sha256:aaa", "untrusted"),
            ("/Users/me/.codex/hooks.json:stop:1:0", lumiCommand, "sha256:bbb", "trusted"),
            ("/Users/me/.codex/hooks.json:stop:2:0", "'/Users/me/.vibe-island/bin/vibe-island-bridge'", "sha256:ccc", "untrusted"),
        ]),
        codexHooksList([
            (untrustedKey, lumiCommand, "sha256:aaa", "trusted"),
            ("/Users/me/.codex/hooks.json:stop:1:0", lumiCommand, "sha256:bbb", "trusted"),
        ]),
    ])

    let state = CodexHookTrustAuthorizer(makeTransport: { stub }).authorize()

    #expect(state == .trusted(2))
    #expect(stub.batchWrites.count == 1)
    let edits = stub.batchWrites.first ?? []
    #expect(edits.count == 1)
    #expect(edits.first?["keyPath"] == "hooks.state.\"\(untrustedKey)\".trusted_hash")
    #expect(edits.first?["value"] == "sha256:aaa")
    #expect(edits.first?["mergeStrategy"] == "replace")
}

@Test func codexHookTrustReportsWhatCodexStillRefusesAfterWriting() {
    let key = "/Users/me/.codex/hooks.json:pre_tool_use:0:0"
    let stub = StubCodexAppServer(listResponses: [
        codexHooksList([(key, lumiCommand, "sha256:aaa", "untrusted")]),
        codexHooksList([(key, lumiCommand, "sha256:aaa", "untrusted")]),
    ])

    #expect(CodexHookTrustAuthorizer(makeTransport: { stub }).authorize() == .untrusted([key]))
}

/// A rejected write must not read as "this Codex has no trust gate" — the
/// handlers really are untrusted and the user has to be told.
@Test func codexHookTrustDoesNotMistakeARejectedWriteForAnOlderCodex() {
    let key = "/Users/me/.codex/hooks.json:pre_tool_use:0:0"
    let stub = StubCodexAppServer(
        listResponses: [codexHooksList([(key, lumiCommand, "sha256:aaa", "untrusted")])],
        failure: CodexAppServerError.rpc(code: -32603, message: "config is read-only"),
        failingMethod: "config/batchWrite"
    )

    #expect(CodexHookTrustAuthorizer(makeTransport: { stub }).authorize() == .untrusted([key]))
}

@Test func codexHookTrustProbeReadsWithoutWriting() {
    let key = "/Users/me/.codex/hooks.json:stop:1:0"
    let stub = StubCodexAppServer(listResponses: [
        codexHooksList([(key, lumiCommand, "sha256:aaa", "untrusted")]),
    ])

    #expect(CodexHookTrustAuthorizer(makeTransport: { stub }).probe() == .untrusted([key]))
    #expect(stub.batchWrites.isEmpty)
}

/// The same user-level handler is repeated once per cwd group.
@Test func codexHookTrustCountsEachHandlerOnce() {
    let entry = """
    {"key":"/Users/me/.codex/hooks.json:stop:1:0","command":"\(lumiCommand)","currentHash":"sha256:aaa","trustStatus":"trusted"}
    """
    let stub = StubCodexAppServer(listResponses: [
        #"{"data":[{"cwd":"/a","hooks":[\#(entry)]},{"cwd":"/b","hooks":[\#(entry)]}]}"#,
    ])

    #expect(CodexHookTrustAuthorizer(makeTransport: { stub }).probe() == .trusted(1))
}

@Test func codexHookTrustTreatsAMissingOrOlderCodexAsUnsupported() {
    let noCodex = CodexHookTrustAuthorizer(makeTransport: { throw CodexAppServerError.executableNotFound })
    #expect(noCodex.authorize() == .unsupported)

    let noHooksList = StubCodexAppServer(
        listResponses: [],
        failure: CodexAppServerError.rpc(code: -32601, message: "method not found")
    )
    #expect(CodexHookTrustAuthorizer(makeTransport: { noHooksList }).authorize() == .unsupported)
    #expect(!CodexHookTrustState.unsupported.needsAttention)
}

/// Read-only smoke test against the Codex actually installed on this machine —
/// the stubs above cannot catch a change to the app-server's JSON-RPC contract.
/// Opt in with `AGENT_STATUS_CODEX_INTEGRATION=1 swift test`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_STATUS_CODEX_INTEGRATION"] != nil))
func codexAppServerProbeSpeaksToTheInstalledCodex() throws {
    let transport = try CodexAppServerProcessTransport()
    defer { transport.close() }
    let result = try transport.send(method: "hooks/list", params: Data("{}".utf8))
    let response = try JSONDecoder().decode(CodexHooksListResponse.self, from: result)

    #expect(!response.data.isEmpty)
    let keys = response.data.flatMap(\.hooks).map(\.key)
    #expect(keys.allSatisfy { $0.contains(":") })

    // A `.failed` here means the contract moved, not that hooks are untrusted.
    if case .failed(let reason) = CodexHookTrustAuthorizer().probe() {
        Issue.record("probe against the installed Codex failed: \(reason)")
    }
}

@Test func codexHookTrustSurfacesAnUnresponsiveCodex() {
    let stalled = StubCodexAppServer(
        listResponses: [],
        failure: CodexAppServerError.timedOut(method: "hooks/list")
    )
    let state = CodexHookTrustAuthorizer(makeTransport: { stalled }).authorize()

    guard case .failed = state else {
        Issue.record("expected a failed state, got \(state)")
        return
    }
    #expect(state.needsAttention)
}

@Test @MainActor
func nookAppearanceIsPinnedAndAdjustmentDefaultsAreFilled() {
    let original = NookAppearancePreferences(
        chromePalette: .light,
        surfaceStyle: .translucent,
        presentation: .floating,
        hapticFeedbackEnabled: true,
        keepNookOpen: true
    )

    let normalized = AgentStatusNookController.normalizedAppearancePreferences(original)

    #expect(normalized.chromePalette == .dark)
    #expect(normalized.presentation == .notch)
    #expect(normalized.surfaceStyle == .translucent)
    #expect(normalized.hapticFeedbackEnabled)
    #expect(normalized.keepNookOpen)
    #expect(normalized.compactNotchWidth == AgentStatusNookAdjustmentDefaults.compactWidth)
    #expect(normalized.expandedNotchWidth == AgentStatusNookAdjustmentDefaults.expandedWidth)
    #expect(
        normalized.expandAnimationDuration
            == AgentStatusNookAdjustmentDefaults.expandAnimationDuration
    )
}

@Test @MainActor
func nookAppearancePreservesCustomAdjustments() {
    var original = NookAppearancePreferences.default
    original.compactNotchWidth = 96
    original.expandedNotchWidth = 608
    original.expandAnimationDuration = 0.72

    let normalized = AgentStatusNookController.normalizedAppearancePreferences(original)

    #expect(normalized.compactNotchWidth == 96)
    #expect(normalized.expandedNotchWidth == 608)
    #expect(normalized.expandAnimationDuration == 0.72)
}

@Test @MainActor
func pairingContentUsesVerticalLayoutBelowItsHorizontalMinimum() {
    let minimum = PairingViewController.minimumHorizontalContentWidth
    #expect(PairingViewController.usesCompactContentLayout(availableWidth: minimum - 1))
    #expect(!PairingViewController.usesCompactContentLayout(availableWidth: minimum))
}

/// Fixtures use epoch-relative dates, so tests pass an epoch-relative `now`
/// that keeps them inside the seven-day window.
private let nookNow = Date(timeIntervalSince1970: 100)

@Test func nookSnapshotShowsTheCurrentTurnUserMessageAndListsEverySession() {
    let active = nookSummary(id: "active", lifecycle: .running, phase: .executing, updatedAt: 20)
    let completed = nookSummary(id: "completed", lifecycle: .completed, phase: .idle, updatedAt: 10)
    let firstTurn = TurnID("turn-1")
    let currentTurn = TurnID("turn-2")
    let detail = SessionDetail(summary: active, timeline: [
        TimelineItem(
            id: TimelineItemID("first"),
            sessionID: active.id,
            turnID: firstTurn,
            occurredAt: Date(timeIntervalSince1970: 1),
            payload: .message(MessageTimelinePayload(role: .user, text: "Older request"))
        ),
        TimelineItem(
            id: TimelineItemID("current"),
            sessionID: active.id,
            turnID: currentTurn,
            occurredAt: Date(timeIntervalSince1970: 2),
            payload: .message(MessageTimelinePayload(role: .user, text: "Current request"))
        ),
    ])

    // A completed session stays in the list (grey dot, archivable).
    let visible = AgentStatusNookSnapshot.visibleSummaries(from: [active, completed], now: nookNow)
    let rows = AgentStatusNookSnapshot.make(summaries: visible, details: [active.id: detail])

    #expect(rows.map(\.id) == [active.id, completed.id])
    #expect(rows.first?.currentUserMessage == "Current request")
    #expect(rows.first?.statusText == "Running · Executing")
    #expect(rows.first?.recentRows.map(\.tag) == [.user, .user])
    #expect(rows.first?.turnEnded == false)
    #expect(rows.last?.turnEnded == true)
    #expect(rows.last?.statusTone == .gray)

    // No cap: the viewport scrolls, so every eligible session is listed.
    let eligible = [active] + (1...7).map {
        nookSummary(id: "extra-\($0)", lifecycle: .running, phase: .executing, updatedAt: TimeInterval(20 - $0))
    }
    #expect(AgentStatusNookSnapshot.eligibleSummaries(from: eligible, now: nookNow).count == 8)
    #expect(AgentStatusNookSnapshot.visibleSummaries(from: eligible, now: nookNow).count == 8)
}

@Test func nookSnapshotHidesArchivedStaleAndUnknownSessions() {
    let active = nookSummary(id: "active", lifecycle: .running, phase: .executing, updatedAt: 20)
    let archived = nookSummary(id: "archived", lifecycle: .waitingForInput, phase: .idle, updatedAt: 10)
        .withHiddenInNotch(true)

    // Archived sessions leave the Notch entirely: rows and the footer count.
    #expect(AgentStatusNookSnapshot.eligibleSummaries(from: [active, archived], now: nookNow).map(\.id) == [active.id])
    #expect(AgentStatusNookSnapshot.visibleSummaries(from: [active, archived], now: nookNow).map(\.id) == [active.id])

    // The Mac window ignores the flag.
    let hierarchy = SessionListHierarchy.build(from: [active, archived])
    #expect(hierarchy.roots.map(\.summary.id) == [active.id, archived.id])

    // Sessions idle for more than seven days drop out; the boundary is exact.
    let sevenDays = AgentStatusNookSnapshot.maximumSessionAge
    let now = Date(timeIntervalSince1970: sevenDays + 1_000)
    let stale = nookSummary(id: "stale", lifecycle: .waitingForInput, phase: .idle, updatedAt: 999)
    let fresh = nookSummary(id: "fresh", lifecycle: .waitingForInput, phase: .idle, updatedAt: 1_001)
    let boundary = nookSummary(id: "boundary", lifecycle: .waitingForInput, phase: .idle, updatedAt: 1_000)
    #expect(
        AgentStatusNookSnapshot.eligibleSummaries(from: [stale, fresh, boundary], now: now).map(\.id.rawValue)
            == ["fresh"]
    )

}

@Test func nookListKeepsStoreOrderAndKeepsSubagentsWithTheirParent() {
    let running = nookSummary(id: "running", lifecycle: .running, phase: .executing, updatedAt: 30)
    let waiting = nookSummary(id: "waiting", lifecycle: .waitingForInput, phase: .idle, updatedAt: 20)
    let failed = nookSummary(id: "failed", lifecycle: .failed, phase: .idle, updatedAt: 25)
    let runningChild = hierarchySummary(id: "running-child", parentID: "running", updatedAt: 29)
    let waitingChild = hierarchySummary(id: "waiting-child", parentID: "waiting", updatedAt: 19)

    // Store order (newest first) is kept; every parent keeps its children
    // (the list folds them into a count strip), whatever its lifecycle.
    let visible = AgentStatusNookSnapshot.visibleSummaries(
        from: [running, runningChild, failed, waiting, waitingChild],
        now: nookNow
    )
    #expect(visible.map(\.id.rawValue) == ["running", "running-child", "failed", "waiting", "waiting-child"])
}

@Test func nookListFoldsSubagentsOfSubagentsIntoTheSameGroup() {
    let parent = nookSummary(id: "parent", lifecycle: .running, phase: .executing, updatedAt: 30)
    let child = hierarchySummary(id: "child", parentID: "parent", lifecycle: .completed, phase: .idle, updatedAt: 28)
    let grandchild = hierarchySummary(id: "grandchild", parentID: "child", depth: 2, updatedAt: 29)
    let visible = AgentStatusNookSnapshot.visibleSummaries(from: [parent, grandchild, child], now: nookNow)
    // The grandchild is not dropped: it folds into the parent's strip, in
    // strip order (running before done), as on the iPhone.
    #expect(visible.map(\.id.rawValue) == ["parent", "grandchild", "child"])
    let items = AgentStatusNookSnapshot.listItems(from: AgentStatusNookSnapshot.make(summaries: visible, details: [:]))
    #expect(items.count == 1)
    #expect(items[0].children.map(\.id.rawValue) == ["grandchild", "child"])
}

@Test func nookListItemsOrderSubagentsRunningWaitingFailedDone() {
    let rows = AgentStatusNookSnapshot.make(
        summaries: [
            nookSummary(id: "parent", lifecycle: .running, phase: .executing, updatedAt: 30),
            hierarchySummary(id: "done", parentID: "parent", lifecycle: .completed, phase: .idle, updatedAt: 29),
            hierarchySummary(id: "failed", parentID: "parent", lifecycle: .failed, phase: .idle, updatedAt: 28),
            hierarchySummary(id: "waiting", parentID: "parent", lifecycle: .waitingForInput, phase: .waitingForApproval, updatedAt: 27),
            hierarchySummary(id: "older-running", parentID: "parent", updatedAt: 20),
            hierarchySummary(id: "running", parentID: "parent", updatedAt: 26),
        ],
        details: [:]
    )

    let items = AgentStatusNookSnapshot.listItems(from: rows)
    #expect(items.count == 1)
    #expect(items[0].children.map(\.id.rawValue) == ["running", "older-running", "waiting", "failed", "done"])
    #expect(items[0].subagentTones == [.blue, .blue, .orange, .red, .gray])
    #expect(items[0].subagentSummary == "5 subagents · 2 running · 1 waiting · 1 failed · 1 done")
}

@Test func nookSubagentDisclosureFollowsTheLifecycleUntilToggled() {
    let parentID = SessionID("parent")
    func item(_ lifecycle: SessionLifecycle, phase: TurnPhase) -> AgentStatusNookListItem {
        let rows = AgentStatusNookSnapshot.make(
            summaries: [
                nookSummary(id: "parent", lifecycle: lifecycle, phase: phase, updatedAt: 30),
                hierarchySummary(id: "child", parentID: "parent", updatedAt: 29),
            ],
            details: [:]
        )
        return AgentStatusNookSnapshot.listItems(from: rows)[0]
    }
    let running = item(.running, phase: .executing)
    let finished = item(.waitingForInput, phase: .idle)
    var disclosure = AgentStatusNookSubagentDisclosure()

    // Defaults: Running open, everything else collapsed.
    #expect(disclosure.isExpanded(running))
    #expect(!disclosure.isExpanded(finished))

    // A toggle sticks for that tier …
    disclosure.toggle(id: parentID, tone: running.session.statusTone)
    #expect(!disclosure.isExpanded(running))
    disclosure.prune(keeping: [running])
    #expect(!disclosure.isExpanded(running))

    // … and is spent once the lifecycle moves on: back to the default.
    #expect(!disclosure.isExpanded(finished))
    disclosure.toggle(id: parentID, tone: finished.session.statusTone)
    #expect(disclosure.isExpanded(finished))
    disclosure.prune(keeping: [running])
    #expect(disclosure.isExpanded(running))
    #expect(!disclosure.isExpanded(finished))
}

@Test func nookListItemsFoldChildrenIntoTheirParentRow() {
    let rows = AgentStatusNookSnapshot.make(
        summaries: [
            nookSummary(id: "parent", lifecycle: .running, phase: .executing, updatedAt: 30),
            hierarchySummary(id: "child-a", parentID: "parent", updatedAt: 29),
            hierarchySummary(id: "child-b", parentID: "parent", updatedAt: 28),
            nookSummary(id: "flat", lifecycle: .waitingForInput, phase: .idle, updatedAt: 20),
            // A promoted orphan keeps a flat row instead of joining a stranger.
            hierarchySummary(id: "orphan", parentID: "missing", updatedAt: 10),
        ],
        details: [:]
    )

    let items = AgentStatusNookSnapshot.listItems(from: rows)
    #expect(items.map(\.id.rawValue) == ["parent", "flat", "orphan"])
    #expect(items.first?.children.map(\.id.rawValue) == ["child-a", "child-b"])
    #expect(items.dropFirst().allSatisfy { $0.children.isEmpty })
}

@Test @MainActor
func selectedSessionDetailMergesLiveEventsWithoutAFullReload() {
    let sessionID = SessionID("selected")
    let initialDate = Date(timeIntervalSince1970: 10)
    let initialSummary = SessionSummary(
        id: sessionID,
        agent: .codex,
        title: "Selected",
        lifecycle: .running,
        phase: .thinking,
        startedAt: initialDate,
        updatedAt: initialDate,
        lastActivityAt: initialDate
    )
    let original = TimelineItem(
        id: TimelineItemID("original"),
        sessionID: sessionID,
        occurredAt: initialDate,
        payload: .message(MessageTimelinePayload(role: .assistant, text: "Old"))
    )
    let detail = SessionDetail(summary: initialSummary, timeline: [original])
    let appended = TimelineItem(
        id: TimelineItemID("appended"),
        sessionID: sessionID,
        occurredAt: initialDate.addingTimeInterval(1),
        payload: .message(MessageTimelinePayload(role: .user, text: "New"))
    )
    let replacement = TimelineItem(
        id: original.id,
        sessionID: sessionID,
        occurredAt: initialDate.addingTimeInterval(2),
        payload: .message(MessageTimelinePayload(role: .assistant, text: "Updated"))
    )
    let updatedDate = initialDate.addingTimeInterval(2)
    let updatedSummary = SessionSummary(
        id: sessionID,
        agent: .codex,
        title: "Selected",
        lifecycle: .running,
        phase: .responding,
        startedAt: initialDate,
        updatedAt: updatedDate,
        lastActivityAt: updatedDate
    )
    let merged = MacSessionStore.merging(
        detail,
        summary: updatedSummary,
        events: [
            AgentIngressEvent(
                eventID: EventID("append"),
                sessionID: sessionID,
                agent: .codex,
                occurredAt: appended.occurredAt,
                timelineItem: appended
            ),
            AgentIngressEvent(
                eventID: EventID("replace"),
                sessionID: sessionID,
                agent: .codex,
                occurredAt: replacement.occurredAt,
                timelineItem: replacement
            ),
        ]
    )

    #expect(merged.summary == updatedSummary)
    #expect(merged.timeline.map(\.id) == [appended.id, original.id])
    #expect(merged.timeline.last?.payload == replacement.payload)
}

private func nookRow(
    _ id: String,
    _ tag: TimelineTag,
    _ text: String = "x",
    toolUseID: String? = nil
) -> AgentStatusNookActivityRow {
    AgentStatusNookActivityRow(row: TimelineRow(
        id: id,
        sessionID: SessionID("session"),
        turnID: nil,
        occurredAt: Date(timeIntervalSince1970: 0),
        tag: tag,
        status: .info,
        text: text,
        items: [TimelineItem(
            id: TimelineItemID(id),
            sessionID: SessionID("session"),
            occurredAt: Date(timeIntervalSince1970: 0),
            payload: .message(MessageTimelinePayload(role: .user, text: text))
        )],
        toolUseID: toolUseID
    ))
}

private func nookSession(
    _ rows: [AgentStatusNookActivityRow],
    lifecycle: SessionLifecycle = .running,
    id: String = "session",
    parentID: SessionID? = nil
) -> AgentStatusNookSession {
    AgentStatusNookSession(
        id: SessionID(id),
        title: "Session",
        agent: .codex,
        workspace: nil,
        lifecycle: lifecycle,
        phase: .thinking,
        needsReview: false,
        currentUserMessage: "Build it",
        lastActivityAt: Date(timeIntervalSince1970: 0),
        startedAt: Date(timeIntervalSince1970: 0),
        groupID: parentID,
        depth: parentID == nil ? 0 : 1,
        currentTurn: nil,
        model: nil,
        totalTokens: nil,
        contextFraction: nil,
        recentRows: rows
    )
}

@Test func nookTurnEventsOnlyComeFromNewL3Rows() {
    let before = nookSession([nookRow("u1", .user)])
    let after = nookSession([
        nookRow("u1", .user),
        nookRow("t1", .tool),          // L1: never a notch event
        nookRow("r1", .reasoning),     // L1: never a notch event
        nookRow("e1", .turnEnd),
        nookRow("f1", .turnFailed),
    ])
    let events = AgentStatusNookActivityDiff.turnEvents(previous: [before], current: [after])
    #expect(events.map(\.kind) == [.ended, .failed])
    #expect(events.map(\.row.id) == ["e1", "f1"])

    let newTurn = nookSession(after.recentRows + [nookRow("u2", .user)])
    #expect(AgentStatusNookActivityDiff.turnEvents(previous: [after], current: [newTurn]).map(\.kind) == [.started])
    // Unchanged rows never re-fire, and unknown sessions are ignored.
    #expect(AgentStatusNookActivityDiff.turnEvents(previous: [after], current: [after]).isEmpty)
    #expect(AgentStatusNookActivityDiff.turnEvents(previous: [], current: [after]).isEmpty)
}

@Test func nookTurnEventsSkipListedSubagentsAndRowBackfills() {
    let parent = nookSession([nookRow("p1", .user)], id: "parent")
    let childBefore = nookSession([nookRow("c1", .user)], id: "child", parentID: parent.id)
    let childAfter = nookSession(
        childBefore.recentRows + [nookRow("c2", .turnEnd)],
        id: "child",
        parentID: parent.id
    )
    // A subagent whose parent is listed is the parent's internal progress.
    #expect(AgentStatusNookActivityDiff.turnEvents(
        previous: [parent, childBefore],
        current: [parent, childAfter]
    ).isEmpty)
    // The same session promoted to top level (parent not listed) notifies.
    #expect(AgentStatusNookActivityDiff.turnEvents(
        previous: [childBefore],
        current: [childAfter]
    ).map(\.kind) == [.ended])

    // Rows appearing in bulk over an empty window are a detail-cache backfill,
    // not fresh activity — replaying them would re-fire old turn ends.
    let summaryOnly = nookSession([])
    let backfilled = nookSession([nookRow("u1", .user), nookRow("e1", .turnEnd)])
    #expect(AgentStatusNookActivityDiff.turnEvents(
        previous: [summaryOnly],
        current: [backfilled]
    ).isEmpty)

    // One tool call failing mid-turn (FAILED in the Exec lane) is routine
    // noise; only turn-level failures (FAILED in the Model lane) notify.
    let toolFailure = nookSession(
        backfilled.recentRows + [nookRow("f1", .failed, toolUseID: "tool-1")]
    )
    #expect(AgentStatusNookActivityDiff.turnEvents(
        previous: [backfilled],
        current: [toolFailure]
    ).isEmpty)
    let turnFailure = nookSession(toolFailure.recentRows + [nookRow("f2", .turnFailed)])
    #expect(AgentStatusNookActivityDiff.turnEvents(
        previous: [toolFailure],
        current: [turnFailure]
    ).map(\.kind) == [.failed])
}

@Test func sessionReconcilePlanFetchesChangedAndPrunesAbsent() {
    let unchanged = nookSummary(id: "unchanged", lifecycle: .running, phase: .thinking, updatedAt: 10)
    let stale = nookSummary(id: "stale", lifecycle: .running, phase: .thinking, updatedAt: 10)
    let fresh = nookSummary(id: "stale", lifecycle: .waitingForInput, phase: .idle, updatedAt: 20)
    let added = nookSummary(id: "added", lifecycle: .running, phase: .executing, updatedAt: 30)
    let removed = nookSummary(id: "removed", lifecycle: .completed, phase: .idle, updatedAt: 5)

    let plan = SessionReconcilePlan.make(
        local: [unchanged, stale, removed],
        daemon: [added, fresh, unchanged]
    )
    #expect(plan.fetch == [added.id, fresh.id])
    #expect(plan.prune == [removed.id])

    let idle = SessionReconcilePlan.make(local: [unchanged], daemon: [unchanged])
    #expect(idle.fetch.isEmpty)
    #expect(idle.prune.isEmpty)
}

@Test func sessionListPresentationShowsTitleAgentAndStatus() {
    let date = Date(timeIntervalSince1970: 100)
    let summary = SessionSummary(
        id: SessionID("claude-session"),
        agent: .claude,
        title: "Rewrite Session\n  module",
        lifecycle: .running,
        phase: .thinking,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date
    )

    let presentation = SessionListRowPresentation(session: summary)

    #expect(presentation.title == "Rewrite Session module")
    #expect(presentation.agent == "Claude")
    #expect(presentation.status == "Running · Thinking")

    let codexSubagent = SessionListRowPresentation(session: SessionSummary(
        id: SessionID("codex-subagent"),
        agent: .codexSubagent,
        title: "Hypatia · docs_review",
        lifecycle: .running,
        phase: .executing,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date
    ))
    #expect(codexSubagent.agent == "Codex Subagent")
}

@Test func sessionListHierarchyNestsSubagentsAndKeepsOrphansReachable() throws {
    let main = hierarchySummary(id: "main")
    let child = hierarchySummary(id: "child", parentID: "main", depth: 1)
    let grandchild = hierarchySummary(id: "grandchild", parentID: "child", depth: 2)
    let orphan = hierarchySummary(id: "orphan", parentID: "missing", depth: 1)
    let cycleA = hierarchySummary(id: "cycle-a", parentID: "cycle-b", depth: 1)
    let cycleB = hierarchySummary(id: "cycle-b", parentID: "cycle-a", depth: 1)

    let hierarchy = SessionListHierarchy.build(from: [
        child, main, orphan, grandchild, cycleA, cycleB,
    ])

    #expect(hierarchy.roots.map { $0.summary.id.rawValue } == [
        "main", "orphan", "cycle-a", "cycle-b",
    ])
    let mainNode = try #require(hierarchy.nodesByID[main.id])
    let childNode = try #require(hierarchy.nodesByID[child.id])
    #expect(mainNode.children.map { $0.summary.id } == [child.id])
    #expect(childNode.children.map { $0.summary.id } == [grandchild.id])
}

@Test func sessionListHierarchyOrdersChildrenRunningWaitingFailedDone() throws {
    let hierarchy = SessionListHierarchy.build(from: [
        hierarchySummary(id: "parent", updatedAt: 100),
        hierarchySummary(id: "done", parentID: "parent", lifecycle: .completed, phase: .idle, updatedAt: 99),
        hierarchySummary(id: "failed", parentID: "parent", lifecycle: .failed, phase: .idle, updatedAt: 98),
        hierarchySummary(id: "waiting", parentID: "parent", lifecycle: .waitingForInput, phase: .waitingForApproval, updatedAt: 97),
        hierarchySummary(id: "running", parentID: "parent", updatedAt: 96),
    ])
    // The same strip order the Notch and the iPhone use, not newest first.
    #expect(hierarchy.roots.first?.children.map(\.summary.id.rawValue) == ["running", "waiting", "failed", "done"])
}

@Test func sessionListHierarchyReusesNodesAndReloadsOnlyVisibleChanges() throws {
    let original = SessionListHierarchy.build(from: [
        hierarchySummary(id: "main"),
        hierarchySummary(id: "child", parentID: "main", depth: 1),
    ])
    let timestampOnly = SessionListHierarchy.build(from: [
        hierarchySummary(id: "main", updatedAt: 200),
        hierarchySummary(id: "child", parentID: "main", depth: 1, updatedAt: 200),
    ])

    #expect(original.hasSameStructure(as: timestampOnly))
    #expect(original.updateSummaries(from: timestampOnly.roots.flatMap(flatten)) == [])
    let originalMain = try #require(original.nodesByID[SessionID("main")])
    #expect(originalMain.summary.updatedAt == Date(timeIntervalSince1970: 200))

    let phaseChange = SessionListHierarchy.build(from: [
        hierarchySummary(id: "main", phase: .executing, updatedAt: 201),
        hierarchySummary(id: "child", parentID: "main", depth: 1, updatedAt: 201),
    ])
    #expect(original.hasSameStructure(as: phaseChange))
    #expect(original.updateSummaries(from: phaseChange.roots.flatMap(flatten)) == [SessionID("main")])

    // `needsReview` flips the tone (green ⇄ gray) without changing the
    // status text; the row diff must still report the change.
    let reviewFlip = SessionListHierarchy.build(from: [
        hierarchySummary(id: "main", lifecycle: .waitingForInput, phase: .idle, needsReview: true, updatedAt: 202),
        hierarchySummary(id: "child", parentID: "main", depth: 1, updatedAt: 202),
    ])
    #expect(original.hasSameStructure(as: reviewFlip))
    #expect(original.updateSummaries(from: reviewFlip.roots.flatMap(flatten)) == [SessionID("main")])
    let reviewed = SessionListHierarchy.build(from: [
        hierarchySummary(id: "main", lifecycle: .waitingForInput, phase: .idle, needsReview: false, updatedAt: 203),
        hierarchySummary(id: "child", parentID: "main", depth: 1, updatedAt: 203),
    ])
    #expect(original.updateSummaries(from: reviewed.roots.flatMap(flatten)) == [SessionID("main")])

    let reordered = SessionListHierarchy.build(from: [
        hierarchySummary(id: "child", parentID: "main", depth: 1),
        hierarchySummary(id: "main"),
    ])
    #expect(original.hasSameStructure(as: reordered))

    let detached = SessionListHierarchy.build(from: [
        hierarchySummary(id: "main"),
        hierarchySummary(id: "child"),
    ])
    #expect(!original.hasSameStructure(as: detached))
}

@Test func sessionPagePresentationBuildsSummaryAndCategorizesActivity() throws {
    let date = Date(timeIntervalSince1970: 100)
    let summary = SessionSummary(
        id: SessionID("session-page"),
        agent: .codex,
        title: "Session page",
        workspace: "/tmp/lumi",
        lifecycle: .running,
        phase: .responding,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date,
        needsAttention: true,
        lineage: SessionLineage(
            threadSource: "subagent",
            parentSessionID: SessionID("parent"),
            subagentDepth: 1,
            agentNickname: "Hypatia"
        )
    )
    let timeline: [TimelineItem] = [
        TimelineItem(
            id: TimelineItemID("model"),
            sessionID: summary.id,
            occurredAt: date,
            payload: .modelConfiguration(ModelConfigurationTimelinePayload(
                source: "turn_context",
                model: "gpt-5.6",
                provider: "openai",
                contextWindow: 200_000,
                reasoningEffort: "high",
                clientVersion: "1.0",
                settings: .object(["must-not-render": .string("raw-json")])
            ))
        ),
        TimelineItem(
            id: TimelineItemID("usage"),
            sessionID: summary.id,
            occurredAt: date.addingTimeInterval(1),
            payload: .usageMetrics(UsageMetricsTimelinePayload(
                total: TokenUsage(
                    inputTokens: 70,
                    cachedInputTokens: 20,
                    cacheWriteInputTokens: 10,
                    outputTokens: 30,
                    reasoningOutputTokens: 5,
                    totalTokens: 100
                ),
                modelContextWindow: 200_000
            ))
        ),
        activityItem(
            id: "system",
            sessionID: summary.id,
            date: date.addingTimeInterval(2),
            payload: .internalContext(InternalContextTimelinePayload(
                kind: "base_instructions",
                content: .object(["text": .string("System instruction")])
            ))
        ),
        activityItem(
            id: "context",
            sessionID: summary.id,
            date: date.addingTimeInterval(3),
            payload: .internalContext(InternalContextTimelinePayload(
                kind: "turn_context",
                content: .object(["type": .string("context")])
            ))
        ),
        activityItem(
            id: "reasoning",
            sessionID: summary.id,
            date: date.addingTimeInterval(4),
            payload: .internalContext(InternalContextTimelinePayload(
                kind: "reasoning",
                content: .string("Reasoning")
            ))
        ),
        activityItem(
            id: "user",
            sessionID: summary.id,
            date: date.addingTimeInterval(5),
            payload: .message(MessageTimelinePayload(role: .user, text: "User message"))
        ),
        activityItem(
            id: "assistant",
            sessionID: summary.id,
            date: date.addingTimeInterval(6),
            payload: .message(MessageTimelinePayload(role: .assistant, text: "Assistant message"))
        ),
        activityItem(
            id: "tool",
            sessionID: summary.id,
            date: date.addingTimeInterval(7),
            payload: .tool(ToolTimelinePayload(name: "Build", status: .succeeded))
        ),
        activityItem(
            id: "subagent",
            sessionID: summary.id,
            date: date.addingTimeInterval(8),
            payload: .subagent(SubagentTimelinePayload(name: "Reviewer", status: .completed))
        ),
        activityItem(
            id: "other",
            sessionID: summary.id,
            date: date.addingTimeInterval(9),
            payload: .error(ErrorTimelinePayload(
                title: "Failure",
                message: "Something failed",
                recoverable: true
            ))
        ),
    ]

    let presentation = SessionPagePresentationBuilder.presentation(
        for: SessionDetail(summary: summary, timeline: timeline)
    )

    #expect(presentation.summarySections.map(\.kind) == [
        .overview,
        .lineage,
        .modelConfiguration,
        .usage,
    ])
    let model = try #require(
        presentation.summarySections.first { $0.kind == .modelConfiguration }
    )
    #expect(model.title == "Model")
    #expect(model.fields.map(\.label) == [
        "Model",
        "Provider",
        "Context Window",
        "Reasoning Effort",
        "Client Version",
    ])
    #expect(!model.fields.contains { $0.value.contains("raw-json") })
    #expect(model.fields.first { $0.label == "Context Window" }?.value == "200,000")
    let overview = try #require(presentation.summarySections.first { $0.kind == .overview })
    #expect(overview.fields.map(\.label) == [
        "Session ID",
        "Agent",
        "Lifecycle",
        "Turn Phase",
        "Needs Attention",
        "Started",
    ])
    #expect(overview.fields.first { $0.label == "Session ID" }?.isMonospaced == true)
    let usage = try #require(presentation.summarySections.first { $0.kind == .usage })
    #expect(usage.fields.first { $0.label == "Total Tokens" }?.value == "100")
    #expect(presentation.metrics.totalTokens == 100)
    #expect(presentation.metrics.contextFraction == 100.0 / 200_000.0)
    #expect(presentation.metrics.endedAt == nil)
    #expect(presentation.metrics.totalTokensText == "100")
    #expect(presentation.metrics.contextText == "0%")
    #expect(presentation.activities.map(\.tag) == [
        .contextGroup,   // base_instructions (session scope)
        .context,        // turn_context
        .reasoning,
        .user,
        .assistant,
        .result,
        .subagent,
        .turnFailed,     // error payload: the turn failed, Model lane
    ])
    #expect(presentation.activities.first { $0.tag == .user }?.content == "User message")
    #expect(presentation.activities.first { $0.tag == .result }?.lane == .exec)
    #expect(presentation.activities.first { $0.tag == .turnFailed }?.level == .l3)
    #expect(presentation.activities.first { $0.tag == .turnFailed }?.lane == .model)
    let userActivity = try #require(presentation.activities.first { $0.tag == .user })
    #expect(
        SessionPagePresentationBuilder.rawData(for: userActivity.rawItem)
            .contains("User message")
    )
}

@Test func timelineTagsMapToLanesAndLevels() {
    #expect([TimelineTag.user, .context, .contextGroup].map(\.lane) == [.user, .user, .user])
    #expect([TimelineTag.tool, .result, .failed].map(\.lane) == [.exec, .exec, .exec])
    #expect([TimelineTag.reasoning, .assistant, .plan, .subagent, .turnEnd].map(\.lane) == [.model, .model, .model, .model, .model])
    #expect([TimelineTag.session, .compact].map(\.lane) == [nil, nil])
    #expect(TimelineTag.user.level == .l3 && TimelineTag.tool.level == .l1 && TimelineTag.reasoning.level == .l1)
    #expect(TimelineTag.user.tagStyle(.light).fill != .clear)
    #expect(TimelineTag.session.tagStyle(.light).fill == .clear)
    // Every tier carries a `.5px` ring, the Notch's dark variant included.
    #expect(TimelineTag.session.tagStyle(.light).ring.alpha > 0)
    #expect(TimelineTag.user.tagStyle(.dark).ring.alpha > 0)
}

@Test func sessionListFilteringKeepsAncestorsOfMatches() {
    let main = hierarchySummary(id: "main")
    let child = hierarchySummary(id: "child", parentID: "main", depth: 1)
    let other = hierarchySummary(id: "other")

    let filtered = SessionListHierarchy.filtering([main, child, other], query: "CHILD")
    #expect(filtered.map { $0.id.rawValue } == ["main", "child"])
    #expect(SessionListHierarchy.filtering([main, child, other], query: "   ").count == 3)
    #expect(SessionListHierarchy.filtering([main, child, other], query: "nope").isEmpty)
}

@Test func timelineModeTogglesBetweenLanesAndSingle() {
    #expect(ActivityTimelineMode.lanes.toggled == .single)
    #expect(ActivityTimelineMode.single.toggled == .lanes)
}

@Test func relativeTimeFormatterUsesListUnits() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func text(_ secondsAgo: TimeInterval) -> String {
        SessionRelativeTimeFormatter.string(from: now.addingTimeInterval(-secondsAgo), now: now)
    }
    #expect(text(3) == "now")
    #expect(text(12) == "12s")
    #expect(text(4 * 60 + 5) == "4m")
    #expect(text(3_600 + 30) == "1h")
    #expect(text(30 * 3_600) == "1d")
    #expect(text(3 * 86_400) == "3d")
}

@Test func elapsedFormatterUsesCompactUnits() {
    #expect(SessionElapsedFormatter.string(from: 12) == "12s")
    #expect(SessionElapsedFormatter.string(from: 223) == "3m 43s")
    #expect(SessionElapsedFormatter.string(from: 3_720) == "1h 02m")
    #expect(SessionElapsedFormatter.string(from: 48_180) == "13h 23m")
    #expect(SessionElapsedFormatter.string(from: 200_000) == "2d 07h")
}

@Test func completedSessionMetricsStopTheClock() {
    let started = Date(timeIntervalSince1970: 100)
    let ended = Date(timeIntervalSince1970: 400)
    let summary = SessionSummary(
        id: SessionID("done"),
        agent: .codex,
        title: "Done",
        lifecycle: .completed,
        phase: .idle,
        startedAt: started,
        updatedAt: ended,
        lastActivityAt: ended
    )
    let metrics = SessionPagePresentationBuilder.presentation(
        for: SessionDetail(summary: summary, timeline: [])
    ).metrics
    #expect(metrics.endedAt == ended)
    #expect(metrics.elapsedText(now: Date(timeIntervalSince1970: 10_000)) == "5m 0s")
    #expect(metrics.totalTokensText == "—")
    #expect(metrics.contextText == "—")
}

@Test @MainActor
func statusTonesResolveDistinctPillColors() {
    let tones: [SessionStatusTone] = [.blue, .orange, .green, .gray, .red]
    let fills = Set(tones.map { $0.pillFill.description })
    let texts = Set(tones.map { $0.pillText.description })
    #expect(fills.count == 5)
    #expect(texts.count == 5)
    #expect(SessionStatusTone.blue.dotHalo != nil)
    #expect(SessionStatusTone.orange.dotHalo != nil)
    #expect(SessionStatusTone.green.dotHalo != nil)
    #expect(SessionStatusTone.gray.dotHalo == nil)
}

@Test func sessionPageRendererBuildsOnItsOwnActor() async throws {
    let date = Date(timeIntervalSince1970: 100)
    let summary = SessionSummary(
        id: SessionID("actor-render"),
        agent: .codex,
        title: "Actor render",
        lifecycle: .running,
        phase: .thinking,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date
    )
    let renderer = SessionPagePresentationRenderer()
    let presentation = await renderer.presentation(
        for: SessionDetail(summary: summary, timeline: [])
    )

    #expect(presentation?.summarySections.map(\.kind) == [
        .overview,
        .modelConfiguration,
        .usage,
    ])
}


private func activityItem(
    id: String,
    sessionID: SessionID,
    date: Date,
    payload: TimelinePayload
) -> TimelineItem {
    TimelineItem(
        id: TimelineItemID(id),
        sessionID: sessionID,
        occurredAt: date,
        payload: payload
    )
}

private func nookSummary(
    id: String,
    lifecycle: SessionLifecycle,
    phase: TurnPhase,
    updatedAt: TimeInterval
) -> SessionSummary {
    let date = Date(timeIntervalSince1970: updatedAt)
    return SessionSummary(
        id: SessionID(id),
        agent: .codex,
        title: id.capitalized,
        lifecycle: lifecycle,
        phase: phase,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date
    )
}

private func hierarchySummary(
    id: String,
    parentID: String? = nil,
    depth: Int? = nil,
    lifecycle: SessionLifecycle = .running,
    phase: TurnPhase = .thinking,
    needsReview: Bool = false,
    updatedAt: TimeInterval = 100
) -> SessionSummary {
    let date = Date(timeIntervalSince1970: updatedAt)
    let lineage = parentID.map {
        SessionLineage(
            threadSource: "subagent",
            parentSessionID: SessionID($0),
            subagentDepth: depth,
            agentPath: "/root/\(id)",
            subagentKind: "thread_spawn"
        )
    }
    return SessionSummary(
        id: SessionID(id),
        agent: lineage == nil ? .codex : .codexSubagent,
        title: id,
        lifecycle: lifecycle,
        phase: phase,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date,
        needsReview: needsReview,
        lineage: lineage
    )
}

private func flatten(_ node: SessionListNode) -> [SessionSummary] {
    [node.summary] + node.children.flatMap(flatten)
}

// MARK: - Provisional sessions in the Mac store

@MainActor
private func macStoreFixture(client: (any MacDaemonClient)? = nil) throws -> (MacSessionStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumi-mac-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = if let client {
        MacSessionStore(
            socketPath: directory.appendingPathComponent("missing.sock").path,
            cachePath: directory.appendingPathComponent("cache.sqlite3").path,
            client: client
        )
    } else {
        MacSessionStore(
            socketPath: directory.appendingPathComponent("missing.sock").path,
            cachePath: directory.appendingPathComponent("cache.sqlite3").path
        )
    }
    return (store, directory)
}

/// A scripted daemon: summaries + full details behind offset-cursor paging,
/// mirroring the repository's `get_session` semantics.
private final class StubDaemonClient: MacDaemonClient, @unchecked Sendable {
    private let lock = NSLock()
    private var summaries: [SessionSummary]
    private var details: [SessionID: SessionDetail]
    private(set) var operations: [IPCOperation] = []

    init(details: [SessionDetail]) {
        summaries = details.map(\.summary)
        self.details = Dictionary(uniqueKeysWithValues: details.map { ($0.summary.id, $0) })
    }

    func replace(details: [SessionDetail]) {
        lock.lock()
        defer { lock.unlock() }
        summaries = details.map(\.summary)
        self.details = Dictionary(uniqueKeysWithValues: details.map { ($0.summary.id, $0) })
    }

    func request(_ request: IPCRequest, socketPath: String, timeoutSeconds: Int64) throws -> IPCResponse {
        lock.lock()
        defer { lock.unlock() }
        operations.append(request.operation)
        switch request.operation {
        case .health:
            return IPCResponse(status: .ok, health: DaemonHealth(
                daemonVersion: "test", executableHash: "test-hash", uptimeSeconds: 1, activeSessionCount: summaries.count,
                retainedSessionCount: summaries.count, socketPath: socketPath, relayConnected: false
            ))
        case .listSessions:
            return IPCResponse(status: .ok, sessions: summaries)
        case .getSession:
            guard let id = request.sessionID, let detail = details[id] else {
                return IPCResponse(status: .error, failure: IPCFailure(
                    code: "session_not_found", message: "gone", retryable: false
                ))
            }
            let offset = max(0, Int(request.cursor?.value ?? "0") ?? 0)
            let pageSize = max(1, min(request.limit ?? 200, 500))
            let page = Array(detail.timeline.dropFirst(offset).prefix(pageSize))
            let nextOffset = offset + page.count
            return IPCResponse(status: .ok, session: SessionDetail(
                summary: detail.summary,
                turns: detail.turns,
                timeline: page,
                nextCursor: nextOffset < detail.timeline.count
                    ? PaginationCursor(value: String(nextOffset))
                    : nil
            ))
        case .deleteSession:
            if let id = request.sessionID {
                summaries.removeAll { $0.id == id }
                details.removeValue(forKey: id)
            }
            return IPCResponse(status: .ok)
        default:
            return IPCResponse(status: .ok)
        }
    }
}

private func reconcileDetail(_ id: String, items: Int, updatedAt: TimeInterval) -> SessionDetail {
    let sessionID = SessionID(id)
    let date = Date(timeIntervalSince1970: updatedAt)
    return SessionDetail(
        summary: SessionSummary(
            id: sessionID, agent: .claude, title: id.capitalized,
            lifecycle: .running, phase: .thinking,
            startedAt: date, updatedAt: date, lastActivityAt: date,
            firstTurnAt: date
        ),
        turns: [TurnSummary(id: TurnID("\(id)-turn"), sessionID: sessionID, phase: .thinking, prompt: "hi", startedAt: date)],
        timeline: (0..<items).map { index in
            TimelineItem(
                id: TimelineItemID("\(id)-item-\(index)"), sessionID: sessionID,
                occurredAt: date.addingTimeInterval(Double(index)),
                payload: .message(MessageTimelinePayload(role: .assistant, text: "Update \(index)"))
            )
        }
    )
}

@Test @MainActor
func macStoreReconcileFetchesPagesPrunesAndConvergesOnDelete() async throws {
    let alpha = reconcileDetail("alpha", items: 7, updatedAt: 100)
    let beta = reconcileDetail("beta", items: 2, updatedAt: 90)
    let stub = StubDaemonClient(details: [alpha, beta])
    let (store, directory) = try macStoreFixture(client: stub)
    defer { try? FileManager.default.removeItem(at: directory) }

    await store.reconcileForTesting()
    #expect(store.sessions.map(\.id) == [alpha.summary.id, beta.summary.id])
    #expect(store.health?.daemonVersion == "test")
    let fetched = try await store.cachedSessionDetails(ids: [alpha.summary.id]).first
    #expect(fetched?.timeline.count == 7)
    #expect(fetched?.turns.count == 1)

    // Nothing changed: the second pass fetches no session.
    let before = stub.operations.filter { $0 == .getSession }.count
    await store.reconcileForTesting()
    #expect(stub.operations.filter { $0 == .getSession }.count == before)

    // The daemon dropped beta and advanced alpha: fetch one, prune one.
    let freshAlpha = reconcileDetail("alpha", items: 8, updatedAt: 200)
    stub.replace(details: [freshAlpha])
    await store.reconcileForTesting()
    #expect(store.sessions.map(\.id) == [alpha.summary.id])
    #expect(try await store.cachedSessionDetails(ids: [alpha.summary.id]).first?.timeline.count == 8)

    // Deleting converges: gone locally at once, still gone after reconcile.
    store.deleteSession(alpha.summary.id)
    for _ in 0..<100 where !store.sessions.isEmpty {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(store.sessions.isEmpty)
    await store.reconcileForTesting()
    #expect(store.sessions.isEmpty)
    #expect(try await store.cachedSessionDetails(ids: [alpha.summary.id]).isEmpty)
}

private func macStartEvent(_ id: String, event: String, at: TimeInterval) -> AgentIngressEvent {
    let sessionID = SessionID(id)
    return AgentIngressEvent(
        eventID: EventID(event), sessionID: sessionID, agent: .claude,
        occurredAt: Date(timeIntervalSince1970: at), lifecycle: .starting, phase: .idle,
        timelineItem: TimelineItem(
            id: TimelineItemIDs.sessionMarker(sessionID, .sessionStarted), sessionID: sessionID,
            occurredAt: Date(timeIntervalSince1970: at),
            payload: .sessionMarker(SessionMarkerTimelinePayload(kind: .sessionStarted, detail: "startup"))
        )
    )
}

private func macPromptEvent(_ id: String, event: String, at: TimeInterval) -> AgentIngressEvent {
    let sessionID = SessionID(id)
    return AgentIngressEvent(
        eventID: EventID(event), sessionID: sessionID, turnID: TurnID("turn-\(event)"), agent: .claude,
        occurredAt: Date(timeIntervalSince1970: at), lifecycle: .running, phase: .thinking,
        turn: TurnSummary(id: TurnID("turn-\(event)"), sessionID: sessionID, phase: .thinking, prompt: "hi", startedAt: Date(timeIntervalSince1970: at))
    )
}

@Test @MainActor
func macStoreHidesProvisionalSessionsUntilTheirFirstTurn() async throws {
    let (store, directory) = try macStoreFixture()
    defer { try? FileManager.default.removeItem(at: directory) }

    store.enqueueAgentEvent(macStartEvent("fresh", event: "fresh-start", at: 100))
    await store.flushPendingEventsForTesting()
    #expect(store.sessions.isEmpty)

    store.enqueueAgentEvent(macPromptEvent("fresh", event: "fresh-p1", at: 101))
    await store.flushPendingEventsForTesting()
    #expect(store.sessions.map(\.id) == [SessionID("fresh")])
    // The start marker was kept in the cache while the session was hidden.
    let detail = try await store.cachedSessionDetails(ids: [SessionID("fresh")]).first
    #expect(detail?.timeline.contains { $0.id == TimelineItemIDs.sessionMarker(SessionID("fresh"), .sessionStarted) } == true)
    #expect(try await store.snapshotDetails().map(\.summary.id) == [SessionID("fresh")])
}

@Test @MainActor
func macStoreAppliesDaemonEventsInArrivalOrderSoDiscardsWin() async throws {
    let (store, directory) = try macStoreFixture()
    defer { try? FileManager.default.removeItem(at: directory) }

    // start, prompt, discard → gone.
    store.enqueueAgentEvent(macStartEvent("ghost", event: "g-start", at: 100))
    store.enqueueAgentEvent(macPromptEvent("ghost", event: "g-p1", at: 101))
    store.enqueueAgentEvent(AgentIngressEvent(
        eventID: EventID("g-discard"), sessionID: SessionID("ghost"), agent: .claude,
        occurredAt: Date(timeIntervalSince1970: 102), disposition: .discard
    ))
    await store.flushPendingEventsForTesting()
    #expect(store.sessions.isEmpty)
    #expect(try await store.cachedSessionDetails(ids: [SessionID("ghost")]).isEmpty)

    // A later prompt (new event) is live activity and brings it back.
    store.enqueueAgentEvent(macPromptEvent("ghost", event: "g-p2", at: 200))
    await store.flushPendingEventsForTesting()
    #expect(store.sessions.map(\.id) == [SessionID("ghost")])
}

@Test func laneStripHitTestingSkipsGapsAndEmptyCells() {
    // 13pt cells on a 17pt pitch, three lanes; column 1 is filled in lane 1 only.
    let geometry = LaneStripGeometry(cellSize: 13, spacing: 4, laneCount: 3, columns: 3)
    let filled: (LaneStripGeometry.Cell) -> Bool = { $0.index == 1 && $0.lane == 1 }
    #expect(geometry.height == 47)
    #expect(geometry.contentWidth == 47)
    #expect(geometry.rect(index: 1, lane: 1) == CGRect(x: 17, y: 17, width: 13, height: 13))
    // Inside the filled square.
    #expect(geometry.cell(at: CGPoint(x: 20, y: 20), isFilled: filled) == .init(index: 1, lane: 1))
    // Same column, empty lane → nil.
    #expect(geometry.cell(at: CGPoint(x: 20, y: 3), isFilled: filled) == nil)
    // In the 4pt gap between columns / lanes → nil even if the lane is "filled".
    #expect(geometry.cell(at: CGPoint(x: 14, y: 20), isFilled: { _ in true }) == nil)
    #expect(geometry.cell(at: CGPoint(x: 20, y: 15), isFilled: { _ in true }) == nil)
    // Beyond the last column or below the strip → nil.
    #expect(geometry.cell(at: CGPoint(x: 60, y: 5), isFilled: { _ in true }) == nil)
    #expect(geometry.cell(at: CGPoint(x: 5, y: 60), isFilled: { _ in true }) == nil)
    #expect(geometry.cell(at: CGPoint(x: -1, y: 5), isFilled: { _ in true }) == nil)
    // Visible columns clamp to the content and pad one column for partial redraws.
    let wide = LaneStripGeometry(cellSize: 13, spacing: 4, laneCount: 3, columns: 100)
    #expect(wide.visibleColumns(in: CGRect(x: 30, y: 0, width: 40, height: 47)) == 1 ... 5)
    #expect(LaneStripGeometry(cellSize: 13, spacing: 4, laneCount: 3, columns: 2)
        .visibleColumns(in: CGRect(x: 0, y: 0, width: 40, height: 47)) == 0 ... 1)
    #expect(LaneStripGeometry(cellSize: 13, spacing: 4, laneCount: 3, columns: 0).visibleColumns(in: .zero) == nil)
}

@Test func laneStripMarkersAreFourPointBars() {
    // marker 4 · cell 13 · marker 4 · cell 13, gap 4 → lefts 0, 8, 25, 33; content 46.
    let geometry = LaneStripGeometry(cellSize: 13, spacing: 4, laneCount: 3, columnWidths: [4, 13, 4, 13])
    #expect(geometry.columnLefts == [0, 8, 25, 33, 50])
    #expect(geometry.contentWidth == 46)
    #expect(geometry.isMarker(0) && !geometry.isMarker(1))
    #expect(geometry.rect(index: 2, lane: 2) == CGRect(x: 25, y: 34, width: 4, height: 13))
    #expect(geometry.cell(at: CGPoint(x: 26, y: 40), isFilled: { _ in true }) == .init(index: 2, lane: 2))
    #expect(geometry.cell(at: CGPoint(x: 30, y: 40), isFilled: { _ in true }) == nil) // gap after the bar
    #expect(geometry.visibleColumns(in: CGRect(x: 26, y: 0, width: 5, height: 47)) == 2 ... 3)
}

@Test func activityScrollMapRelatesRowsAndColumnsByIndex() {
    // Rows: marker 32 (4pt bar), then three item rows of 40 (13pt cells). Top inset 6, gap 4.
    let map = ActivityScrollMap(
        rows: [(32, 4), (40, 13), (40, 13), (40, 13)],
        topInset: 6, spacing: 4
    )
    #expect(map.rowCount == 4 && map.columnCount == 4)
    #expect(map.rowOfColumn == [0, 1, 2, 3])
    // Column lefts: 0 (bar), 8, 25, 42; next 59.
    #expect(map.columnLefts == [0, 8, 25, 42, 59])
    // Row tops: 6, 38, 78, 118; bottom 158.
    #expect(map.rowIndex(at: 0) == 0 && map.rowIndex(at: 38) == 1 && map.rowIndex(at: 117.9) == 2 && map.rowIndex(at: 999) == 3)
    // Row 0 top edge ↔ column 0; half way down row 1 ↔ half way across column 1 (8 + 8.5).
    #expect(map.stripOffset(forListOffset: 6) == 0)
    #expect(map.stripOffset(forListOffset: 58) == 16.5)
    // Row tops land on column lefts.
    #expect(map.stripOffset(forListOffset: 78) == 25)
    #expect(map.stripOffset(forListOffset: 118) == 42)
    // Inverse: column 2 ↔ row 2's top; half way across column 0 (4) ↔ half way down row 0.
    #expect(map.listOffset(forStripOffset: 25) == 78)
    #expect(map.listOffset(forStripOffset: 4) == 22.0)
    // Out of range clamps instead of crashing.
    #expect(map.listOffset(forStripOffset: 1000) == 158.0)
    #expect(ActivityScrollMap().stripOffset(forListOffset: 10) == 0)
}

@Test @MainActor
func activityScrollLinkOnlyLetsTheDriverSteer() {
    let link = ActivityScrollLink()
    var listRequests: [CGFloat] = []
    var stripRequests: [CGFloat] = []
    link.scrollList = { listRequests.append($0) }
    link.scrollStrip = { stripRequests.append($0) }
    // 10 item rows of 40, every row draws a cell; pitch 17.
    link.map = ActivityScrollMap(rows: Array(repeating: (40, 13), count: 10), topInset: 0, spacing: 4)
    link.listDidScroll(.init(offset: 0, content: 400, viewport: 200))
    link.stripDidScroll(.init(offset: 0, content: 170, viewport: 85))

    // Nobody is driving: programmatic moves and content growth propagate nothing.
    link.listDidScroll(.init(offset: 80, content: 400, viewport: 200))
    link.listDidScroll(.init(offset: 80, content: 440, viewport: 200))
    #expect(stripRequests.isEmpty && listRequests.isEmpty)

    // User scrolls the list: strip follows row 2 → column 2 (34pt); strip's own report steers nothing back.
    link.listPhaseChanged(isUserScrolling: true)
    link.listDidScroll(.init(offset: 80, content: 440, viewport: 200))
    #expect(stripRequests == [34])
    link.stripDidScroll(.init(offset: 34, content: 170, viewport: 85))
    #expect(listRequests.isEmpty)
    link.listPhaseChanged(isUserScrolling: false)
    #expect(link.driver == .none)

    // User pans the strip to column 4 → list to row 4 (160pt); list's report steers nothing back.
    link.beginStripPan()
    link.stripDidScroll(.init(offset: 68, content: 170, viewport: 85))
    #expect(listRequests == [160])
    link.listDidScroll(.init(offset: 160, content: 440, viewport: 200))
    #expect(stripRequests == [34])
    link.endStripPan()

    // Follow-bottom is explicit: both sides go to the end.
    link.scrollStripToEnd()
    #expect(stripRequests.last == 85)
}
