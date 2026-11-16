import Transport
import Foundation

/// How the usage scanner recognises a file across polls. The path is not
/// identity: Codex `archive` moves a rollout from `sessions/` to
/// `archived_sessions/`, and a moved file must continue from its cursor
/// rather than be read again. The device + inode pair survives a move; a
/// hash of the file's first bytes tells a rewrite (new content under the
/// same inode, or an inode reused after a delete) from an append.
public enum UsageFileIdentity {
    /// Leading bytes the prefix hash covers.
    public static let prefixLimit = 4096

    /// `<source>:<device>:<inode>`, falling back to the path on a file
    /// system that reports neither.
    public static func identity(source: AgentProvider, attributes: [FileAttributeKey: Any], path: String) -> String {
        let device = (attributes[.systemNumber] as? NSNumber)?.int64Value
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        guard let device, let inode else { return "\(source.rawValue):path:\(path)" }
        return identity(source: source, device: device, inode: inode)
    }

    /// The same identity from a `stat` result (`st_dev`, `st_ino`). Stored
    /// cursors key on this string, so both spellings must stay identical.
    public static func identity(source: AgentProvider, device: Int64, inode: UInt64) -> String {
        "\(source.rawValue):\(device):\(inode)"
    }

    /// SHA-256 of the first `length` bytes, or `nil` when the file no longer
    /// has that many — which is itself a rewrite.
    public static func prefixHash(path: String, length: Int) throws -> String? {
        guard length > 0 else { return "" }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: length), data.count == length else { return nil }
        return data.sha256Hex
    }
}
