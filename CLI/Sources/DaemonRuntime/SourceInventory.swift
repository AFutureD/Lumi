import Foundation
import Synchronization

/// One regular `.jsonl` file under a source root as a walk of the tree saw
/// it: where it is, how big, when it last changed, and the device + inode
/// pair that survives a move.
struct SourceFile: Sendable, Equatable {
    let relativePath: String
    let size: UInt64
    let modifiedAt: Date
    let device: Int64
    let inode: UInt64
}

/// Every regular `.jsonl` under `root`, recursively, hidden entries skipped.
///
/// One `fts` walk, whose own `stat` is the only one per file. The walk is a
/// level-triggered inventory — what is on disk now — and the callers treat
/// it as nomination only: whoever reads a file asks for its size again.
///
/// Path-based on purpose: a path is the configured root plus the relative
/// path, never resolved (`/var` stays `/var`), because cursors key by path
/// string and the hook path derives them from the same root. A missing root
/// is an agent that was never used here, not an error.
func jsonlFiles(under root: URL) -> [SourceFile] {
    let rootPath = root.path
    guard let rootCString = strdup(rootPath) else { return [] }
    defer { free(rootCString) }
    var arguments: [UnsafeMutablePointer<CChar>?] = [rootCString, nil]
    // PHYSICAL: a symlink inside the tree is an entry, not a detour.
    // COMFOLLOW: the root itself may be one.
    guard let stream = fts_open(&arguments, FTS_PHYSICAL | FTS_COMFOLLOW | FTS_NOCHDIR, nil) else { return [] }
    defer { fts_close(stream) }

    let prefixLength = rootPath.utf8.count + 1
    let suffix = Array(".jsonl".utf8)
    var files: [SourceFile] = []
    while let entry = fts_read(stream) {
        let info = Int32(entry.pointee.fts_info)
        let pathLength = Int(entry.pointee.fts_pathlen)
        let nameLength = Int(entry.pointee.fts_namelen)
        guard entry.pointee.fts_level > 0, let path = entry.pointee.fts_path else { continue }
        if nameLength > 0, path[pathLength - nameLength] == 0x2E {
            // Hidden: skip the file, and never descend into the directory.
            if info == FTS_D { fts_set(stream, entry, FTS_SKIP) }
            continue
        }
        guard info == FTS_F, nameLength >= suffix.count, pathLength > prefixLength,
              let status = entry.pointee.fts_statp else { continue }
        let isJSONL = suffix.withUnsafeBufferPointer { expected in
            memcmp(path + pathLength - expected.count, expected.baseAddress, expected.count) == 0
        }
        guard isJSONL else { continue }
        let relative = String(
            decoding: UnsafeRawBufferPointer(start: path + prefixLength, count: pathLength - prefixLength),
            as: UTF8.self
        )
        let modified = status.pointee.st_mtimespec
        files.append(SourceFile(
            relativePath: relative,
            size: UInt64(max(0, status.pointee.st_size)),
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(modified.tv_sec) + TimeInterval(modified.tv_nsec) / 1_000_000_000),
            device: Int64(status.pointee.st_dev),
            inode: UInt64(status.pointee.st_ino)
        ))
    }
    return files
}

/// Whether `path` is a file `jsonlFiles(under:)` would list for `root`: a
/// `.jsonl` below it with no hidden component on the way. Only the part
/// below the root is judged — the root itself is `~/.codex/…`, `~/.claude/…`.
func isSourceFile(_ path: String, underRoot root: String) -> Bool {
    guard path.hasSuffix(".jsonl"), path.hasPrefix(root + "/") else { return false }
    return !path.dropFirst(root.count).contains("/.")
}

/// The current size of one file, or `nil` when it is gone. The readers ask
/// here right before they read, so an inventory taken a moment ago can never
/// pass a stale size for a truncation.
func currentFileSize(atPath path: String) -> UInt64? {
    var status = stat()
    guard stat(path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
    return UInt64(max(0, status.st_size))
}

/// When one file was last written, or `nil` when it is gone.
func fileModificationDate(atPath path: String) -> Date? {
    var status = stat()
    guard stat(path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
    let modified = status.st_mtimespec
    return Date(timeIntervalSince1970: TimeInterval(modified.tv_sec) + TimeInterval(modified.tv_nsec) / 1_000_000_000)
}

/// One walk per root, so the usage scan does not repeat the walk a session
/// watcher just took of the same root.
///
/// The watchers always walk (`freshFiles`): their inventory decides what is
/// read and what is watched, and a listing taken before a write cannot find
/// it. The usage scan is not latency-bound and takes a walk no older than
/// `maximumAge` (`files`) — a write it misses that way is counted on its
/// next pass.
public final class SourceInventory: Sendable {
    private struct Snapshot {
        let files: [SourceFile]
        let takenAt: ContinuousClock.Instant
    }

    private let maximumAge: Duration
    private let snapshots = Mutex<[String: Snapshot]>([:])

    public init(maximumAge: Duration = .seconds(10)) {
        self.maximumAge = maximumAge
    }

    /// The root's files as of this call; the walk is kept for `files`.
    func freshFiles(under root: URL) -> [SourceFile] {
        let takenAt = ContinuousClock.now
        let files = jsonlFiles(under: root)
        snapshots.withLock { $0[root.path] = Snapshot(files: files, takenAt: takenAt) }
        return files
    }

    /// The root's files, from a walk no older than `maximumAge`.
    func files(under root: URL) -> [SourceFile] {
        let cached = snapshots.withLock { $0[root.path] }
        if let cached, ContinuousClock.now - cached.takenAt <= maximumAge { return cached.files }
        return freshFiles(under: root)
    }
}
