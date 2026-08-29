import Transport
import Foundation

/// The AaaS app (Agentic AI as a Service) hosting this agent session — the
/// application layer above the agent engine, recovered from the environment
/// the hook inherited plus, for wrappers, their own on-disk state. Every
/// session belongs to exactly one AaaS; detection is total:
///
/// - Paseo stamps `PASEO_AGENT_ID` and keeps a per-agent JSON with a `title`
///   under `~/.paseo/agents/<workspace>/<agentId>.json`.
/// - Raft stamps `SLOCK_AGENT_ID` and keeps no session title anywhere local;
///   the agent's display name is its only durable identity, recoverable from
///   the first line of the system prompt file in `SLOCK_CLI_TRANSPORT_DIR`
///   (`You are "Fable", an AI agent in Raft …`). Its daemon's utility
///   sessions (account-usage polls) carry only `SLOCK_HOME`; that alone
///   still means Raft, with no agent id and no title.
/// - ChatGPT is the OpenAI desktop app driving Codex: launched processes
///   inherit its `__CFBundleIdentifier` (observed `com.openai.codex`; the
///   historic `com.openai.chat` is accepted too).
/// - Codex is every other codex session — the CLI in a terminal, IDE
///   extensions (`com.microsoft.VSCode`), anything not the desktop app.
/// - Claude Desktop is the Claude desktop app, including the Claude Code
///   sessions it hosts: `CLAUDE_CODE_ENTRYPOINT` starts with
///   `claude-desktop` (the `-3p` variant included) or the bundle identifier
///   is `com.anthropic.claudefordesktop`.
/// - Claude Code is every other claude session (`cli`, SDK entrypoints,
///   or no entrypoint at all).
///
/// A wrapper we can see but cannot title still detects, with `title` nil.
/// Raft's `~/.slock/computer/servers/*/runner.state.json` holds a plaintext
/// API key and must never be read.
public struct AaaS: Hashable, Sendable {
    public typealias Kind = AaaSKind

    public var kind: Kind
    /// The wrapper's own agent id (`PASEO_AGENT_ID` / `SLOCK_AGENT_ID`) —
    /// not a Lumi session id. Only Paseo and Raft have one.
    public var agentID: String?
    /// The hosting terminal (`TERM_PROGRAM`), when the session runs in one.
    public var terminalProgram: String?
    /// Display title per the wrapper; nil when its files were absent,
    /// unreadable, or malformed. Only Paseo and Raft carry titles of their
    /// own — the other AaaS title through the agent's native channels.
    public var title: String?

    /// The persistable ownership record (drops the transient title).
    public var ownership: SessionAaaS {
        SessionAaaS(kind: kind, agentID: agentID, terminalProgram: terminalProgram)
    }

    public static func detect(
        provider: AgentProvider,
        environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AaaS {
        let terminal = nonEmpty(environment["TERM_PROGRAM"])
        // Wrappers first: they may themselves run inside a desktop app or a
        // terminal, and their markers are the most specific signal.
        if let agentID = nonEmpty(environment["PASEO_AGENT_ID"]) {
            return AaaS(
                kind: .paseo,
                agentID: agentID,
                terminalProgram: terminal,
                title: paseoTitle(agentID: agentID, environment: environment, homeDirectory: homeDirectory)
            )
        }
        if let agentID = nonEmpty(environment["SLOCK_AGENT_ID"]) {
            return AaaS(
                kind: .raft,
                agentID: agentID,
                terminalProgram: terminal,
                title: raftTitle(environment: environment)
            )
        }
        // Raft's daemon also spawns utility sessions (e.g. its account-usage
        // poll) that are not agent launches: they inherit only `SLOCK_HOME`.
        // Still Raft's — classified as such with no agent id and no title.
        if nonEmpty(environment["SLOCK_HOME"]) != nil {
            return AaaS(kind: .raft, terminalProgram: terminal)
        }
        let bundle = nonEmpty(environment["__CFBundleIdentifier"])
        switch provider {
        case .codex:
            let isDesktopApp = bundle == "com.openai.codex" || bundle == "com.openai.chat"
            return AaaS(kind: isDesktopApp ? .chatgpt : .codex, terminalProgram: terminal)
        case .claude:
            let entrypoint = nonEmpty(environment["CLAUDE_CODE_ENTRYPOINT"])
            let isDesktopApp = entrypoint?.hasPrefix("claude-desktop") == true
                || bundle == "com.anthropic.claudefordesktop"
            return AaaS(kind: isDesktopApp ? .claudeDesktop : .claudeCode, terminalProgram: terminal)
        }
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
