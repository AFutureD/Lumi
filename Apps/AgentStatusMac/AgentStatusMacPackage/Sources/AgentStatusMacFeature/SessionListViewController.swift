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
    private var relativeTimeTimer: Timer?

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
        outline.rowHeight = SessionRowView.rowHeight
        outline.intercellSpacing = .zero
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
        view.additionalSafeAreaInsets = NSEdgeInsets(top: SessionRowView.listInset, left: 0, bottom: 0, right: 0)
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard relativeTimeTimer == nil else { return }
        // Relative times ("4m", "1h") only need coarse refreshes.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRelativeTimes() }
        }
        RunLoop.main.add(timer, forMode: .common)
        relativeTimeTimer = timer
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        relativeTimeTimer?.invalidate()
        relativeTimeTimer = nil
    }

    /// Toolbar search field → title / agent / workspace filter.
    func apply(filter: String) {
        guard filter != filterText else { return }
        filterText = filter
        displayedSessions = []
        reload()
    }

    // MARK: NSOutlineViewDataSource / Delegate

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
        row.horizontalInset = SessionRowView.listInset
        row.bottomInset = SessionRowView.rowGap
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
        cell.configure(with: node.summary, layout: rowLayout(for: node))
        cell.onToggle = { [weak self, weak node] in
            guard let self, let node else { return }
            self.toggle(node)
        }
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
        reloadRow(for: node)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isReloading,
              let node = notification.userInfo?["NSObject"] as? SessionListNode else { return }
        collapsedSessionIDs.insert(node.summary.id)
        reloadRow(for: node)
    }

    // MARK: Row layout

    private func rowLayout(for node: SessionListNode) -> SessionRowView.Layout {
        let parent = outline.parent(forItem: node) as? SessionListNode
        let siblings = parent?.children ?? hierarchy.roots
        let isLastSibling = siblings.last === node
        return SessionRowView.Layout(
            level: outline.level(forItem: node),
            hasChildren: !node.children.isEmpty,
            isExpanded: outline.isItemExpanded(node),
            childCount: node.children.count,
            isLastSibling: isLastSibling
        )
    }

    private func toggle(_ node: SessionListNode) {
        if outline.isItemExpanded(node) {
            outline.animator().collapseItem(node)
        } else {
            outline.animator().expandItem(node)
        }
    }

    private func reloadRow(for node: SessionListNode) {
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        // The previous sibling's trunk depends on whether this node is last / expanded.
        if let parent = outline.parent(forItem: node) as? SessionListNode {
            let parentRow = outline.row(forItem: parent)
            if parentRow >= 0 {
                outline.reloadData(forRowIndexes: IndexSet(integer: parentRow), columnIndexes: IndexSet(integer: 0))
            }
        }
    }

    private func refreshRelativeTimes() {
        guard isViewLoaded, outline.numberOfRows > 0 else { return }
        let visible = outline.rows(in: outline.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location ..< visible.location + visible.length {
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SessionRowView else { continue }
            cell.refreshRelativeTime()
        }
    }

    // MARK: Data

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
                let parents = hierarchy.nodesByID.values.filter { !$0.children.isEmpty }
                for node in parents where !collapsedSessionIDs.contains(node.summary.id) {
                    outline.expandItem(node)
                }
                // Parent rows were built before their children were expanded; refresh
                // chevron rotation, count pills and tree guides.
                for node in parents {
                    reloadRow(for: node)
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

/// 4A row grid: `[18 chevron][18 icon][title][time]` over `[·][dot][status][count]`.
/// Children are not indented; hierarchy is drawn in the leading gutter.
@MainActor
private final class SessionRowView: NSTableCellView {
    struct Layout {
        var level: Int
        var hasChildren: Bool
        var isExpanded: Bool
        var childCount: Int
        var isLastSibling: Bool
    }

    /// Scroll-body padding on both sides (`10px 10px 0`).
    static let listInset: CGFloat = 10
    /// Vertical gap between rows, carried inside the row so tree guides stay continuous.
    static let rowGap: CGFloat = 2
    /// `9 + 16 + 5 + 14 + 10` content + gap.
    static let rowHeight: CGFloat = 54 + rowGap

    private static let padding: CGFloat = 10
    private static let gutter: CGFloat = 18
    private static let columnGap: CGFloat = 8
    private static let firstRowCenterY: CGFloat = 9 + 8
    private static let secondRowCenterY: CGFloat = 9 + 16 + 5 + 7
    private static var guideX: CGFloat { listInset + padding + gutter / 2 }

    private let chevronButton = NSButton(frame: .zero)
    private let agentIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let countPill = NSButton(frame: .zero)
    private var layoutInfo = Layout(level: 0, hasChildren: false, isExpanded: false, childCount: 0, isLastSibling: true)
    private var updatedAt = Date()
    private var isChevronExpanded = false

    var onToggle: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        chevronButton.isBordered = false
        chevronButton.imagePosition = .imageOnly
        chevronButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Toggle subagents")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        chevronButton.contentTintColor = NSColor(white: 90 / 255, alpha: 1)
        chevronButton.wantsLayer = true
        chevronButton.layer?.cornerRadius = 4
        chevronButton.layer?.backgroundColor = NSColor(red: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.1).cgColor
        chevronButton.target = self
        chevronButton.action = #selector(toggle)
        chevronButton.toolTip = "Toggle subagents"

        agentIcon.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeLabel.font = AgentStatusDesign.Font.caption
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .right
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        statusLabel.font = AgentStatusDesign.Font.caption
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        countPill.isBordered = false
        countPill.wantsLayer = true
        countPill.layer?.cornerRadius = 8
        countPill.layer?.backgroundColor = AgentStatusDesign.Color.chipFill.cgColor
        countPill.font = .systemFont(ofSize: 10, weight: .semibold)
        countPill.contentTintColor = NSColor(white: 90 / 255, alpha: 1)
        countPill.target = self
        countPill.action = #selector(toggle)
        countPill.toolTip = "Show subagents"

        [chevronButton, agentIcon, titleLabel, timeLabel, statusDot, statusLabel, countPill].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        let col1 = Self.listInset + Self.padding
        let col2 = col1 + Self.gutter + Self.columnGap
        let col3 = col2 + Self.gutter + Self.columnGap
        NSLayoutConstraint.activate([
            chevronButton.centerXAnchor.constraint(equalTo: leadingAnchor, constant: col1 + Self.gutter / 2),
            chevronButton.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.firstRowCenterY),
            chevronButton.widthAnchor.constraint(equalToConstant: 16),
            chevronButton.heightAnchor.constraint(equalToConstant: 16),

            agentIcon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: col2 + Self.gutter / 2),
            agentIcon.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.firstRowCenterY),
            agentIcon.widthAnchor.constraint(equalToConstant: 16),
            agentIcon.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: col3),
            titleLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.firstRowCenterY),

            timeLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Self.listInset + Self.padding)),
            timeLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.firstRowCenterY),

            statusDot.centerXAnchor.constraint(equalTo: agentIcon.centerXAnchor),
            statusDot.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.secondRowCenterY),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.secondRowCenterY),

            countPill.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 10),
            countPill.trailingAnchor.constraint(equalTo: timeLabel.trailingAnchor),
            countPill.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.secondRowCenterY),
            countPill.heightAnchor.constraint(equalToConstant: 16),
        ])
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countPill.setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func configure(with session: SessionSummary, layout: Layout) {
        let presentation = SessionListRowPresentation(session: session)
        layoutInfo = layout
        updatedAt = session.updatedAt
        let isChild = layout.level > 0

        titleLabel.stringValue = presentation.title
        titleLabel.toolTip = presentation.title
        titleLabel.font = isChild ? AgentStatusDesign.Font.body : AgentStatusDesign.Font.rowTitle
        titleLabel.textColor = isChild ? NSColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 1) : .labelColor

        let tone = session.statusTone
        statusLabel.stringValue = presentation.status
        statusLabel.textColor = tone.appKitColor
        statusDot.layer?.backgroundColor = tone.appKitColor.cgColor
        refreshRelativeTime()

        if isChild {
            agentIcon.image = NSImage(systemSymbolName: "arrow.turn.down.right", accessibilityDescription: "Subagent")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
            agentIcon.contentTintColor = NSColor(red: 150 / 255, green: 150 / 255, blue: 155 / 255, alpha: 1)
            agentIcon.toolTip = "Subagent"
        } else {
            agentIcon.image = AgentIcons.image(for: session.agent, pointSize: 16)
            agentIcon.contentTintColor = .secondaryLabelColor
            agentIcon.toolTip = presentation.agent
        }

        chevronButton.isHidden = !layout.hasChildren
        setChevronExpanded(layout.isExpanded, animated: false)

        let showCount = layout.hasChildren && !layout.isExpanded
        countPill.isHidden = !showCount
        countPill.title = "\(layout.childCount)"
        countPill.attributedTitle = NSAttributedString(
            string: "\(layout.childCount)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor(white: 90 / 255, alpha: 1),
                .paragraphStyle: {
                    let style = NSMutableParagraphStyle()
                    style.alignment = .center
                    return style
                }(),
            ]
        )
        countPill.contentTintColor = NSColor(white: 90 / 255, alpha: 1)
        needsDisplay = true
    }

    func refreshRelativeTime() {
        timeLabel.stringValue = SessionRelativeTimeFormatter.string(from: updatedAt)
    }

    @objc private func toggle() {
        setChevronExpanded(!isChevronExpanded, animated: true)
        onToggle?()
    }

    private func setChevronExpanded(_ expanded: Bool, animated: Bool) {
        isChevronExpanded = expanded
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        guard let image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: expanded ? "Hide subagents" : "Show subagents"
        )?.withSymbolConfiguration(configuration) else { return }
        chevronButton.image = image
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let x = Self.guideX + 0.5
        let path = NSBezierPath()
        path.lineWidth = 1
        AgentStatusDesign.Color.elbow.setStroke()

        if layoutInfo.level > 0 {
            // Elbow from the row above into this row's first line.
            let bottom = Self.firstRowCenterY + 0.5
            path.move(to: NSPoint(x: x, y: 0))
            path.appendArc(from: NSPoint(x: x, y: bottom), to: NSPoint(x: x + 10, y: bottom), radius: 4)
            path.line(to: NSPoint(x: x + 10, y: bottom))
        }
        let continuesBelow = (layoutInfo.hasChildren && layoutInfo.isExpanded)
            || (layoutInfo.level > 0 && !layoutInfo.isLastSibling)
        if continuesBelow {
            path.move(to: NSPoint(x: x, y: Self.firstRowCenterY + (layoutInfo.level > 0 ? 0.5 : 1)))
            path.line(to: NSPoint(x: x, y: bounds.height))
        }
        path.stroke()
    }
}
