import Transport
import Foundation
import GRDB
import Testing
@testable import Core
@testable import Persistence

// MARK: - Matcher

private func summary(
    id: String = "s",
    agent: AgentKind = .codex,
    workspace: String? = nil,
    aaas: SessionAaaS? = nil,
    lineage: SessionLineage? = nil,
    hiddenByFilter: Bool = false
) -> SessionSummary {
    let date = Date(timeIntervalSince1970: 100)
    return SessionSummary(
        id: SessionID(id),
        agent: agent,
        title: "T",
        workspace: workspace,
        lifecycle: .running,
        phase: .thinking,
        startedAt: date,
        updatedAt: date,
        lastActivityAt: date,
        hiddenByFilter: hiddenByFilter,
        lineage: lineage,
        aaas: aaas
    )
}

private func rule(
    _ conditions: [SessionFilterCondition],
    isEnabled: Bool = true
) -> SessionFilterRule {
    SessionFilterRule(isEnabled: isEnabled, conditions: conditions)
}

@Test func matcherCoversEveryFieldAndOperator() {
    let target = summary(
        agent: .codex,
        workspace: "/Users/dev/tmp/project",
        aaas: SessionAaaS(kind: .paseo)
    )

    // Agent is / contains (set semantics over provider raw values).
    #expect(SessionFilterMatcher.shouldHide(
        rules: [rule([.init(field: .agent, op: .is, value: .text("codex"))])],
        summary: target, firstUserMessage: nil
    ))
    #expect(!SessionFilterMatcher.shouldHide(
        rules: [rule([.init(field: .agent, op: .is, value: .text("claude"))])],
        summary: target, firstUserMessage: nil
    ))
    #expect(SessionFilterMatcher.shouldHide(
        rules: [rule([.init(field: .agent, op: .contains, value: .options(["claude", "codex"]))])],
        summary: target, firstUserMessage: nil
    ))

    // Application over AaaS raw values; nil aaas never matches.
    #expect(SessionFilterMatcher.shouldHide(
        rules: [rule([.init(field: .application, op: .contains, value: .options(["paseo", "raft"]))])],
        summary: target, firstUserMessage: nil
    ))
    #expect(!SessionFilterMatcher.shouldHide(
        rules: [rule([.init(field: .application, op: .is, value: .text("paseo"))])],
        summary: summary(aaas: nil), firstUserMessage: nil
    ))

    // Message contains / startsWith on the first user message.
    #expect(SessionFilterMatcher.shouldHide(
        rules: [rule([.init(field: .message, op: .contains, value: .text("throwaway"))])],
        summary: target, firstUserMessage: "a throwaway probe"
    ))
    #expect(SessionFilterMatcher.shouldHide(
        rules: [rule([.init(field: .message, op: .startsWith, value: .text("test:"))])],
        summary: target, firstUserMessage: "test: ignore me"
    ))
    #expect(!SessionFilterMatcher.shouldHide(
        rules: [rule([.init(field: .message, op: .contains, value: .text("throwaway"))])],
        summary: target, firstUserMessage: nil
    ))

    // Folder is component-safe prefix.
    #expect(SessionFilterMatcher.shouldHide(
        rules: [rule([.init(field: .folder, op: .is, value: .text("/Users/dev/tmp"))])],
        summary: target, firstUserMessage: nil
    ))
    #expect(!SessionFilterMatcher.shouldHide(
        rules: [rule([.init(field: .folder, op: .is, value: .text("/Users/dev/tm"))])],
        summary: target, firstUserMessage: nil
    ))
    #expect(SessionFilterMatcher.shouldHide(
        rules: [rule([.init(field: .folder, op: .is, value: .text("/Users/dev/tmp/project"))])],
        summary: target, firstUserMessage: nil
    ))
}

@Test func matcherAndsWithinARuleAndOrsAcrossRules() {
    let target = summary(agent: .codex, workspace: "/tmp/x")
    let both = rule([
        .init(field: .agent, op: .is, value: .text("codex")),
        .init(field: .folder, op: .is, value: .text("/tmp")),
    ])
    let halfMiss = rule([
        .init(field: .agent, op: .is, value: .text("claude")),
        .init(field: .folder, op: .is, value: .text("/tmp")),
    ])
    #expect(SessionFilterMatcher.shouldHide(rules: [both], summary: target, firstUserMessage: nil))
    #expect(!SessionFilterMatcher.shouldHide(rules: [halfMiss], summary: target, firstUserMessage: nil))
    // OR across rules: the missing rule does not veto the matching one.
    #expect(SessionFilterMatcher.shouldHide(rules: [halfMiss, both], summary: target, firstUserMessage: nil))
}

@Test func matcherSkipsDisabledRulesEmptyValuesAndEmptyRules() {
    let target = summary(agent: .codex)
    let matching = SessionFilterCondition(field: .agent, op: .is, value: .text("codex"))
    #expect(!SessionFilterMatcher.shouldHide(
        rules: [rule([matching], isEnabled: false)],
        summary: target, firstUserMessage: nil
    ))
    #expect(!SessionFilterMatcher.shouldHide(
        rules: [rule([.init(field: .message, op: .contains, value: .text(""))])],
        summary: target, firstUserMessage: "anything"
    ))
    #expect(!SessionFilterMatcher.shouldHide(
        rules: [rule([.init(field: .agent, op: .contains, value: .options(["", ""]))])],
        summary: target, firstUserMessage: nil
    ))
    #expect(!SessionFilterMatcher.shouldHide(rules: [rule([])], summary: target, firstUserMessage: nil))
}

@Test func firstUserMessageIsClassificationOnly() {
    // A turn prompt without a user-classified timeline message is NOT a user
    // message — the matcher reads classification, never raw turn data.
    let viaPromptOnly = AgentIngressEvent(
        eventID: EventID("e1"), sessionID: SessionID("s"), agent: .codex,
        occurredAt: Date(timeIntervalSince1970: 10),
        turn: TurnSummary(id: TurnID("t"), sessionID: SessionID("s"), phase: .thinking, prompt: "hello", startedAt: Date(timeIntervalSince1970: 10))
    )
    #expect(SessionFilterMatcher.firstUserMessage(of: viaPromptOnly) == nil)

    let viaMessage = AgentIngressEvent(
        eventID: EventID("e2"), sessionID: SessionID("s"), agent: .codex,
        occurredAt: Date(timeIntervalSince1970: 10),
        timelineItem: TimelineItem(
            id: TimelineItemID("m"), sessionID: SessionID("s"),
            occurredAt: Date(timeIntervalSince1970: 10),
            payload: .message(MessageTimelinePayload(role: .user, text: "hello"))
        )
    )
    #expect(SessionFilterMatcher.firstUserMessage(of: viaMessage) == "hello")

    let assistant = AgentIngressEvent(
        eventID: EventID("e3"), sessionID: SessionID("s"), agent: .codex,
        occurredAt: Date(timeIntervalSince1970: 10),
        timelineItem: TimelineItem(
            id: TimelineItemID("a"), sessionID: SessionID("s"),
            occurredAt: Date(timeIntervalSince1970: 10),
            payload: .message(MessageTimelinePayload(role: .assistant, text: "hi there"))
        )
    )
    #expect(SessionFilterMatcher.firstUserMessage(of: assistant) == nil)
}

// MARK: - Transitive hidden set

@Test func filterHiddenIDsHidesTheWholeSubagentGroup() {
    let parent = summary(id: "parent", hiddenByFilter: true)
    let child = summary(id: "child", agent: .codexSubagent, lineage: SessionLineage(parentSessionID: SessionID("parent")))
    let grandchild = summary(id: "grandchild", agent: .codexSubagent, lineage: SessionLineage(parentSessionID: SessionID("child")))
    let bystander = summary(id: "bystander")

    let hidden = SessionSummary.filterHiddenIDs([parent, child, grandchild, bystander])
    #expect(hidden == [SessionID("parent"), SessionID("child"), SessionID("grandchild")])
}

// MARK: - Repository evaluation on the first user message

private final class RecordingFilter: SessionFilterEvaluating, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(SessionID, String?)] = []
    let verdict: Bool

    init(verdict: Bool) { self.verdict = verdict }

    var calls: [(SessionID, String?)] {
        lock.withLock { _calls }
    }

    func shouldHide(summary: SessionSummary, event: AgentIngressEvent) -> Bool {
        lock.withLock { _calls.append((summary.id, SessionFilterMatcher.firstUserMessage(of: event))) }
        return verdict
    }
}

private func startEvent(_ id: String, session: String = "s", at seconds: TimeInterval) -> AgentIngressEvent {
    AgentIngressEvent(
        eventID: EventID(id), sessionID: SessionID(session), agent: .codex,
        occurredAt: Date(timeIntervalSince1970: seconds),
        workspace: "/tmp/x",
        lifecycle: .starting, phase: .idle
    )
}

/// A Codex-watcher-style turn opener: carries the turn but NO timeline item —
/// under classification-based triggering it must not evaluate.
private func turnOnlyEvent(_ id: String, session: String = "s", turn: String = "t", at seconds: TimeInterval) -> AgentIngressEvent {
    AgentIngressEvent(
        eventID: EventID(id), sessionID: SessionID(session), turnID: TurnID(turn), agent: .codex,
        occurredAt: Date(timeIntervalSince1970: seconds),
        lifecycle: .running, phase: .thinking,
        turn: TurnSummary(id: TurnID(turn), sessionID: SessionID(session), phase: .thinking, startedAt: Date(timeIntervalSince1970: seconds))
    )
}

/// A user-classified message event — the evaluation trigger. `turn` is
/// optional: slash-command and Raft sessions carry none.
private func userMessageEvent(
    _ id: String,
    session: String = "s",
    turn: String? = "t",
    at seconds: TimeInterval,
    text: String = "hi"
) -> AgentIngressEvent {
    let sessionID = SessionID(session)
    return AgentIngressEvent(
        eventID: EventID(id), sessionID: sessionID, turnID: turn.map(TurnID.init), agent: .codex,
        occurredAt: Date(timeIntervalSince1970: seconds),
        lifecycle: .running, phase: .thinking,
        timelineItem: TimelineItem(
            id: TimelineItemID("item-\(id)"),
            sessionID: sessionID,
            turnID: turn.map(TurnID.init),
            occurredAt: Date(timeIntervalSince1970: seconds),
            payload: .message(MessageTimelinePayload(role: .user, text: text))
        )
    )
}

private func repositories(filter: (any SessionFilterEvaluating)?) throws -> [any SessionRepository] {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("filter-tests-\(UUID().uuidString)")
    return [
        InMemorySessionRepository(sessionFilter: filter),
        try SQLiteSessionRepository(
            path: directory.appendingPathComponent("sessions.sqlite3").path,
            sessionFilter: filter
        ),
    ]
}

@Test func evaluatorFiresOnceOnTheFirstUserMessageAndStampsVerdictPlusLatch() async throws {
    let filter = RecordingFilter(verdict: true)
    for repository in try repositories(filter: filter) {
        let before = filter.calls.count
        // Session start and a turn-opening event without a message item
        // (the Codex watcher's task_started): no evaluation.
        #expect(try await repository.apply(startEvent("start", at: 10)))
        #expect(try await repository.apply(turnOnlyEvent("task-started", at: 15)))
        #expect(filter.calls.count == before)
        let pending = try await repository.sessionDetail(id: SessionID("s"), cursor: nil, limit: 1)?.summary
        #expect(pending?.filterEvaluated == false)

        // First user-classified message: evaluated once, text visible,
        // verdict and latch stamped together.
        #expect(try await repository.apply(userMessageEvent("m1", at: 20)))
        #expect(filter.calls.count == before + 1)
        #expect(filter.calls.last?.1 == "hi")
        let stamped = try await repository.sessionDetail(id: SessionID("s"), cursor: nil, limit: 1)?.summary
        #expect(stamped?.hiddenByFilter == true)
        #expect(stamped?.filterEvaluated == true)

        // Later user messages never re-evaluate.
        #expect(try await repository.apply(userMessageEvent("m2", turn: "t2", at: 30, text: "again")))
        #expect(filter.calls.count == before + 1)
    }
}

@Test func aTurnlessUserMessageTriggersEvaluation() async throws {
    // Slash-command / Raft sessions: a user message with no turn at all.
    let filter = RecordingFilter(verdict: true)
    for repository in try repositories(filter: filter) {
        let before = filter.calls.count
        let command = userMessageEvent("cmd", session: "ghost", turn: nil, at: 20, text: "<command-name>/usage</command-name>")
        #expect(try await repository.apply(command))
        #expect(filter.calls.count == before + 1)
        #expect(filter.calls.last?.1 == "<command-name>/usage</command-name>")
        let stored = try await repository.sessionDetail(id: SessionID("ghost"), cursor: nil, limit: 1)?.summary
        #expect(stored?.hiddenByFilter == true)
        #expect(stored?.firstTurnAt == nil)
    }
}

@Test func theLatchStampsEvenWhenTheVerdictIsVisible() async throws {
    let filter = RecordingFilter(verdict: false)
    for repository in try repositories(filter: filter) {
        let before = filter.calls.count
        #expect(try await repository.apply(userMessageEvent("m1", at: 20)))
        let stored = try await repository.sessionDetail(id: SessionID("s"), cursor: nil, limit: 1)?.summary
        #expect(stored?.hiddenByFilter == false)
        #expect(stored?.filterEvaluated == true)
        // Judged-and-visible is final: the next message does not re-judge.
        #expect(try await repository.apply(userMessageEvent("m2", at: 30)))
        #expect(filter.calls.count == before + 1)
    }
}

@Test func evaluatorSkipsSubagentSessions() async throws {
    let filter = RecordingFilter(verdict: true)
    for repository in try repositories(filter: filter) {
        let before = filter.calls.count
        var event = userMessageEvent("sub-m", session: "child", at: 20, text: "seed prompt from parent")
        event.agent = .codexSubagent
        event.lineage = SessionLineage(parentSessionID: SessionID("parent"))
        #expect(try await repository.apply(event))
        #expect(filter.calls.count == before)
        let child = try await repository.sessionDetail(id: SessionID("child"), cursor: nil, limit: 1)?.summary
        #expect(child?.hiddenByFilter == false)
        #expect(child?.filterEvaluated == false)
    }
}

@Test func withoutAnEvaluatorTheLatchStillStampsAndNothingHides() async throws {
    // Mirrors run without an evaluator but must converge on the latch.
    for repository in try repositories(filter: nil) {
        #expect(try await repository.apply(userMessageEvent("m1", at: 20)))
        let stored = try await repository.sessionDetail(id: SessionID("s"), cursor: nil, limit: 1)?.summary
        #expect(stored?.hiddenByFilter == false)
        #expect(stored?.filterEvaluated == true)
    }
}

@Test func verdictAndLatchAreFrozenThroughResurrectionEvents() {
    let hidden = summary(hiddenByFilter: true).withFilterEvaluated(true)
    // A new user prompt resurrects deleted/archived sessions, but the filter
    // verdict is frozen — it must survive exactly this event.
    let prompt = userMessageEvent("resurrect", at: 500)
    #expect(prompt.resurrectsHiddenSession)
    let reduced = SessionReduction.summary(applying: prompt, to: hidden)
    #expect(reduced.hiddenByFilter == true)
    #expect(reduced.filterEvaluated == true)
}

@Test func setSessionFilterVerdictWritesBothFieldsBothDirections() async throws {
    for repository in try repositories(filter: nil) {
        #expect(try await repository.apply(userMessageEvent("m1", at: 20)))
        try await repository.setSessionFilterVerdict(SessionID("s"), hiddenByFilter: true, filterEvaluated: true)
        var stored = try await repository.sessionDetail(id: SessionID("s"), cursor: nil, limit: 1)?.summary
        #expect(stored?.hiddenByFilter == true)
        #expect(stored?.filterEvaluated == true)
        try await repository.setSessionFilterVerdict(SessionID("s"), hiddenByFilter: false, filterEvaluated: false)
        stored = try await repository.sessionDetail(id: SessionID("s"), cursor: nil, limit: 1)?.summary
        #expect(stored?.hiddenByFilter == false)
        #expect(stored?.filterEvaluated == false)
    }
}

// MARK: - Rule storage

@Test func filterRulesRoundTripInOrderAndSurviveClearHistory() async throws {
    let rules = [
        rule([.init(field: .agent, op: .is, value: .text("codex"))]),
        rule([.init(field: .folder, op: .is, value: .text("/tmp"))], isEnabled: false),
        rule([.init(field: .application, op: .contains, value: .options(["paseo", "raft"]))]),
    ]
    for repository in try repositories(filter: nil) {
        try await repository.setSessionFilterRules(rules)
        #expect(try await repository.sessionFilterRules() == rules)

        // Reorder via whole-list replace.
        let reversed = Array(rules.reversed())
        try await repository.setSessionFilterRules(reversed)
        #expect(try await repository.sessionFilterRules() == reversed)

        // Rules are settings, not history: clearing history keeps them.
        #expect(try await repository.apply(userMessageEvent("m-storage", at: 20)))
        _ = try await repository.deleteAllSessions()
        #expect(try await repository.sessionFilterRules() == reversed)

        // Per-session delete does not touch them either.
        #expect(try await repository.apply(userMessageEvent("m-storage-2", session: "s2", turn: "t2", at: 30)))
        _ = try await repository.deleteSession(id: SessionID("s2"))
        #expect(try await repository.sessionFilterRules() == reversed)
    }
}

// A real-world v6 database can hold turns/timeline rows whose session is
// gone (stranded before FK enforcement caught it). GRDB ends each migration
// with a full-database foreign-key check, so lumi-v7 must sweep those
// orphans first or the daemon crash-loops on open.
@Test func migrationV7SweepsOrphanedChildRowsBeforeItsForeignKeyCheck() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("filter-v6db-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("sessions.sqlite3").path

    // A v6-era database: v1+v2 schema, migrations v1..v6 recorded as applied,
    // one valid session, and orphaned child rows (foreign keys off, the state
    // an old bug left behind).
    var configuration = Configuration()
    configuration.foreignKeysEnabled = false
    let db = try DatabaseQueue(path: path, configuration: configuration)
    try await db.write { db in
        try db.execute(sql: """
            CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
            INSERT INTO grdb_migrations(identifier) VALUES
                ('lumi-v1'), ('lumi-v2-turns'), ('lumi-v3-sweep-empty-claude-sessions'),
                ('lumi-v4-needs-review'), ('lumi-v5-hidden-in-notch'), ('lumi-v6-retire-subagent-running');
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY NOT NULL,
                summary BLOB NOT NULL,
                updated_at REAL NOT NULL,
                last_activity_at REAL NOT NULL
            );
            CREATE TABLE timeline (
                id TEXT PRIMARY KEY NOT NULL,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                occurred_at REAL NOT NULL,
                item BLOB NOT NULL
            );
            CREATE TABLE processed_events (id TEXT PRIMARY KEY NOT NULL, occurred_at REAL NOT NULL);
            CREATE TABLE rollout_cursors (
                path TEXT PRIMARY KEY NOT NULL, byte_offset INTEGER NOT NULL,
                file_size INTEGER NOT NULL, session_id TEXT, updated_at REAL NOT NULL
            );
            CREATE TABLE ignored_sessions (id TEXT PRIMARY KEY NOT NULL);
            CREATE TABLE metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
            CREATE TABLE turns (
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                turn_id TEXT NOT NULL, started_at REAL NOT NULL, summary BLOB NOT NULL,
                PRIMARY KEY(session_id, turn_id)
            );
            """)
        let kept = summary(id: "kept")
        // A v6-era summary blob predates both filter keys: strip them so the
        // v7 (hiddenByFilter) and v8 (filterEvaluated) backfills are exercised.
        try db.execute(
            sql: """
                INSERT INTO sessions(id, summary, updated_at, last_activity_at)
                VALUES(?, CAST(json_remove(CAST(? AS TEXT), '$.hiddenByFilter', '$.filterEvaluated') AS BLOB), 100, 100)
                """,
            arguments: ["kept", try TransportCoding.makeEncoder().encode(kept.withHiddenInNotch(false))]
        )
        try db.execute(sql: """
            INSERT INTO turns(session_id, turn_id, started_at, summary) VALUES('gone', 't1', 50, x'7b7d');
            INSERT INTO timeline(id, session_id, occurred_at, item) VALUES('i1', 'gone', 50, x'7b7d');
            """)
    }

    // Opening the repository runs lumi-v7 and v8; the chain must survive the
    // orphans (v7's FK check), drop the turns table and backfill both flags.
    let repository = try SQLiteSessionRepository(path: path)
    let sessions = try await repository.listSessions(limit: 10)
    #expect(sessions.map(\.id) == [SessionID("kept")])
    #expect(sessions[0].hiddenByFilter == false)
    // Pre-existing sessions are frozen as already judged (no retroactivity).
    #expect(sessions[0].filterEvaluated == true)
    let (timelineOrphans, turnsTableCount) = try await db.read { db in
        (
            try Int.fetchOne(db, sql: "SELECT count(*) FROM timeline WHERE session_id = 'gone'") ?? -1,
            try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'turns'") ?? -1
        )
    }
    #expect(timelineOrphans == 0)
    #expect(turnsTableCount == 0)
}

@Test func filterRulesPersistAcrossRepositoryInstances() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("filter-persist-\(UUID().uuidString)")
    let path = directory.appendingPathComponent("sessions.sqlite3").path
    let rules = [rule([.init(field: .message, op: .startsWith, value: .text("test:"))])]

    let first = try SQLiteSessionRepository(path: path)
    try await first.setSessionFilterRules(rules)

    let second = try SQLiteSessionRepository(path: path)
    #expect(try await second.sessionFilterRules() == rules)
}
