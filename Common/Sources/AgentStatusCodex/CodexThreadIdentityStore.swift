import AgentStatusTransport
import Foundation
import GRDB

public struct CodexThreadIdentity: Hashable, Sendable {
    public let sessionID: SessionID
    /// `threads.title` from `state_5.sqlite`. Codex keeps this in sync with the
    /// first user message, so an explicit rename does not survive here.
    public let title: String?
    /// The latest `thread_name` recorded for this thread in
    /// `session_index.jsonl`, written when the user or a tool renames the thread.
    public let threadName: String?
    public let threadSource: String?
    public let agentNickname: String?
    public let agentRole: String?
    public let agentPath: String?
    public let parentSessionID: SessionID?
    public let subagentDepth: Int?
    public let subagentKind: String?
    public let titleIsInheritedUserMessage: Bool

    public init(
        sessionID: SessionID,
        title: String? = nil,
        threadName: String? = nil,
        threadSource: String? = nil,
        agentNickname: String? = nil,
        agentRole: String? = nil,
        agentPath: String? = nil,
        parentSessionID: SessionID? = nil,
        subagentDepth: Int? = nil,
        subagentKind: String? = nil,
        titleIsInheritedUserMessage: Bool = false
    ) {
        self.sessionID = sessionID
        self.title = title
        self.threadName = threadName
        self.threadSource = threadSource
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.agentPath = agentPath
        self.parentSessionID = parentSessionID
        self.subagentDepth = subagentDepth
        self.subagentKind = subagentKind
        self.titleIsInheritedUserMessage = titleIsInheritedUserMessage
    }

    public var isSubagent: Bool {
        threadSource == "subagent" || parentSessionID != nil || subagentKind != nil
    }

    public var agentKind: AgentKind { isSubagent ? .codexSubagent : .codex }

    public var lineage: SessionLineage {
        SessionLineage(
            threadSource: threadSource,
            parentSessionID: parentSessionID,
            subagentDepth: subagentDepth,
            agentNickname: agentNickname,
            agentRole: agentRole,
            agentPath: agentPath,
            subagentKind: subagentKind
        )
    }

    public var displayTitle: String? {
        if let threadName = Self.nonEmpty(threadName) { return threadName }
        if !titleIsInheritedUserMessage, let title = Self.nonEmpty(title) { return title }
        guard isSubagent else { return nil }
        let pathName = agentPath.flatMap {
            Self.nonEmpty(URL(fileURLWithPath: $0).lastPathComponent)
        }
        if let nickname = Self.nonEmpty(agentNickname), let pathName, nickname != pathName {
            return "\(nickname) · \(pathName)"
        }
        return Self.nonEmpty(agentNickname)
            ?? pathName
            ?? Self.nonEmpty(subagentKind).map { $0.capitalized }
            ?? "Codex Subagent"
    }

    fileprivate static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public protocol CodexThreadIdentityProviding: Sendable {
    func identity(for sessionID: SessionID) -> CodexThreadIdentity?
    func identities(for sessionIDs: [SessionID]) -> [SessionID: CodexThreadIdentity]
}

public extension CodexThreadIdentityProviding {
    func identities(for sessionIDs: [SessionID]) -> [SessionID: CodexThreadIdentity] {
        Dictionary(uniqueKeysWithValues: sessionIDs.compactMap { sessionID in
            identity(for: sessionID).map { (sessionID, $0) }
        })
    }
}

public final class CodexThreadIdentityStore: CodexThreadIdentityProviding, @unchecked Sendable {
    private let database: DatabaseQueue?
    private let sessionIndexPath: String
    private let indexLock = NSLock()
    private var indexCache: SessionIndexCache?

    /// - Parameters:
    ///   - databasePath: `state_5.sqlite` inside `CODEX_HOME`.
    ///   - sessionIndexPath: `session_index.jsonl` inside `CODEX_HOME`. Defaults
    ///     to the sibling of `databasePath`.
    public init(
        databasePath: String = CodexThreadIdentityStore.defaultDatabasePath(),
        sessionIndexPath: String? = nil
    ) {
        var configuration = Configuration()
        configuration.readonly = true
        database = try? DatabaseQueue(path: databasePath, configuration: configuration)
        self.sessionIndexPath = sessionIndexPath
            ?? URL(fileURLWithPath: databasePath)
                .deletingLastPathComponent()
                .appendingPathComponent("session_index.jsonl")
                .path
    }

    public func identity(for sessionID: SessionID) -> CodexThreadIdentity? {
        guard let database else { return nil }
        let threadNames = threadNames()
        return try? database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT id, title, first_user_message, has_user_event,
                           thread_source, agent_nickname, agent_role, agent_path, source
                    FROM threads WHERE id = ? LIMIT 1
                    """,
                arguments: [sessionID.rawValue]
            ).map { Self.identity(from: $0, threadName: threadNames[sessionID.rawValue]) }
        }
    }

    public func identities(for sessionIDs: [SessionID]) -> [SessionID: CodexThreadIdentity] {
        guard let database, !sessionIDs.isEmpty else { return [:] }
        let threadNames = threadNames()
        return (try? database.read { db in
            let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, title, first_user_message, has_user_event,
                           thread_source, agent_nickname, agent_role, agent_path, source
                    FROM threads WHERE id IN (\(placeholders))
                    """,
                arguments: StatementArguments(sessionIDs.map(\.rawValue))
            )
            return Dictionary(uniqueKeysWithValues: rows.map {
                let identity = Self.identity(from: $0, threadName: threadNames[$0["id"] as String])
                return (identity.sessionID, identity)
            })
        }) ?? [:]
    }

    /// Latest `thread_name` per thread id from `session_index.jsonl`. The file
    /// is append-only, so the last line for an id wins. Re-parsed only when the
    /// file's size or modification date changes.
    private func threadNames() -> [String: String] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: sessionIndexPath)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
        indexLock.lock()
        defer { indexLock.unlock() }
        if let cached = indexCache, cached.size == size, cached.modified == modified {
            return cached.names
        }
        let names = Self.parseSessionIndex(atPath: sessionIndexPath)
        indexCache = SessionIndexCache(size: size, modified: modified, names: names)
        return names
    }

    static func parseSessionIndex(atPath path: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        var names: [String: String] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = object["id"] as? String else { continue }
            guard let name = CodexThreadIdentity.nonEmpty(object["thread_name"] as? String) else {
                continue
            }
            names[id] = name
        }
        return names
    }

    public static func defaultDatabasePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        return codexHome.appendingPathComponent("state_5.sqlite").path
    }

    private static func identity(from row: Row, threadName: String?) -> CodexThreadIdentity {
        let sessionID = SessionID(row["id"] as String)
        let title = row["title"] as String?
        let firstUserMessage = row["first_user_message"] as String?
        let hasUserEvent = (row["has_user_event"] as Int64?) == 1
        let threadSource = row["thread_source"] as String?
        let source: String = row["source"]
        let subagent = subagentMetadata(from: source)
        let isSubagent = threadSource == "subagent"
            || subagent.parentID != nil
            || subagent.kind != nil
        let titleIsInheritedUserMessage = isSubagent
            && !hasUserEvent
            && CodexThreadIdentity.nonEmpty(title) != nil
            && CodexThreadIdentity.nonEmpty(title)
                == CodexThreadIdentity.nonEmpty(firstUserMessage)
        return CodexThreadIdentity(
            sessionID: sessionID,
            title: title,
            threadName: threadName,
            threadSource: threadSource,
            agentNickname: CodexThreadIdentity.nonEmpty(row["agent_nickname"] as String?)
                ?? subagent.nickname,
            agentRole: CodexThreadIdentity.nonEmpty(row["agent_role"] as String?)
                ?? subagent.role,
            agentPath: CodexThreadIdentity.nonEmpty(row["agent_path"] as String?)
                ?? subagent.path,
            parentSessionID: subagent.parentID.map(SessionID.init),
            subagentDepth: subagent.depth,
            subagentKind: subagent.kind,
            titleIsInheritedUserMessage: titleIsInheritedUserMessage
        )
    }

    private static func subagentMetadata(from source: String) -> SubagentMetadata {
        guard let data = source.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subagent = root["subagent"] as? [String: Any] else {
            return SubagentMetadata()
        }
        if let spawn = subagent["thread_spawn"] as? [String: Any] {
            return SubagentMetadata(
                parentID: spawn["parent_thread_id"] as? String,
                depth: (spawn["depth"] as? NSNumber)?.intValue,
                nickname: spawn["agent_nickname"] as? String,
                role: spawn["agent_role"] as? String,
                path: spawn["agent_path"] as? String,
                kind: "thread_spawn"
            )
        }
        return SubagentMetadata(kind: subagent["other"] as? String)
    }
}

private struct SessionIndexCache {
    var size: UInt64
    var modified: Date
    var names: [String: String]
}

private struct SubagentMetadata {
    var parentID: String?
    var depth: Int?
    var nickname: String?
    var role: String?
    var path: String?
    var kind: String?
}
