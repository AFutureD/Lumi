import Logging
import ServiceContextModule

/// The id that ties every log line of one unit of work together: an IPC
/// request id, a helper run id, a Relay request id. It travels in the
/// task-local `ServiceContext` (the same carrier swift-distributed-tracing
/// uses), so nothing is threaded through parameters; the handler renders it
/// first in the message as `['trace':<id>]`.
public enum TraceIDKey: ServiceContextKey {
    public typealias Value = String
    public static let nameOverride: String? = "trace"
}

public extension ServiceContext {
    var traceID: String? {
        get { self[TraceIDKey.self] }
        set { self[TraceIDKey.self] = newValue }
    }
}

/// Runs `body` as one unit of work: every logger used inside (this task and
/// its children) carries `['trace':id]`. Inherits the caller's isolation, so
/// a `@MainActor` caller or an actor method can pass a closure touching its
/// own state.
public func withTrace<T>(
    _ id: String,
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> T
) async rethrows -> T {
    var context = ServiceContext.current ?? .topLevel
    context.traceID = id
    return try await ServiceContext.$current.withValue(context, operation: body, isolation: isolation)
}

/// Synchronous variant for code that never suspends.
public func withTrace<T>(_ id: String, _ body: () throws -> T) rethrows -> T {
    var context = ServiceContext.current ?? .topLevel
    context.traceID = id
    return try ServiceContext.$current.withValue(context, operation: body)
}

/// The current unit's id, for crossing a boundary the context cannot
/// (handing it to a NIO handler, putting it in an IPC request id).
public var currentTraceID: String? {
    ServiceContext.current?.traceID
}

/// A fresh short id for a unit of work that has no natural one (a helper
/// run, a Mac reconcile pass): 8 hex characters, enough to grep.
public func makeTraceID() -> String {
    var generator = SystemRandomNumberGenerator()
    let value = UInt32.random(in: .min ... .max, using: &generator)
    return String(format: "%08x", value)
}

public extension Logger.MetadataProvider {
    /// swift-log's hook: read the task-local trace id on every log call.
    static let traceID = Logger.MetadataProvider {
        guard let trace = ServiceContext.current?.traceID else { return [:] }
        return ["trace": .string(trace)]
    }
}
