import IPCClient
import Diagnostics
import Logging
import Transport
import Darwin
import Foundation

private let log = Logger(label: "agent")

/// `Spark --agent codex|claude [--verbose]`
///
/// Invoked by Codex / Claude Code hooks with the hook payload on stdin.
/// Captures the invocation — the raw stdin bytes, the agent kind, and a
/// whitelisted environment subset — and forwards it to the daemon in one
/// `ingest_hook` frame. All parsing and domain reduction happen in the
/// daemon; the helper never looks inside the payload.
///
/// Always exits 0: a hook exit code of 2 would block the agent's tool call,
/// and a monitoring failure must never do that. Problems go to stderr and to
/// `helper.log`; `--verbose` mirrors every line (debug included) to stderr.
/// `SPARK_LOG_LEVEL` sets the helper's log level (over `LUMI_LOG_LEVEL`);
/// `SPARK_DEBUG_ENV_VALUE=1|true` additionally logs the full inherited
/// environment with values — local log only, never the frame.
@main
enum SparkMain {
    /// The only environment keys that cross the socket. The full inherited
    /// environment carries API keys and tokens and must never be forwarded.
    static let environmentWhitelist = [
        "PASEO_AGENT_ID", "PASEO_HOME",
        "SLOCK_AGENT_ID", "SLOCK_CLI_TRANSPORT_DIR", "SLOCK_HOME",
        "CLAUDE_PROJECT_DIR", "CODEX_HOME",
        // AaaS-layer detection: the hosting app and terminal. None of these
        // carry secrets.
        "TERM_PROGRAM", "__CFBundleIdentifier", "CLAUDE_CODE_ENTRYPOINT",
    ]

    /// The frame budget derives from the codec's real limit: `data` inflates
    /// by 4/3 as base64 inside the JSON envelope, and 64 KiB of headroom
    /// covers every other field. A payload that cannot fit is abandoned —
    /// the rollout/transcript watchers self-heal the content side; only that
    /// one hook's low-latency signal is lost.
    static let maximumDataBytes = (LengthPrefixedFrameCodec.maximumFrameLength - 64 * 1024) * 3 / 4
    /// Cap for the JSON rendering in the local `hook_frame` log line — the
    /// rendering never enters the frame.
    static let maximumLoggedJSONBytes = 4 * 1024 * 1024

    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        var agent: AgentProvider?
        var verbose = false
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--agent":
                if let value = iterator.next() {
                    agent = AgentProvider(rawValue: value)
                }
            case "--verbose", "-v":
                verbose = true
            default:
                if argument.hasPrefix("--agent=") {
                    agent = AgentProvider(rawValue: String(argument.dropFirst("--agent=".count)))
                }
            }
        }

        var configuration = LogConfiguration.fromEnvironment(
            subsystem: "helper",
            standardErrorPrefix: "Spark:",
            standardErrorMinimumLevel: verbose ? .debug : .warning
        )
        // `SPARK_LOG_LEVEL` overrides `LUMI_LOG_LEVEL` for the helper alone;
        // `--verbose` still wins over both.
        if let level = ProcessInfo.processInfo.environment["SPARK_LOG_LEVEL"]
            .flatMap(Logger.Level.init(lenient:)) {
            configuration.minimumLevel = level
        }
        if verbose { configuration.minimumLevel = .debug }
        Diagnostics.bootstrap(configuration)
        let started = ContinuousClock.now

        // One hook invocation is one unit of work: its run id leads every
        // line here and, as the IPC request id, every daemon line it caused.
        let runID = makeTraceID()
        withTrace(runID) {
            run(agent: agent, started: started)
        }
        exit(EXIT_SUCCESS)
    }

    private static func run(agent: AgentProvider?, started: ContinuousClock.Instant) {
        guard let agent else {
            log.error("hook_agent_missing", metadata: .fields([
                "detail": "Spark needs --agent codex|claude; the installers always pass it.",
            ]))
            return
        }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard !input.isEmpty else {
            log.error("hook_input_empty", metadata: .fields(["agent": agent.rawValue]))
            return
        }
        guard input.count <= maximumDataBytes else {
            log.warning("hook_frame_oversized", metadata: .fields([
                "agent": agent.rawValue,
                "hook_bytes": input.count,
            ]))
            return
        }

        let environment = ProcessInfo.processInfo.environment
        let env = environmentWhitelist.reduce(into: [String: String]()) { result, key in
            if let value = environment[key] { result[key] = value }
        }
        // The whitelisted subset never carries secrets: always log it at
        // info, key and value. The full inherited environment does carry API
        // keys and tokens, so it renders only behind
        // `SPARK_DEBUG_ENV_VALUE=1|true` — local log only, the frame still
        // ships nothing beyond the whitelist.
        log.info("hook_environment", metadata: .fields([
            "env": env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }.joined(separator: ","),
        ]))
        if ["1", "true"].contains(environment["SPARK_DEBUG_ENV_VALUE"]?.lowercased() ?? "") {
            log.info("hook_environment_values", metadata: .fields([
                "env": environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }.joined(separator: ","),
            ]))
        }
        let json = input.count <= maximumLoggedJSONBytes ? jsonText(input) : nil
        let createdAt = Date()
        let request = IPCRequest(
            operation: .ingestHook,
            createdAt: createdAt,
            agent: agent,
            env: env,
            data: input
        )

        // The whole frame, with the raw bytes rendered as JSON (log only —
        // the frame ships the bytes once): what went to the daemon,
        // reviewable without replaying it.
        log.info("hook_frame", metadata: .fields([
            "created_at": createdAt.formatted(.iso8601.year().month().day()
                .timeZone(separator: .omitted).time(includingFractionalSeconds: true)),
            "agent": agent.rawValue,
            "env": env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }.joined(separator: ","),
            "json": json,
        ]))

        do {
            let response = try DaemonIPCClient().request(
                request,
                socketPath: DaemonEndpoint.defaultSocketPath(),
                timeout: .seconds(2)
            )
            if let failure = response.failure {
                log.error("hook_forward_rejected", metadata: .fields([
                    "agent": agent.rawValue,
                    "code": failure.code,
                    "detail": failure.message,
                    "ms": LogClock.milliseconds(since: started),
                ]))
                return
            }
            log.info("hook_forwarded", metadata: .fields([
                "agent": agent.rawValue,
                "hook_bytes": input.count,
                "events": response.acceptedCount,
                "ms": LogClock.milliseconds(since: started),
            ]))
        } catch {
            // A timeout is not a loss: the daemon finishes the work on its
            // own once the frame arrived; the response is only advisory.
            log.error("hook_forward_failed", metadata: .fields([
                "agent": agent.rawValue,
                "hook_bytes": input.count,
                "ms": LogClock.milliseconds(since: started),
                "error": error,
            ]))
        }
    }

    /// One-line JSON rendering of the payload for the frame log (sorted
    /// keys, compact — greppable); `nil` when stdin is not valid JSON.
    private static func jsonText(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ) else { return nil }
        return String(data: pretty, encoding: .utf8)
    }
}
