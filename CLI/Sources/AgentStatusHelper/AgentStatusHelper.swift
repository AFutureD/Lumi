import AgentStatusCodex
import AgentStatusCore
import AgentStatusIPCClient
import AgentStatusTransport
import Darwin
import Foundation
import NIOCore

/// `agent-status-helper [--agent codex|claude|auto] [--verbose]`
///
/// Invoked by Codex / Claude Code hooks with the hook payload on stdin. Reads
/// the session's transcript increment, reduces hook + transcript into
/// Agent-domain events, and ships them to the daemon over the Unix socket.
///
/// Always exits 0: a hook exit code of 2 would block the agent's tool call,
/// and a monitoring failure must never do that. Problems go to stderr.
@main
enum AgentStatusHelperMain {
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

        do {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard !input.isEmpty else { throw HelperError.emptyInput }

            let socketPath = DaemonEndpoint.defaultSocketPath()
            let port = IPCDaemonPort(client: DaemonIPCClient(), socketPath: socketPath)
            let pipeline = HelperIngestPipeline(port: port)
            let report = try pipeline.run(hookData: input, agent: selection)
            for warning in report.warnings {
                log("warning: \(warning)")
            }
            if verbose {
                log("provider=\(report.provider.rawValue) session=\(report.sessionID?.rawValue ?? "-") hook=\(report.hookEventName ?? "-") rich=\(report.richSourcePath ?? "-") lines=\(report.richSourceLinesRead) events=\(report.eventsSent)")
            }
        } catch {
            log("\(error)")
        }
        exit(EXIT_SUCCESS)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("agent-status-helper: \(message)\n".utf8))
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

    func turns(sessionID: SessionID) throws -> [TurnSummary] {
        let response = try client.request(
            IPCRequest(operation: .getSession, sessionID: sessionID, limit: 1),
            socketPath: socketPath,
            timeout: .seconds(1)
        )
        return response.session?.turns ?? []
    }
}
