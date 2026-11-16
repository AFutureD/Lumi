import Diagnostics
import Logging
import Synchronization
import Foundation

private let log = Logger(label: "agent")

/// How a watcher learns that the files under one source root moved, without
/// polling them.
///
/// Three signals feed one inbox, and the owner reads them as one batch:
///
/// | Signal | Source | Tells the owner |
/// | --- | --- | --- |
/// | directory event | `DirectoryEvents` (FSEvents) | a file appeared, or was written and closed |
/// | file event | `FileWatchSet` (kqueue) | a watched file was written, or is gone |
/// | reconcile clock | a slow timer | take a full inventory — the level-triggered resync |
///
/// The first two are edges: prompt, and allowed to be lost. The third is
/// the level: it makes a lost edge cost one interval of delay instead of a
/// missed write. Every edge names a path and nothing else — the owner reads
/// the file from its own cursor, so a duplicate or a stale hint is harmless.
///
/// A batch is taken after `settle`: an agent streaming output appends many
/// times a second, and one read per burst is enough. While nothing moves the
/// owner is parked in `next()` and only the reconcile clock ever fires.
final class SourceFileMonitor: Sendable {
    struct Batch: Sendable, Equatable {
        /// Files that may have changed (or gone), as configured-root paths.
        var paths: Set<String> = []
        /// Take a full inventory: the clock fired, or events were dropped.
        var fullPass = false
        /// The owner's own `signal()` arrived.
        var signalled = false

        var isEmpty: Bool { paths.isEmpty && !fullPass && !signalled }
    }

    private final class Inbox: Sendable {
        private let pending = Mutex(Batch())
        let wake: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() {
            (wake, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        }

        func note(_ change: (inout Batch) -> Void) {
            pending.withLock { change(&$0) }
            continuation.yield()
        }

        func take() -> Batch {
            pending.withLock { batch in
                defer { batch = Batch() }
                return batch
            }
        }

        func finish() {
            continuation.finish()
        }
    }

    let root: URL
    let reconcileInterval: Duration
    private let settle: Duration
    private let inbox: Inbox
    private let directory: DirectoryEvents
    private let watches: FileWatchSet

    /// - Parameters:
    ///   - accepts: which directory-event paths matter to the owner; file
    ///     events are for files the owner chose to watch and always pass.
    ///   - watchLimit: the file-descriptor budget of the watch set.
    init(
        root: URL,
        accepts: @escaping @Sendable (String) -> Bool,
        settle: Duration = .milliseconds(200),
        reconcileInterval: Duration = .seconds(30),
        watchLimit: Int = 256
    ) {
        self.root = root
        self.settle = settle
        self.reconcileInterval = reconcileInterval
        let inbox = Inbox()
        self.inbox = inbox
        directory = DirectoryEvents(root: root) { event in
            switch event {
            case let .changed(path):
                guard accepts(path) else { return }
                inbox.note { $0.paths.insert(path) }
            case .mustRescan:
                inbox.note { $0.fullPass = true }
            }
        }
        watches = FileWatchSet(limit: watchLimit) { event in
            switch event {
            case let .written(path), let .gone(path):
                inbox.note { $0.paths.insert(path) }
            }
        }
    }

    var watchLimit: Int { watches.limit }
    var watchedCount: Int { watches.count }

    /// Starts the directory events. Call it before the first inventory: a
    /// write that lands during that pass is then seen by the pass or
    /// announced after it, never neither. `false` while the root is missing.
    @discardableResult
    func start() -> Bool {
        directory.start()
    }

    func stop() {
        directory.stop()
        watches.removeAll()
        inbox.finish()
    }

    /// The slow clock: asks for a full pass every `reconcileInterval`, and
    /// retries the directory events for a root that did not exist yet or was
    /// replaced. Runs until cancelled, as a sibling of the owner's `next()`
    /// loop.
    func runReconcileClock() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: reconcileInterval)
            } catch {
                return
            }
            directory.start()
            inbox.note { $0.fullPass = true }
        }
    }

    /// The next batch of changes, or `nil` once the task is cancelled or the
    /// monitor stopped. One consumer.
    func next() async -> Batch? {
        for await _ in inbox.wake {
            try? await Task.sleep(for: settle)
            if Task.isCancelled { return nil }
            let batch = inbox.take()
            if !batch.isEmpty { return batch }
        }
        return nil
    }

    /// Wakes the owner for work of its own, coalesced with file changes.
    func signal() {
        inbox.note { $0.signalled = true }
    }

    /// Makes the watch set these files, most important first.
    func setWatched(_ ranked: [(path: String, activity: Date)]) {
        watches.replace(with: ranked)
    }

    /// A file that was just written is watched from now on, budget allowing.
    func ensureWatched(_ path: String) {
        watches.watch(path)
    }
}
