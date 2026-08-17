import AppKit

@MainActor
final class NavigationSidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case section(String)
        case destination(MainWindowController.Tab, title: String, symbol: String)

        var tab: MainWindowController.Tab? {
            guard case let .destination(tab, _, _) = self else { return nil }
            return tab
        }
    }

    private let rows: [Row] = [
        .section("MONITOR"),
        .destination(.sessions, title: "Sessions", symbol: "rectangle.split.2x1"),
        .section("CONNECTIONS"),
        .destination(.pairing, title: "iPhone", symbol: "iphone.gen3.radiowaves.left.and.right"),
        .section("APPLICATION"),
        .destination(.settings, title: "Settings", symbol: "gearshape"),
    ]
    private let table = NSTableView()
    private var isSelecting = false
    private var selectedTab: MainWindowController.Tab = .sessions
    var onSelection: ((MainWindowController.Tab) -> Void)?

    override func loadView() {
        view = NSView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("navigation")))
        table.headerView = nil
        table.style = .sourceList
        table.floatsGroupRows = false
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.delegate = self
        table.dataSource = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        applySelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .section = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows[row].tab != nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows[row].tab == nil ? 28 : 38
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .section(title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case let .destination(_, title, symbol):
            let cell = NSTableCellView()
            let icon = NSImageView(image: NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: title
            ) ?? NSImage())
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            let stack = NSStackView(views: [icon, label])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 9
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18),
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSelecting,
              table.selectedRow >= 0,
              table.selectedRow < rows.count,
              let tab = rows[table.selectedRow].tab else { return }
        onSelection?(tab)
    }

    func select(_ tab: MainWindowController.Tab) {
        selectedTab = tab
        guard isViewLoaded else { return }
        applySelection()
    }

    private func applySelection() {
        guard let row = rows.firstIndex(where: { $0.tab == selectedTab }) else { return }
        isSelecting = true
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isSelecting = false
    }
}
