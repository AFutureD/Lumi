import Foundation
import Logging

/// Where and how much a process logs. Built once at process start
/// (`fromEnvironment` for the daemon / helper, explicit for the Mac app) and
/// handed to `AgentStatusLogging.bootstrap`.
public struct LogConfiguration: Sendable {
    /// `daemon` / `helper` / `app` / `ios`: the `[LEVEL:subsystem]` column,
    /// the per-process file name and the `os.Logger` subsystem suffix.
    public var subsystem: String
    /// Lines below this level are dropped by the handler before rendering.
    public var minimumLevel: Logger.Level
    /// Directory of `<subsystem>.log` and `errors.log`; `nil` writes no files.
    public var directory: URL?
    /// Mirror lines at or above `standardErrorMinimumLevel` to stderr with
    /// this prefix (`agent-status-daemon:`); `nil` leaves stderr alone.
    public var standardErrorPrefix: String?
    public var standardErrorMinimumLevel: Logger.Level
    /// A file past this size is rotated (`x.log` → `x.log.1` …).
    public var maximumFileBytes: Int
    /// How many rotated generations to keep besides the live file.
    public var retainedRotations: Int

    public static let environmentLevelKey = "AGENT_STATUS_LOG_LEVEL"
    public static let environmentDirectoryKey = "AGENT_STATUS_LOG_DIRECTORY"

    public init(
        subsystem: String,
        minimumLevel: Logger.Level = .info,
        directory: URL? = nil,
        standardErrorPrefix: String? = nil,
        standardErrorMinimumLevel: Logger.Level = .info,
        maximumFileBytes: Int = 5 * 1024 * 1024,
        retainedRotations: Int = 3
    ) {
        self.subsystem = subsystem
        self.minimumLevel = minimumLevel
        self.directory = directory
        self.standardErrorPrefix = standardErrorPrefix
        self.standardErrorMinimumLevel = standardErrorMinimumLevel
        self.maximumFileBytes = maximumFileBytes
        self.retainedRotations = retainedRotations
    }

    /// The current user's home; `NSHomeDirectory()` is the one spelling that
    /// exists on macOS and iOS alike (the iOS app links this module through
    /// `AgentStatusRemote`, even though it writes no files).
    public static var currentHomeDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// `~/Library/Logs/Agent Status` — where Console.app's file browser and
    /// the Mac app's "Show in Finder" both look.
    public static func defaultDirectory(homeDirectory: URL = currentHomeDirectory) -> URL {
        homeDirectory.appendingPathComponent("Library/Logs/Agent Status", isDirectory: true)
    }

    /// Level from `AGENT_STATUS_LOG_LEVEL` (default `info`); directory from
    /// `AGENT_STATUS_LOG_DIRECTORY` (default `~/Library/Logs/Agent Status`;
    /// `off` / `0` / `none` disables files). Isolated smoke runs point the
    /// directory at their scratch folder so they never touch the real logs.
    public static func fromEnvironment(
        subsystem: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = currentHomeDirectory,
        standardErrorPrefix: String? = nil,
        standardErrorMinimumLevel: Logger.Level = .info
    ) -> LogConfiguration {
        let level = environment[environmentLevelKey].flatMap(Logger.Level.init(lenient:)) ?? .info
        let directory: URL?
        if let override = environment[environmentDirectoryKey]?.trimmingCharacters(in: .whitespaces), !override.isEmpty {
            directory = ["off", "0", "none", "false"].contains(override.lowercased())
                ? nil
                : URL(fileURLWithPath: override, isDirectory: true)
        } else {
            directory = defaultDirectory(homeDirectory: homeDirectory)
        }
        return LogConfiguration(
            subsystem: subsystem,
            minimumLevel: level,
            directory: directory,
            standardErrorPrefix: standardErrorPrefix,
            standardErrorMinimumLevel: standardErrorMinimumLevel
        )
    }
}

/// The process-wide wiring of swift-log: `bootstrap` once at process start,
/// then every `Logger(label:)` in the process (label = category) renders
/// through `AgentStatusLogHandler` and carries the current trace id.
///
/// Business code only writes the message (`event key=value …`); the
/// timestamp, level, subsystem, category and trace columns are the
/// handler's. Fields carry identifiers, counts, sizes, kinds and durations —
/// never Session content, prompts, tool arguments, pairing codes or
/// credentials.
public enum AgentStatusLogging {
    /// Calls `LoggingSystem.bootstrap`; swift-log allows this once per
    /// process, so every entry point does it first thing and nothing else
    /// ever does.
    public static func bootstrap(_ configuration: LogConfiguration) {
        let sinks = LogSinks(configuration: configuration)
        LoggingSystem.bootstrap(
            { label, metadataProvider in
                AgentStatusLogHandler(category: label, sinks: sinks, metadataProvider: metadataProvider)
            },
            metadataProvider: .traceID
        )
    }

    /// The handler factory for a standalone `Logger(label:factory:)` — tests,
    /// and any process that must not touch the global bootstrap.
    public static func makeHandler(category: String, configuration: LogConfiguration) -> AgentStatusLogHandler {
        AgentStatusLogHandler(category: category, sinks: LogSinks(configuration: configuration), metadataProvider: .traceID)
    }
}

public extension Logger.Level {
    /// `debug` / `info` / `warning` (`warn`) / `error` …, case-insensitive;
    /// `verbose` and `trace` both mean the most detailed level we use.
    init?(lenient name: String) {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "trace", "verbose": self = .trace
        case "debug": self = .debug
        case "info": self = .info
        case "notice": self = .notice
        case "warning", "warn": self = .warning
        case "error": self = .error
        case "critical", "fault": self = .critical
        default: return nil
        }
    }

    /// The label inside `[LEVEL:subsystem]`.
    var label: String {
        switch self {
        case .trace: "TRACE"
        case .debug: "DEBUG"
        case .info: "INFO"
        case .notice: "NOTICE"
        case .warning: "WARN"
        case .error: "ERROR"
        case .critical: "CRITICAL"
        }
    }
}

public extension Logger.Metadata {
    /// Business fields as a metadata dictionary: `nil` values are dropped,
    /// dates render as ISO-8601, doubles with one decimal, everything else
    /// through `String(describing:)`. Keys render sorted, `trace` first and
    /// `error` last — see `AgentStatusLogHandler`.
    static func fields(_ pairs: KeyValuePairs<String, Any?>) -> Logger.Metadata {
        var metadata: Logger.Metadata = [:]
        for (key, value) in pairs {
            guard let value else { continue }
            metadata[key] = .string(LogRendering.renderValue(value, quoted: false))
        }
        return metadata
    }
}

/// Whole milliseconds since `start`, for `ms=` fields.
public enum LogClock {
    public static func milliseconds(since start: ContinuousClock.Instant, now: ContinuousClock.Instant = .now) -> Int {
        let components = start.duration(to: now).components
        return Int(components.seconds * 1_000) + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}
