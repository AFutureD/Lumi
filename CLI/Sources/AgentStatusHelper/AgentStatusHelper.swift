import AgentStatusCodex
import AgentStatusIPCClient
import AgentStatusTransport
import Darwin
import Foundation

@main
enum AgentStatusHelperMain {
    static func main() {
        do {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard !input.isEmpty else {
                throw HelperError.emptyInput
            }
            let events = try CodexAdapter().events(fromHookData: input)
            let socketPath = DaemonEndpoint.defaultSocketPath()
            let client = DaemonIPCClient()

            for event in events {
                let response = try client.request(
                    IPCRequest(operation: .ingest, event: event),
                    socketPath: socketPath,
                    timeout: .seconds(1)
                )
                guard response.status != .error else {
                    throw response.failure ?? IPCFailure(
                        code: "daemon_rejected_event",
                        message: "The daemon rejected the event.",
                        retryable: true
                    )
                }
            }
        } catch {
            FileHandle.standardError.write(Data("agent-status-helper: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}

private enum HelperError: Error {
    case emptyInput
}
