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
            let updatedHierarchy = SessionListHierarchy.build(from: updated)
            if hierarchy.hasSameStructure(as: updatedHierarchy) {
                let changedIDs = hierarchy.updateSummaries(from: updated)
                let changedRows = IndexSet(changedIDs.compactMap { id in
                    guard let node = hierarchy.nodesByID[id] else { return nil }
                    let row = outline.row(forItem: node)
                    return row >= 0 ? row : nil
                })
                if !changedRows.isEmpty {
                    outline.reloadData(
                        forRowIndexes: changedRows,
                        columnIndexes: IndexSet(integer: 0)
                    )
                }
            } else {
                hierarchy = updatedHierarchy
                outline.reloadData()
                for node in hierarchy.nodesByID.values where !node.children.isEmpty {
                    if !collapsedSessionIDs.contains(node.summary.id) {
                        outline.expandItem(node)
                    }
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
