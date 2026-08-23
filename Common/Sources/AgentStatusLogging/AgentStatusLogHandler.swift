import Foundation
import Logging
import os

/// The one `LogHandler` of the project. Renders
/// `[<iso-8601 ms>] [<LEVEL>:<subsystem>] [<category>] <message>` where the
/// message is `['trace':<id>] <event> key=value … [error="…"]`, and fans it
/// out to `os.Logger` (subsystem `app.huanan.lumi.<subsystem>`,
/// category = the logger's label), the per-process file, `errors.log` for
/// `error` and above, and optionally stderr.
public struct AgentStatusLogHandler: LogHandler {
    public let category: String
    public var metadata: Logging.Logger.Metadata = [:]
    public var logLevel: Logging.Logger.Level
    public var metadataProvider: Logging.Logger.MetadataProvider?

    private let sinks: LogSinks
    private let osLogger: os.Logger

    public init(category: String, sinks: LogSinks, metadataProvider: Logging.Logger.MetadataProvider?) {
        self.category = category
        self.sinks = sinks
        self.metadataProvider = metadataProvider
        logLevel = sinks.configuration.minimumLevel
        osLogger = os.Logger(subsystem: "\(LogSinks.osSubsystemPrefix).\(sinks.configuration.subsystem)", category: category)
    }

    public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata explicit: Logging.Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        var merged = metadata
        if let provided = metadataProvider?.get() {
            merged.merge(provided, uniquingKeysWith: { _, rhs in rhs })
        }
        if let explicit {
            merged.merge(explicit, uniquingKeysWith: { _, rhs in rhs })
        }
        let rendered = LogRendering.message(message.description, metadata: merged)
        let text = LogRendering.line(
            timestamp: Date(), level: level, subsystem: sinks.configuration.subsystem, category: category, message: rendered
        )
        osLogger.log(level: LogRendering.osLogType(level), "[\(category, privacy: .public)] \(rendered, privacy: .public)")
        sinks.write(text, level: level)
    }
}

/// The process-wide sinks behind every handler: the per-subsystem file, the
/// shared `errors.log`, stderr. One instance per `bootstrap`.
public final class LogSinks: @unchecked Sendable {
    public static let osSubsystemPrefix = "app.huanan.lumi"
    public static let errorsFileName = "errors.log"

    public let configuration: LogConfiguration
    private let processFile: LogFile?
    private let errorsFile: LogFile?

    public init(configuration: LogConfiguration) {
        self.configuration = configuration
        if let directory = configuration.directory {
            processFile = LogFile(
                url: directory.appendingPathComponent("\(configuration.subsystem).log"),
                maximumBytes: configuration.maximumFileBytes,
                retainedRotations: configuration.retainedRotations
            )
            errorsFile = LogFile(
                url: directory.appendingPathComponent(Self.errorsFileName),
                maximumBytes: configuration.maximumFileBytes,
                retainedRotations: configuration.retainedRotations
            )
        } else {
            processFile = nil
            errorsFile = nil
        }
    }

    func write(_ line: String, level: Logging.Logger.Level) {
        processFile?.append(line)
        if level >= .error { errorsFile?.append(line) }
        if let prefix = configuration.standardErrorPrefix, level >= configuration.standardErrorMinimumLevel {
            FileHandle.standardError.write(Data("\(prefix) \(line)\n".utf8))
        }
    }
}

/// Pure rendering, shared by the handler and its tests.
public enum LogRendering {
    /// `[<iso-8601 ms>] [<LEVEL>:<subsystem>] [<category>] <message>`.
    public static func line(
        timestamp: Date,
        level: Logging.Logger.Level,
        subsystem: String,
        category: String,
        message: String
    ) -> String {
        "[\(timestamp.formatted(timestampStyle))] [\(level.label):\(subsystem)] [\(category)] \(message)"
    }

    /// `['trace':<id>] <text> key=value … [error="…"]`: the trace leads so a
    /// grep for a request id finds every line of it; the remaining keys are
    /// sorted for a stable column order, `error` always last.
    public static func message(_ text: String, metadata: Logging.Logger.Metadata) -> String {
        var parts: [String] = []
        if let trace = metadata["trace"].map(render), !trace.isEmpty {
            parts.append("['trace':\(trace)]")
        }
        parts.append(text)
        for key in metadata.keys.sorted() where key != "trace" && key != "error" {
            parts.append("\(key)=\(renderValue(render(metadata[key]!), quoted: true))")
        }
        if let error = metadata["error"] {
            parts.append("error=\(renderValue(render(error), quoted: true))")
        }
        return parts.joined(separator: " ")
    }

    /// One metadata value as text (nested values fall back to their description).
    static func render(_ value: Logging.Logger.Metadata.Value) -> String {
        switch value {
        case let .string(string): string
        case let .stringConvertible(convertible): convertible.description
        case .dictionary, .array: value.description
        }
    }

    /// A field value as text; with `quoted`, values holding whitespace,
    /// quotes or `=` are wrapped in double quotes and escaped.
    public static func renderValue(_ value: Any, quoted: Bool) -> String {
        let text: String
        switch value {
        case let string as String: text = string
        case let date as Date: text = date.formatted(timestampStyle)
        case let url as URL: text = url.isFileURL ? url.path : url.absoluteString
        case let double as Double: text = String(format: "%.1f", double)
        case let float as Float: text = String(format: "%.1f", float)
        case let bool as Bool: text = bool ? "true" : "false"
        default: text = String(describing: value)
        }
        guard quoted else { return text }
        let needsQuotes = text.isEmpty || text.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "=" })
        guard needsQuotes else { return text }
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
        return "\"\(escaped)\""
    }

    static func osLogType(_ level: Logging.Logger.Level) -> OSLogType {
        switch level {
        case .trace, .debug: .debug
        case .info: .info
        case .notice, .warning: .default
        case .error: .error
        case .critical: .fault
        }
    }

    /// ISO-8601 UTC with milliseconds, the same shape the transport uses.
    static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

/// One append-only log file with size-based rotation. Opened `O_APPEND` so
/// several processes (daemon, helper, Mac app) can share `errors.log`
/// without interleaving inside a line. Directory 0700, files 0600: the lines
/// name local paths and session ids.
final class LogFile: @unchecked Sendable {
    let url: URL
    private let maximumBytes: Int
    private let retainedRotations: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    private var written: Int = 0
    private var openFailed = false

    init(url: URL, maximumBytes: Int, retainedRotations: Int) {
        self.url = url
        self.maximumBytes = maximumBytes
        self.retainedRotations = retainedRotations
    }

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let data = Data((line + "\n").utf8)
        guard openIfNeeded() != nil else { return }
        // Rotate before the write that would overflow, so the newest line is
        // always in the live file.
        if written > 0, written + data.count > maximumBytes { rotate() }
        guard let handle = openIfNeeded() else { return }
        do {
            try handle.write(contentsOf: data)
            written += data.count
        } catch {
            return
        }
    }

    private func openIfNeeded() -> FileHandle? {
        if let handle { return handle }
        guard !openFailed else { return nil }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            openFailed = true
            return nil
        }
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else {
            openFailed = true
            return nil
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        self.handle = handle
        written = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return handle
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        written = 0
        let manager = FileManager.default
        // x.log.3 is dropped, .2 → .3, .1 → .2, x.log → .1. Another process
        // rotating at the same moment only costs a generation, never a line.
        try? manager.removeItem(at: rotatedURL(retainedRotations))
        if retainedRotations >= 2 {
            for generation in stride(from: retainedRotations - 1, through: 1, by: -1) {
                let source = rotatedURL(generation)
                guard manager.fileExists(atPath: source.path) else { continue }
                try? manager.moveItem(at: source, to: rotatedURL(generation + 1))
            }
        }
        if retainedRotations >= 1 {
            try? manager.moveItem(at: url, to: rotatedURL(1))
        } else {
            try? manager.removeItem(at: url)
        }
    }

    private func rotatedURL(_ generation: Int) -> URL {
        URL(fileURLWithPath: url.path + ".\(generation)")
    }
}
