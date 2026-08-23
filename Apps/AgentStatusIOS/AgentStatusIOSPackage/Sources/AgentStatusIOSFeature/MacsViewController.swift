import AgentStatusCore
import AgentStatusDesignSystem
import AgentStatusRemote
import AgentStatusTransport
import UIKit

/// Macs tab (design 1g): the paired Macs, each with its online state and the
/// Relay it is reached through. Swipe to remove a channel; `+` adds a Mac
/// (code or scan, in one sheet) or renames this iPhone.
@MainActor
final class MacsViewController: UIViewController, UICollectionViewDelegate {
    private enum Section { case paired }

    private let relay: RelayDeviceController
    private let settings: LocalSettings
    private let onShowSessions: (HostID) -> Void
    private let onAddDevice: () -> Void
    private var observer: UUID?
    private var states: [MacChannelState] = []
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private lazy var dataSource = makeDataSource()
    private let emptyLabel = UILabel()

    init(
        relay: RelayDeviceController,
        settings: LocalSettings,
        onShowSessions: @escaping (HostID) -> Void,
        onAddDevice: @escaping () -> Void
    ) {
        self.relay = relay
        self.settings = settings
        self.onShowSessions = onShowSessions
        self.onAddDevice = onAddDevice
        super.init(nibName: nil, bundle: nil)
        title = "Macs"
        tabBarItem = UITabBarItem(title: "Macs", image: UIImage(systemName: "laptopcomputer"), tag: 1)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .inline
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            menu: UIMenu(children: [
                UIAction(title: "Add Device", image: UIImage(systemName: "laptopcomputer")) { [weak self] _ in
                    self?.onAddDevice()
                },
                UIAction(title: "Rename this iPhone", image: UIImage(systemName: "pencil")) { [weak self] _ in
                    self?.rename()
                },
            ])
        )
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .design(IOSDS.Typography.body)
        emptyLabel.text = "No Macs paired\nTap + › Add Device and enter the 6-character code from Lumi › Pair an iPhone on your Mac."
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        let background = UIView()
        background.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: background.leadingAnchor, constant: IOSDS.Layout.groupFooterInset),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -IOSDS.Layout.groupFooterInset),
        ])
        collectionView.backgroundView = background
        _ = dataSource
        observer = relay.observe { [weak self] in self?.reload() }
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        states = relay.channelStates
        emptyLabel.isHidden = !states.isEmpty
        var snapshot = NSDiffableDataSourceSnapshot<Section, HostID>()
        if !states.isEmpty {
            snapshot.appendSections([.paired])
            snapshot.appendItems(states.map(\.hostID))
            snapshot.reconfigureItems(states.map(\.hostID).filter { id in dataSource.snapshot().itemIdentifiers.contains(id) })
        }
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    }

    private func makeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.footerMode = .supplementary
        configuration.backgroundColor = .clear
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let hostID = dataSource.itemIdentifier(for: indexPath) else { return nil }
            let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, completion in
                self?.confirmRemove(hostID: hostID, completion: completion)
            }
            remove.image = UIImage(systemName: "trash")
            return UISwipeActionsConfiguration(actions: [remove])
        }
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Section, HostID> {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, HostID> { [weak self] cell, _, hostID in
            guard let self, let state = states.first(where: { $0.hostID == hostID }) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = state.displayName
            content.textProperties.font = .design(IOSDS.Typography.listTitle)
            content.secondaryText = Self.meta(for: state, now: Date())
            content.secondaryTextProperties.font = .design(DesignSystem.Pairing.IOS.macRowSubtitle)
            content.secondaryTextProperties.color = .inkTertiary
            content.secondaryTextProperties.numberOfLines = 1
            content.secondaryTextProperties.lineBreakMode = .byTruncatingTail
            content.textToSecondaryTextVerticalPadding = IOSDS.MacRow.lineGap
            content.image = UIImage(systemName: "laptopcomputer")
            content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            content.imageProperties.tintColor = UIColor(state.isOnline ? IOSDS.Color.macIconOnline : IOSDS.Color.macIconOffline)
            content.imageToTextPadding = IOSDS.MacRow.gap
            content.directionalLayoutMargins.top = IOSDS.MacRow.verticalPadding
            content.directionalLayoutMargins.bottom = IOSDS.MacRow.verticalPadding
            cell.contentConfiguration = content
            cell.accessories = [
                .dot(state.isOnline ? UIColor(IOSDS.Color.systemGreen) : UIColor(IOSDS.Color.inactiveDot)),
                .disclosureIndicator(),
            ]
            var background = UIBackgroundConfiguration.listGroupedCell()
            background.backgroundColor = .secondarySystemGroupedBackground
            cell.backgroundConfiguration = background
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { view, _, _ in
            var content = UIListContentConfiguration.plainHeader()
            content.text = "Paired"
            content.textProperties.font = .design(IOSDS.Typography.captionEmphasized)
            content.textProperties.color = .inkTertiary
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: 0, leading: IOSDS.Layout.groupHeaderInset - IOSDS.Layout.cardMargin, bottom: IOSDS.Layout.groupHeaderGap, trailing: 0
            )
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { view, _, _ in
            var content = UIListContentConfiguration.plainFooter()
            content.text = "左滑移除某台 Mac 只关闭这一条通道，其他设备不受影响。凭据保存在 Keychain，每台 Mac 各自记着自己的 Relay。"
            content.textProperties.font = .design(IOSDS.Typography.caption)
            content.textProperties.color = .inkTertiary
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: IOSDS.Layout.groupHeaderGap,
                leading: IOSDS.Layout.groupFooterInset - IOSDS.Layout.cardMargin,
                bottom: IOSDS.Layout.groupGap,
                trailing: IOSDS.Layout.groupFooterInset - IOSDS.Layout.cardMargin
            )
            view.contentConfiguration = content
        }
        let dataSource = UICollectionViewDiffableDataSource<Section, HostID>(collectionView: collectionView) { collectionView, indexPath, hostID in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: hostID)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
        return dataSource
    }

    /// `Online · relay.lumi.huanan.app` / `Offline · 2h ago · relay.lumi.huanan.app`
    /// / `Revoked · relay.lumi.huanan.app`: the state, then which Relay this Mac
    /// is reached through (each Mac remembers its own).
    static func meta(for state: MacChannelState, now: Date) -> String {
        let relayHost = RelayURLValidation.displayHost(state.relayURL)
        if state.accessRevoked {
            return "Revoked · \(relayHost)"
        }
        if state.isOnline {
            return "Online · \(relayHost)"
        }
        if let lastSync = state.lastSyncAt {
            return "Offline · \(SessionRelativeTimeFormatter.string(from: lastSync, now: now)) ago · \(relayHost)"
        }
        return "Offline · \(relayHost)"
    }

    // MARK: - Actions

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let hostID = dataSource.itemIdentifier(for: indexPath) else { return }
        onShowSessions(hostID)
    }

    private func confirmRemove(hostID: HostID, completion: @escaping (Bool) -> Void) {
        let name = states.first { $0.hostID == hostID }?.displayName ?? "this Mac"
        let alert = UIAlertController(
            title: "Remove \(name)?",
            message: "Only this iPhone's channel is removed. The Mac keeps its pairing record until you revoke it there.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            self?.relay.unpair(hostID: hostID)
            completion(true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false) })
        present(alert, animated: true)
    }

    private func rename() {
        let alert = UIAlertController(
            title: "Rename this iPhone",
            message: "The name a Mac sees when you pair with it next.",
            preferredStyle: .alert
        )
        alert.addTextField { [settings] field in
            field.text = settings.deviceName
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            self?.settings.deviceName = alert?.textFields?.first?.text ?? ""
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}
