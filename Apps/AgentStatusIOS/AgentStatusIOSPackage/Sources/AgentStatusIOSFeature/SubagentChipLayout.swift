import AgentStatusDesignSystem
import Foundation

/// One chip's slot on a line: its index in the input and the width cap the
/// pairing rule imposes (`nil` = natural width).
struct SubagentChipPlacement: Equatable, Sendable {
    let index: Int
    let maxWidth: Double?
}

/// L4 §4.4 — Session-row subagent chip pairing.
///
/// Chips keep their natural width (never stretched). Scanning pairs: if the
/// narrower of two chips is under ½ of the available width they share a line,
/// the wider one capped at ⅔ of the available width and at whatever the
/// narrow one leaves (the name ellipsizes, the duration never does). A chip
/// that cannot pair takes a line of its own at up to the full width.
enum SubagentChipLayout {
    static func lines(
        widths: [Double],
        availableWidth: Double,
        gap: Double = IOSDS.SubagentChip.gap,
        pairThreshold: Double = IOSDS.SubagentChip.pairThreshold,
        widerCap: Double = IOSDS.SubagentChip.widerCap
    ) -> [[SubagentChipPlacement]] {
        var lines: [[SubagentChipPlacement]] = []
        var index = 0
        while index < widths.count {
            let first = widths[index]
            if index + 1 < widths.count {
                let second = widths[index + 1]
                let narrow = min(first, second)
                if narrow < availableWidth * pairThreshold {
                    let widerIsFirst = first >= second
                    let cap = min(availableWidth * widerCap, availableWidth - narrow - gap)
                    lines.append([
                        SubagentChipPlacement(index: index, maxWidth: widerIsFirst ? cap : nil),
                        SubagentChipPlacement(index: index + 1, maxWidth: widerIsFirst ? nil : cap),
                    ])
                    index += 2
                    continue
                }
            }
            lines.append([SubagentChipPlacement(index: index, maxWidth: availableWidth)])
            index += 1
        }
        return lines
    }
}
