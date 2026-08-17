import AgentStatusTransport
import AppKit
import NookApp
import ServiceManagement
import SwiftUI

enum AgentStatusSettingsSection: Int, CaseIterable {
    case general
    case notch
    case daemon
    case agents
    case about

    var title: String {
        switch self {
        case .general: "General"
        case .notch: "Notch"
        case .daemon: "Daemon"
        case .agents: "Agents"
        case .about: "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Launch behavior"
        case .notch: "Appearance and interaction"
        case .daemon: "Local service and history"
        case .agents: "Codex integration"
        case .about: "Version and updates"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .notch: "macbook"
        case .daemon: "server.rack"
        case .agents: "terminal"
        case .about: "info.circle"
        }
    }
}

@MainActor
final class SettingsNavigationViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var isSelecting = false
    private(set) var selectedSection: AgentStatusSettingsSection = .general
    var onSelection: ((AgentStatusSettingsSection) -> Void)?

    override func loadView() {
        view = NSView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("settings"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .fullWidth
        table.rowHeight = 54
        table.intercellSpacing = .zero
        table.delegate = self
        table.dataSource = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        applySelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        AgentStatusSettingsSection.allCases.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let section = AgentStatusSettingsSection(rawValue: row) else { return nil }
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(
            systemSymbolName: section.symbol,
            accessibilityDescription: section.title
        ) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor

        let title = NSTextField(labelWithString: section.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let subtitle = NSTextField(labelWithString: section.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        let rowView = NSStackView(views: [icon, labels])
        rowView.orientation = .horizontal
        rowView.alignment = .centerY
        rowView.spacing = 10
        rowView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(rowView)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            rowView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14),
            rowView.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -12),
            rowView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSelecting,
              let section = AgentStatusSettingsSection(rawValue: table.selectedRow) else { return }
        selectedSection = section
        onSelection?(section)
    }

    func select(_ section: AgentStatusSettingsSection) {
        selectedSection = section
        guard isViewLoaded else { return }
        applySelection()
    }

    private func applySelection() {
        isSelecting = true
        table.selectRowIndexes(IndexSet(integer: selectedSection.rawValue), byExtendingSelection: false)
        isSelecting = false
    }
}

@MainActor
final class SettingsDetailViewController: NSViewController {
    private let store: MacSessionStore
    private let nook: AgentStatusNookController
    private let loginService = SMAppService.mainApp
    private let daemonService = SMAppService.agent(plistName: "com.huanan.AgentStatusDaemon.plist")

    private var selectedSection: AgentStatusSettingsSection = .general
    private var hostedController: NSViewController?
    private let loginButton = NSButton(checkboxWithTitle: "Open Agent Status at login", target: nil, action: nil)
    private let daemonStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let daemonButton = NSButton(title: "", target: nil, action: nil)
    private let hookStatusLabel = NSTextField(labelWithString: "")
    private let hookButton = NSButton(title: "", target: nil, action: nil)

    init(store: MacSessionStore, nook: AgentStatusNookController) {
        self.store = store
        self.nook = nook
        super.init(nibName: nil, bundle: nil)
        loginButton.target = self
        loginButton.action = #selector(toggleOpenAtLogin)
        daemonButton.target = self
        daemonButton.action = #selector(toggleDaemon)
        hookButton.target = self
        hookButton.action = #selector(toggleCodexHook)
        store.observe { [weak self] in
            guard self?.selectedSection == .daemon else { return }
            self?.reloadDaemonDiagnostic()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        rebuild()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reloadControls()
    }

    func select(_ section: AgentStatusSettingsSection) {
        guard selectedSection != section || !isViewLoaded else { return }
        selectedSection = section
        guard isViewLoaded else { return }
        rebuild()
    }

    private func rebuild() {
        hostedController?.removeFromParent()
        hostedController = nil
        view.subviews.forEach { $0.removeFromSuperview() }
        reloadControls()

        switch selectedSection {
        case .general:
            installAppKitContent(
                title: "General",
                subtitle: "Choose how Agent Status starts on this Mac.",
                sections: [section(title: "Startup", views: [
                    loginButton,
                    secondary("The daemon is managed independently in Daemon settings."),
                ])]
            )
        case .notch:
            installNotchSettings()
        case .daemon:
            daemonStatusLabel.maximumNumberOfLines = 3
            daemonStatusLabel.textColor = .secondaryLabelColor
            let clearButton = NSButton(title: "Clear Session history…", target: self, action: #selector(clearHistory))
            let buttons = NSStackView(views: [daemonButton, clearButton])
            buttons.orientation = .horizontal
            buttons.spacing = 8
            installAppKitContent(
                title: "Daemon",
                subtitle: "Install and diagnose the local Agent Status service.",
                sections: [section(title: "Local service", views: [
                    daemonStatusLabel,
                    buttons,
                    secondary("Session history stays in SQLite until you delete it."),
                ])]
            )
        case .agents:
            let row = NSStackView(views: [hookStatusLabel, hookButton])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            installAppKitContent(
                title: "Agents",
                subtitle: "Manage integrations that send Session events to the daemon.",
                sections: [section(title: "Codex", views: [
                    row,
                    secondary("Codex is supported in v1. Installing the integration preserves existing Hook handlers."),
                ])]
            )
        case .about:
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
            let project = NSTextField(labelWithString: "Agent Status \(version) (\(build))")
            let frameworks = secondary("AppKit main window · OpenNook notch · UIKit iPhone app")
            let updates = secondary("No automatic update channel is configured for this build.")
            let aboutButton = NSButton(title: "About Agent Status", target: self, action: #selector(showAbout))
            installAppKitContent(
                title: "About",
                subtitle: "Version, framework and update information.",
                sections: [section(title: "Agent Status", views: [project, frameworks, updates, aboutButton])]
            )
        }
    }

    private func installNotchSettings() {
        let header = detailHeader(
            title: "Notch",
            subtitle: "Configure the Notch surface, screen, size, and interaction."
        )
        let hosting = NSHostingController(rootView: AgentStatusNookSettingsView(
            appState: nook.appState,
            showNook: { [weak nook] in nook?.showNook() },
            toggleKeepOpen: { [weak nook] in nook?.toggleKeepOpen() }
        ))
        addChild(hosting)
        hostedController = hosting
        let hostedView = hosting.view
        header.translatesAutoresizingMaskIntoConstraints = false
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(hostedView)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: AgentStatusDetailLayout.horizontalInset
            ),
            header.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
                constant: -AgentStatusDetailLayout.horizontalInset
            ),
            header.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: AgentStatusDetailLayout.topInset
            ),
            hostedView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostedView.topAnchor.constraint(
                equalTo: header.bottomAnchor,
                constant: AgentStatusDetailLayout.headerToContentSpacing
            ),
            hostedView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func installAppKitContent(title: String, subtitle: String, sections: [NSView]) {
        let header = detailHeader(title: title, subtitle: subtitle)
        let arrangedViews = [header] + sections
        let stack = NSStackView(views: arrangedViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = AgentStatusDetailLayout.headerToContentSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        arrangedViews.forEach { arrangedView in
            arrangedView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: AgentStatusDetailLayout.topInset
            ),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: view.bottomAnchor,
                constant: -AgentStatusDetailLayout.bottomInset
            ),
        ] + AgentStatusDetailLayout.adaptiveWidthConstraints(for: stack, in: view))
    }

    private func detailHeader(title: String, subtitle: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func section(title: String, views: [NSView]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let contentStack = NSStackView(views: views)
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 9
        contentStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.layer?.cornerRadius = 10
        container.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: container.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let sectionStack = NSStackView(views: [heading, container])
        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = 10
        container.widthAnchor.constraint(equalTo: sectionStack.widthAnchor).isActive = true
        return sectionStack
    }

    private func secondary(_ value: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 3
        return label
    }

    private func reloadControls() {
        loginButton.state = loginService.status == .enabled ? .on : .off
        daemonButton.title = daemonService.status == .enabled ? "Stop & Uninstall daemon" : "Install & Start daemon"
        let installed = CodexHookInstaller().isInstalled()
        hookStatusLabel.stringValue = installed ? "Codex integration installed" : "Codex integration not installed"
        hookButton.title = installed ? "Remove Hook" : "Install Hook"
        reloadDaemonDiagnostic()
    }

    private func reloadDaemonDiagnostic() {
        if let health = store.health {
            let active = store.sessions.filter {
                switch $0.lifecycle {
                case .starting, .running, .waitingForInput: true
                default: false
                }
            }.count
            daemonStatusLabel.stringValue = "Running · uptime \(health.uptimeSeconds)s · \(active) active · \(store.sessions.count) stored\n\(health.socketPath)"
        } else {
            daemonStatusLabel.stringValue = "Not connected · \(store.connectionError ?? daemonServiceStatus(daemonService.status))"
        }
    }

    @objc private func toggleOpenAtLogin() {
        do {
            if loginButton.state == .on {
                try loginService.register()
            } else {
                try loginService.unregister()
            }
        } catch {
            showError(error)
        }
        reloadControls()
    }

    @objc private func toggleDaemon() {
        do {
            if daemonService.status == .enabled {
                try daemonService.unregister()
            } else {
                try daemonService.register()
            }
            store.refresh()
        } catch {
            showError(error)
        }
        reloadControls()
    }

    @objc private func toggleCodexHook() {
        do {
            let installer = CodexHookInstaller()
            if installer.isInstalled() {
                try installer.uninstall()
            } else {
                guard let helper = Bundle.main.url(forResource: "agent-status-helper", withExtension: nil) else {
                    throw CodexHookInstallerError.helperMissing
                }
                try installer.install(helperSourceURL: helper)
            }
        } catch {
            showError(error)
        }
        reloadControls()
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear Agent Status Session history?"
        alert.informativeText = "This deletes Agent Status history from the daemon and synced app databases. It does not delete Codex's own files."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clearHistory()
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    private func daemonServiceStatus(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "daemon is not installed"
        case .enabled: "daemon is registered but unavailable"
        case .requiresApproval: "approval is required in System Settings"
        case .notFound: "embedded daemon service was not found"
        @unknown default: "daemon status is unknown"
        }
    }

    private func showError(_ error: Error) {
        NSAlert(error: error).runModal()
    }
}
