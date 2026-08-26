import DesignSystem
import UIKit

/// Settings tab: push-notification permission (three states) and About
/// (version, clear received data).
@MainActor
final class SettingsViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Int, CaseIterable { case notifications, about }
    private enum Row: Hashable { case notifications, version, clear }

    private let relay: RelayDeviceController
    private let notifications: NotificationAuthorization
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private lazy var dataSource = makeDataSource()

    init(relay: RelayDeviceController, notifications: NotificationAuthorization) {
        self.relay = relay
        self.notifications = notifications
        super.init(nibName: nil, bundle: nil)
        title = "Settings"
        tabBarItem = UITabBarItem(title: "Settings", image: UIImage(systemName: "gearshape"), tag: 2)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .inline
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
        _ = dataSource
        notifications.onChange = { [weak self] in self?.reload() }
        reload()
    }

    private func reload() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.notifications, .about])
        snapshot.appendItems([.notifications], toSection: .notifications)
        snapshot.appendItems([.version, .clear], toSection: .about)
        snapshot.reconfigureItems([.notifications])
        dataSource.apply(snapshot, animatingDifferences: false)
        // Footers re-render with the permission state.
        collectionView.collectionViewLayout.invalidateLayout()
        for view in collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionFooter) {
            if let cell = view as? UICollectionViewListCell, let path = collectionView.indexPath(forSupplementaryView: cell) {
                configureFooter(cell, section: path.section)
            }
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.footerMode = .supplementary
        configuration.backgroundColor = .clear
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    private var notificationFooter: String {
        switch notifications.state {
        case .notDetermined:
            "还没请求过权限。点这一行弹出系统授权弹窗；通知由 Relay 推送，只在 Session 回合结束、失败或中断时到达。"
        case .authorized:
            "已授权。点这一行跳转 iOS 设置里的通知选项；通知由 Relay 推送，只在 Session 回合结束、失败或中断时到达。"
        case .denied:
            "已被拒绝，系统不再弹窗。点这一行跳转 iOS 设置开启；通知由 Relay 推送，只在 Session 回合结束、失败或中断时到达。"
        }
    }

    private func configureFooter(_ view: UICollectionViewListCell, section: Int) {
        var content = UIListContentConfiguration.plainFooter()
        content.text = section == Section.notifications.rawValue
            ? notificationFooter
            : "收到的 Session 内容缓存在本机（每台 Mac 一个数据库），重启后立即显示；Clear received data 清空全部缓存并自动从每台 Mac 重新取回。配对凭据保存在 Keychain。"
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

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Section, Row> {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            guard let self else { return }
            var background = UIBackgroundConfiguration.listGroupedCell()
            background.backgroundColor = .secondarySystemGroupedBackground
            cell.backgroundConfiguration = background
            cell.accessories = []
            switch row {
            case .notifications:
                var content = UIListContentConfiguration.valueCell()
                content.text = "Push notifications"
                content.textProperties.font = .design(IOSDS.Typography.listTitle)
                content.secondaryTextProperties.font = .design(IOSDS.Typography.listTitle)
                content.prefersSideBySideTextAndSecondaryText = true
                switch notifications.state {
                case .notDetermined:
                    content.secondaryText = "Allow"
                    content.secondaryTextProperties.color = .systemBlue
                case .authorized:
                    content.secondaryText = "Allowed"
                    content.secondaryTextProperties.color = .secondaryLabel
                    cell.accessories = [.dot(UIColor(IOSDS.Color.systemGreen)), .disclosureIndicator()]
                case .denied:
                    content.secondaryText = "Not allowed"
                    content.secondaryTextProperties.color = .secondaryLabel
                    cell.accessories = [.dot(UIColor(IOSDS.Color.inactiveDot)), .disclosureIndicator()]
                }
                cell.contentConfiguration = content
            case .version:
                var content = UIListContentConfiguration.valueCell()
                content.text = "Version"
                content.textProperties.font = .design(IOSDS.Typography.listTitle)
                content.secondaryText = Self.versionText
                content.secondaryTextProperties.font = .design(IOSDS.Typography.listTitleMono)
                content.secondaryTextProperties.color = .secondaryLabel
                cell.contentConfiguration = content
            case .clear:
                var content = UIListContentConfiguration.cell()
                content.text = "Clear received data"
                content.textProperties.font = .design(IOSDS.Typography.listTitle)
                content.textProperties.color = .systemRed
                cell.contentConfiguration = content
            }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { view, _, indexPath in
            var content = UIListContentConfiguration.plainHeader()
            content.text = indexPath.section == Section.notifications.rawValue ? "Notifications" : "About"
            content.textProperties.font = .design(IOSDS.Typography.captionEmphasized)
            content.textProperties.color = .inkTertiary
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: 0, leading: IOSDS.Layout.groupHeaderInset - IOSDS.Layout.cardMargin, bottom: IOSDS.Layout.groupHeaderGap, trailing: 0
            )
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            self?.configureFooter(view, section: indexPath.section)
        }
        let dataSource = UICollectionViewDiffableDataSource<Section, Row>(collectionView: collectionView) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: row)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
        return dataSource
    }

    static var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
        return "\(short) (\(build))"
    }

    // MARK: - Actions

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .notifications:
            Task { await notifications.handleTap() }
        case .clear:
            confirmClear()
        default:
            break
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .notifications, .clear: true
        default: false
        }
    }

    private func confirmClear() {
        let alert = UIAlertController(
            title: "Clear received data?",
            message: "Every session cached on this iPhone is dropped and fetched again from each Mac.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            self?.relay.clearReceivedData()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}
