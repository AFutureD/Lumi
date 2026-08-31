import Core
import DesignSystem
import Transport
import AppKit

/// The Sessions column (§4.4b): a flat table with one row per main session.
/// Each row is a two-line block — status dot + title + relative time over
/// agent icon + `model · effort` + stacked subagent dots + chevron — and,
/// when expanded, one line per subagent inside the same block. Selection is
/// two-level and mutually exclusive: session blocks (full-width, square;
/// shift / ⌘ build a multi-selection at this level only) or one subagent
/// line (rounded, outset 4); both are painted by the cell, not by
/// NSTableView.
@MainActor
final class SessionListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: MacSessionStore
    private let table = SessionListTableView()
    private let emptyLabel = NSTextField(labelWithString: "No Sessions")
    private var rows: [SessionListRowModel] = []
    private var rowSelections: [SessionListCellView.SelectionState] = []
    /// Rows the user toggled by hand; missing rows take the tier default.
    /// An entry is dropped when that session's tier changes.
    private var expandedOverrides: [SessionID: Bool] = [:]
    private var lastTones: [SessionID: SessionStatusTone] = [:]
    /// The fixed end of a shift range (last plainly- or ⌘-clicked session
    /// block); nil while a subagent line is selected.
    private var anchorID: SessionID?
    private var filterText = ""
    private var relativeTimeTimer: Timer?
    /// Row currently carrying the hover wash; -1 when none.
    private var hoverRow = -1

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
        table.intercellSpacing = .zero
        table.style = .plain
        // Session-level selection stays NSTableView's (keyboard focus and
        // accessibility come with it); the row view paints it full-width and
        // square, and the cell paints the subagent-line shape. The table's
        // selection is presentation only — every change to it goes through
        // this controller, never through the table's own mouse handling.
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.delegate = self
        table.dataSource = self
        table.onHit = { [weak self] rowIndex, region, modifiers in
            self?.handleHit(rowIndex: rowIndex, region: region, modifiers: modifiers)
        }
        table.onKey = { [weak self] key, modifiers in
            self?.handleKey(key, modifiers: modifiers) ?? false
        }
        table.onSelectAll = { [weak self] in
            self?.selectAllSessions()
        }
        table.onContextMenu = { [weak self] rowIndex, region in
            self?.contextMenu(rowIndex: rowIndex, region: region)
        }
        table.onHover = { [weak self] point in
            self?.updateHover(at: point)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // Scrolling moves the rows under a stationary pointer without any
        // mouse event; re-derive the hover from the pointer position.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )

        emptyLabel.font = Design.Font.body
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
        view.additionalSafeAreaInsets = NSEdgeInsets(
            top: 0,
            left: 0,
            bottom: DesignSystem.SessionList.listBottomPadding,
            right: 0
        )
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard relativeTimeTimer == nil else { return }
        // Live subagent durations print seconds ("3m 43s"), so the refresh
        // ticks every second; only label text moves, so the status dots keep
        // breathing undisturbed.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
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
        reload()
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        SessionListCellView.height(for: rows[row])
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("SessionRow")
        let cell = table.makeView(withIdentifier: identifier, owner: self) as? SessionListCellView
            ?? SessionListCellView(identifier: identifier)
        cell.configure(with: rows[row], selection: rowSelections[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("SessionRowContainer")
        if let view = table.makeView(withIdentifier: identifier, owner: self) as? PlainRowView {
            return view
        }
        let view = PlainRowView()
        view.identifier = identifier
        return view
    }

    // MARK: Interaction

    private func handleHit(rowIndex: Int, region: SessionListCellView.Region, modifiers: NSEvent.ModifierFlags) {
        guard rows.indices.contains(rowIndex) else { return }
        let row = rows[rowIndex]
        let flags = modifiers.intersection([.shift, .command])
        switch region {
        case .disclosure:
            // Toggling never changes the selection.
            setExpanded(!row.isExpanded, at: rowIndex, animated: true)
        case let .subagentLine(id):
            // Subagent lines sit outside multi-selection; a modifier click
            // is ignored rather than silently replacing a built-up set.
            guard flags.isEmpty else { return }
            select(id)
        case .body:
            if flags.contains(.shift) {
                // ⇧ extends from the anchor; ⌘⇧ joins the range to the
                // existing selection instead of replacing it.
                extendSelection(to: rowIndex, keepExisting: flags.contains(.command))
            } else if flags.contains(.command) {
                toggleSelection(of: row.id)
            } else {
                select(row.id)
            }
        }
    }

    private func select(_ id: SessionID) {
        anchorID = rows.contains { $0.id == id } ? id : nil
        store.setSelection([id], lead: id)
        applySelections()
    }

    /// The current selection restricted to session blocks — a lone subagent
    /// selection contributes nothing to a range or a toggle.
    private func sessionSelection() -> [SessionID] {
        let topLevel = Set(rows.map(\.id))
        return store.selectedIDs.filter { topLevel.contains($0) }
    }

    private func extendSelection(to rowIndex: Int, keepExisting: Bool) {
        guard let anchorID, let anchorRow = rows.firstIndex(where: { $0.id == anchorID }) else {
            select(rows[rowIndex].id)
            return
        }
        var ids = keepExisting ? sessionSelection() : []
        for index in min(anchorRow, rowIndex) ... max(anchorRow, rowIndex) {
            let id = rows[index].id
            if !ids.contains(id) { ids.append(id) }
        }
        store.setSelection(ids, lead: rows[rowIndex].id)
        applySelections()
    }

    private func toggleSelection(of id: SessionID) {
        var ids = sessionSelection()
        anchorID = id
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
            // The detail pane keeps its session unless that one was removed;
            // then the most recently selected survivor takes over.
            let currentLead = store.leadSelectedID
            let lead = currentLead.flatMap { ids.contains($0) ? $0 : nil } ?? ids.last
            store.setSelection(ids, lead: lead)
        } else {
            ids.append(id)
            store.setSelection(ids, lead: id)
        }
        applySelections()
    }

    /// ⌘A: every session block; the detail pane stays where it was when its
    /// session is part of the list.
    private func selectAllSessions() {
        guard !rows.isEmpty else { return }
        let ids = rows.map(\.id)
        anchorID = ids.first
        let currentLead = store.leadSelectedID
        let lead = currentLead.flatMap { ids.contains($0) ? $0 : nil } ?? ids.last
        store.setSelection(ids, lead: lead)
        applySelections()
    }

    /// `←` / `→` collapse / expand the selected row's subagent group;
    /// `↑` / `↓` walk sessions and visible subagent lines as one list
    /// (`⇧↑` / `⇧↓` grow or shrink a session range instead); `⌘⌫` deletes
    /// the selection.
    private func handleKey(_ key: SessionListTableView.Key, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch key {
        case .left, .right:
            guard let rowIndex = selectedRowIndex() else { return false }
            let expand = key == .right
            let row = rows[rowIndex]
            guard !row.subagents.isEmpty, row.isExpanded != expand else { return true }
            // Collapsing hides a selected subagent line; move the selection
            // up to the session so it stays visible.
            if !expand, case .subagent = rowSelections[rowIndex] {
                select(row.id)
            }
            setExpanded(expand, at: rowIndex, animated: true)
            return true
        case .delete:
            guard !store.selectedIDs.isEmpty else { return false }
            deleteSelectedSessions()
            return true
        case .up, .down:
            if modifiers.contains(.shift) {
                return extendSelectionWithArrow(down: key == .down)
            }
            let items = selectableItems()
            guard !items.isEmpty else { return false }
            let currentID = store.leadSelectedID
            let currentIndex = items.firstIndex { $0.id == currentID }
            let next: Int = if let currentIndex {
                key == .down ? min(items.count - 1, currentIndex + 1) : max(0, currentIndex - 1)
            } else {
                0
            }
            select(items[next].id)
            table.scrollRowToVisible(items[next].rowIndex)
            return true
        }
    }

    /// `⇧↑` / `⇧↓`: the moving end of the range steps one session block
    /// while the anchor stays put, so walking back over the range shrinks
    /// it. A subagent-line selection first climbs to its session block.
    private func extendSelectionWithArrow(down: Bool) -> Bool {
        guard !rows.isEmpty else { return false }
        guard let leadRow = selectedRowIndex() else {
            select(rows[0].id)
            return true
        }
        if anchorID == nil || !rows.contains(where: { $0.id == anchorID }) {
            anchorID = rows[leadRow].id
        }
        guard let anchorID, let anchorRow = rows.firstIndex(where: { $0.id == anchorID }) else { return false }
        let newLeadRow = max(0, min(rows.count - 1, leadRow + (down ? 1 : -1)))
        let ids = (min(anchorRow, newLeadRow) ... max(anchorRow, newLeadRow)).map { rows[$0].id }
        store.setSelection(ids, lead: rows[newLeadRow].id)
        applySelections()
        table.scrollRowToVisible(newLeadRow)
        return true
    }

    private func selectableItems() -> [(id: SessionID, rowIndex: Int)] {
        var items: [(SessionID, Int)] = []
        for (index, row) in rows.enumerated() {
            items.append((row.id, index))
            if row.isExpanded {
                items.append(contentsOf: row.subagents.map { ($0.id, index) })
            }
        }
        return items
    }

    private func selectedRowIndex() -> Int? {
        guard let selectedID = store.leadSelectedID else { return nil }
        return rows.firstIndex { row in
            row.id == selectedID || row.subagents.contains { $0.id == selectedID }
        }
    }

    // MARK: Deletion

    /// Toolbar trash, the context menu, and `⌘⌫` all land here: one
    /// count-aware confirmation, then a batch delete with the selection
    /// moved to the nearest surviving row so the list stays selected.
    func deleteSelectedSessions() {
        let ids = store.selectedIDs
        guard !ids.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        if ids.count == 1 {
            alert.messageText = "Delete this Session?"
            let title = sessionTitle(for: ids[0]).map { "“\($0)” and its timeline" } ?? "The Session and its timeline"
            alert.informativeText = "\(title) will be removed from this Mac, the daemon, and connected iPhones."
        } else {
            alert.messageText = "Delete \(ids.count) Sessions?"
            alert.informativeText = "These Sessions and their timelines will be removed from this Mac, the daemon, and connected iPhones."
        }
        alert.alertStyle = .warning
        let deleteButton = alert.addButton(withTitle: "Delete")
        deleteButton.hasDestructiveAction = true
        // A destructive action must not sit on Return; Cancel is the default.
        deleteButton.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let next = self.survivingNeighbor(afterDeleting: ids)
            self.store.deleteSessions(ids)
            self.anchorID = next
            self.store.setSelection(next.map { [$0] } ?? [], lead: next)
            self.applySelections()
        }
    }

    private func sessionTitle(for id: SessionID) -> String? {
        if let row = rows.first(where: { $0.id == id }) { return row.title }
        for row in rows {
            if let line = row.subagents.first(where: { $0.id == id }) { return line.title }
        }
        return store.sessions.first { $0.id == id }?.title
    }

    /// The first session block after the deleted range, else the last one
    /// before it; a deleted subagent line falls back to its parent block.
    private func survivingNeighbor(afterDeleting ids: [SessionID]) -> SessionID? {
        let deleted = Set(ids)
        if let parent = rows.first(where: { row in row.subagents.contains { deleted.contains($0.id) } }),
           !deleted.contains(parent.id) {
            return parent.id
        }
        let deletedRows = rows.indices.filter { deleted.contains(rows[$0].id) }
        guard let first = deletedRows.first, let last = deletedRows.last else { return nil }
        if let after = rows.indices.first(where: { $0 > last && !deleted.contains(rows[$0].id) }) {
            return rows[after].id
        }
        if let before = rows.indices.last(where: { $0 < first && !deleted.contains(rows[$0].id) }) {
            return rows[before].id
        }
        return nil
    }

    /// Right-click follows the Finder convention: outside the selection it
    /// moves the selection to the clicked target first; inside it, the menu
    /// acts on the whole selection.
    private func contextMenu(rowIndex: Int, region: SessionListCellView.Region) -> NSMenu? {
        guard rows.indices.contains(rowIndex) else { return nil }
        let row = rows[rowIndex]
        switch region {
        case let .subagentLine(id):
            if store.selectedIDs != [id] { select(id) }
        case .body, .disclosure:
            if !store.selectedIDs.contains(row.id) { select(row.id) }
        }
        let count = store.selectedIDs.count
        guard count > 0 else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(
            title: count > 1 ? "Delete \(count) Sessions" : "Delete Session",
            action: #selector(deleteFromContextMenu),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func deleteFromContextMenu() {
        deleteSelectedSessions()
    }

    private func setExpanded(_ expanded: Bool, at rowIndex: Int, animated: Bool) {
        var row = rows[rowIndex]
        guard !row.subagents.isEmpty else { return }
        expandedOverrides[row.id] = expanded
        row.isExpanded = expanded
        rows[rowIndex] = row
        rowSelections[rowIndex] = selectionState(for: row)
        let indexes = IndexSet(integer: rowIndex)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? DesignSystem.SessionList.chevronAnimation : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            table.noteHeightOfRows(withIndexesChanged: indexes)
        }
        if let cell = table.view(atColumn: 0, row: rowIndex, makeIfNecessary: false) as? SessionListCellView {
            cell.configure(with: row, selection: rowSelections[rowIndex])
        }
        refreshHoverFromPointer()
    }

    // MARK: Hover

    /// Applies the hover wash to the cell under `tablePoint` (table
    /// coordinates; `nil` clears), clearing the one that had it.
    private func updateHover(at tablePoint: NSPoint?) {
        var newRow = -1
        if let tablePoint, table.visibleRect.contains(tablePoint) {
            newRow = table.row(at: tablePoint)
        }
        if hoverRow != newRow, hoverRow >= 0, hoverRow < table.numberOfRows,
           let previous = table.view(atColumn: 0, row: hoverRow, makeIfNecessary: false) as? SessionListCellView {
            previous.setHoverLocation(nil)
        }
        hoverRow = newRow
        guard newRow >= 0, let tablePoint,
              let cell = table.view(atColumn: 0, row: newRow, makeIfNecessary: false) as? SessionListCellView else { return }
        cell.setHoverLocation(cell.convert(tablePoint, from: table))
    }

    @objc private func clipViewBoundsChanged() {
        refreshHoverFromPointer()
    }

    /// Re-derives hover from the real pointer position — after scrolling
    /// moved the rows under it, or after a reconfigure reset a cell's hover.
    private func refreshHoverFromPointer() {
        guard let window = view.window else { return }
        let tablePoint = table.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        updateHover(at: tablePoint)
    }

    private func refreshRelativeTimes() {
        guard isViewLoaded, table.numberOfRows > 0 else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location ..< visible.location + visible.length {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SessionListCellView else { continue }
            cell.refreshRelativeTimes()
        }
    }

    // MARK: Data

    private func reload() {
        guard isViewLoaded else { return }

        // Newest created first (creation time is stable, so activity never
        // shuffles the rows); a session whose tier changed loses any manual
        // expansion override and falls back to the tier default.
        let sorted = SessionListModel.ordered(store.sessions)
        var tones: [SessionID: SessionStatusTone] = [:]
        for session in sorted { tones[session.id] = session.statusTone }
        for (id, tone) in tones {
            guard let previous = lastTones[id],
                  SessionListModel.defaultDisclosureChanged(from: previous, to: tone) else { continue }
            expandedOverrides.removeValue(forKey: id)
        }
        lastTones = tones
        expandedOverrides = expandedOverrides.filter { tones[$0.key] != nil }

        let overrides = expandedOverrides
        let updated = SessionListModel.rows(
            sessions: sorted,
            filter: filterText,
            modelStamps: store.modelStamps,
            isExpanded: { id, tone in overrides[id] ?? SessionListModel.expandsByDefault(tone) }
        )

        emptyLabel.stringValue = filterText.isEmpty ? "No Sessions" : "No matching Sessions"
        emptyLabel.isHidden = !updated.isEmpty

        let updatedSelections = updated.map { selectionState(for: $0) }

        if rows.map(Self.structureKey) == updated.map(Self.structureKey) {
            // Same rows and heights: reconfigure changed blocks in place —
            // never through `reloadData`, which would recreate the cells and
            // restart the status dots' breathing.
            var changed = IndexSet()
            for index in updated.indices
                where updated[index] != rows[index] || updatedSelections[index] != rowSelections[index] {
                changed.insert(index)
            }
            rows = updated
            rowSelections = updatedSelections
            for index in changed {
                guard let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? SessionListCellView else { continue }
                cell.configure(with: updated[index], selection: updatedSelections[index])
            }
        } else {
            rows = updated
            rowSelections = updatedSelections
            table.reloadData()
            hoverRow = -1
        }
        syncTableSelection()
        // Reconfigures reset cell hover; put it back where the pointer is.
        refreshHoverFromPointer()
    }

    private func applySelections() {
        let updated = rows.map { selectionState(for: $0) }
        var changed = IndexSet()
        for index in rows.indices where updated[index] != rowSelections[index] {
            changed.insert(index)
        }
        rowSelections = updated
        for index in changed {
            guard let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? SessionListCellView else { continue }
            cell.configure(with: rows[index], selection: updated[index])
        }
        syncTableSelection()
        refreshHoverFromPointer()
    }

    /// The table's own selection mirrors the session-level state (row-view
    /// wash, accessibility); a subagent-line selection leaves it empty.
    private func syncTableSelection() {
        let indexes = IndexSet(rowSelections.indices.filter { rowSelections[$0] == .session })
        guard table.selectedRowIndexes != indexes else { return }
        if indexes.isEmpty {
            table.deselectAll(nil)
        } else {
            table.selectRowIndexes(indexes, byExtendingSelection: false)
        }
    }

    private func selectionState(for row: SessionListRowModel) -> SessionListCellView.SelectionState {
        let selected = store.selectedIDs
        guard !selected.isEmpty else { return .none }
        if selected.contains(row.id) { return .session }
        // A selected subagent line highlights only while visible; the parent
        // block never highlights in its place (two-level, mutually exclusive).
        if row.isExpanded, let line = row.subagents.first(where: { selected.contains($0.id) }) {
            return .subagent(line.id)
        }
        return .none
    }

    /// Row identity and height inputs; equal keys mean `reloadData` can be
    /// skipped in favour of per-row reloads.
    private static func structureKey(of row: SessionListRowModel) -> String {
        "\(row.id.rawValue)|\(row.isExpanded ? row.subagents.count : 0)"
    }
}

// MARK: - Table

/// Routes clicks through the cell's region classification (selection is
/// painted by the cell, so the table's own selection machinery stays off)
/// and arrow keys to the controller.
@MainActor
final class SessionListTableView: NSTableView {
    enum Key {
        case up, down, left, right, delete
    }

    var onHit: ((Int, SessionListCellView.Region, NSEvent.ModifierFlags) -> Void)?
    var onKey: ((Key, NSEvent.ModifierFlags) -> Bool)?
    var onSelectAll: (() -> Void)?
    /// Menu for a right-clicked row region; nil shows no menu.
    var onContextMenu: ((Int, SessionListCellView.Region) -> NSMenu?)?
    /// Pointer position in table coordinates; `nil` when it left the table.
    var onHover: ((NSPoint?) -> Void)?

    private var hoverTrackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let rowIndex = row(at: point)
        guard rowIndex >= 0,
              let cell = view(atColumn: 0, row: rowIndex, makeIfNecessary: false) as? SessionListCellView else {
            return
        }
        window?.makeFirstResponder(self)
        onHit?(rowIndex, cell.region(at: cell.convert(point, from: self)), event.modifierFlags)
    }

    /// Right-click routes through the same region classification as clicks;
    /// the controller decides selection and builds the menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let rowIndex = row(at: point)
        guard rowIndex >= 0,
              let cell = view(atColumn: 0, row: rowIndex, makeIfNecessary: false) as? SessionListCellView else {
            return nil
        }
        window?.makeFirstResponder(self)
        return onContextMenu?(rowIndex, cell.region(at: cell.convert(point, from: self)))
    }

    // ⌘A arrives via the Edit menu's Select All through the responder
    // chain; the keyDown branch below covers the table when no menu item
    // claims the key.
    override func selectAll(_ sender: Any?) {
        onSelectAll?()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            onSelectAll?()
            return
        }
        // No menu item claims ⌘⌫, so it arrives here. Deletion requires the
        // deliberate ⌘ — a bare ⌫ must never destroy sessions.
        let key: Key? = switch event.specialKey {
        case .upArrow?: .up
        case .downArrow?: .down
        case .leftArrow?: .left
        case .rightArrow?: .right
        case .delete?, .deleteForward?, .backspace?:
            event.modifierFlags.contains(.command) ? .delete : nil
        default: nil
        }
        if let key, onKey?(key, event.modifierFlags) == true { return }
        super.keyDown(with: event)
    }
}

/// Row container: transparent background, and a selected session paints the
/// §4.4b wash — full-width, square, flush with the column edges. Text keeps
/// its normal colours when selected.
@MainActor
private final class PlainRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        Design.Color.selection.setFill()
        bounds.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // Transparent rows; the enclosing column paints the surface.
    }
}

// MARK: - Cell

/// One session block. Flipped, manually laid out from the §4.4b constants;
/// paints its own hover and selection washes under the content.
@MainActor
final class SessionListCellView: NSView {
    typealias SL = DesignSystem.SessionList

    enum SelectionState: Equatable {
        case none
        /// Full-width square wash over the whole block.
        case session
        /// Rounded wash over one subagent line.
        case subagent(SessionID)
    }

    enum Region: Equatable {
        case body
        case disclosure
        case subagentLine(SessionID)
    }

    private enum HoverTarget: Equatable {
        case block
        case subagentLine(Int)
    }

    private static let contentLeft = SL.rowHorizontalPadding + SL.dotColumnWidth + SL.columnGap
    private static let titleCenterY = SL.rowVerticalPadding + SL.titleLineHeight / 2
    private static let subtitleTop = SL.rowVerticalPadding + SL.titleLineHeight + SL.lineGap
    private static let subtitleCenterY = subtitleTop + SL.subtitleLineHeight / 2
    private static let separatorY = subtitleTop + SL.subtitleLineHeight + SL.subagentGroupTopMargin
    private static let firstLineY = separatorY + 1 + SL.subagentGroupTopPadding
    static let collapsedHeight = SL.rowVerticalPadding * 2 + SL.titleLineHeight + SL.lineGap + SL.subtitleLineHeight

    static func height(for row: SessionListRowModel) -> CGFloat {
        guard row.isExpanded, !row.subagents.isEmpty else { return collapsedHeight }
        return firstLineY + CGFloat(row.subagents.count) * SL.subagentLineHeight + SL.rowVerticalPadding
    }

    private let statusDot = StatusDotView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let agentIcon = NSImageView()
    private let modelLabel = NSTextField(labelWithString: "")
    private let effortLabel = NSTextField(labelWithString: "")
    private let cluster = SubagentClusterView()
    private var lineViews: [SubagentLineView] = []

    private var model: SessionListRowModel?
    private var selection: SelectionState = .none
    private var hover: HoverTarget?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        titleLabel.font = Design.Font.rowTitle
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true

        timeLabel.font = Design.Font.mono
        timeLabel.textColor = NSColor(SL.subtitleText)
        timeLabel.toolTip = "Last update"

        agentIcon.imageScaling = .scaleProportionallyUpOrDown

        for label in [modelLabel, effortLabel] {
            label.font = Design.Font.caption
            label.textColor = NSColor(SL.subtitleText)
            label.usesSingleLineMode = true
        }
        modelLabel.lineBreakMode = .byTruncatingTail

        // The dot keeps its internal size constraints; its frame starts at
        // exactly that size so the autoresizing-mask constraints agree.
        statusDot.setFrameSize(NSSize(
            width: DesignSystem.StatusDot.size,
            height: DesignSystem.StatusDot.size
        ))

        for subview in [statusDot, titleLabel, timeLabel, agentIcon, modelLabel, effortLabel, cluster] {
            addSubview(subview)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    // The content-list column is a vibrancy context; the row's inks are
    // fixed design values and must not be tinted by it.
    override var allowsVibrancy: Bool { false }

    func configure(with row: SessionListRowModel, selection: SelectionState) {
        model = row
        self.selection = selection
        // A recycled cell must not inherit the previous row's hover; the
        // controller re-applies the current pointer position afterwards.
        hover = nil

        titleLabel.stringValue = row.title
        titleLabel.toolTip = row.title
        titleLabel.textColor = row.tone == .gray ? NSColor(SL.completedTitle) : Design.Color.inkPrimary

        statusDot.configure(row.tone.lightStyle.dot)
        statusDot.toolTip = row.status

        agentIcon.image = AgentIcons.image(for: row.agent, pointSize: SL.agentIcon)
        agentIcon.toolTip = row.agentName

        modelLabel.stringValue = row.model ?? row.reasoningEffort ?? ""
        modelLabel.toolTip = row.model
        // The CLI reported no effort: the separator goes with it.
        effortLabel.stringValue = row.model != nil && row.reasoningEffort != nil
            ? " · \(row.reasoningEffort ?? "")"
            : ""

        cluster.isHidden = row.subagents.isEmpty
        if !row.subagents.isEmpty {
            cluster.configure(
                tones: row.clusterTones,
                expanded: row.isExpanded,
                label: row.subagentSummaryLabel
            )
        }

        let visibleLines = row.isExpanded ? row.subagents : []
        while lineViews.count > visibleLines.count {
            lineViews.removeLast().removeFromSuperview()
        }
        while lineViews.count < visibleLines.count {
            let line = SubagentLineView()
            addSubview(line)
            lineViews.append(line)
        }
        for (line, view) in zip(visibleLines, lineViews) {
            view.configure(with: line)
        }

        refreshRelativeTimes()
        needsLayout = true
        needsDisplay = true
    }

    func refreshRelativeTimes() {
        guard let model else { return }
        timeLabel.stringValue = SessionRelativeTimeFormatter.string(from: model.lastActivityAt)
        for (line, view) in zip(model.isExpanded ? model.subagents : [], lineViews) {
            view.refreshDuration(line)
        }
        needsLayout = true
    }

    /// What a click at `point` (cell coordinates) means.
    func region(at point: NSPoint) -> Region {
        guard let model else { return .body }
        if !cluster.isHidden {
            // The whole dots + chevron cluster toggles; give it a slop.
            let hit = cluster.frame.insetBy(dx: -SL.subtitleGap, dy: -SL.lineGap)
            if hit.contains(point) { return .disclosure }
        }
        if model.isExpanded {
            for (index, view) in lineViews.enumerated() where view.frame.contains(point) {
                return .subagentLine(model.subagents[index].id)
            }
        }
        return .body
    }

    override func layout() {
        super.layout()
        guard model != nil else { return }
        let rightEdge = bounds.width - SL.rowHorizontalPadding

        // Title line: dot column, title, relative time (never squeezed).
        statusDot.frame = NSRect(
            x: SL.rowHorizontalPadding + (SL.dotColumnWidth - DesignSystem.StatusDot.size) / 2,
            y: Self.titleCenterY - DesignSystem.StatusDot.size / 2,
            width: DesignSystem.StatusDot.size,
            height: DesignSystem.StatusDot.size
        )
        let timeSize = timeLabel.measuredSize
        let timeX = rightEdge - timeSize.width
        timeLabel.frame = NSRect(
            x: timeX,
            y: Self.titleCenterY - timeSize.height / 2,
            width: timeSize.width,
            height: timeSize.height
        )
        let titleHeight = titleLabel.measuredSize.height
        titleLabel.frame = NSRect(
            x: Self.contentLeft,
            y: Self.titleCenterY - titleHeight / 2,
            width: max(0, timeX - SL.columnGap - Self.contentLeft),
            height: titleHeight
        )

        // Subtitle line: icon, model (truncates first), effort, cluster.
        agentIcon.frame = NSRect(
            x: Self.contentLeft,
            y: Self.subtitleCenterY - SL.agentIcon / 2,
            width: SL.agentIcon,
            height: SL.agentIcon
        )
        let clusterSize = cluster.isHidden ? .zero : cluster.intrinsicContentSize
        cluster.frame = NSRect(
            x: rightEdge - clusterSize.width,
            y: Self.subtitleTop,
            width: clusterSize.width,
            height: SL.subtitleLineHeight
        )
        var textX = Self.contentLeft + SL.agentIcon + SL.subtitleGap
        let textLimit = cluster.isHidden ? rightEdge : cluster.frame.minX - SL.subtitleGap
        let effortSize = effortLabel.measuredSize
        let modelSize = modelLabel.measuredSize
        let modelWidth = min(modelSize.width, max(0, textLimit - textX - effortSize.width))
        modelLabel.frame = NSRect(
            x: textX,
            y: Self.subtitleCenterY - modelSize.height / 2,
            width: modelWidth,
            height: modelSize.height
        )
        textX += modelWidth
        effortLabel.frame = NSRect(
            x: textX,
            y: Self.subtitleCenterY - effortSize.height / 2,
            width: min(effortSize.width, max(0, textLimit - textX)),
            height: effortSize.height
        )

        // Subagent lines.
        for (index, view) in lineViews.enumerated() {
            view.frame = NSRect(
                x: Self.contentLeft,
                y: Self.firstLineY + CGFloat(index) * SL.subagentLineHeight,
                width: max(0, rightEdge - Self.contentLeft),
                height: SL.subagentLineHeight
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let model else { return }

        // Block hover wash (the selected wash is the row view's). Hovering a
        // selected block would be invisible anyway — the two greys are near
        // identical — so it is skipped rather than stacked.
        if selection != .session, hover != nil {
            NSColor(SL.hover).setFill()
            bounds.fill()
        }

        // Line washes: rounded, grown 4 to each side.
        if model.isExpanded {
            let selectedLineID: SessionID? = if case let .subagent(id) = selection { id } else { nil }
            for (index, line) in model.subagents.enumerated() {
                let isSelected = line.id == selectedLineID
                let isHovered = hover == .subagentLine(index)
                guard isSelected || isHovered else { continue }
                let lineRect = NSRect(
                    x: Self.contentLeft - SL.subagentSelectionOutset,
                    y: Self.firstLineY + CGFloat(index) * SL.subagentLineHeight,
                    width: bounds.width - SL.rowHorizontalPadding - Self.contentLeft + SL.subagentSelectionOutset * 2,
                    height: SL.subagentLineHeight
                )
                let path = NSBezierPath(
                    roundedRect: lineRect,
                    xRadius: SL.subagentSelectionRadius,
                    yRadius: SL.subagentSelectionRadius
                )
                if isSelected {
                    Design.Color.selection.setFill()
                    path.fill()
                }
                if isHovered {
                    NSColor(SL.hover).setFill()
                    path.fill()
                }
            }

            // Group separator above the first line.
            let separator = NSRect(
                x: Self.contentLeft,
                y: Self.separatorY,
                width: max(0, bounds.width - SL.rowHorizontalPadding - Self.contentLeft),
                height: 1
            )
            NSColor(SL.subagentGroupSeparator).setFill()
            separator.fill()
        }
    }

    // MARK: Hover

    /// Hover is driven centrally by the controller (one tracking area on the
    /// table, re-evaluated on scroll) — per-cell tracking areas miss the
    /// exits while cells move under a stationary pointer, leaving stale
    /// washes behind. `nil` clears; a point (cell coordinates) picks the
    /// block or the subagent line under it.
    func setHoverLocation(_ point: NSPoint?) {
        guard let point, bounds.contains(point) else {
            setHover(nil)
            return
        }
        if case let .subagentLine(id) = region(at: point),
           let index = model?.subagents.firstIndex(where: { $0.id == id }) {
            setHover(.subagentLine(index))
        } else {
            setHover(.block)
        }
    }

    private func setHover(_ target: HoverTarget?) {
        guard target != hover else { return }
        hover = target
        needsDisplay = true
    }
}

// MARK: - Subagent cluster (stacked dots + chevron)

/// Right end of the subtitle: up to five 9px status dots ringed in
/// near-white, overlapping 3 from the second on, then the `chevron.down`
/// that turns 180° when the group opens. The whole cluster is the toggle
/// target; counts and buckets live in the tooltip.
@MainActor
private final class SubagentClusterView: NSView {
    private typealias SL = DesignSystem.SessionList

    /// The symbol pre-tinted in the chevron ink, so it can live as plain
    /// layer contents (a self-owned layer rotates cleanly; AppKit fights
    /// anchor-point rotation on view-backing layers).
    private static let chevronImage: NSImage? = {
        guard let symbol = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Toggle subagents")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(
                pointSize: SL.chevronSymbolSize,
                weight: .bold
            )) else { return nil }
        return NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor(SL.chevronStroke).set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }()

    private var tones: [SessionStatusTone] = []
    private var expanded = false
    private let chevron = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        if let image = Self.chevronImage {
            chevron.contents = image
            chevron.bounds = CGRect(origin: .zero, size: image.size)
        }
        chevron.contentsGravity = .resizeAspect
        chevron.contentsScale = 2
        layer?.addSublayer(chevron)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    override var intrinsicContentSize: NSSize {
        let count = min(tones.count, SL.stackedDotMaximum)
        let dotsWidth = count == 0
            ? 0
            : SL.stackedDot + CGFloat(count - 1) * (SL.stackedDot - SL.stackedDotOverlap)
        return NSSize(
            width: dotsWidth + SL.clusterGap + SL.chevronSlot,
            height: SL.subtitleLineHeight
        )
    }

    func configure(tones: [SessionStatusTone], expanded: Bool, label: String) {
        let animated = expanded != self.expanded && window != nil
        self.tones = tones
        self.expanded = expanded
        toolTip = label
        invalidateIntrinsicContentSize()
        needsDisplay = true
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? SL.chevronAnimation : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        chevron.transform = expanded
            ? CATransform3DMakeRotation(.pi, 0, 0, 1)
            : CATransform3DIdentity
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.position = CGPoint(
            x: bounds.width - SL.chevronSlot / 2,
            y: bounds.height / 2
        )
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let shown = tones.prefix(SL.stackedDotMaximum)
        let step = SL.stackedDot - SL.stackedDotOverlap
        let y = (bounds.height - SL.stackedDot) / 2
        for (index, tone) in shown.enumerated() {
            let x = CGFloat(index) * step
            let dotRect = NSRect(x: x, y: y, width: SL.stackedDot, height: SL.stackedDot)
            NSColor(SL.stackedDotRingColor).setFill()
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -SL.stackedDotRing, dy: -SL.stackedDotRing)).fill()
            NSColor(tone.lightStyle.dot.color).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }
}

// MARK: - Subagent line

private extension NSTextField {
    /// Text measurement for manual layout. `intrinsicContentSize` runs a few
    /// points narrow for truncating labels and produces spurious ellipses;
    /// the cell's own measurement does not.
    var measuredSize: NSSize {
        guard let cell else { return intrinsicContentSize }
        var size = cell.cellSize
        size.width = ceil(size.width)
        size.height = ceil(size.height)
        return size
    }
}

/// One expanded subagent: 6px solid dot, name, its duration (ticking while
/// live, frozen once its displayed lifecycle ends).
@MainActor
private final class SubagentLineView: NSView {
    private typealias SL = DesignSystem.SessionList

    private let dot = StatusDotView(size: SL.subagentDot, haloWidth: 0)
    private let nameLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        nameLabel.font = Design.Font.body
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.usesSingleLineMode = true
        timeLabel.font = Design.Font.mono
        timeLabel.textColor = NSColor(SL.subtitleText)
        timeLabel.toolTip = "Duration"
        dot.setFrameSize(NSSize(width: SL.subagentDot, height: SL.subagentDot))
        for subview in [dot, nameLabel, timeLabel] {
            addSubview(subview)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    func configure(with line: SessionListRowModel.SubagentLine) {
        nameLabel.stringValue = line.title
        nameLabel.toolTip = line.title
        nameLabel.textColor = line.tone == .gray
            ? NSColor(SL.completedTitle)
            : Design.Color.inkPrimary
        var style = line.tone.lightStyle.dot
        // Line dots are plain colour: solid, no halo, no breathing.
        style.form = .solid
        dot.configure(style)
        dot.toolTip = line.status
        refreshDuration(line)
        needsLayout = true
    }

    func refreshDuration(_ line: SessionListRowModel.SubagentLine) {
        timeLabel.stringValue = SessionElapsedFormatter.string(
            from: (line.endedAt ?? Date()).timeIntervalSince(line.startedAt)
        )
        needsLayout = true
    }

    override func layout() {
        super.layout()
        dot.frame = NSRect(
            x: 0,
            y: (bounds.height - SL.subagentDot) / 2,
            width: SL.subagentDot,
            height: SL.subagentDot
        )
        let timeSize = timeLabel.measuredSize
        let timeX = bounds.width - timeSize.width
        timeLabel.frame = NSRect(
            x: timeX,
            y: (bounds.height - timeSize.height) / 2,
            width: timeSize.width,
            height: timeSize.height
        )
        let nameX = SL.subagentDot + SL.subagentLineGap
        let nameHeight = nameLabel.measuredSize.height
        nameLabel.frame = NSRect(
            x: nameX,
            y: (bounds.height - nameHeight) / 2,
            width: max(0, timeX - SL.subagentLineGap - nameX),
            height: nameHeight
        )
    }
}
