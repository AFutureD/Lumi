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
