import Transport
import Foundation
import SQLite3

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

/// Reads Codex's own `state_5.sqlite` through the system SQLite3 library.
/// A connection is opened read-only per lookup: every lookup sees the latest
/// committed state, and the helper never holds Codex's database open.
public final class CodexThreadIdentityStore: CodexThreadIdentityProviding, @unchecked Sendable {
    private let databasePath: String
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
        self.databasePath = databasePath
        self.sessionIndexPath = sessionIndexPath
            ?? URL(fileURLWithPath: databasePath)
                .deletingLastPathComponent()
                .appendingPathComponent("session_index.jsonl")
                .path
    }

    public func identity(for sessionID: SessionID) -> CodexThreadIdentity? {
        identities(for: [sessionID])[sessionID]
    }

    public func identities(for sessionIDs: [SessionID]) -> [SessionID: CodexThreadIdentity] {
        guard !sessionIDs.isEmpty, let database = openDatabase() else { return [:] }
        defer { sqlite3_close_v2(database) }

        let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")
        let sql = """
            SELECT id, title, first_user_message, has_user_event,
                   thread_source, agent_nickname, agent_role, agent_path, source
            FROM threads WHERE id IN (\(placeholders))
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        for (index, sessionID) in sessionIDs.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), sessionID.rawValue, -1, sqliteTransient)
        }

        let threadNames = threadNames()
        var identities: [SessionID: CodexThreadIdentity] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = Self.columnText(statement, 0) else { continue }
            let identity = Self.identity(
                id: id,
                title: Self.columnText(statement, 1),
                firstUserMessage: Self.columnText(statement, 2),
                hasUserEvent: sqlite3_column_int64(statement, 3) == 1,
                threadSource: Self.columnText(statement, 4),
                agentNickname: Self.columnText(statement, 5),
                agentRole: Self.columnText(statement, 6),
                agentPath: Self.columnText(statement, 7),
                source: Self.columnText(statement, 8) ?? "",
                threadName: threadNames[id]
            )
            identities[identity.sessionID] = identity
        }
        return identities
    }

    private func openDatabase() -> OpaquePointer? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close_v2(database)
            return nil
        }
        sqlite3_busy_timeout(database, 500)
        return database
    }

    private static func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
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

    private static func identity(
        id: String,
        title: String?,
        firstUserMessage: String?,
        hasUserEvent: Bool,
        threadSource: String?,
        agentNickname: String?,
        agentRole: String?,
        agentPath: String?,
        source: String,
        threadName: String?
    ) -> CodexThreadIdentity {
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
            sessionID: SessionID(id),
            title: title,
            threadName: threadName,
            threadSource: threadSource,
            agentNickname: CodexThreadIdentity.nonEmpty(agentNickname) ?? subagent.nickname,
            agentRole: CodexThreadIdentity.nonEmpty(agentRole) ?? subagent.role,
            agentPath: CodexThreadIdentity.nonEmpty(agentPath) ?? subagent.path,
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

/// SQLITE_TRANSIENT: have SQLite copy bound text before the call returns.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
