import Adapters
import Core
import IPCClient
import Diagnostics
import Logging
import Transport
import Darwin
import Foundation

private let log = Logger(label: "agent")

/// `Spark [--agent codex|claude|auto] [--verbose]`
///
/// Invoked by Codex / Claude Code hooks with the hook payload on stdin. Reads
/// the session's transcript increment, reduces hook + transcript into
/// Agent-domain events, and ships them to the daemon over the Unix socket.
///
/// Always exits 0: a hook exit code of 2 would block the agent's tool call,
/// and a monitoring failure must never do that. Problems go to stderr and to
/// `helper.log`; `--verbose` mirrors every line (debug included) to stderr.
@main
enum SparkMain {
    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        var selection: HelperAgentSelection = .auto
        var verbose = false
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--agent":
                if let value = iterator.next(), let parsed = HelperAgentSelection(rawValue: value) {
                    selection = parsed
                }
            case "--verbose", "-v":
                verbose = true
            default:
                if argument.hasPrefix("--agent="),
                   let parsed = HelperAgentSelection(rawValue: String(argument.dropFirst("--agent=".count))) {
                    selection = parsed
                }
            }
        }

        var configuration = LogConfiguration.fromEnvironment(
            subsystem: "helper",
            standardErrorPrefix: "Spark:",
            standardErrorMinimumLevel: verbose ? .debug : .warning
        )
        if verbose { configuration.minimumLevel = .debug }
        Diagnostics.bootstrap(configuration)
        let started = ContinuousClock.now

        // One hook invocation is one unit of work: its run id leads every
        // line here and, as the IPC request id, every daemon line it caused.
        let runID = makeTraceID()
        withTrace(runID) {
            run(selection: selection, verbose: verbose, started: started)
        }
        exit(EXIT_SUCCESS)
    }

    private static func run(selection: HelperAgentSelection, verbose: Bool, started: ContinuousClock.Instant) {
        do {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard !input.isEmpty else { throw HelperError.emptyInput }

            // Key names only, never values: the inherited environment carries
            // API keys and tokens. `LUMI_LOG_ENV=1` lifts the line to info so
            // a wrapper app's markers can be diagnosed without --verbose.
            let environment = ProcessInfo.processInfo.environment
            let dumpRequested = environment["LUMI_LOG_ENV"] == "1"
            if verbose || dumpRequested {
                log.log(level: dumpRequested ? .info : .debug, "hook_environment", metadata: .fields([
                    "keys": environment.keys.sorted().joined(separator: ","),
                ]))
            }

            let socketPath = DaemonEndpoint.defaultSocketPath()
            let port = IPCDaemonPort(client: DaemonIPCClient(), socketPath: socketPath)
            let pipeline = HelperIngestPipeline(port: port)
            let report = try pipeline.run(hookData: input, agent: selection)
            for warning in report.warnings {
                log.warning("hook_ingest_warning", metadata: .fields([
                    "session": report.sessionID?.rawValue,
                    "hook": report.hookEventName,
                    "detail": warning,
                ]))
            }
            for note in report.notes {
                log.debug("hook_ingest_note", metadata: .fields([
                    "session": report.sessionID?.rawValue,
                    "hook": report.hookEventName,
                    "detail": note,
                ]))
            }
            log.info("hook_ingested", metadata: .fields([
                "provider": report.provider.rawValue,
                "session": report.sessionID?.rawValue,
                "hook": report.hookEventName,
                "rich": report.richSourcePath,
                "lines": report.richSourceLinesRead,
                "events": report.eventsSent,
                "hook_bytes": input.count,
                "wrapper": report.wrapperKind,
                "wrapper_agent": report.wrapperAgentID,
                "ms": LogClock.milliseconds(since: started),
            ]))
        } catch {
            log.error("hook_ingest_failed", metadata: .fields([
                "agent": selection.rawValue,
                "ms": LogClock.milliseconds(since: started),
                "error": error,
            ]))
        }
    }
}

private enum HelperError: Error {
    case emptyInput
}

/// `HelperDaemonPort` over the daemon's Unix-domain socket.
struct IPCDaemonPort: HelperDaemonPort {
    let client: DaemonIPCClient
    let socketPath: String

    func ingest(_ events: [AgentIngressEvent]) throws {
        // Large replays are chunked so a single frame stays well below the
        // codec's maximum length.
        let chunkSize = 200
        var index = 0
        while index < events.count {
            let chunk = Array(events[index..<min(index + chunkSize, events.count)])
            let response = try client.request(
                IPCRequest(operation: .ingestBatch, events: chunk),
                socketPath: socketPath,
                timeout: .seconds(5)
            )
            guard response.status != .error else {
                throw response.failure ?? IPCFailure(
                    code: "daemon_rejected_batch",
                    message: "The daemon rejected the event batch.",
                    retryable: true
                )
            }
            index += chunkSize
        }
    }

    func rolloutCursor(path: String) throws -> RolloutCursor? {
        let response = try client.request(
            IPCRequest(operation: .getRolloutCursor, path: path),
            socketPath: socketPath,
            timeout: .seconds(1)
        )
        return response.rolloutCursor
    }

    func saveRolloutCursor(_ cursor: RolloutCursor) throws {
        _ = try client.request(
            IPCRequest(operation: .saveRolloutCursor, rolloutCursor: cursor),
            socketPath: socketPath,
            timeout: .seconds(1)
        )
    }

    func session(sessionID: SessionID) throws -> SessionDetail? {
        let response = try client.request(
            IPCRequest(operation: .getSession, sessionID: sessionID, limit: 1),
            socketPath: socketPath,
            timeout: .seconds(1)
        )
        // "Not retained" is a real answer (nil); any other failure is not.
        if let failure = response.failure, failure.code != "session_not_found" {
            throw failure
        }
        return response.session
    }

    func requestBackfill(sessionID: SessionID, path: String) throws {
        let response = try client.request(
            IPCRequest(operation: .backfillSession, sessionID: sessionID, path: path),
            socketPath: socketPath,
            timeout: .seconds(1)
        )
        if let failure = response.failure { throw failure }
    }
}
