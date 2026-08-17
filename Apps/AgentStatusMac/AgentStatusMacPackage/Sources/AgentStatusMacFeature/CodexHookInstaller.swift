import Foundation

public enum CodexHookInstallerError: Error, Sendable {
    case invalidRoot
    case helperMissing
}

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

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public var hooksURL: URL {
        homeDirectory.appendingPathComponent(".codex/hooks.json")
    }

    public var installedHelperURL: URL {
        homeDirectory.appendingPathComponent("Library/Application Support/Agent Status/bin/agent-status-helper")
    }

    public func install(helperSourceURL: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: helperSourceURL.path) else {
            throw CodexHookInstallerError.helperMissing
        }
        let manager = FileManager.default
        let binDirectory = installedHelperURL.deletingLastPathComponent()
        try manager.createDirectory(at: binDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporaryURL = binDirectory.appendingPathComponent(".agent-status-helper-\(UUID().uuidString)")
        try manager.copyItem(at: helperSourceURL, to: temporaryURL)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporaryURL.path)
        if manager.fileExists(atPath: installedHelperURL.path) {
            _ = try manager.replaceItemAt(installedHelperURL, withItemAt: temporaryURL)
        } else {
            try manager.moveItem(at: temporaryURL, to: installedHelperURL)
        }

        let existingData = try? Data(contentsOf: hooksURL)
        let merged = try Self.merging(existingData, helperCommand: quoted(installedHelperURL.path))
        try manager.createDirectory(at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: hooksURL.path), let existingData {
            let backup = hooksURL.appendingPathExtension("agent-status-backup")
            try existingData.write(to: backup, options: .atomic)
        }
        try merged.write(to: hooksURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hooksURL.path)
    }

    public func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: hooksURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            guard let groups = value as? [[String: Any]] else { return false }
            return groups.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains {
                    ($0["command"] as? String)?.contains("agent-status-helper") == true
                } == true
            }
        }
    }

    public func uninstall() throws {
        guard let existingData = try? Data(contentsOf: hooksURL) else { return }
        let updated = try Self.removingAgentStatus(from: existingData)
        let backup = hooksURL.appendingPathExtension("agent-status-backup")
        try existingData.write(to: backup, options: .atomic)
        try updated.write(to: hooksURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hooksURL.path)
    }

    public static func merging(_ existingData: Data?, helperCommand: String) throws -> Data {
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
        for event in supportedEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let alreadyInstalled = groups.contains { group in
                let handlers = group["hooks"] as? [[String: Any]] ?? []
                return handlers.contains { handler in
                    (handler["command"] as? String)?.contains("agent-status-helper") == true
                }
            }
            if !alreadyInstalled {
                groups.append([
                    "hooks": [[
                        "type": "command",
                        "command": helperCommand,
                        "timeout": 3,
                    ]],
                ])
            }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
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
                    ($0["command"] as? String)?.contains("agent-status-helper") != true
                }
                guard !retainedHandlers.isEmpty else { return nil }
                var retainedGroup = group
                retainedGroup["hooks"] = retainedHandlers
                return retainedGroup
            }
            if retainedGroups.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = retainedGroups }
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private func quoted(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
