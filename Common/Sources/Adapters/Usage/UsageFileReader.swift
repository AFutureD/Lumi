import Core
import Diagnostics
import Logging
import Transport
import Foundation

private let log = Logger(label: "convert")

public struct UsageFileRead: Sendable {
    public var records: [UsageRecord]
    /// Position after the last complete line consumed.
    public var byteOffset: UInt64
    public var fileSize: UInt64
    public var state: UsageScanState
    public var lines: Int
    public var rejectedLines: Int
}

/// Reads the complete JSONL lines of one transcript / rollout from a byte
/// offset and reduces each through `UsageTranscriptParser`. A file smaller
/// than the offset was rewritten: the read restarts at 0 with fresh state
/// (the store's dedupe keys keep the re-read from double counting).
public enum UsageFileReader {
    public static func read(
        path: String,
        source: AgentProvider,
        fromOffset requestedOffset: UInt64,
        state initialState: UsageScanState
    ) throws -> UsageFileRead {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        var offset = requestedOffset
        var state = initialState
        if fileSize < offset {
            log.warning("usage_file_rewritten", metadata: .fields([
                "path": path, "offset": offset, "size": fileSize,
            ]))
            offset = 0
            state = UsageScanState()
        }
        guard fileSize > offset else {
            return UsageFileRead(records: [], byteOffset: offset, fileSize: fileSize, state: state, lines: 0, rejectedLines: 0)
        }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()

        var records: [UsageRecord] = []
        // Claude repeats one message's usage on every content block, always
        // adjacent: dropping repeats here keeps the store's write small. The
        // store still checks its own seen-keys — a message can straddle two
        // incremental reads, and history gets copied across files.
        var seenKeys = Set<String>()
        var lines = 0
        var rejected = 0
        var lineStart = data.startIndex
        var consumed = 0
        while let newline = data[lineStart...].firstIndex(of: 0x0A) {
            if newline > lineStart {
                let line = data[lineStart..<newline]
                if UsageTranscriptParser.mightMatter(line, source: source) {
                    do {
                        for record in try UsageTranscriptParser.parse(line: Data(line), source: source, state: &state)
                            where seenKeys.insert(record.dedupeKey).inserted {
                            records.append(record)
                        }
                    } catch {
                        // One bad record must not lose the rest of the file;
                        // position only, never the record.
                        rejected += 1
                        log.warning("usage_line_rejected", metadata: .fields([
                            "path": path,
                            "offset": offset + UInt64(consumed),
                            "bytes": line.count,
                            "error": error,
                        ]))
                    }
                }
                lines += 1
            }
            let next = data.index(after: newline)
            consumed += data.distance(from: lineStart, to: next)
            lineStart = next
            if lineStart == data.endIndex { break }
        }
        // A Codex call still waiting for its context at the end of the read
        // goes out as it is: the hold spans one read, never the file's life —
        // a finished rollout must not keep its last call out of the totals.
        if let pending = state.codexPending {
            state.codexPending = nil
            if seenKeys.insert(pending.dedupeKey).inserted { records.append(pending) }
        }
        return UsageFileRead(
            records: records,
            byteOffset: offset + UInt64(consumed),
            fileSize: fileSize,
            state: state,
            lines: lines,
            rejectedLines: rejected
        )
    }
}
