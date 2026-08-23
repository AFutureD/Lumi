import Foundation
import Logging
import Testing
@testable import Diagnostics

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("lumi-log-\(UUID().uuidString)", isDirectory: true)
}

private func lines(of url: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
}

/// A `Logger` bound to our handler without touching the process-wide bootstrap.
private func makeLogger(category: String, _ configuration: LogConfiguration) -> Logger {
    Logger(label: category) { label in Diagnostics.makeHandler(category: label, configuration: configuration) }
}

@Test func messageRendersTextThenSortedFieldsWithErrorLastAndTraceFirst() {
    let message = LogRendering.message("ipc_request", metadata: .fields([
        "op": "list_sessions", "bytes": 512, "skipped": nil, "path": "/tmp/a b", "ok": true, "ms": 12.34,
        "error": "socket closed", "trace": "req-42",
    ]))
    #expect(message == #"['trace':req-42] ipc_request bytes=512 ms=12.3 ok=true op=list_sessions path="/tmp/a b" error="socket closed""#)
    #expect(LogRendering.message("tick", metadata: [:]) == "tick")
    #expect(LogRendering.message("tick", metadata: ["trace": ""]) == "tick")
}

@Test func lineWrapsEveryColumnInBrackets() {
    let line = LogRendering.line(
        timestamp: Date(timeIntervalSince1970: 0), level: .warning, subsystem: "daemon", category: "ipc", message: "x a=1"
    )
    #expect(line == "[1970-01-01T00:00:00.000Z] [WARN:daemon] [ipc] x a=1")
}

@Test func valuesWithQuotesNewlinesOrEqualsAreQuotedAndEscaped() {
    #expect(LogRendering.renderValue("a=b", quoted: true) == #""a=b""#)
    #expect(LogRendering.renderValue("say \"hi\"\nnow", quoted: true) == #""say \"hi\"\nnow""#)
    #expect(LogRendering.renderValue("", quoted: true) == #""""#)
    #expect(LogRendering.renderValue(URL(fileURLWithPath: "/tmp/x.log"), quoted: true) == "/tmp/x.log")
    #expect(LogRendering.renderValue(Date(timeIntervalSince1970: 0), quoted: true) == "1970-01-01T00:00:00.000Z")
}

@Test func handlerDropsLinesBelowTheLevelAndCopiesErrorsToErrorsLog() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = LogConfiguration(subsystem: "daemon", minimumLevel: .info, directory: directory)
    let agent = makeLogger(category: "agent", configuration)
    let db = makeLogger(category: "db", configuration)
    agent.debug("dropped")
    agent.info("events_ingested", metadata: .fields(["count": 3]))
    db.error("apply_failed", metadata: .fields(["session": "s1", "error": NSError(domain: "test", code: 7)]))

    let processLines = try lines(of: directory.appendingPathComponent("daemon.log"))
    #expect(processLines.count == 2)
    #expect(processLines[0].hasSuffix("] [INFO:daemon] [agent] events_ingested count=3"))
    #expect(processLines[0].hasPrefix("[20"))
    #expect(processLines[1].contains("] [ERROR:daemon] [db] apply_failed session=s1 error="))

    let errorLines = try lines(of: directory.appendingPathComponent(LogSinks.errorsFileName))
    #expect(errorLines == [processLines[1]])

    let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("daemon.log").path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func traceFromTheTaskContextLeadsEveryLineInsideWithTrace() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = makeLogger(category: "ipc", LogConfiguration(subsystem: "daemon", minimumLevel: .debug, directory: directory))
    await withTrace("req-8f3a") {
        log.info("ipc_handled", metadata: .fields(["op": "health"]))
        await Task { log.debug("nested") }.value
    }
    log.info("outside")
    log.info("explicit", metadata: ["trace": "manual"])
    let written = try lines(of: directory.appendingPathComponent("daemon.log"))
    #expect(written.count == 4)
    #expect(written[0].hasSuffix("[ipc] ['trace':req-8f3a] ipc_handled op=health"))
    #expect(written[1].hasSuffix("[ipc] ['trace':req-8f3a] nested"))
    #expect(written[2].hasSuffix("[ipc] outside"))
    #expect(written[3].hasSuffix("[ipc] ['trace':manual] explicit"))
    #expect(currentTraceID == nil)
    #expect(makeTraceID().count == 8)
}

@Test func fileRotatesPastTheSizeLimitAndKeepsTheConfiguredGenerations() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = makeLogger(category: "lifecycle", LogConfiguration(
        subsystem: "app", minimumLevel: .debug, directory: directory, maximumFileBytes: 200, retainedRotations: 2
    ))
    for index in 0..<40 {
        log.info("tick", metadata: .fields(["index": index, "padding": String(repeating: "x", count: 40)]))
    }
    let manager = FileManager.default
    let live = directory.appendingPathComponent("app.log")
    #expect(manager.fileExists(atPath: live.path + ".1"))
    #expect(manager.fileExists(atPath: live.path + ".2"))
    #expect(!manager.fileExists(atPath: live.path + ".3"))
    let all = try (lines(of: live) + lines(of: URL(fileURLWithPath: live.path + ".1")) + lines(of: URL(fileURLWithPath: live.path + ".2")))
    #expect(all.allSatisfy { $0.contains("[lifecycle] tick index=") })
    #expect(try lines(of: live).last?.contains("index=39") == true)
}

@Test func configurationReadsLevelAndDirectoryFromTheEnvironment() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    let defaults = LogConfiguration.fromEnvironment(subsystem: "daemon", environment: [:], homeDirectory: home)
    #expect(defaults.minimumLevel == .info)
    #expect(defaults.directory?.path == "/Users/example/Library/Logs/Lumi")

    let tuned = LogConfiguration.fromEnvironment(
        subsystem: "daemon",
        environment: ["LUMI_LOG_LEVEL": "Debug", "LUMI_LOG_DIRECTORY": "/tmp/smoke"],
        homeDirectory: home
    )
    #expect(tuned.minimumLevel == .debug)
    #expect(tuned.directory?.path == "/tmp/smoke")

    let off = LogConfiguration.fromEnvironment(
        subsystem: "helper",
        environment: ["LUMI_LOG_LEVEL": "nonsense", "LUMI_LOG_DIRECTORY": "off"],
        homeDirectory: home
    )
    #expect(off.minimumLevel == .info)
    #expect(off.directory == nil)
}

@Test func levelNamesParseLeniently() {
    #expect(Logger.Level(lenient: "WARN") == .warning)
    #expect(Logger.Level(lenient: "warning") == .warning)
    #expect(Logger.Level(lenient: " error ") == .error)
    #expect(Logger.Level(lenient: "verbose") == .trace)
    #expect(Logger.Level(lenient: "loud") == nil)
    #expect(Logger.Level.error.label == "ERROR")
}

@Test func millisecondsSinceCountsWholeMilliseconds() {
    let start = ContinuousClock.now
    let later = start.advanced(by: .milliseconds(1_250))
    #expect(LogClock.milliseconds(since: start, now: later) == 1_250)
}
