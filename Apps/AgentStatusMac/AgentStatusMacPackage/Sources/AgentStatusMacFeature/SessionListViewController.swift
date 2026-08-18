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
    private var filterText = ""
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
        outline.rowHeight = AgentStatusDesign.Layout.listRowHeight
        outline.intercellSpacing = NSSize(width: 0, height: 1)
        outline.style = .plain
        outline.selectionHighlightStyle = .regular
        outline.indentationPerLevel = 0
        outline.indentationMarkerFollowsCell = false
        outline.backgroundColor = .clear
        outline.delegate = self
        outline.dataSource = self

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
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
        view.additionalSafeAreaInsets = NSEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)
        reload()
    }

    /// Toolbar search field → title / agent / workspace filter.
    func apply(filter: String) {
        guard filter != filterText else { return }
        filterText = filter
        displayedSessions = []
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

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("SessionRowContainer")
        if let row = outlineView.makeView(withIdentifier: identifier, owner: self) as? RoundedSelectionRowView {
            return row
        }
        let row = RoundedSelectionRowView()
        row.identifier = identifier
        return row
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
        cell.configure(with: node.summary, level: outlineView.level(forItem: item))
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

        let sorted = store.sessions.sorted { $0.updatedAt > $1.updatedAt }
        let updated = SessionListHierarchy.filtering(sorted, query: filterText)
        let changed = updated != displayedSessions
        displayedSessions = updated
        emptyLabel.stringValue = filterText.isEmpty ? "No Sessions" : "No matching Sessions"
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

/// `[agent icon] Title` / `● Running · Thinking`; subagents indent, drop the icon
/// and draw an elbow connector to their parent.
@MainActor
private final class SessionRowView: NSTableCellView {
    private let agentIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var titleLeading: NSLayoutConstraint!
    private var statusLeading: NSLayoutConstraint!
    private var level = 0
    private var statusTone: SessionStatusTone = .gray

    private static let baseInset = AgentStatusDesign.Layout.listHorizontalInset + AgentStatusDesign.Layout.listRowInset

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        agentIcon.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = AgentStatusDesign.Font.rowTitle
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        statusLabel.font = AgentStatusDesign.Font.caption
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1

        [agentIcon, titleLabel, statusDot, statusLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        titleLeading = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.baseInset + 22)
        statusLeading = statusDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.baseInset + 22)
        NSLayoutConstraint.activate([
            agentIcon.trailingAnchor.constraint(equalTo: titleLabel.leadingAnchor, constant: -6),
            agentIcon.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            agentIcon.widthAnchor.constraint(equalToConstant: 16),
            agentIcon.heightAnchor.constraint(equalToConstant: 16),
            titleLeading,
            titleLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -(AgentStatusDesign.Layout.listHorizontalInset + AgentStatusDesign.Layout.listRowInset)
            ),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            statusLeading,
            statusDot.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),
            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 6),
            statusLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func configure(with session: SessionSummary, level: Int) {
        let presentation = SessionListRowPresentation(session: session)
        self.level = level
        titleLabel.stringValue = presentation.title
        titleLabel.toolTip = presentation.title
        titleLabel.font = level == 0 ? AgentStatusDesign.Font.rowTitle : AgentStatusDesign.Font.childRowTitle
        statusLabel.stringValue = presentation.status
        statusTone = session.statusTone
        statusDot.layer?.backgroundColor = statusTone.appKitColor.cgColor
        statusLabel.textColor = statusTone.appKitColor
        titleLabel.textColor = .labelColor

        if level == 0 {
            agentIcon.isHidden = false
            agentIcon.image = AgentIcons.image(for: session.agent, pointSize: 16)
            agentIcon.contentTintColor = .secondaryLabelColor
            agentIcon.toolTip = presentation.agent
            titleLeading.constant = Self.baseInset + 22
            statusLeading.constant = Self.baseInset + 22
        } else {
            agentIcon.isHidden = true
            let indent = Self.baseInset + 22 + AgentStatusDesign.Layout.listChildIndent * CGFloat(level - 1)
            titleLeading.constant = indent
            statusLeading.constant = indent
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard level > 0 else { return }
        // Elbow: 10 wide, 20 tall, starting 1pt above the row, rounded 5 at the corner.
        let x = AgentStatusDesign.Layout.listHorizontalInset + 16
            + AgentStatusDesign.Layout.listChildIndent * CGFloat(level - 1) + 0.5
        let top: CGFloat = -1
        let bottom: CGFloat = 19.5
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: x, y: top))
        path.appendArc(
            from: NSPoint(x: x, y: bottom),
            to: NSPoint(x: x + 10, y: bottom),
            radius: 5
        )
        path.line(to: NSPoint(x: x + 10, y: bottom))
        AgentStatusDesign.Color.elbow.setStroke()
        path.stroke()
    }
}
