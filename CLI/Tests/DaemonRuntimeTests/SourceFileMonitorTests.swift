import Adapters
import Core
import Synchronization
import Transport
import Foundation
import Testing
@testable import DaemonRuntime

private func temporaryDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumi-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func eventually(
    _ comment: Comment,
    timeout: Duration = .seconds(10),
    _ condition: @Sendable () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while try await !condition() {
        try #require(ContinuousClock.now < deadline, comment)
        try await Task.sleep(for: .milliseconds(25))
    }
}

private final class Collected<Element: Sendable>: Sendable {
    private let storage = Mutex<[Element]>([])

    func append(_ element: Element) {
        storage.withLock { $0.append(element) }
    }

    var all: [Element] {
        storage.withLock { $0 }
    }
}

// MARK: Inventory

@Test func inventoryListsVisibleJSONLFilesWithTheFactsOfOneWalk() throws {
    let root = try temporaryDirectory("inventory")
    defer { try? FileManager.default.removeItem(at: root) }
    let day = root.appendingPathComponent("2026/11/17", isDirectory: true)
    for directory in [day, root.appendingPathComponent(".hidden"), day.appendingPathComponent(".trash")] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    for relative in [
        "top.jsonl", "2026/11/17/rollout-a.jsonl",
        // Not listed: compressed, another kind, hidden, inside something hidden.
        "2026/11/17/rollout-old.jsonl.zst", "2026/11/17/notes.txt", "2026/11/17/.partial.jsonl",
        ".hidden/x.jsonl", "2026/11/17/.trash/y.jsonl",
    ] {
        try Data("{\"n\":1}\n".utf8).write(to: root.appendingPathComponent(relative))
    }

    let files = jsonlFiles(under: root).sorted { $0.relativePath < $1.relativePath }
    #expect(files.map(\.relativePath) == ["2026/11/17/rollout-a.jsonl", "top.jsonl"])

    // The walk's own stat carries what the readers key on.
    let top = try #require(files.last)
    let path = root.appendingPathComponent("top.jsonl").path
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    #expect(top.size == (attributes[.size] as? NSNumber)?.uint64Value)
    #expect(currentFileSize(atPath: path) == top.size)
    let modified = try #require(attributes[.modificationDate] as? Date)
    #expect(abs(top.modifiedAt.timeIntervalSince(modified)) < 0.001)
    // Stored usage cursors key on this string: both spellings are one.
    #expect(
        UsageFileIdentity.identity(source: .codex, device: top.device, inode: top.inode)
            == UsageFileIdentity.identity(source: .codex, attributes: attributes, path: path)
    )

    // A root that was never created is an agent that was never used here.
    #expect(jsonlFiles(under: root.appendingPathComponent("missing")).isEmpty)
    #expect(currentFileSize(atPath: root.appendingPathComponent("missing.jsonl").path) == nil)
}

@Test func onlyThePartBelowTheRootDecidesWhetherAPathIsHidden() {
    // The roots themselves are `~/.codex/sessions` and `~/.claude/projects`.
    let root = "/Users/someone/.codex/sessions"
    #expect(isSourceFile(root + "/2026/11/17/rollout.jsonl", underRoot: root))
    #expect(!isSourceFile(root + "/2026/.cache/rollout.jsonl", underRoot: root))
    #expect(!isSourceFile(root + "/2026/11/17/.rollout.jsonl", underRoot: root))
    #expect(!isSourceFile(root + "/2026/11/17/rollout.jsonl.zst", underRoot: root))
    #expect(!isSourceFile("/Users/someone/.codex/state_5.sqlite", underRoot: root))
    #expect(!isSourceFile("/Users/someone/.codex/sessions-other/a.jsonl", underRoot: root))
}

@Test func theUsageScanReusesAWatchersWalkAndWatchersAlwaysWalk() async throws {
    let root = try temporaryDirectory("shared-inventory")
    defer { try? FileManager.default.removeItem(at: root) }
    func add(_ name: String) throws {
        try Data("{}\n".utf8).write(to: root.appendingPathComponent(name))
    }
    try add("a.jsonl")
    let inventory = SourceInventory(maximumAge: .seconds(60))
    // A watcher's pass walks, and leaves the walk behind.
    #expect(inventory.freshFiles(under: root).count == 1)
    try add("b.jsonl")
    // The usage scan takes that walk instead of repeating it…
    #expect(inventory.files(under: root).count == 1)
    // …while a watcher never does: its inventory decides what is read.
    #expect(inventory.freshFiles(under: root).count == 2)
    #expect(inventory.files(under: root).count == 2)

    // A walk that has grown too old is repeated, by the same inventory.
    let brief = SourceInventory(maximumAge: .milliseconds(20))
    #expect(brief.files(under: root).count == 2)
    try add("c.jsonl")
    try await Task.sleep(for: .milliseconds(80))
    #expect(brief.files(under: root).count == 3)
}

@Test func watchBudgetLeavesRoomForTheRestOfTheDaemon() {
    #expect(OpenFileLimit.watchBudget(limit: 4_096, watchers: 2) == 256)
    // launchd's default for an agent: 256 descriptors in all.
    #expect(OpenFileLimit.watchBudget(limit: 256, watchers: 2) == 32)
    #expect(OpenFileLimit.watchBudget(limit: 100, watchers: 2) == 0)
    // Raising never lowers.
    #expect(OpenFileLimit.raise(to: 1) > 1)
}

// MARK: Directory events

@Test func directoryEventsNameNewFilesUnderTheConfiguredRoot() async throws {
    let root = try temporaryDirectory("directory-events")
    defer { try? FileManager.default.removeItem(at: root) }
    let seen = Collected<DirectoryEvents.Event>()
    let events = DirectoryEvents(root: root) { seen.append($0) }
    #expect(events.start())
    #expect(events.start())
    defer { events.stop() }

    let day = root.appendingPathComponent("2026/11", isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let file = day.appendingPathComponent("rollout.jsonl")
    try Data("{}\n".utf8).write(to: file)
    // The temporary directory sits behind `/var` → `/private/var`. The
    // event names the path as configured — the one cursors key on.
    try await eventually("a new file is announced under the configured root") {
        seen.all.contains(.changed(path: file.path))
    }
    #expect(!seen.all.contains { event in
        if case let .changed(path) = event { !path.hasPrefix(root.path + "/") } else { false }
    })
}

@Test func directoryEventsWaitForARootThatDoesNotExistYet() throws {
    let parent = try temporaryDirectory("directory-events-missing")
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("sessions", isDirectory: true)
    let events = DirectoryEvents(root: root) { _ in }
    #expect(!events.start())
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    #expect(events.start())
    events.stop()
}

// MARK: File watches

@Test func fileWatchHearsEveryWriteToAFileItsWriterKeepsOpen() async throws {
    let root = try temporaryDirectory("file-watch")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("open.jsonl")
    #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
    let seen = Collected<FileWatchSet.Event>()
    let watches = FileWatchSet(limit: 4) { seen.append($0) }
    #expect(watches.watch(file.path))

    // The writer never closes the file between writes — the case directory
    // events are silent about.
    let writer = try FileHandle(forWritingTo: file)
    defer { try? writer.close() }
    try writer.write(contentsOf: Data("one\n".utf8))
    try await eventually("the first write is heard") { seen.all.contains(.written(path: file.path)) }
    let heard = seen.all.count
    try writer.write(contentsOf: Data("two\n".utf8))
    try await eventually("the next write is heard, the file still open") { seen.all.count > heard }

    try FileManager.default.removeItem(at: file)
    try await eventually("a deleted file leaves the set") { seen.all.contains(.gone(path: file.path)) }
    #expect(watches.count == 0)
    #expect(!watches.watch(root.appendingPathComponent("never-there.jsonl").path))
}

@Test func fileWatchKeepsTheMostRecentlyActiveFilesWithinItsLimit() throws {
    let root = try temporaryDirectory("file-watch-limit")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = ["a", "b", "c"].map { root.appendingPathComponent("\($0).jsonl").path }
    for path in paths {
        #expect(FileManager.default.createFile(atPath: path, contents: nil))
    }
    let (a, b, c) = (paths[0], paths[1], paths[2])
    let now = Date()
    let watches = FileWatchSet(limit: 2) { _ in }
    #expect(watches.watch(a, activity: now.addingTimeInterval(-300)))
    #expect(watches.watch(b, activity: now.addingTimeInterval(-200)))
    // At the limit, the least recently active file gives its place.
    #expect(watches.watch(c, activity: now.addingTimeInterval(-100)))
    #expect(!watches.contains(a))
    #expect(watches.contains(b) && watches.contains(c))
    // A file less active than everything watched displaces nothing.
    #expect(!watches.watch(a, activity: now.addingTimeInterval(-400)))
    #expect(watches.count == 2)

    watches.replace(with: [
        (path: a, activity: now),
        (path: b, activity: now.addingTimeInterval(-10)),
        (path: c, activity: now.addingTimeInterval(-20)),
    ])
    #expect(watches.contains(a) && watches.contains(b))
    #expect(!watches.contains(c))
    watches.removeAll()
    #expect(watches.count == 0)
}

// MARK: The watchers, driven by events alone

/// The reconcile clock is out of reach in these tests: whatever is read
/// after the first pass, an event announced it.
private let noReconcile: Double = 3_600

@Test func rolloutWatcherFollowsAnOpenRolloutThroughEventsAlone() async throws {
    let home = try temporaryDirectory("codex-events")
    defer { try? FileManager.default.removeItem(at: home) }
    let sessions = home.appendingPathComponent("sessions", isDirectory: true)
    let day = sessions.appendingPathComponent("2026/11/17", isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)

    let repository = InMemorySessionRepository()
    let watcher = CodexRolloutWatcher(
        rootDirectory: sessions,
        repository: repository,
        reconcileIntervalSeconds: noReconcile
    )
    let running = Task { try await watcher.run() }
    defer { running.cancel() }
    // The launch pass has finished over an empty root, and the reconcile
    // clock is an hour away: from here on only an event can name a file.
    try await eventually("the launch pass is over") { await watcher.completedPasses >= 1 }

    // No hook ever fires in this test, and Codex holds a rollout open for
    // the whole session: one handle, never closed between writes.
    let sid = SessionID("open-rollout")
    let rollout = day.appendingPathComponent("rollout-2026-11-17T10-00-00-open-rollout.jsonl")
    #expect(FileManager.default.createFile(atPath: rollout.path, contents: nil))
    let writer = try FileHandle(forWritingTo: rollout)
    defer { try? writer.close() }
    func append(_ lines: String) throws {
        try writer.write(contentsOf: Data((lines + "\n").utf8))
    }
    @Sendable func lifecycle() async throws -> SessionLifecycle? {
        try await repository.sessionSummary(id: sid)?.lifecycle
    }

    try append("""
    {"timestamp":"2026-11-17T10:00:00Z","type":"session_meta","payload":{"id":"open-rollout","cwd":"/tmp/project"}}
    {"timestamp":"2026-11-17T10:00:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
    {"timestamp":"2026-11-17T10:00:02Z","type":"event_msg","payload":{"type":"user_message","message":"open a page"}}
    """)
    try await eventually("a session with no hook is discovered from its new rollout") {
        try await lifecycle() == .running
    }

    try append("""
    {"timestamp":"2026-11-17T10:00:09Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","last_agent_message":"Done."}}
    """)
    try await eventually("the turn's end is read from the open file") {
        try await lifecycle() == .waitingForInput
    }

    // Parked, the file still open. The session goes on with no hook and no
    // close: its displayed state must not have stopped the watcher listening.
    try append("""
    {"timestamp":"2026-11-17T10:05:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2"}}
    {"timestamp":"2026-11-17T10:05:01Z","type":"event_msg","payload":{"type":"user_message","message":"and another"}}
    {"timestamp":"2026-11-17T10:05:07Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-2","reason":"interrupted"}}
    """)
    try await eventually("a parked session's next write is read without a hook") {
        try await lifecycle() == .interrupted
    }
    #expect(await watcher.completedPasses == 1)

    // Cancelling ends the watcher: its loops return and `run` does.
    running.cancel()
    _ = await running.result
}

@Test func claudeWatcherFollowsKnownSessionsThroughEventsAlone() async throws {
    let home = try temporaryDirectory("claude-events")
    defer { try? FileManager.default.removeItem(at: home) }
    let projectDir = home.appendingPathComponent(".claude/projects/-tmp-project", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    func transcript(_ session: SessionID) -> URL {
        projectDir.appendingPathComponent("\(session.rawValue).jsonl")
    }
    func title(_ value: String, for session: SessionID) -> Data {
        Data("{\"type\":\"custom-title\",\"customTitle\":\"\(value)\",\"sessionId\":\"\(session.rawValue)\"}\n".utf8)
    }

    let repository = InMemorySessionRepository()
    @Sendable func storedTitle(_ session: SessionID) async throws -> String? {
        try await repository.sessionSummary(id: session)?.title
    }
    // A parked finished session, and something written to its transcript
    // while the daemon was away.
    let parked = SessionID("bbbb2222-0000-0000-0000-000000000001")
    _ = try await repository.apply(AgentIngressEvent(
        eventID: EventID("seed-parked"), sessionID: parked, agent: .claude,
        occurredAt: Date(timeIntervalSince1970: 1_787_219_000), workspace: "/tmp/project",
        lifecycle: .waitingForInput, phase: .idle
    ))
    try title("Written while away", for: parked).write(to: transcript(parked))

    let watcher = ClaudeTranscriptWatcher(
        repository: repository,
        homeDirectory: home,
        reconcileIntervalSeconds: noReconcile
    )
    let running = Task { try await watcher.run() }
    defer { running.cancel() }
    try await eventually("the launch pass is over") { await watcher.completedPasses >= 1 }
    // The launch pass brings in what was written while the daemon was away.
    #expect(try await storedTitle(parked) == "Written while away")

    // The way Claude Code writes: open, append, close. No hook.
    let handle = try FileHandle(forWritingTo: transcript(parked))
    try handle.seekToEnd()
    try handle.write(contentsOf: title("Renamed while parked", for: parked))
    try handle.close()
    try await eventually("a parked session's write is read without a hook") {
        try await storedTitle(parked) == "Renamed while parked"
    }

    // A transcript nobody announced: its session is not one Lumi holds.
    let stranger = SessionID("bbbb2222-0000-0000-0000-000000000002")
    try title("Never seen by a hook", for: stranger).write(to: transcript(stranger))
    // A session that started and has no transcript yet is found by name
    // the moment the file appears — nothing looks for it meanwhile.
    let fresh = SessionID("bbbb2222-0000-0000-0000-000000000003")
    _ = try await repository.apply(AgentIngressEvent(
        eventID: EventID("seed-fresh"), sessionID: fresh, agent: .claude,
        occurredAt: Date(timeIntervalSince1970: 1_787_219_000), workspace: "/tmp/project",
        lifecycle: .starting, phase: .idle
    ))
    try title("Named on its first write", for: fresh).write(to: transcript(fresh))
    try await eventually("a session without a cursor is matched by its transcript's name") {
        try await storedTitle(fresh) == "Named on its first write"
    }
    #expect(try await repository.sessionSummary(id: stranger) == nil)

    // The other order: the transcript is there first and set aside, then a
    // hook brings its session in. The daemon hands the applied event to the
    // watcher, which reads the waiting transcript — the file never moves
    // again in between.
    let arrival = AgentIngressEvent(
        eventID: EventID("seed-stranger"), sessionID: stranger, agent: .claude,
        occurredAt: Date(timeIntervalSince1970: 1_787_219_000), workspace: "/tmp/project",
        lifecycle: .starting, phase: .idle
    )
    #expect(try await repository.apply(arrival))
    watcher.noteApplied(arrival)
    try await eventually("a transcript that was waiting is read when its session arrives") {
        try await storedTitle(stranger) == "Never seen by a hook"
    }
    #expect(await watcher.completedPasses == 1)

    running.cancel()
    _ = await running.result
}

// The launch pass reads what was written while the daemon was away — which
// includes the terminal record of a turn the hook had already closed and the
// human had already looked at. That record is no news and asks for nothing.
@Test func theLaunchPassDoesNotAskForReviewOfATurnAlreadyLookedAt() async throws {
    let home = try temporaryDirectory("claude-reviewed")
    defer { try? FileManager.default.removeItem(at: home) }
    let projectDir = home.appendingPathComponent(".claude/projects/-tmp-project", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let sid = SessionID("cccc3333-0000-0000-0000-000000000001")
    let repository = InMemorySessionRepository()
    // The Stop hook closed the turn at 09:44:50; the human opened the session.
    let closedAt = try #require(ISO8601DateFormatter().date(from: "2026-08-20T09:44:50Z"))
    _ = try await repository.apply(AgentIngressEvent(
        eventID: EventID("stop-hook"), sessionID: sid, turnID: TurnID("p1"), agent: .claude,
        occurredAt: closedAt, workspace: "/tmp/project",
        lifecycle: .waitingForInput, phase: .idle,
        timelineItem: TimelineItem(
            id: TimelineItemIDs.turnEnd(sid, turnID: TurnID("p1")), sessionID: sid, turnID: TurnID("p1"), occurredAt: closedAt,
            payload: .turnEnd(TurnEndTimelinePayload(outcome: .completed))
        )
    ))
    #expect(try await repository.sessionSummary(id: sid)?.needsReview == true)
    try await repository.markSessionReviewed(sid)

    // The turn's own records, stamped before the hook, never read.
    try Data("""
    {"type":"user","uuid":"u1","sessionId":"\(sid.rawValue)","promptId":"p1","timestamp":"2026-08-20T09:44:42Z","origin":{"kind":"human"},"message":{"role":"user","content":"Do the thing"}}
    {"type":"assistant","uuid":"a1","sessionId":"\(sid.rawValue)","timestamp":"2026-08-20T09:44:49Z","message":{"role":"assistant","model":"claude-opus-4-7","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}

    """.utf8).write(to: projectDir.appendingPathComponent("\(sid.rawValue).jsonl"))

    let watcher = ClaudeTranscriptWatcher(repository: repository, homeDirectory: home)
    await watcher.scanOnce()
    let detail = try #require(try await repository.sessionDetail(id: sid, cursor: nil, limit: 100))
    // Read, and in the timeline…
    #expect(detail.timeline.contains { item in
        if case let .message(message) = item.payload { message.role == .assistant } else { false }
    })
    // …with the session as the human left it.
    #expect(detail.summary.lifecycle == .waitingForInput)
    #expect(!detail.summary.needsReview)
}
