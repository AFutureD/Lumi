/// Every hook event the agents can deliver. The vocabulary is closed and
/// ours: an event only reaches the helper if our installers registered it,
/// and the installers derive their registration lists from this enum — a new
/// hook means a new case here and ships with the installer change. No
/// `.unknown` fallback: a name outside this list is a mis-registered hook —
/// the daemon logs it and degrades that frame to increment-only (the
/// rich-source catch-up still runs; nothing is reduced from the hook itself).
public enum HookEventName: String, Codable, Hashable, Sendable, CaseIterable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case permissionRequest = "PermissionRequest"
    case permissionDenied = "PermissionDenied"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case preCompact = "PreCompact"
    case postCompact = "PostCompact"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case sessionEnd = "SessionEnd"
    case instructionsLoaded = "InstructionsLoaded"
    case configChange = "ConfigChange"
    case cwdChanged = "CwdChanged"
    case notification = "Notification"

    /// What the Codex installer registers in `~/.codex/hooks.json` — the
    /// released Codex hook set (codex-rs hooks/schema/generated at the
    /// running release, 0.145). Codex 0.150 adds an `Interrupt` hook that
    /// closes aborted turns with low latency; register it here (new case +
    /// this list) once that release is the baseline. Until then the rollout
    /// watcher closes aborted turns.
    public static let codexEvents: [HookEventName] = [
        .sessionStart, .userPromptSubmit, .preToolUse, .permissionRequest,
        .postToolUse, .preCompact, .postCompact, .subagentStart,
        .subagentStop, .stop, .sessionEnd,
    ]

    /// What the Claude Code installer registers in `~/.claude/settings.json`.
    public static let claudeEvents: [HookEventName] = [
        .sessionStart, .userPromptSubmit, .preToolUse, .permissionRequest,
        .permissionDenied, .postToolUse, .postToolUseFailure, .preCompact,
        .postCompact, .subagentStart, .subagentStop, .stop, .stopFailure,
        .sessionEnd, .instructionsLoaded, .configChange, .cwdChanged,
        .notification,
    ]
}
