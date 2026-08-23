import Core
import DesignSystem
import Transport
import Foundation

// Session detail: the shared page presentation (metrics, Info groups,
// Activity rows — `Core`) plus the iPhone header and the Activity
// detail sheet. Pure; built from one `SessionDetail`.

struct SessionHeaderPresentation: Equatable, Sendable {
    /// `Running · Responding` — display lifecycle · phase, as on the Mac.
    let statusText: String
    let tone: SessionStatusTone
    /// `Codex` / `Claude`.
    let agentName: String
    /// `~/dev/lumi`, or nil when the session has no workspace.
    let workspace: String?
}

struct SessionDetailPresentation: Equatable, Sendable {
    let page: SessionPagePresentation
    let header: SessionHeaderPresentation

    var sessionID: SessionID { page.sessionID }
    var title: String { page.title }
    var metrics: SessionMetricsPresentation { page.metrics }
    var sections: [SessionSummarySectionPresentation] { page.summarySections }
    var activities: [SessionActivityPresentation] { page.activities }
}

enum SessionDetailPresentationBuilder {
    static func make(detail: SessionDetail) -> SessionDetailPresentation {
        let summary = detail.summary
        let row = SessionListRowPresentation(session: summary)
        return SessionDetailPresentation(
            page: SessionPagePresentationBuilder.presentation(for: detail),
            header: SessionHeaderPresentation(
                statusText: row.status,
                tone: row.tone,
                agentName: summary.agent.providerName,
                workspace: SessionPagePresentationBuilder.abbreviatedWorkspace(summary.workspace)
            )
        )
    }
}

// MARK: - Activity detail sheet

struct ActivityDetailSection: Hashable, Sendable {
    let title: String
    let text: String
    let isMonospaced: Bool
}

struct ActivityDetailPresentation: Equatable, Sendable {
    let tag: TimelineTag
    let label: String
    let title: String
    let sections: [ActivityDetailSection]
    let isFailed: Bool
}

enum ActivityDetailPresentationBuilder {
    /// A tool call and its result are paired by `toolUseID` into Command +
    /// Output; everything else shows its own text under a category heading.
    static func make(for activity: SessionActivityPresentation, in activities: [SessionActivityPresentation]) -> ActivityDetailPresentation {
        let row = activity.row
        let title = TextShaping.firstLine(row.text)
        var sections: [ActivityDetailSection] = []

        if let toolUseID = row.toolUseID {
            let paired = activities.map(\.row).filter { $0.toolUseID == toolUseID }
            let call = paired.first { $0.tag == .tool } ?? (row.tag == .tool ? row : nil)
            let result = paired.first { $0.tag == .result || $0.tag == .failed }
            if let call {
                sections.append(ActivityDetailSection(title: "Command", text: call.text, isMonospaced: true))
            }
            if let result {
                sections.append(ActivityDetailSection(title: "Output", text: result.text, isMonospaced: true))
            } else if call != nil {
                sections.append(ActivityDetailSection(title: "Output", text: "Still running…", isMonospaced: true))
            }
        } else {
            switch row.tag {
            case .user, .assistant:
                sections.append(ActivityDetailSection(title: "Message", text: row.text, isMonospaced: false))
            case .reasoning:
                sections.append(ActivityDetailSection(title: "Reasoning", text: row.text, isMonospaced: false))
            case .plan:
                sections.append(ActivityDetailSection(title: "Plan", text: planText(row), isMonospaced: false))
            case .subagent:
                sections.append(ActivityDetailSection(title: "Subagent", text: row.text, isMonospaced: false))
            case .failed, .turnFailed, .aborted:
                sections.append(ActivityDetailSection(title: "Error", text: row.text, isMonospaced: true))
            case .turnEnd:
                sections.append(ActivityDetailSection(title: "Turn", text: row.text, isMonospaced: false))
            case .session, .compact, .context, .contextGroup, .tool, .result:
                sections.append(ActivityDetailSection(title: "Context", text: row.text, isMonospaced: true))
            }
            if row.count > 1 {
                let merged = row.items.compactMap { item -> String? in
                    guard case let .context(payload) = item.payload else { return nil }
                    return payload.summary ?? payload.kind
                }
                if !merged.isEmpty {
                    sections.append(ActivityDetailSection(title: "Merged items", text: merged.joined(separator: "\n"), isMonospaced: true))
                }
            }
        }

        return ActivityDetailPresentation(
            tag: row.tag,
            label: row.label,
            title: title,
            sections: sections,
            isFailed: activity.isFailed
        )
    }

    private static func planText(_ row: TimelineRow) -> String {
        guard case let .plan(payload) = row.items.last?.payload else { return row.text }
        let steps = payload.steps.map { step in
            let mark = switch step.status {
            case .pending: "○"
            case .inProgress: "◐"
            case .completed: "●"
            }
            return "\(mark) \(step.text)"
        }
        return ([payload.explanation].compactMap { $0 } + steps).joined(separator: "\n")
    }
}
