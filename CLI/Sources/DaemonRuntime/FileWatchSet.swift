import Diagnostics
import Logging
import Foundation

private let log = Logger(label: "agent")

/// File-level change notifications (kqueue) for the files that may still be
/// written: one event descriptor per file, an event on every write whether
/// or not the writer ever closes the file, and nothing — no wakeup, no CPU —
/// while the file is quiet.
///
/// The set is a budget, not a list of sessions. Each watch holds one file
/// descriptor, so at `limit` the least recently active file gives its place
/// to a more recently active one. Losing a watch changes how soon a write is
/// noticed (the owner's slow reconcile pass instead of at once); it says
/// nothing about the session, whose state only ever follows what is read.
///
/// A watched file that is deleted or renamed — Codex compressing or
/// archiving a rollout — reports `gone` and leaves the set; the descriptor
/// follows the old file, not the path.
final class FileWatchSet: @unchecked Sendable {
    enum Event: Sendable, Equatable {
        case written(path: String)
        case gone(path: String)
    }

    private struct Watch {
        let source: any DispatchSourceFileSystemObject
        var activity: Date
    }

    let limit: Int
    private let handler: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "lumi.file-watch", qos: .utility)
    private let lock = NSLock()
    private var watches: [String: Watch] = [:]

    init(limit: Int, handler: @escaping @Sendable (Event) -> Void) {
        self.limit = max(0, limit)
        self.handler = handler
    }

    deinit {
        removeAll()
    }

    var count: Int {
        lock.withLock { watches.count }
    }

    func contains(_ path: String) -> Bool {
        lock.withLock { watches[path] != nil }
    }

    /// Watches `path`, last active at `activity`. At the limit the least
    /// recently active watch is given up for it — unless the newcomer is
    /// itself the least active, in which case it is not watched. `false`
    /// when the file is not watched after the call (gone, or over budget).
    @discardableResult
    func watch(_ path: String, activity: Date = Date()) -> Bool {
        var evicted: [String] = []
        let watched: Bool = lock.withLock {
            if watches[path] != nil {
                if let known = watches[path]?.activity, activity > known { watches[path]?.activity = activity }
                return true
            }
            while watches.count >= limit {
                guard let oldest = watches.min(by: { $0.value.activity < $1.value.activity }),
                      oldest.value.activity < activity else { return false }
                oldest.value.source.cancel()
                watches[oldest.key] = nil
                evicted.append(oldest.key)
            }
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { return false }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .delete, .rename, .revoke],
                queue: queue
            )
            source.setEventHandler { [weak self, handler] in
                let flags = source.data
                if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                    self?.unwatch(path)
                    handler(.gone(path: path))
                } else {
                    self?.touch(path)
                    handler(.written(path: path))
                }
            }
            // The descriptor is closed by value: retiring a watch never
            // depends on this set still being alive.
            source.setCancelHandler { close(descriptor) }
            watches[path] = Watch(source: source, activity: activity)
            source.activate()
            return true
        }
        if !evicted.isEmpty {
            log.debug("file_watch_evicted", metadata: .fields(["files": evicted.count, "limit": limit]))
        }
        return watched
    }

    func unwatch(_ path: String) {
        let source = lock.withLock { watches.removeValue(forKey: path)?.source }
        source?.cancel()
    }

    /// Makes the set these files, most important first: what is not listed
    /// stops being watched, what is listed is watched up to the limit.
    func replace(with ranked: [(path: String, activity: Date)]) {
        let kept = ranked.prefix(limit)
        let keptPaths = Set(kept.map(\.path))
        let dropped: [any DispatchSourceFileSystemObject] = lock.withLock {
            let stale = watches.filter { !keptPaths.contains($0.key) }
            for path in stale.keys { watches[path] = nil }
            return stale.values.map(\.source)
        }
        dropped.forEach { $0.cancel() }
        for file in kept {
            watch(file.path, activity: file.activity)
        }
    }

    func removeAll() {
        let sources: [any DispatchSourceFileSystemObject] = lock.withLock {
            defer { watches.removeAll() }
            return watches.values.map(\.source)
        }
        sources.forEach { $0.cancel() }
    }

    private func touch(_ path: String) {
        lock.withLock { watches[path]?.activity = Date() }
    }
}
