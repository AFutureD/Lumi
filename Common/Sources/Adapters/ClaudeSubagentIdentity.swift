import Core
import Transport
import Foundation

/// A Claude Code subagent has no session of its own: its hook events carry the
/// parent's `session_id` plus `agent_id` / `agent_type`, and its transcript is
/// a sidechain file at `<project>/<session>/subagents/agent-<id>.jsonl` with a
/// sibling `.meta.json` (`agentType`, `description`, `model`, `spawnDepth`,
/// `toolUseId`). Lumi gives each one a derived child session so it can
/// hang under its parent like a Codex subagent thread.
public enum ClaudeSubagentIdentity {
    static let separator = ":agent:"

    public struct Meta: Decodable, Hashable, Sendable {
        public var agentType: String?
        public var description: String?
        public var model: String?
        public var spawnDepth: Int?
        public var toolUseId: String?
    }

    /// `<parent>:agent:<agent_id>` — unique per subagent, parent recoverable.
    public static func sessionID(parent: SessionID, agentID: String) -> SessionID {
        SessionID(parent.rawValue + separator + agentID)
    }

    public static func parse(_ sessionID: SessionID) -> (parent: SessionID, agentID: String)? {
        guard let range = sessionID.rawValue.range(of: separator) else { return nil }
        let parent = String(sessionID.rawValue[..<range.lowerBound])
        let agent = String(sessionID.rawValue[range.upperBound...])
        guard !parent.isEmpty, !agent.isEmpty else { return nil }
        return (SessionID(parent), agent)
    }

    public static func isSubagentSession(_ sessionID: SessionID) -> Bool {
        parse(sessionID) != nil
    }

    /// `…/<project>/<session>.jsonl` → `…/<project>/<session>/subagents/agent-<id>.jsonl`.
    public static func transcriptPath(parentTranscriptPath: String, parent: SessionID, agentID: String) -> String {
        let projectDirectory = (parentTranscriptPath as NSString).deletingLastPathComponent
        return (projectDirectory as NSString)
            .appendingPathComponent(parent.rawValue)
            .appending("/subagents/agent-\(agentID).jsonl")
    }

    public static func metaPath(forTranscriptPath transcriptPath: String) -> String {
        guard transcriptPath.hasSuffix(".jsonl") else { return transcriptPath + ".meta.json" }
        return String(transcriptPath.dropLast(".jsonl".count)) + ".meta.json"
    }

    public static func readMeta(atTranscriptPath transcriptPath: String) -> Meta? {
        let path = metaPath(forTranscriptPath: transcriptPath)
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    /// Lineage for the child session. `agentNickname` is the spawn description
    /// (`Output hi four times`), `agentRole` the agent type (`claude`, `Explore`).
    public static func lineage(parent: SessionID, agentType: String?, meta: Meta?) -> SessionLineage {
        SessionLineage(
            threadSource: "subagent",
            parentSessionID: parent,
            subagentDepth: meta?.spawnDepth ?? 1,
            agentNickname: nonEmpty(meta?.description),
            agentRole: nonEmpty(agentType) ?? nonEmpty(meta?.agentType),
            subagentKind: "claude_agent"
        )
    }

    /// What the daemon knows about the process that runs a Claude session's
    /// subagents: the session's latest start and end, as its own markers
    /// record them (`source` / `reason` in `detail`).
    public struct ProcessMarkers: Equatable, Sendable {
        public let startedAt: Date?
        public let startSource: String?
        public let endedAt: Date?
        public let endReason: String?

        public init(startedAt: Date? = nil, startSource: String? = nil, endedAt: Date? = nil, endReason: String? = nil) {
            self.startedAt = startedAt
            self.startSource = startSource
            self.endedAt = endedAt
            self.endReason = endReason
        }
    }

    /// The Claude session whose process runs this subagent: the top of its
    /// lineage. `nil` when the chain leaves the given sessions, loops, or
    /// ends on anything but a main Claude session.
    public static func processOwner(of subagent: SessionSummary, in byID: [SessionID: SessionSummary]) -> SessionSummary? {
        var visited: Set<SessionID> = [subagent.id]
        var current = subagent
        while let parentID = current.lineage?.parentSessionID {
            guard visited.insert(parentID).inserted, let parent = byID[parentID] else { return nil }
            current = parent
        }
        return current.agent == .claude ? current : nil
    }

    /// The moment a subagent that still reads as at work is known to have
    /// stopped with its process — or `nil` while that process may be alive.
    ///
    /// Claude Code runs subagents inside the session's own process and
    /// writes nothing for them when that process goes away (verified against
    /// 2.1.322: a background subagent cut off by the exit leaves no closing
    /// transcript record, no `SubagentStop`, no `finished` in its meta). Two
    /// facts about the owning session say the process is gone:
    ///
    /// - It ended and has not started again. The subagent stopped no later
    ///   than its own last record. An end by `/clear` is not one: the
    ///   process lives on under a new session.
    /// - It started (`startup` / `resume`) after the subagent's last record:
    ///   a new process cannot own a subagent that was running before it.
    ///   This is what closes the subagents of a process that was killed
    ///   without ever reporting its end. A `compact` restart is the same
    ///   process and closes nothing.
    ///
    /// A state, not a moment: the caller asks again on every pass, so a
    /// subagent rebuilt from its transcript (which holds no end) is closed
    /// again. An interrupt of the session is deliberately no trigger —
    /// background subagents outlive it, and a foreground one writes its own
    /// marker.
    public static func leftBehindAt(
        _ subagent: SessionSummary,
        owner: SessionSummary,
        markers: ProcessMarkers
    ) -> Date? {
        guard subagent.agent == .claudeSubagent, subagent.isAtWork else { return nil }
        if let startedAt = markers.startedAt,
           markers.startSource == "startup" || markers.startSource == "resume",
           startedAt > subagent.lastActivityAt {
            return startedAt
        }
        if owner.lifecycle == .completed, let endedAt = markers.endedAt, markers.endReason != "clear" {
            return max(endedAt, subagent.lastActivityAt)
        }
        return nil
    }

    /// List title: the spawn description, else the agent type.
    public static func title(agentType: String?, meta: Meta?) -> String? {
        nonEmpty(meta?.description)
            ?? nonEmpty(agentType).map { $0 == "claude" ? "Claude Agent" : $0 }
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
