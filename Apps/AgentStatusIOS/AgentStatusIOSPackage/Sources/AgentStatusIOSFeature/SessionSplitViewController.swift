import AgentStatusCore
import AgentStatusDesignSystem
import AgentStatusTransport
import UIKit

@MainActor
final class SessionSplitViewController: UISplitViewController, UITableViewDataSource, UITableViewDelegate, UISplitViewControllerDelegate {
    private let relay: RelayDeviceController
    private let listController = UITableViewController(style: .insetGrouped)
    private let detailController = TimelineViewController()
    private var selectedHostID: HostID?

    init(relay: RelayDeviceController) {
        self.relay = relay
        super.init(style: .doubleColumn)
        delegate = self
        preferredDisplayMode = .oneBesideSecondary
        listController.title = "Agent Status"
        listController.tableView.dataSource = self
        listController.tableView.delegate = self
        listController.navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Pair",
            style: .plain,
            target: self,
            action: #selector(pairDevice)
        )
        setViewController(UINavigationController(rootViewController: listController), for: .primary)
        setViewController(UINavigationController(rootViewController: detailController), for: .secondary)
        relay.onChange = { [weak self] in self?.reload() }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func splitViewController(
        _ svc: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        .primary
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard !relay.channelStates.isEmpty else { return 1 }
        return max(relay.channelStates[section].sessions.count, 1)
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        max(relay.channelStates.count, 1)
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard section < relay.channelStates.count else { return nil }
        let channel = relay.channelStates[section]
        let status = channel.isConnected && channel.isHostOnline ? "Online" : "Unavailable"
        return "\(channel.displayName) · \(status)"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard indexPath.section < relay.channelStates.count else {
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            cell.textLabel?.text = "Pair with a Mac"
            cell.detailTextLabel?.text = "Scan the pairing code shown by Agent Status on macOS."
            cell.selectionStyle = .none
            return cell
        }
        let channel = relay.channelStates[indexPath.section]
        guard indexPath.row < channel.sessions.count else {
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            cell.textLabel?.text = channel.isConnected && channel.isHostOnline
                ? "No live sessions"
                : "Mac unavailable"
            cell.detailTextLabel?.text = channel.lastError ?? "Waiting to sync from this Mac."
            cell.selectionStyle = .none
            return cell
        }
        let session = channel.sessions[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = session.summary.title
        cell.textLabel?.font = .design(DesignSystem.Typography.listTitle)
        cell.detailTextLabel?.text = "\(session.summary.lifecycle.rawValue) · \(session.summary.phase.rawValue)"
        cell.detailTextLabel?.font = .design(DesignSystem.Typography.caption)
        cell.accessoryType = .disclosureIndicator
        let tone = session.summary.statusTone
        cell.imageView?.image = UIImage(systemName: tone == .red ? "exclamationmark.circle.fill" : "circle.fill")
        cell.imageView?.tintColor = tone.uiKitColor
        // Completed reads as tertiary ink; every other tier keeps its colour.
        cell.detailTextLabel?.textColor = tone == .gray
            ? UIColor(AdaptiveDesignColor(light: DesignSystem.Ink.tertiary, dark: DesignSystem.InkDark.tertiary))
            : tone.uiKitColor
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard indexPath.section < relay.channelStates.count else { return }
        let channel = relay.channelStates[indexPath.section]
        guard indexPath.row < channel.sessions.count else { return }
        selectedHostID = channel.hostID
        detailController.session = channel.sessions[indexPath.row]
        show(.secondary)
    }

    private func reload() {
        listController.navigationItem.prompt = connectionText
        listController.navigationItem.rightBarButtonItem?.title = relay.isPaired ? "Device" : "Pair"
        listController.tableView.reloadData()
        if let selectedHostID,
           let currentID = detailController.session?.summary.id,
           let channel = relay.channelStates.first(where: { $0.hostID == selectedHostID }),
           let updated = channel.sessions.first(where: { $0.summary.id == currentID }) {
            detailController.session = updated
        } else if detailController.session != nil {
            selectedHostID = nil
            detailController.session = nil
        }
    }

    @objc private func pairDevice() {
        if relay.isPaired {
            let sheet = UIAlertController(title: "Mac channels", message: connectionText, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "Add another Mac", style: .default) { [weak self] _ in self?.presentScanner() })
            for channel in relay.channelStates {
                sheet.addAction(UIAlertAction(title: "Remove \(channel.displayName)", style: .destructive) { [weak self] _ in
                    self?.relay.unpair(hostID: channel.hostID)
                })
            }
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            sheet.popoverPresentationController?.barButtonItem = listController.navigationItem.rightBarButtonItem
            listController.present(sheet, animated: true)
        } else {
            presentScanner()
        }
    }

    private func presentScanner() {
        let scanner = PairingScannerViewController()
        scanner.onOffer = { [weak self, weak scanner] offer in
            guard let self else { return }
            scanner?.setBusy(true)
            Task {
                do {
                    try await relay.pair(using: offer)
                    scanner?.dismiss(animated: true)
                } catch {
                    scanner?.setBusy(false)
                    scanner?.show(error: error)
                }
            }
        }
        listController.present(UINavigationController(rootViewController: scanner), animated: true)
    }

    private var connectionText: String {
        if !relay.isPaired { return "Not paired with a Mac" }
        let states = relay.channelStates
        let online = states.filter { $0.isConnected && $0.isHostOnline }.count
        return "\(states.count) Mac\(states.count == 1 ? "" : "s") · \(online) online"
    }
}

@MainActor
private final class TimelineViewController: UITableViewController {
    var session: SessionDetail? { didSet { title = session?.summary.title ?? "Session"; tableView.reloadData() } }

    init() { super.init(style: .insetGrouped) }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        visibleTimeline.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = visibleTimeline[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = item.payload.displayTitle
        cell.detailTextLabel?.text = item.payload.displayBody
        cell.detailTextLabel?.numberOfLines = 0
        cell.selectionStyle = .none
        return cell
    }

    private var visibleTimeline: [TimelineItem] {
        session?.timeline.filter {
            switch $0.payload {
            case .message, .reasoning, .tool, .plan, .subagent, .error, .context, .sessionMarker, .turnEnd: true
            case .unknown, .modelConfiguration, .internalContext, .usageMetrics: false
            }
        } ?? []
    }
}

private extension TimelinePayload {
    var displayTitle: String {
        switch self {
        case let .message(value): value.role == .user ? "User" : "Assistant"
        case .reasoning: "Reasoning"
        case let .context(value): value.scope == .session ? "Context · session" : "Context · \(value.kind)"
        case let .sessionMarker(value): value.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        case let .turnEnd(value): "Turn \(value.outcome.rawValue)"
        case let .tool(value): "\(value.name) · \(value.status.rawValue)"
        case .plan: "Plan"
        case let .subagent(value): "Sub-agent · \(value.name)"
        case .error: "Error"
        case .modelConfiguration: "Model configuration"
        case let .internalContext(value): "Internal context · \(value.kind)"
        case .usageMetrics: "Usage metrics"
        case let .unknown(value): value.kind
        }
    }

    var displayBody: String {
        switch self {
        case let .message(value): value.text
        case let .reasoning(value): value.text
        case let .context(value): value.summary ?? value.kind
        case let .sessionMarker(value): [value.detail, value.model].compactMap { $0 }.joined(separator: " · ")
        case let .turnEnd(value): value.message ?? ""
        case let .tool(value): value.summary ?? ""
        case let .plan(value): value.steps.map { "• \($0.text) [\($0.status.rawValue)]" }.joined(separator: "\n")
        case let .subagent(value): value.status.rawValue
        case let .error(value): "\(value.title): \(value.message)"
        case let .modelConfiguration(value):
            [value.model, value.provider, value.reasoningEffort]
                .compactMap { $0 }
                .joined(separator: " · ")
        case .internalContext: "Retained in Session data"
        case let .usageMetrics(value): "\(value.total?.totalTokens ?? value.last?.totalTokens ?? 0) tokens"
        case let .unknown(value): value.summary ?? "Unsupported event"
        }
    }
}
