import Foundation

/// The AaaS app (Agentic AI as a Service) that spawned this agent process,
/// recovered from the environment the hook inherited plus the wrapper's own
/// on-disk state. Paseo and Raft both wrap the supported CLIs, so their
/// sessions already flow in through the normal hooks — what they add is a
/// display title of their own:
///
/// - Paseo stamps `PASEO_AGENT_ID` and keeps a per-agent JSON with a `title`
///   under `~/.paseo/agents/<workspace>/<agentId>.json`.
/// - Raft stamps `SLOCK_AGENT_ID` and keeps no session title anywhere local;
///   the agent's display name is its only durable identity, recoverable from
///   the first line of the system prompt file in `SLOCK_CLI_TRANSPORT_DIR`
///   (`You are "Fable", an AI agent in Raft …`).
///
/// Detection never fails: a wrapper we can see but cannot title still
/// detects, with `title` nil. Raft's `~/.slock/computer/servers/*/
/// runner.state.json` holds a plaintext API key and must never be read.
public struct AaaS: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case paseo
        case raft
    }

    public var kind: Kind
    /// The wrapper's own agent id (`PASEO_AGENT_ID` / `SLOCK_AGENT_ID`) —
    /// not a Lumi session id.
    public var agentID: String
    /// Display title per the wrapper; nil when its files were absent,
    /// unreadable, or malformed.
    public var title: String?

    public static func detect(
        environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AaaS? {
        if let agentID = nonEmpty(environment["PASEO_AGENT_ID"]) {
            return AaaS(
                kind: .paseo,
                agentID: agentID,
                title: paseoTitle(agentID: agentID, environment: environment, homeDirectory: homeDirectory)
            )
        }
        if let agentID = nonEmpty(environment["SLOCK_AGENT_ID"]) {
            return AaaS(
                kind: .raft,
                agentID: agentID,
                title: raftTitle(environment: environment)
            )
        }
        return nil
    }

    /// `<root>/agents/<workspace-dir>/<agentId>.json`, top-level `"title"`.
    /// The workspace directory name is a sanitized cwd; globbing for the
    /// agent id avoids re-deriving Paseo's sanitization rule.
    private static func paseoTitle(
        agentID: String,
        environment: [String: String],
        homeDirectory: URL
    ) -> String? {
        let root = environment["PASEO_HOME"].flatMap(nonEmpty).map { URL(fileURLWithPath: $0) }
            ?? homeDirectory.appendingPathComponent(".paseo")
        let agentsDirectory = root.appendingPathComponent("agents")
        guard let workspaces = try? FileManager.default.contentsOfDirectory(
            at: agentsDirectory,
            includingPropertiesForKeys: nil
        ) else { return nil }
        for workspace in workspaces {
            let file = workspace.appendingPathComponent("\(agentID).json")
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return nonEmpty(root["title"] as? String)
        }
        return nil
    }

    /// First line of `$SLOCK_CLI_TRANSPORT_DIR/claude-system-prompt.md`:
    /// `You are "<name>", …`. Bounded read — the prompt is large and only
    /// the opening sentence matters.
    private static func raftTitle(environment: [String: String]) -> String? {
        guard let transportDirectory = nonEmpty(environment["SLOCK_CLI_TRANSPORT_DIR"]) else { return nil }
        let path = (transportDirectory as NSString).appendingPathComponent("claude-system-prompt.md")
        guard let handle = FileHandle(forReadingAtPath: path),
              let head = try? handle.read(upToCount: 4096)
        else { return nil }
        defer { try? handle.close() }
        guard let text = String(data: head, encoding: .utf8),
              let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
        else { return nil }
        let marker = "You are \""
        guard let start = firstLine.range(of: marker),
              let end = firstLine[start.upperBound...].firstIndex(of: "\"")
        else { return nil }
        return nonEmpty(String(firstLine[start.upperBound..<end]))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
