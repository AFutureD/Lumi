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
    /// Rows behind this activity the Relay carried trimmed; the whole copy
    /// is on the Mac and can be asked for.
    let truncatedItemIDs: [TimelineItemID]
}

enum ActivityDetailPresentationBuilder {
    /// The row's records as the shared preview reads them
    /// (`ActivityPreviewBuilder`): a tool call and its result open together,
    /// each section holding what the record itself says — the command, the
    /// output, the diff — rather than the row's one-line text. This page
    /// shows every section as text.
    static func make(for activity: SessionActivityPresentation, in activities: [SessionActivityPresentation]) -> ActivityDetailPresentation {
        let row = activity.row
        let preview = ActivityPreviewBuilder.make(for: row, among: activities.map(\.row))
        var sections: [ActivityDetailSection] = []
        if !preview.facts.isEmpty, row.toolUseID != nil {
            sections.append(ActivityDetailSection(title: "Status", text: lines(preview.facts), isMonospaced: true))
        }
        for section in preview.sections {
            let (text, isMonospaced): (String, Bool) = switch section.body {
            case let .prose(text), let .markdown(text):
                (text, false)
            case let .code(text), let .diff(text):
                (text, true)
            case let .image(image):
                (imageNote(image), false)
            case let .facts(facts):
                (lines(facts), true)
            case let .links(links):
                (links.map { [$0.title, $0.url == $0.title ? nil : $0.url].compactMap { $0 }.joined(separator: "\n") }.joined(separator: "\n\n"), false)
            }
            sections.append(ActivityDetailSection(title: section.title, text: text, isMonospaced: isMonospaced))
        }
        // A call whose result has not come yet says so where the output goes.
        if row.toolUseID != nil, preview.items.count == 1, row.tag == .tool {
            sections.append(ActivityDetailSection(title: "Output", text: "Still running…", isMonospaced: true))
        }
        // A record with nothing but its line: the line is the content.
        if sections.isEmpty {
            sections.append(ActivityDetailSection(title: row.label.capitalized, text: row.text, isMonospaced: false))
        }
        return ActivityDetailPresentation(
            tag: row.tag,
            label: row.label,
            title: TextShaping.firstLine(row.text),
            sections: sections,
            isFailed: activity.isFailed,
            truncatedItemIDs: preview.truncatedItemIDs
        )
    }

    private static func lines(_ facts: [ActivityPreview.Fact]) -> String {
        facts.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }

    private static func imageNote(_ image: ActivityPreview.Image) -> String {
        switch image {
        case .base64: "Image"
        case let .file(path): path
        }
    }
}
