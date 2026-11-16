import CoreServices
import Diagnostics
import Logging
import Foundation

private let log = Logger(label: "agent")

/// Directory-level change hints for one source root, from FSEvents.
///
/// What it reports, as measured on macOS 27 / APFS:
/// - a file created under the root, at once;
/// - a file modified and then closed by its writer, at the close.
///
/// What it does not report: a file its writer keeps open and appends to says
/// nothing until the close — Codex holds a rollout open for the whole
/// session. Following a file that may still be written is `FileWatchSet`'s
/// job; this stream is for discovery and for writers that close.
///
/// A hint, never a log. An event means "look at this path"; the reader asks
/// the file system what is there. When the system says events were dropped
/// the stream reports `mustRescan` and the owner takes a full inventory.
///
/// Paths come back under the configured root, not the resolved one
/// (`/var` → `/private/var`), for the same reason `jsonlFiles` is
/// path-based: cursors key by path string.
final class DirectoryEvents: @unchecked Sendable {
    enum Event: Sendable, Equatable {
        case changed(path: String)
        case mustRescan
    }

    private let root: String
    private let latency: TimeInterval
    private let handler: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "lumi.directory-events", qos: .utility)
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var resolvedRoot = ""
    private var needsRestart = false

    init(root: URL, latency: TimeInterval = 0.1, handler: @escaping @Sendable (Event) -> Void) {
        self.root = root.path
        self.latency = latency
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// Starts listening, or keeps listening. `false` while the root does not
    /// exist — an agent that was never used here — so the owner asks again
    /// on its slow clock. A root that was replaced under the stream is
    /// listened to afresh.
    @discardableResult
    func start() -> Bool {
        let replaced = lock.withLock { stream != nil && needsRestart }
        if replaced { stop() }
        return lock.withLock {
            if stream != nil { return true }
            guard let resolved = realpath(root, nil) else { return false }
            defer { free(resolved) }
            let resolvedPath = String(cString: resolved)
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagUseCFTypes
            )
            guard let created = FSEventStreamCreate(
                nil,
                directoryEventsCallback,
                &context,
                [resolvedPath] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            ) else {
                log.error("directory_events_unavailable", metadata: .fields(["root": root]))
                return false
            }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                log.error("directory_events_unavailable", metadata: .fields(["root": root]))
                return false
            }
            stream = created
            resolvedRoot = resolvedPath
            needsRestart = false
            return true
        }
    }

    func stop() {
        let stopped: FSEventStreamRef? = lock.withLock {
            defer { stream = nil }
            return stream
        }
        guard let stopped else { return }
        FSEventStreamStop(stopped)
        FSEventStreamInvalidate(stopped)
        FSEventStreamRelease(stopped)
        // The callback holds `self` unretained: let one that is already
        // running finish before the caller may let go of this object.
        queue.sync {}
    }

    fileprivate func receive(path: String, flags: FSEventStreamEventFlags) {
        let rootChanged = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
        let dropped = flags & FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
        ) != 0
        if rootChanged || dropped {
            if rootChanged { lock.withLock { needsRestart = true } }
            log.warning("directory_events_lost", metadata: .fields([
                "root": root,
                "flags": String(flags, radix: 16),
                "root_changed": rootChanged,
            ]))
            handler(.mustRescan)
            return
        }
        guard flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0 else { return }
        let resolved = lock.withLock { resolvedRoot }
        guard !resolved.isEmpty, path.hasPrefix(resolved + "/") else { return }
        handler(.changed(path: root + path.dropFirst(resolved.count)))
    }
}

private let directoryEventsCallback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
    guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
    let events = Unmanaged<DirectoryEvents>.fromOpaque(info).takeUnretainedValue()
    for index in 0..<min(count, paths.count) {
        events.receive(path: paths[index], flags: flags[index])
    }
}
