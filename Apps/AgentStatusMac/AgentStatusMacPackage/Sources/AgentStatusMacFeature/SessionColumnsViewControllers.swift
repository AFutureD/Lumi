import AgentStatusCore
import AgentStatusTransport
import AppKit

@MainActor
final class SessionListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: MacSessionStore
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No Sessions")
    private var displayedSessions: [SessionSummary] = []
    private var isReloading = false

    init(store: MacSessionStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        store.observe { [weak self] in self?.reload() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sessions"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 84
        table.intercellSpacing = .zero
        table.style = .fullWidth
        table.selectionHighlightStyle = .regular
        table.delegate = self
        table.dataSource = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scroll)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { displayedSessions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < displayedSessions.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("SessionRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SessionRowView
            ?? SessionRowView(identifier: identifier)
        cell.configure(with: displayedSessions[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        let row = table.selectedRow
        store.select(row >= 0 && row < displayedSessions.count ? displayedSessions[row].id : nil)
    }

    private func reload() {
        guard isViewLoaded else { return }
        isReloading = true
        defer { isReloading = false }

        let updated = store.sessions
        let changed = updated != displayedSessions
        displayedSessions = updated
        emptyLabel.isHidden = !updated.isEmpty
        if changed { table.reloadData() }

        if let selected = store.selectedSession,
           let row = displayedSessions.firstIndex(where: { $0.id == selected.summary.id }) {
            if table.selectedRow != row {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else if table.selectedRow != -1 {
            table.deselectAll(nil)
        }
    }
}

@MainActor
private final class SessionRowView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let workspaceLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()
    private var statusTone: SessionStatusTone = .gray

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        timeLabel.font = .systemFont(ofSize: 11)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingTail
        workspaceLabel.font = .systemFont(ofSize: 11)
        workspaceLabel.lineBreakMode = .byTruncatingMiddle
        separator.boxType = .separator

        [titleLabel, timeLabel, statusLabel, workspaceLabel, separator].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            timeLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            workspaceLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            workspaceLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            workspaceLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    func configure(with session: SessionSummary) {
        titleLabel.stringValue = session.title
        timeLabel.stringValue = SessionDateFormatting.listTime(session.lastActivityAt)
        statusLabel.stringValue = "\(session.lifecycle.displayName) · \(session.phase.displayName)"
        let workspace = session.workspace.flatMap { URL(fileURLWithPath: $0).lastPathComponent }
        workspaceLabel.stringValue = workspace?.isEmpty == false ? workspace! : session.agent.displayName
        workspaceLabel.toolTip = session.workspace
        statusTone = session.statusTone
        updateColors()
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        titleLabel.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        timeLabel.textColor = selected
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8)
            : .secondaryLabelColor
        statusLabel.textColor = selected
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.9)
            : statusTone.appKitColor
        workspaceLabel.textColor = selected
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75)
            : .tertiaryLabelColor
        separator.isHidden = selected
    }
}

@MainActor
final class SessionDetailViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: MacSessionStore
    private let table = NSTableView()
    private let avatar = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Select a Session")
    private let statusLabel = NSTextField(labelWithString: "Session messages and tool activity appear here.")
    private let workspaceLabel = NSTextField(labelWithString: "")
    private let updatedLabel = NSTextField(labelWithString: "")
    private let headerView = NSView()
    private let contentColumn = NSView()
    private let headerSeparator = NSBox()
    private let emptyLabel = NSTextField(labelWithString: "No supported events")
    private var displayedTimeline: [TimelineItem] = []
    private var headerHeightConstraint: NSLayoutConstraint?

    init(store: MacSessionStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        store.observe { [weak self] in self?.reload() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()

        avatar.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Agent")
        avatar.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        avatar.contentTintColor = .secondaryLabelColor
        avatar.wantsLayer = true
        avatar.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        avatar.layer?.cornerRadius = 21

        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        workspaceLabel.font = .systemFont(ofSize: 12)
        workspaceLabel.textColor = .secondaryLabelColor
        workspaceLabel.lineBreakMode = .byTruncatingMiddle
        updatedLabel.font = .systemFont(ofSize: 11)
        updatedLabel.textColor = .tertiaryLabelColor

        headerSeparator.boxType = .separator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("timeline"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 88
        table.usesAutomaticRowHeights = true
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.delegate = self
        table.dataSource = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor

        [avatar, titleLabel, statusLabel, workspaceLabel, updatedLabel, headerSeparator].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            headerView.addSubview($0)
        }
        [headerView, scroll, emptyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentColumn.addSubview($0)
        }
        contentColumn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentColumn)
        let headerHeightConstraint = headerView.heightAnchor.constraint(equalToConstant: 102)
        self.headerHeightConstraint = headerHeightConstraint
        NSLayoutConstraint.activate([
            contentColumn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            contentColumn.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            headerView.leadingAnchor.constraint(equalTo: contentColumn.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: contentColumn.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: contentColumn.topAnchor),
            headerHeightConstraint,
            avatar.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 24),
            avatar.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 18),
            avatar.widthAnchor.constraint(equalToConstant: 42),
            avatar.heightAnchor.constraint(equalToConstant: 42),
            titleLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: updatedLabel.leadingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: avatar.topAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -24),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            workspaceLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            workspaceLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -24),
            workspaceLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 3),
            updatedLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -24),
            updatedLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            headerSeparator.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 24),
            headerSeparator.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -24),
            headerSeparator.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: contentColumn.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentColumn.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: contentColumn.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ] + AgentStatusDetailLayout.adaptiveWidthConstraints(for: contentColumn, in: view))
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { displayedTimeline.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < displayedTimeline.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("TimelineRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TimelineRowView
            ?? TimelineRowView(identifier: identifier)
        cell.configure(with: displayedTimeline[row])
        return cell
    }

    private func reload() {
        guard isViewLoaded else { return }
        let detail = store.selectedSession
        let updated = detail?.timeline.filter {
            if case .unknown = $0.payload { return false }
            return true
        } ?? []
        let changed = updated != displayedTimeline
        displayedTimeline = updated
        emptyLabel.stringValue = detail == nil ? "Select a Session" : "No supported events"
        emptyLabel.isHidden = !updated.isEmpty

        if let summary = detail?.summary {
            headerView.isHidden = false
            headerHeightConstraint?.constant = 102
            avatar.isHidden = false
            titleLabel.stringValue = summary.title
            statusLabel.stringValue = "\(summary.agent.displayName) · \(summary.lifecycle.displayName) · \(summary.phase.displayName)"
            statusLabel.textColor = summary.statusTone.appKitColor
            workspaceLabel.stringValue = summary.workspace ?? ""
            updatedLabel.stringValue = SessionDateFormatting.detailTime(summary.lastActivityAt)
        } else {
            headerView.isHidden = true
            headerHeightConstraint?.constant = 0
            avatar.isHidden = true
            titleLabel.stringValue = "Select a Session"
            statusLabel.stringValue = "Session messages and tool activity appear here."
            statusLabel.textColor = .secondaryLabelColor
            workspaceLabel.stringValue = ""
            updatedLabel.stringValue = ""
        }
        if changed { table.reloadData() }
    }
}

@MainActor
private final class TimelineRowView: NSTableCellView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.textColor = .tertiaryLabelColor
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = .labelColor
        bodyLabel.maximumNumberOfLines = 0

        let separator = NSBox()
        separator.boxType = .separator
        [icon, titleLabel, timeLabel, bodyLabel, separator].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 17),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -12),
            titleLabel.firstBaselineAnchor.constraint(equalTo: icon.firstBaselineAnchor),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            timeLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            bodyLabel.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -16),
            separator.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(with item: TimelineItem) {
        icon.image = NSImage(
            systemSymbolName: item.payload.symbolName,
            accessibilityDescription: item.payload.title
        )
        titleLabel.stringValue = item.payload.title
        timeLabel.stringValue = SessionDateFormatting.detailTime(item.occurredAt)
        bodyLabel.stringValue = item.payload.body
    }
}

private enum SessionDateFormatting {
    static func listTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func detailTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private extension AgentKind {
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case let .unknown(value): value.capitalized
        }
    }
}

private extension TimelinePayload {
    var symbolName: String {
        switch self {
        case let .message(value): value.role == .user ? "person" : "sparkles"
        case .tool: "hammer"
        case .plan: "checklist"
        case .subagent: "person.2"
        case .error: "exclamationmark.triangle"
        case .unknown: "questionmark.circle"
        }
    }

    var title: String {
        switch self {
        case let .message(value): value.role == .user ? "User" : "Assistant"
        case let .tool(value): "Tool · \(value.name) · \(value.status.rawValue.capitalized)"
        case .plan: "Plan"
        case let .subagent(value): "Sub-agent · \(value.name)"
        case .error: "Error"
        case let .unknown(value): value.kind
        }
    }

    var body: String {
        switch self {
        case let .message(value): value.text
        case let .tool(value): value.summary ?? "No details"
        case let .plan(value): value.steps.map {
            "\($0.status == .completed ? "✓" : "•") \($0.text)"
        }.joined(separator: "\n")
        case let .subagent(value): value.status.rawValue.capitalized
        case let .error(value): "\(value.title): \(value.message)"
        case let .unknown(value): value.summary ?? "Unsupported event"
        }
    }
}
