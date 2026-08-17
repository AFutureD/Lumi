import AgentStatusTransport
import Foundation
import GRDB

public struct CodexThreadIdentity: Hashable, Sendable {
    public let sessionID: SessionID
    public let title: String?
    public let threadSource: String?
    public let agentNickname: String?
    public let agentRole: String?
    public let agentPath: String?
    public let parentSessionID: SessionID?
    public let subagentDepth: Int?
    public let subagentKind: String?

    public init(
        sessionID: SessionID,
        title: String? = nil,
        threadSource: String? = nil,
        agentNickname: String? = nil,
        agentRole: String? = nil,
        agentPath: String? = nil,
        parentSessionID: SessionID? = nil,
        subagentDepth: Int? = nil,
        subagentKind: String? = nil
    ) {
        self.sessionID = sessionID
        self.title = title
        self.threadSource = threadSource
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.agentPath = agentPath
        self.parentSessionID = parentSessionID
        self.subagentDepth = subagentDepth
        self.subagentKind = subagentKind
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
        if let title = Self.nonEmpty(title) { return title }
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

    public init(
        databasePath: String = CodexThreadIdentityStore.defaultDatabasePath()
    ) {
        var configuration = Configuration()
        configuration.readonly = true
        database = try? DatabaseQueue(path: databasePath, configuration: configuration)
    }

    public func identity(for sessionID: SessionID) -> CodexThreadIdentity? {
        guard let database else { return nil }
        return try? database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT id, title, thread_source, agent_nickname, agent_role, agent_path, source
                    FROM threads WHERE id = ? LIMIT 1
                    """,
                arguments: [sessionID.rawValue]
            ).map(Self.identity(from:))
        }
    }

    public func identities(for sessionIDs: [SessionID]) -> [SessionID: CodexThreadIdentity] {
        guard let database, !sessionIDs.isEmpty else { return [:] }
        return (try? database.read { db in
            let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, title, thread_source, agent_nickname, agent_role, agent_path, source
                    FROM threads WHERE id IN (\(placeholders))
                    """,
                arguments: StatementArguments(sessionIDs.map(\.rawValue))
            )
            return Dictionary(uniqueKeysWithValues: rows.map {
                let identity = Self.identity(from: $0)
                return (identity.sessionID, identity)
            })
        }) ?? [:]
    }

    public static func defaultDatabasePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        return codexHome.appendingPathComponent("state_5.sqlite").path
    }

    private static func identity(from row: Row) -> CodexThreadIdentity {
        let sessionID = SessionID(row["id"] as String)
        let source: String = row["source"]
        let subagent = subagentMetadata(from: source)
        return CodexThreadIdentity(
            sessionID: sessionID,
            title: row["title"],
            threadSource: row["thread_source"],
            agentNickname: CodexThreadIdentity.nonEmpty(row["agent_nickname"] as String?)
                ?? subagent.nickname,
            agentRole: CodexThreadIdentity.nonEmpty(row["agent_role"] as String?)
                ?? subagent.role,
            agentPath: CodexThreadIdentity.nonEmpty(row["agent_path"] as String?)
                ?? subagent.path,
            parentSessionID: subagent.parentID.map(SessionID.init),
            subagentDepth: subagent.depth,
            subagentKind: subagent.kind
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

private struct SubagentMetadata {
    var parentID: String?
    var depth: Int?
    var nickname: String?
    var role: String?
    var path: String?
    var kind: String?
}
