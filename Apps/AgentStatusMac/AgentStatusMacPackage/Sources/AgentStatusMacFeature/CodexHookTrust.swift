import Foundation

/// Codex 0.148 refuses to run a `hooks.json` handler unless `~/.codex/config.toml`
/// holds a matching trust record:
///
/// ```toml
/// [hooks.state."/Users/me/.codex/hooks.json:pre_tool_use:0:0"]
/// trusted_hash = "sha256:…"
/// ```
///
/// The key is *positional*, so writing `hooks.json` — ours or another tool's —
/// invalidates the records of every handler that shifted. Codex then drops the
/// hooks silently: no stderr, nothing in its logs, only a "hooks are new or
/// changed" review the user has to find. Ingest stops without a single symptom.
///
/// So the app authorizes its own handlers through Codex's app-server the same
/// way Codex's own `/hooks` review does: `hooks/list` reports each handler's
/// `key` / `currentHash` / `trustStatus`, and `config/batchWrite` writes the
/// hash back as `trusted_hash`. Only handlers whose command is our helper are
/// ever touched.

// MARK: - App-server transport

public enum CodexAppServerError: Error, Sendable {
    case executableNotFound
    case launchFailed(String)
    case timedOut(method: String)
    case rpc(code: Int, message: String)
    case malformedResponse(method: String)
}

/// One JSON-RPC round trip against `codex app-server`. `params` and the return
/// value are JSON payloads; an `error` reply is thrown, never returned.
public protocol CodexAppServerTransport: Sendable {
    func send(method: String, params: Data) throws -> Data
    /// Releases whatever backs the transport. Idempotent.
    func close()
}

public extension CodexAppServerTransport {
    func close() {}
}

/// Talks to a `codex app-server` child process over line-delimited JSON-RPC on
/// stdio. The process is launched — and `initialize` sent — on the first
/// request, and torn down by `close()` or deinit.
public final class CodexAppServerProcessTransport: CodexAppServerTransport, @unchecked Sendable {
    public let executableURL: URL
    public let timeout: TimeInterval

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let condition = NSCondition()
    private var pending: [Int: [String: Any]] = [:]
    private var buffer = Data()
    private var nextID = 0
    private var started = false
    private var closed = false

    public init(executableURL: URL, timeout: TimeInterval = 15) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    /// Fails with `.executableNotFound` when no Codex CLI is installed.
    public convenience init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        timeout: TimeInterval = 15
    ) throws {
        guard let url = Self.locateExecutable(environment: environment, homeDirectory: homeDirectory) else {
            throw CodexAppServerError.executableNotFound
        }
        self.init(executableURL: url, timeout: timeout)
    }

    /// The Desktop app ships its own Codex build and is usually newer than any
    /// standalone CLI, so it wins; `CODEX_CLI_PATH` (which Codex itself exports)
    /// overrides both.
    public static func locateExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let candidates: [URL] = [
            environment["AGENT_STATUS_CODEX_CLI"],
            environment["CODEX_CLI_PATH"],
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            homeDirectory.appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        .compactMap { $0 }
        .map { URL(fileURLWithPath: $0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    deinit { close() }

    public func close() {
        condition.lock()
        let wasRunning = started && !closed
        closed = true
        condition.unlock()
        guard wasRunning else { return }
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    public func send(method: String, params: Data) throws -> Data {
        try startIfNeeded()
        return try request(method: method, params: params)
    }

    private func startIfNeeded() throws {
        condition.lock()
        let alreadyStarted = started
        let isClosed = closed
        started = true
        condition.unlock()
        // A closed transport stays closed; `Process` cannot be run twice.
        if isClosed { throw CodexAppServerError.launchFailed("transport is closed") }
        guard !alreadyStarted else { return }

        process.executableURL = executableURL
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        // Codex logs to stderr; keep it off the app's own log.
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.ingest(handle.availableData)
        }
        do {
            try process.run()
        } catch {
            condition.lock()
            started = false
            condition.unlock()
            throw CodexAppServerError.launchFailed(String(describing: error))
        }
        _ = try request(
            method: "initialize",
            params: try JSONSerialization.data(withJSONObject: [
                "clientInfo": [
                    "name": "agent-status",
                    "title": "Agent Status",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                ],
            ])
        )
    }

    private func request(method: String, params: Data) throws -> Data {
        condition.lock()
        nextID += 1
        let id = nextID
        condition.unlock()

        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": try JSONSerialization.jsonObject(with: params, options: [.fragmentsAllowed]),
        ]
        var line = try JSONSerialization.data(withJSONObject: envelope)
        line.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: line)

        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        while pending[id] == nil {
            guard condition.wait(until: deadline) else {
                condition.unlock()
                throw CodexAppServerError.timedOut(method: method)
            }
        }
        let response = pending.removeValue(forKey: id)
        condition.unlock()

        guard let response else { throw CodexAppServerError.malformedResponse(method: method) }
        if let failure = response["error"] as? [String: Any] {
            throw CodexAppServerError.rpc(
                code: failure["code"] as? Int ?? 0,
                message: failure["message"] as? String ?? "unknown error"
            )
        }
        guard let result = response["result"] else {
            throw CodexAppServerError.malformedResponse(method: method)
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
    }

    /// Accumulates stdout and hands every complete line that carries a request
    /// id to the waiting caller. Notifications have no id and are dropped.
    private func ingest(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        condition.lock()
        defer { condition.unlock() }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = object["id"] as? Int else { continue }
            pending[id] = object
        }
        condition.broadcast()
    }
}

// MARK: - Trust state

/// What Codex thinks of the Agent Status handlers in `hooks.json`.
public enum CodexHookTrustState: Equatable, Sendable {
    /// No Codex CLI, or a build with no hook-trust gate — nothing to authorize.
    case unsupported
    /// Codex sees no Agent Status handler; the integration is not installed.
    case noHooks
    case trusted(Int)
    /// Handlers Codex still refuses to run. The user has to finish this in
    /// Codex's own `/hooks` review.
    case untrusted([String])
    case failed(String)

    public var needsAttention: Bool {
        switch self {
        case .untrusted, .failed: true
        case .unsupported, .noHooks, .trusted: false
        }
    }
}

// MARK: - Authorizer

/// Reads Codex's view of our handlers and writes back the trust records they
/// are missing. Never throws — a Codex that cannot be reached is reported, not
/// escalated, because hook trust is a repair path and must never block install.
public struct CodexHookTrustAuthorizer: Sendable {
    public typealias TransportFactory = @Sendable () throws -> any CodexAppServerTransport

    /// Handlers are ours when their command invokes this binary.
    public static let helperMarker = "agent-status-helper"

    private let makeTransport: TransportFactory

    public init(makeTransport: @escaping TransportFactory = { try CodexAppServerProcessTransport() }) {
        self.makeTransport = makeTransport
    }

    /// Read-only: reports the current state without writing anything.
    public func probe() -> CodexHookTrustState {
        do {
            let transport = try makeTransport()
            defer { transport.close() }
            return Self.state(of: try Self.list(transport))
        } catch {
            return Self.describe(error)
        }
    }

    /// Lists, writes `trusted_hash` for every untrusted handler of ours, then
    /// lists again so the returned state is what Codex will actually enforce —
    /// a rejected write shows up as the handlers Codex still refuses, which is
    /// the state the user has to act on either way.
    @discardableResult
    public func authorize() -> CodexHookTrustState {
        let transport: any CodexAppServerTransport
        let ours: [CodexHookEntry]
        do {
            transport = try makeTransport()
            ours = try Self.list(transport)
        } catch {
            return Self.describe(error)
        }
        defer { transport.close() }

        guard !ours.isEmpty else { return .noHooks }
        let edits = ours.filter { !$0.isTrusted }.compactMap(\.trustEdit)
        guard !edits.isEmpty else { return .trusted(ours.count) }

        do {
            _ = try transport.send(
                method: "config/batchWrite",
                params: try JSONSerialization.data(withJSONObject: ["edits": edits])
            )
            return Self.state(of: try Self.list(transport))
        } catch {
            return .untrusted(ours.filter { !$0.isTrusted }.map(\.key))
        }
    }

    // MARK: Steps

    private static func list(_ transport: any CodexAppServerTransport) throws -> [CodexHookEntry] {
        let result = try transport.send(method: "hooks/list", params: Data("{}".utf8))
        let response = try JSONDecoder().decode(CodexHooksListResponse.self, from: result)
        // `hooks/list` groups by cwd; the same user-level handler is repeated
        // in every group, so keys are deduplicated.
        var seen: Set<String> = []
        return response.data
            .flatMap(\.hooks)
            .filter { $0.command?.contains(helperMarker) == true }
            .filter { seen.insert($0.key).inserted }
    }

    private static func state(of ours: [CodexHookEntry]) -> CodexHookTrustState {
        guard !ours.isEmpty else { return .noHooks }
        let untrusted = ours.filter { !$0.isTrusted }.map(\.key)
        return untrusted.isEmpty ? .trusted(ours.count) : .untrusted(untrusted)
    }

    /// A Codex that cannot be launched, or one whose app-server rejects
    /// `hooks/list`, predates the trust gate — there is nothing to authorize
    /// and nothing to warn about. Only reached for the opening list; a
    /// rejected *write* is reported, never swallowed.
    private static func describe(_ error: Error) -> CodexHookTrustState {
        switch error {
        case CodexAppServerError.executableNotFound,
             CodexAppServerError.launchFailed,
             CodexAppServerError.rpc:
            .unsupported
        default:
            .failed(String(describing: error))
        }
    }
}

// MARK: - Wire types

struct CodexHooksListResponse: Decodable {
    struct Group: Decodable {
        var hooks: [CodexHookEntry] = []
    }

    var data: [Group] = []
}

struct CodexHookEntry: Decodable {
    var key: String
    var command: String?
    var currentHash: String?
    /// `trusted` · `untrusted` · `managed` (enforced by policy, not by us).
    var trustStatus: String?

    var isTrusted: Bool { trustStatus == "trusted" || trustStatus == "managed" }

    /// The `config/batchWrite` edit that trusts this handler as it stands now.
    var trustEdit: [String: String]? {
        guard let currentHash else { return nil }
        return [
            "keyPath": "hooks.state.\(Self.tomlQuoted(key)).trusted_hash",
            "value": currentHash,
            "mergeStrategy": "replace",
        ]
    }

    /// Hook keys are `<hooks.json path>:<event>:<group>:<index>` — full of dots
    /// and slashes, so the path segment has to be a quoted TOML key.
    static func tomlQuoted(_ key: String) -> String {
        let escaped = key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
