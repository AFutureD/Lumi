import AgentStatusCore
import AgentStatusTransport
import Foundation

// Display names, relative / elapsed time and the detail presentation are
// shared with the Mac in `AgentStatusCore/SessionPresentation.swift`. Only
// the iPhone-specific shapes live here.

/// Subagent chip duration: at most two digits plus a unit, rounded down
/// (`2m 41s` → `2m`).
enum CompactDurationText {
    static func string(from interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval).rounded(.down))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }
}

enum TextShaping {
    /// First non-empty line, trimmed.
    static func firstLine(_ value: String) -> String {
        value.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? value
    }
}
