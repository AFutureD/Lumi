import Foundation

/// What a subagent counts as in its parent's collapsed count strip (design
/// system L4 §4.4; Notch Screen 2 "subagent 折叠计数条"). The order of the
/// cases is the order of the stacked dots and of the label's buckets:
/// running → waiting → failed → done. Shared by iOS and the Notch so the
/// wording and the dot order stay identical across both.
public enum SubagentSummaryBucket: Int, Hashable, Sendable, CaseIterable, Comparable {
    case running
    case waiting
    case failed
    case done

    public init(tone: SessionStatusTone) {
        switch tone {
        case .blue: self = .running
        case .orange: self = .waiting
        case .red: self = .failed
        case .green, .gray: self = .done
        }
    }

    public static func < (lhs: SubagentSummaryBucket, rhs: SubagentSummaryBucket) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Word printed after the count in the strip label.
    public var labelWord: String {
        switch self {
        case .running: "running"
        case .waiting: "waiting"
        case .failed: "failed"
        case .done: "done"
        }
    }
}

public enum SubagentGroupSummary {
    /// `3 subagents · 2 running · 1 done` — the total, then only the
    /// non-zero buckets in bucket order; `1 subagent` is singular.
    public static func label(tones: [SessionStatusTone]) -> String {
        var counts: [SubagentSummaryBucket: Int] = [:]
        for tone in tones {
            counts[SubagentSummaryBucket(tone: tone), default: 0] += 1
        }
        var parts = ["\(tones.count) subagent\(tones.count == 1 ? "" : "s")"]
        for bucket in SubagentSummaryBucket.allCases {
            if let count = counts[bucket], count > 0 {
                parts.append("\(count) \(bucket.labelWord)")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Sort key for a subagent group: bucket order first, then newest
    /// activity first inside a bucket.
    public static func precedes(
        _ lhs: (tone: SessionStatusTone, lastActivityAt: Date),
        _ rhs: (tone: SessionStatusTone, lastActivityAt: Date)
    ) -> Bool {
        let l = SubagentSummaryBucket(tone: lhs.tone), r = SubagentSummaryBucket(tone: rhs.tone)
        if l != r { return l < r }
        return lhs.lastActivityAt > rhs.lastActivityAt
    }
}
