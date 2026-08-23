import Transport
import Foundation

/// Developer-only data behind `-LumiPreviewData`: two Macs and the
/// sessions of the design screens, so every screen can be checked without
/// a paired Mac. Never used in a normal launch.
enum PreviewFixture {
    static func channelStates(now: Date) -> [MacChannelState] {
        let pro = HostID("preview-macbook-pro")
        let mini = HostID("preview-mac-mini")
        return [
            MacChannelState(
                hostID: pro,
                displayName: "MacBook Pro",
                relayURL: URL(string: "https://relay.lumi.huanan.app")!,
                pairedAt: now.addingTimeInterval(-7 * 86_400),
                isConnected: true,
                isHostOnline: true,
                accessRevoked: false,
                hasCompleteSync: true,
                sessions: macBookProSessions(now: now),
                lastSyncAt: now,
                lastError: nil,
                health: nil,
                hasLoadedCache: true
            ),
            MacChannelState(
                hostID: mini,
                displayName: "Mac mini",
                relayURL: URL(string: "https://relay.huanan.dev")!,
                pairedAt: now.addingTimeInterval(-30 * 86_400),
                isConnected: true,
                isHostOnline: true,
                accessRevoked: false,
                hasCompleteSync: true,
                sessions: macMiniSessions(now: now),
                lastSyncAt: now.addingTimeInterval(-7_200),
                lastError: nil,
                health: nil,
                hasLoadedCache: true
            ),
        ]
    }

    // MARK: - MacBook Pro

    private static func macBookProSessions(now: Date) -> [SessionDetail] {
        let start = now.addingTimeInterval(-223)
        let refactor = SessionID("01J9EX7M4T2QZR8B3H0V5CKD9A")
        let refactorTurn = TurnID("turn-refactor-1")
        var items: [TimelineItem] = []
        func add(_ offset: TimeInterval, _ payload: TimelinePayload) {
            items.append(TimelineItem(
                id: TimelineItemID("item-\(items.count)"),
                sessionID: refactor,
                turnID: refactorTurn,
                occurredAt: start.addingTimeInterval(offset),
                payload: payload
            ))
        }
        add(0, .sessionMarker(.init(kind: .sessionStarted, detail: "startup", model: "gpt-5-codex")))
        add(1, .modelConfiguration(.init(
            source: "session_meta", model: "gpt-5-codex", provider: "openai", contextWindow: 272_000,
            reasoningEffort: "medium", clientVersion: "codex-cli 0.48.2", settings: .object([:])
        )))
        add(2, .config(.init(kind: "turn_context", summary: "gpt-5-codex · medium · ~/dev/lumi")))
        add(2, .context(.init(kind: "developer_instructions", summary: "System Instructions · developer instructions")))
        add(5, .message(.init(role: .user, text: "Refactor the transport DTO boundaries so Common no longer imports AppKit")))
        add(10, .reasoning(.init(text: "Inspecting package targets before editing")))
        add(12, .tool(.init(name: "shell", summary: "rg --files Common/Sources", status: .started, toolUseID: "t1")))
        add(13, .tool(.init(name: "shell", summary: "rg --files Common/Sources", status: .succeeded, durationMilliseconds: 820, toolUseID: "t1")))
        add(17, .message(.init(role: .assistant, text: "I'll start by mapping which files cross the transport boundary.")))
        add(32, .tool(.init(name: "apply_patch", summary: "Core/SessionStatusTone.swift", status: .started, toolUseID: "t2")))
        add(33, .tool(.init(name: "apply_patch", summary: "Core/SessionStatusTone.swift", status: .succeeded, durationMilliseconds: 210, toolUseID: "t2")))
        add(53, .subagent(.init(name: "audit-encryption", agentSessionID: "01J9F2KQ7YB3", status: .started)))
        add(90, .tool(.init(name: "shell", summary: "swift build --package-path Common", status: .started, toolUseID: "t3")))
        add(95, .tool(.init(
            name: "shell",
            summary: "error: no such module 'AppKit'\n --> Common/Sources/Transport/SessionEnvelope.swift:4:8\n  |\n4 | import AppKit\n  |        ^\nCompiling Transport (12 sources)\nerror: fatalError",
            status: .failed, durationMilliseconds: 5_100, toolUseID: "t3"
        )))
        add(98, .reasoning(.init(text: "Build failed on a missing import")))
        add(113, .tool(.init(name: "apply_patch", summary: "Common/Package.swift", status: .started, toolUseID: "t4")))
        add(114, .tool(.init(name: "apply_patch", summary: "Common/Package.swift", status: .succeeded, durationMilliseconds: 180, toolUseID: "t4")))
        add(166, .tool(.init(name: "shell", summary: "swift build --package-path Common", status: .started, toolUseID: "t5")))
        add(172, .tool(.init(name: "shell", summary: "Build complete! (6.02s)", status: .succeeded, durationMilliseconds: 6_020, toolUseID: "t5")))
        add(173, .plan(.init(explanation: "Plan updated", steps: [
            .init(text: "Map boundary-crossing files", status: .completed),
            .init(text: "Move DTOs into Transport", status: .completed),
            .init(text: "Run the Mac package tests", status: .inProgress),
        ])))
        add(192, .message(.init(role: .assistant, text: "Transport boundary builds cleanly; check-transport-boundaries.sh passes.")))
        add(220, .message(.init(role: .user, text: "Also run the Mac package tests")))
        add(222, .usageMetrics(.init(
            last: TokenUsage(inputTokens: 184_220, cachedInputTokens: 151_808, outputTokens: 9_431, reasoningOutputTokens: 6_208, totalTokens: 193_651),
            total: TokenUsage(inputTokens: 184_220, cachedInputTokens: 151_808, outputTokens: 9_431, reasoningOutputTokens: 6_208, totalTokens: 193_651),
            modelContextWindow: 272_000
        )))
        add(223, .tool(.init(name: "shell", summary: "swift test --package-path MacPackage", status: .started, toolUseID: "t6")))

        let refactorSummary = SessionSummary(
            id: refactor, agent: .codex, title: "Refactor transport DTO boundaries",
            workspace: "/Users/huanan/dev/lumi", lifecycle: .running, phase: .executing,
            startedAt: start, updatedAt: now, lastActivityAt: now,
            lineage: SessionLineage(threadSource: "codex-cli", subagentDepth: 0, agentNickname: "transport", agentRole: "primary"),
            firstTurnAt: start.addingTimeInterval(5)
        )
        let refactorDetail = SessionDetail(
            summary: refactorSummary,
            turns: [TurnSummary(id: refactorTurn, sessionID: refactor, index: 1, phase: .executing, prompt: "Refactor the transport DTO boundaries", startedAt: start.addingTimeInterval(5), toolCallCount: 6, subagentCount: 3)],
            timeline: items
        )

        func child(_ id: String, _ title: String, parent: SessionID, ago: TimeInterval, live: Bool, phase: TurnPhase = .executing) -> SessionDetail {
            let started = now.addingTimeInterval(-ago)
            let sessionID = SessionID(id)
            return SessionDetail(
                summary: SessionSummary(
                    id: sessionID, agent: .codexSubagent, title: title, workspace: "/Users/huanan/dev/lumi",
                    lifecycle: live ? .running : .completed, phase: live ? phase : .idle,
                    startedAt: started, updatedAt: now, lastActivityAt: live ? now : now.addingTimeInterval(-5),
                    lineage: SessionLineage(parentSessionID: parent, subagentDepth: 1, agentRole: "subagent"),
                    firstTurnAt: started
                ),
                turns: [TurnSummary(id: TurnID("\(id)-turn"), sessionID: sessionID, phase: live ? phase : .idle, startedAt: started, endedAt: live ? nil : now.addingTimeInterval(-5), outcome: live ? nil : .completed)],
                timeline: [TimelineItem(id: TimelineItemID("\(id)-user"), sessionID: sessionID, turnID: TurnID("\(id)-turn"), occurredAt: started, payload: .message(.init(role: .user, text: title)))]
            )
        }

        let hookStart = now.addingTimeInterval(-11 * 60)
        let hook = SessionID("01J9EX9Q2HOOKINSTALLFAIL")
        let hookDetail = SessionDetail(
            summary: SessionSummary(
                id: hook, agent: .claude, title: "Investigate hook install failure", workspace: "/Users/huanan/dev/lumi",
                lifecycle: .running, phase: .executing, startedAt: hookStart, updatedAt: now, lastActivityAt: now.addingTimeInterval(-11 * 60),
                firstTurnAt: hookStart
            ),
            turns: [TurnSummary(id: TurnID("hook-turn"), sessionID: hook, phase: .executing, startedAt: hookStart)],
            timeline: [
                TimelineItem(id: TimelineItemID("hook-0"), sessionID: hook, turnID: TurnID("hook-turn"), occurredAt: hookStart, payload: .message(.init(role: .user, text: "Why does install-hooks.sh fail on a clean machine?"))),
                TimelineItem(id: TimelineItemID("hook-1"), sessionID: hook, turnID: TurnID("hook-turn"), occurredAt: hookStart.addingTimeInterval(20), payload: .tool(.init(name: "Bash", summary: "install-hooks.sh", status: .started, toolUseID: "h1"))),
                TimelineItem(id: TimelineItemID("hook-2"), sessionID: hook, turnID: TurnID("hook-turn"), occurredAt: hookStart.addingTimeInterval(25), payload: .tool(.init(name: "Bash", summary: "install-hooks.sh: permission denied", status: .failed, durationMilliseconds: 4_000, toolUseID: "h1"))),
            ]
        )

        let relayStart = now.addingTimeInterval(-40 * 60)
        let relay = SessionID("01J9EXRELAYDURABLEOBJECT")
        let relayDetail = SessionDetail(
            summary: SessionSummary(
                id: relay, agent: .codex, title: "Fix relay durable object lifecycle", workspace: "/Users/huanan/dev/lumi/Relay",
                lifecycle: .waitingForInput, phase: .waitingForApproval, startedAt: relayStart, updatedAt: now, lastActivityAt: now.addingTimeInterval(-6 * 60),
                needsAttention: true, firstTurnAt: relayStart
            ),
            turns: [TurnSummary(id: TurnID("relay-turn"), sessionID: relay, phase: .waitingForApproval, startedAt: relayStart)],
            timeline: [
                TimelineItem(id: TimelineItemID("relay-0"), sessionID: relay, turnID: TurnID("relay-turn"), occurredAt: relayStart, payload: .message(.init(role: .user, text: "Fix the durable object lifecycle so hibernation keeps the host socket"))),
                TimelineItem(id: TimelineItemID("relay-1"), sessionID: relay, turnID: TurnID("relay-turn"), occurredAt: now.addingTimeInterval(-6 * 60), payload: .message(.init(role: .user, text: "等你确认要不要保留旧的 socket 路径"))),
            ]
        )

        return [
            refactorDetail,
            child("sub-audit", "audit-encryption", parent: refactor, ago: 12, live: true),
            child("sub-migrate", "migrate-dto-tests", parent: refactor, ago: 48, live: true),
            child("sub-scan", "scan-public-api", parent: refactor, ago: 150, live: false),
            relayDetail,
            child("sub-trace", "trace-websocket-drop", parent: relay, ago: 6 * 60, live: true, phase: .waitingForApproval),
            child("sub-replay", "replay-durable-log", parent: relay, ago: 7 * 60, live: true),
            hookDetail,
        ]
    }

    // MARK: - Mac mini

    private static func macMiniSessions(now: Date) -> [SessionDetail] {
        let cacheStart = now.addingTimeInterval(-14 * 60)
        let cache = SessionID("01J9EXREBUILDRELAYCACHE")
        let cacheDetail = SessionDetail(
            summary: SessionSummary(
                id: cache, agent: .codex, title: "Rebuild relay session cache", workspace: "/Users/huanan/dev/lumi",
                lifecycle: .running, phase: .executing, startedAt: cacheStart, updatedAt: now, lastActivityAt: now.addingTimeInterval(-14 * 60),
                firstTurnAt: cacheStart
            ),
            turns: [TurnSummary(id: TurnID("cache-turn"), sessionID: cache, phase: .executing, startedAt: cacheStart)],
            timeline: [
                TimelineItem(id: TimelineItemID("cache-0"), sessionID: cache, turnID: TurnID("cache-turn"), occurredAt: cacheStart, payload: .message(.init(role: .user, text: "Rebuild the relay session cache from the index"))),
                TimelineItem(id: TimelineItemID("cache-1"), sessionID: cache, turnID: TurnID("cache-turn"), occurredAt: cacheStart.addingTimeInterval(30), payload: .tool(.init(name: "shell", summary: "rg --files relay/src", status: .started, toolUseID: "c1"))),
            ]
        )
        let migrationStart = now.addingTimeInterval(-90 * 60)
        let migration = SessionID("01J9EXSQLITEMIGRATION")
        let migrationDetail = SessionDetail(
            summary: SessionSummary(
                id: migration, agent: .claude, title: "Add SQLite migration for timeline items", workspace: "/Users/huanan/dev/lumi",
                lifecycle: .completed, phase: .idle, startedAt: migrationStart, updatedAt: now, lastActivityAt: now.addingTimeInterval(-60 * 60),
                firstTurnAt: migrationStart
            ),
            turns: [TurnSummary(id: TurnID("migration-turn"), sessionID: migration, phase: .idle, startedAt: migrationStart, endedAt: now.addingTimeInterval(-60 * 60), outcome: .completed)],
            timeline: [
                TimelineItem(id: TimelineItemID("migration-0"), sessionID: migration, turnID: TurnID("migration-turn"), occurredAt: migrationStart, payload: .message(.init(role: .user, text: "Add a migration for timeline items"))),
                TimelineItem(id: TimelineItemID("migration-1"), sessionID: migration, turnID: TurnID("migration-turn"), occurredAt: now.addingTimeInterval(-61 * 60), payload: .message(.init(role: .assistant, text: "Migration applied; 4 tables touched."))),
                TimelineItem(id: TimelineItemID("migration-2"), sessionID: migration, turnID: TurnID("migration-turn"), occurredAt: now.addingTimeInterval(-60 * 60), payload: .turnEnd(.init(outcome: .completed, message: "Turn complete"))),
            ]
        )
        return [cacheDetail, migrationDetail]
    }
}
