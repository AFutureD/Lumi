import AgentStatusCore
import AgentStatusTransport
import AppKit

@MainActor
final class SessionListViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let store: MacSessionStore
    private let outline = NSOutlineView()
    private let emptyLabel = NSTextField(labelWithString: "No Sessions")
    private var hierarchy = SessionListHierarchy(roots: [], nodesByID: [:])
    private var displayedSessions: [SessionSummary] = []
    private var collapsedSessionIDs: Set<SessionID> = []
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
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 78
        outline.intercellSpacing = .zero
        outline.style = .fullWidth
        outline.selectionHighlightStyle = .regular
        outline.indentationPerLevel = 14
        outline.delegate = self
        outline.dataSource = self

        let scroll = NSScrollView()
        scroll.documentView = outline
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

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SessionListNode)?.children.count ?? hierarchy.roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let nodes = (item as? SessionListNode)?.children ?? hierarchy.roots
        return nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SessionListNode else { return false }
        return !node.children.isEmpty
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? SessionListNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("SessionRow")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SessionRowView
            ?? SessionRowView(identifier: identifier)
        cell.configure(with: node.summary)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        let row = outline.selectedRow
        let sessionID = (row >= 0 ? outline.item(atRow: row) as? SessionListNode : nil)?.summary.id
        store.select(sessionID)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isReloading,
              let node = notification.userInfo?["NSObject"] as? SessionListNode else { return }
        collapsedSessionIDs.remove(node.summary.id)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isReloading,
              let node = notification.userInfo?["NSObject"] as? SessionListNode else { return }
        collapsedSessionIDs.insert(node.summary.id)
    }

    private func reload() {
        guard isViewLoaded else { return }
        isReloading = true
        defer { isReloading = false }

        let updated = store.sessions
        let changed = updated != displayedSessions
        displayedSessions = updated
        emptyLabel.isHidden = !updated.isEmpty
        if changed {
            hierarchy = SessionListHierarchy.build(from: updated)
            outline.reloadData()
            for node in hierarchy.nodesByID.values where !node.children.isEmpty {
                if !collapsedSessionIDs.contains(node.summary.id) {
                    outline.expandItem(node)
                }
            }
        }

        if let selected = store.selectedSession,
           let node = hierarchy.nodesByID[selected.summary.id] {
            let row = outline.row(forItem: node)
            if row >= 0, outline.selectedRow != row {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else if outline.selectedRow != -1 {
            outline.deselectAll(nil)
        }
    }
}

@MainActor
private final class SessionRowView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let agentLabel = NSTextField(labelWithString: "")
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()
    private var statusTone: SessionStatusTone = .gray

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        agentLabel.font = .systemFont(ofSize: 11)
        agentLabel.lineBreakMode = .byTruncatingTail
        statusIcon.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Session status")
        statusIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        separator.boxType = .separator

        [titleLabel, agentLabel, statusIcon, statusLabel, separator].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            agentLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            agentLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            agentLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            statusIcon.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusIcon.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            statusIcon.widthAnchor.constraint(equalToConstant: 9),
            statusIcon.heightAnchor.constraint(equalToConstant: 9),
            statusLabel.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 5),
            statusLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: agentLabel.bottomAnchor, constant: 4),
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
        let presentation = SessionListRowPresentation(session: session)
        titleLabel.stringValue = presentation.title
        titleLabel.toolTip = presentation.title
        agentLabel.stringValue = "Agent · \(presentation.agent)"
        statusLabel.stringValue = presentation.status
        statusTone = session.statusTone
        updateColors()
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        let selectedText = NSColor.alternateSelectedControlTextColor
        titleLabel.textColor = selected ? selectedText : .labelColor
        agentLabel.textColor = selected ? selectedText.withAlphaComponent(0.8) : .secondaryLabelColor
        statusIcon.contentTintColor = selected ? selectedText : statusTone.appKitColor
        statusLabel.textColor = selected ? selectedText.withAlphaComponent(0.9) : statusTone.appKitColor
        separator.isHidden = selected
    }
}

@MainActor
final class SessionDetailViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: MacSessionStore
    private let table = NSTableView()
    private let avatar = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Select a Session")
    private let statusLabel = NSTextField(labelWithString: "")
    private let workspaceLabel = NSTextField(labelWithString: "")
    private let updatedLabel = NSTextField(labelWithString: "")
    private let headerView = NSView()
    private let contentColumn = NSView()
    private let headerSeparator = NSBox()
    private let emptyLabel = NSTextField(labelWithString: "Select a Session")
    private var modules: [SessionDetailModulePresentation] = []
    private var entries: [SessionDetailTableEntry] = []
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
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        workspaceLabel.font = .systemFont(ofSize: 12)
        workspaceLabel.textColor = .secondaryLabelColor
        workspaceLabel.lineBreakMode = .byTruncatingMiddle
        updatedLabel.font = .systemFont(ofSize: 11)
        updatedLabel.textColor = .tertiaryLabelColor
        headerSeparator.boxType = .separator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session-detail"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 76
        table.usesAutomaticRowHeights = true
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.floatsGroupRows = false
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

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard row < entries.count else { return false }
        if case .module = entries[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        switch entries[row] {
        case let .module(kind):
            let identifier = NSUserInterfaceItemIdentifier("SessionModuleHeader")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? SessionModuleHeaderView
                ?? SessionModuleHeaderView(identifier: identifier)
            view.configure(with: kind)
            return view
        case let .row(presentation) where presentation.usesStructuredText:
            let identifier = NSUserInterfaceItemIdentifier("StructuredSessionDetailRow")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? StructuredSessionDetailRowView
                ?? StructuredSessionDetailRowView(identifier: identifier)
            view.configure(with: presentation)
            return view
        case let .row(presentation):
            let identifier = NSUserInterfaceItemIdentifier("SessionDetailRow")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? SessionDetailRowView
                ?? SessionDetailRowView(identifier: identifier)
            view.configure(with: presentation)
            return view
        }
    }

    private func reload() {
        guard isViewLoaded else { return }
        let detail = store.selectedSession
        let updatedModules = detail.map(SessionDetailPresentationBuilder.modules(for:)) ?? []
        let updatedEntries = updatedModules.flatMap { module in
            [.module(module.kind)] + module.rows.map(SessionDetailTableEntry.row)
        }
        let changed = updatedModules != modules
        modules = updatedModules
        entries = updatedEntries
        emptyLabel.isHidden = detail != nil

        if let summary = detail?.summary {
            headerView.isHidden = false
            headerHeightConstraint?.constant = 102
            avatar.isHidden = false
            titleLabel.stringValue = SessionListRowPresentation(session: summary).title
            titleLabel.toolTip = summary.title
            statusLabel.stringValue = "\(summary.agent.displayName) · \(summary.lifecycle.displayName) · \(summary.phase.displayName)"
            statusLabel.textColor = summary.statusTone.appKitColor
            workspaceLabel.stringValue = summary.workspace ?? "No workspace"
            workspaceLabel.toolTip = summary.workspace
            updatedLabel.stringValue = SessionDateFormatting.detailTime(summary.lastActivityAt)
        } else {
            headerView.isHidden = true
            headerHeightConstraint?.constant = 0
            avatar.isHidden = true
            titleLabel.stringValue = "Select a Session"
            titleLabel.toolTip = nil
            statusLabel.stringValue = ""
            statusLabel.textColor = .secondaryLabelColor
            workspaceLabel.stringValue = ""
            workspaceLabel.toolTip = nil
            updatedLabel.stringValue = ""
        }
        if changed { table.reloadData() }
    }
}

private enum SessionDetailTableEntry: Equatable {
    case module(SessionDetailModuleKind)
    case row(SessionDetailRowPresentation)
}

@MainActor
private final class SessionModuleHeaderView: NSTableCellView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        icon.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        separator.boxType = .separator

        [icon, titleLabel, separator].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            icon.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            titleLabel.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -10),
            separator.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(with kind: SessionDetailModuleKind) {
        icon.image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: kind.title)
        titleLabel.stringValue = kind.title
    }
}

@MainActor
private final class SessionDetailRowView: NSTableCellView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let separator = NSBox()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        metadataLabel.font = .systemFont(ofSize: 11)
        metadataLabel.textColor = .tertiaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingHead
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = .labelColor
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.isSelectable = true
        separator.boxType = .separator

        [icon, titleLabel, metadataLabel, bodyLabel, separator].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: metadataLabel.leadingAnchor, constant: -12),
            titleLabel.firstBaselineAnchor.constraint(equalTo: icon.firstBaselineAnchor),
            metadataLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            metadataLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            bodyLabel.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -14),
            separator.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(with presentation: SessionDetailRowPresentation) {
        icon.image = NSImage(
            systemSymbolName: presentation.symbolName,
            accessibilityDescription: presentation.title
        )
        titleLabel.stringValue = presentation.title
        metadataLabel.stringValue = presentation.metadata ?? ""
        metadataLabel.isHidden = presentation.metadata == nil
        bodyLabel.stringValue = presentation.body
    }
}

@MainActor
private final class StructuredSessionDetailRowView: NSTableCellView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private let textScroll = NSScrollView()
    private let separator = NSBox()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        metadataLabel.font = .systemFont(ofSize: 11)
        metadataLabel.textColor = .tertiaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingHead

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.borderType = .bezelBorder
        separator.boxType = .separator

        [icon, titleLabel, metadataLabel, textScroll, separator].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: metadataLabel.leadingAnchor, constant: -12),
            titleLabel.firstBaselineAnchor.constraint(equalTo: icon.firstBaselineAnchor),
            metadataLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            metadataLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            textScroll.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            textScroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            textScroll.heightAnchor.constraint(equalToConstant: 220),
            textScroll.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -14),
            separator.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(with presentation: SessionDetailRowPresentation) {
        icon.image = NSImage(
            systemSymbolName: presentation.symbolName,
            accessibilityDescription: presentation.title
        )
        titleLabel.stringValue = presentation.title
        metadataLabel.stringValue = presentation.metadata ?? ""
        metadataLabel.isHidden = presentation.metadata == nil
        textView.string = presentation.body
        textView.scrollToBeginningOfDocument(nil)
    }
}

private enum SessionDateFormatting {
    static func detailTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private extension SessionDetailModuleKind {
    var symbolName: String {
        switch self {
        case .overview: "info.circle"
        case .modelConfiguration: "cpu"
        case .usage: "gauge.with.dots.needle.67percent"
        case .internalContext: "lock.doc"
        case .activity: "list.bullet.rectangle"
        }
    }
}
