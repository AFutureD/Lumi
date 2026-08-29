import Core
import Diagnostics
import Logging
import Transport
import Foundation

private let log = Logger(label: "convert")

/// Locates a session's rich source on disk (Claude transcript / Codex rollout).
public enum RichSourceLocator {
    /// `~/.claude/projects/<slug-of-cwd>/<session>.jsonl`, falling back to a
    /// search over every project directory.
    public static func claudeTranscript(for sessionID: SessionID, cwd: String?, homeDirectory: URL) -> String? {
        let projects = homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
        let fileName = "\(sessionID.rawValue).jsonl"
        if let cwd {
            let slug = cwd.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            let candidate = projects.appendingPathComponent(slug).appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        }
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        for directory in directories {
            let candidate = directory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    /// `~/.codex/sessions/YYYY/MM/DD/rollout-<stamp>-<session>.jsonl`. Newest
    /// day directories are searched first; the session id is the file suffix.
    public static func codexRollout(for sessionID: SessionID, sessionsDirectory: URL) -> String? {
        let suffix = "-\(sessionID.rawValue).jsonl"
        let fm = FileManager.default
        guard let years = try? fm.contentsOfDirectory(atPath: sessionsDirectory.path) else { return nil }
        for year in years.sorted(by: >) {
            let yearURL = sessionsDirectory.appendingPathComponent(year, isDirectory: true)
            guard let months = try? fm.contentsOfDirectory(atPath: yearURL.path) else { continue }
            for month in months.sorted(by: >) {
                let monthURL = yearURL.appendingPathComponent(month, isDirectory: true)
                guard let days = try? fm.contentsOfDirectory(atPath: monthURL.path) else { continue }
                for day in days.sorted(by: >) {
                    let dayURL = monthURL.appendingPathComponent(day, isDirectory: true)
                    guard let files = try? fm.contentsOfDirectory(atPath: dayURL.path) else { continue }
                    if let match = files.first(where: { $0.hasSuffix(suffix) }) {
                        return dayURL.appendingPathComponent(match).path
                    }
                }
            }
        }
        return nil
    }
}

public struct RichSourceRead: Sendable {
    public var events: [AgentIngressEvent]
    /// Position after the last complete line consumed; save it once the
    /// daemon has accepted `events`.
    public var cursor: RolloutCursor
    public var lines: Int
    /// Turn left open (or last named) after this read — the seed for hook
    /// events ingested right after the increment.
    public var finalTurnID: TurnID?
}

/// Reads complete JSONL lines of a transcript / rollout from a byte offset and
/// reduces each through the adapter. Shared by the helper (increments) and the
/// daemon (whole-file rebuilds).
public enum RichSourceReader {
    /// - Parameters:
    ///   - offset: where to start; reset to 0 when the file is smaller.
    ///   - initialTurnID: Turn that owns records without their own turn id at
    ///     the start of the read (the session's open Turn for increments).
    ///   - maximumBytes: keep only the tail of larger reads, aligned to a line;
    ///     `nil` reads everything.
    public static func read(
        path: String,
        sessionID: SessionID,
        adapter: any AgentAdapter,
        fromOffset requestedOffset: UInt64,
        initialTurnID: TurnID? = nil,
        maximumBytes: Int? = nil
    ) throws -> RichSourceRead {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        var offset = requestedOffset
        if fileSize < offset { offset = 0 }   // truncated / rewritten
        let unchanged = RolloutCursor(path: path, byteOffset: offset, fileSize: fileSize, sessionID: sessionID)
        guard fileSize > offset else {
            return RichSourceRead(events: [], cursor: unchanged, lines: 0, finalTurnID: initialTurnID)
        }

        var state = RolloutReadState()
        state.currentTurnID = initialTurnID

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var data = try handle.readToEnd() ?? Data()
        if let maximumBytes, data.count > maximumBytes {
            // Keep the tail; skip to the first newline so we start on a line.
            // The new offset is absolute — `fileSize - data.count` already
            // includes the original start, so assigning (not adding) is what
            // keeps a capped read from a nonzero cursor in bounds.
            data = Data(data.suffix(maximumBytes))
            if let newline = data.firstIndex(of: 0x0A) {
                let skipped = data.distance(from: data.startIndex, to: newline) + 1
                offset = UInt64(fileSize) - UInt64(data.count) + UInt64(skipped)
                data = Data(data[data.index(after: newline)...])
            }
        }
        // A record ahead of every timestamped one in this window (a
        // resume's `custom-title` / `bridge-session` control records, which
        // carry no `timestamp` field of their own) has nothing earlier to
        // inherit from. Seed the earliest real timestamp found anywhere in
        // the window rather than leaving the per-line carry-forward to fall
        // back to wall-clock `Date()` — records here are not necessarily in
        // strict timestamp order (a queued-prompt record can be logged
        // ahead of the session-start hook it followed), so the minimum,
        // not the first occurrence, is the only safe floor.
        state.lastTimestamp = earliestTimestamp(in: data)

        var events: [AgentIngressEvent] = []
        var lines = 0
        var rejectedLines = 0
        var lineStart = data.startIndex
        var consumed = 0
        while let newline = data[lineStart...].firstIndex(of: 0x0A) {
            if newline > lineStart {
                let line = Data(data[lineStart..<newline])
                let context = RolloutRecordContext(
                    path: path,
                    byteOffset: offset + UInt64(consumed),
                    sessionID: sessionID
                )
                do {
                    events.append(contentsOf: try adapter.events(fromRolloutLine: line, context: context, state: &state))
                } catch {
                    // One bad record must not lose the rest of the read; it
                    // is logged (position only, never the record) and skipped.
                    rejectedLines += 1
                    log.warning("rich_source_line_rejected", metadata: .fields([
                        "session": sessionID.rawValue,
                        "path": path,
                        "offset": context.byteOffset,
                        "bytes": line.count,
                        "error": error,
                    ]))
                }
                lines += 1
            }
            let next = data.index(after: newline)
            consumed += data.distance(from: lineStart, to: next)
            lineStart = next
            if lineStart == data.endIndex { break }
        }

        log.debug("rich_source_read", metadata: .fields([
            "session": sessionID.rawValue,
            "path": path,
            "from": offset,
            "to": offset + UInt64(consumed),
            "lines": lines,
            "rejected": rejectedLines,
            "events": events.count,
        ]))
        return RichSourceRead(
            events: events,
            cursor: RolloutCursor(
                path: path,
                byteOffset: offset + UInt64(consumed),
                fileSize: fileSize,
                sessionID: sessionID
            ),
            lines: lines,
            finalTurnID: state.currentTurnID
        )
    }

    /// Earliest `"timestamp":"…"` value found anywhere in `data`, scanning
    /// raw bytes rather than parsing every line as JSON.
    private static func earliestTimestamp(in data: Data) -> Date? {
        let needle = Data("\"timestamp\":\"".utf8)
        var searchStart = data.startIndex
        var earliest: Date?
        while let range = data.range(of: needle, in: searchStart..<data.endIndex) {
            let valueStart = range.upperBound
            guard let quoteEnd = data[valueStart...].firstIndex(of: 0x22) else { break }
            if let value = String(data: data[valueStart..<quoteEnd], encoding: .utf8),
               let date = AdapterDates.parse(value), earliest.map({ date < $0 }) ?? true {
                earliest = date
            }
            searchStart = quoteEnd
        }
        return earliest
    }
}
