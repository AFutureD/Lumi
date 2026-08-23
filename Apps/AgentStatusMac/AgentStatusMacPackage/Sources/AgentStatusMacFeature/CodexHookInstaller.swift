import Foundation

public enum CodexHookInstallerError: Error, Sendable {
    case invalidRoot
    case helperMissing
}

/// Shared installer for the `{"hooks": {Event: [{"hooks": [{type, command, timeout}]}]}}`
/// shape that both Codex (`~/.codex/hooks.json`) and Claude Code
/// (`~/.claude/settings.json`) use. Merges into the existing file, never
/// duplicates its own handler, and only ever removes handlers that invoke
/// Spark (matched by `CodexHookTrustAuthorizer.helperMarker`). Other keys and other tools' hooks are preserved.
public struct AgentHookConfigInstaller: Sendable {
    public let configURL: URL
    public let installedHelperURL: URL
    public let supportedEvents: [String]
    /// Extra arguments appended to the helper command (e.g. `--agent claude`).
    public let helperArguments: [String]
    public let timeoutSeconds: Int

    public init(
        configURL: URL,
        installedHelperURL: URL,
        supportedEvents: [String],
        helperArguments: [String] = [],
        timeoutSeconds: Int = 3
    ) {
        self.configURL = configURL
        self.installedHelperURL = installedHelperURL
        self.supportedEvents = supportedEvents
        self.helperArguments = helperArguments
        self.timeoutSeconds = timeoutSeconds
    }

    public var helperCommand: String {
        ([Self.quoted(installedHelperURL.path)] + helperArguments).joined(separator: " ")
    }

    /// Copies the signed helper into place (atomic replace) and merges the hooks.
    public func install(helperSourceURL: URL) throws {
        try Self.installHelperBinary(from: helperSourceURL, to: installedHelperURL)
        try mergeHooks()
    }

    /// Merges hooks assuming the helper binary is already installed.
    public func mergeHooks() throws {
        let manager = FileManager.default
        let existingData = try? Data(contentsOf: configURL)
        let merged = try Self.merging(existingData, helperCommand: helperCommand, events: supportedEvents, timeout: timeoutSeconds)
        try manager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: configURL.path), let existingData {
            let backup = configURL.appendingPathExtension("lumi-backup")
            try existingData.write(to: backup, options: .atomic)
        }
        try merged.write(to: configURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    /// Refreshes an existing install after an app update. Hooks execute the
    /// copied helper, not the bundle's, and a stale copy silently ignores
    /// newer ingest capabilities while still exiting 0 — so the binary is
    /// replaced whenever its bytes differ from the bundled one, and the hook
    /// config is re-merged when the supported events or the helper command
    /// changed. A launch where nothing is stale writes nothing. No-op when
    /// the hooks were never installed.
    public func refreshIfStale(helperSourceURL: URL) throws {
        guard isInstalled() else { return }
        let manager = FileManager.default
        if !manager.contentsEqual(atPath: helperSourceURL.path, andPath: installedHelperURL.path) {
            try Self.installHelperBinary(from: helperSourceURL, to: installedHelperURL)
        }
        let existingData = try? Data(contentsOf: configURL)
        let merged = try Self.merging(
            existingData,
            helperCommand: helperCommand,
            events: supportedEvents,
            timeout: timeoutSeconds
        )
        if let existingData,
           let existing = try? JSONSerialization.jsonObject(with: existingData) as? NSDictionary,
           let updated = try? JSONSerialization.jsonObject(with: merged) as? NSDictionary,
           updated.isEqual(existing) {
            return
        }
        try mergeHooks()
    }

    public static func installHelperBinary(from helperSourceURL: URL, to installedHelperURL: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: helperSourceURL.path) else {
            throw CodexHookInstallerError.helperMissing
        }
        let manager = FileManager.default
        let binDirectory = installedHelperURL.deletingLastPathComponent()
        try manager.createDirectory(at: binDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporaryURL = binDirectory.appendingPathComponent(".Spark-\(UUID().uuidString)")
        try manager.copyItem(at: helperSourceURL, to: temporaryURL)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporaryURL.path)
        if manager.fileExists(atPath: installedHelperURL.path) {
            _ = try manager.replaceItemAt(installedHelperURL, withItemAt: temporaryURL)
        } else {
            try manager.moveItem(at: temporaryURL, to: installedHelperURL)
        }
    }

    public func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            guard let groups = value as? [[String: Any]] else { return false }
            return groups.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains {
                    ($0["command"] as? String)?.contains(CodexHookTrustAuthorizer.helperMarker) == true
                } == true
            }
        }
    }

    public func uninstall() throws {
        guard let existingData = try? Data(contentsOf: configURL) else { return }
        let updated = try Self.removingAgentStatus(from: existingData)
        let backup = configURL.appendingPathExtension("lumi-backup")
        try existingData.write(to: backup, options: .atomic)
        try updated.write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    public static func merging(
        _ existingData: Data?,
        helperCommand: String,
        events: [String],
        timeout: Int = 3
    ) throws -> Data {
        var root: [String: Any]
        if let existingData, !existingData.isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
                throw CodexHookInstallerError.invalidRoot
            }
            root = parsed
        } else {
            root = [:]
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            var updated = false
            for index in groups.indices {
                guard var handlers = groups[index]["hooks"] as? [[String: Any]] else { continue }
                for handlerIndex in handlers.indices
                where (handlers[handlerIndex]["command"] as? String)?.contains(CodexHookTrustAuthorizer.helperMarker) == true {
                    // Refresh the command (path / arguments may have changed).
                    handlers[handlerIndex]["command"] = helperCommand
                    handlers[handlerIndex]["timeout"] = timeout
                    updated = true
                }
                groups[index]["hooks"] = handlers
            }
            if !updated {
                groups.append([
                    "hooks": [[
                        "type": "command",
                        "command": helperCommand,
                        "timeout": timeout,
                    ]],
                ])
            }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public static func removingAgentStatus(from existingData: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
            throw CodexHookInstallerError.invalidRoot
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in Array(hooks.keys) {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let retainedGroups = groups.compactMap { group -> [String: Any]? in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let retainedHandlers = handlers.filter {
                    ($0["command"] as? String)?.contains(CodexHookTrustAuthorizer.helperMarker) != true
                }
                guard !retainedHandlers.isEmpty else { return nil }
                var retainedGroup = group
                retainedGroup["hooks"] = retainedHandlers
                return retainedGroup
            }
            if retainedGroups.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = retainedGroups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func quoted(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// Codex: `~/.codex/hooks.json`.
public struct CodexHookInstaller: Sendable {
    public static let supportedEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "PreCompact",
        "PostCompact",
        "SubagentStart",
        "SubagentStop",
        "Stop",
        "SessionEnd",
    ]

    public let homeDirectory: URL
    private let inner: AgentHookConfigInstaller

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
        inner = AgentHookConfigInstaller(
            configURL: homeDirectory.appendingPathComponent(".codex/hooks.json"),
            installedHelperURL: Self.installedHelperURL(homeDirectory: homeDirectory),
            supportedEvents: Self.supportedEvents,
            helperArguments: ["--agent", "codex"]
        )
    }

    public static func installedHelperURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/Lumi/bin/Spark")
    }

    public var hooksURL: URL { inner.configURL }
    public var installedHelperURL: URL { inner.installedHelperURL }

    public func install(helperSourceURL: URL) throws { try inner.install(helperSourceURL: helperSourceURL) }
    public func refreshIfStale(helperSourceURL: URL) throws { try inner.refreshIfStale(helperSourceURL: helperSourceURL) }
    public func isInstalled() -> Bool { inner.isInstalled() }
    public func uninstall() throws { try inner.uninstall() }

    public static func merging(_ existingData: Data?, helperCommand: String) throws -> Data {
        try AgentHookConfigInstaller.merging(existingData, helperCommand: helperCommand, events: supportedEvents)
    }

    public static func removingAgentStatus(from existingData: Data) throws -> Data {
        try AgentHookConfigInstaller.removingAgentStatus(from: existingData)
    }
}

/// Claude Code: `~/.claude/settings.json` (`hooks` key; other settings preserved).
public struct ClaudeHookInstaller: Sendable {
    public static let supportedEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "UserPromptExpansion",
        "PreToolUse",
        "PermissionRequest",
        "PermissionDenied",
        "PostToolUse",
        "PostToolUseFailure",
        "PreCompact",
        "PostCompact",
        "SubagentStart",
        "SubagentStop",
        "Stop",
        "StopFailure",
        "SessionEnd",
        "InstructionsLoaded",
        "ConfigChange",
        "CwdChanged",
        "Notification",
    ]

    public let homeDirectory: URL
    private let inner: AgentHookConfigInstaller

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
        inner = AgentHookConfigInstaller(
            configURL: homeDirectory.appendingPathComponent(".claude/settings.json"),
            installedHelperURL: CodexHookInstaller.installedHelperURL(homeDirectory: homeDirectory),
            supportedEvents: Self.supportedEvents,
            helperArguments: ["--agent", "claude"],
            timeoutSeconds: 5
        )
    }

    public var settingsURL: URL { inner.configURL }
    public var installedHelperURL: URL { inner.installedHelperURL }

    public func install(helperSourceURL: URL) throws { try inner.install(helperSourceURL: helperSourceURL) }
    public func refreshIfStale(helperSourceURL: URL) throws { try inner.refreshIfStale(helperSourceURL: helperSourceURL) }
    public func isInstalled() -> Bool { inner.isInstalled() }
    public func uninstall() throws { try inner.uninstall() }

    public static func merging(_ existingData: Data?, helperCommand: String) throws -> Data {
        try AgentHookConfigInstaller.merging(existingData, helperCommand: helperCommand, events: supportedEvents, timeout: 5)
    }
}
