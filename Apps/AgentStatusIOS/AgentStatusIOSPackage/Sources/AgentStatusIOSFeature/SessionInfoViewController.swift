import AgentStatusCore
import AgentStatusDesignSystem
import UIKit

/// Info tab (the Mac Inspector): Overview / Lineage / Model / Usage groups
/// as inset-grouped value rows. The metric cards live in the detail header.
@MainActor
final class SessionInfoViewController: UIViewController {
    private struct Row: Hashable {
        let sectionID: String
        let field: SessionSummaryFieldPresentation
    }

    private var sections: [SessionSummarySectionPresentation] = []
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private lazy var dataSource = makeDataSource()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.allowsSelection = false
        collectionView.contentInset.top = IOSDS.Layout.infoListTop - IOSDS.Layout.groupHeaderGap
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        _ = dataSource
        apply()
    }

    func update(_ sections: [SessionSummarySectionPresentation]) {
        self.sections = sections
        guard isViewLoaded else { return }
        apply()
    }

    private func apply() {
        var snapshot = NSDiffableDataSourceSnapshot<String, Row>()
        for section in sections {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.fields.map { Row(sectionID: section.id, field: $0) }, toSection: section.id)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func makeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.backgroundColor = .clear
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<String, Row> {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { cell, _, row in
            var content = UIListContentConfiguration.valueCell()
            content.text = row.field.label
            content.textProperties.font = .design(IOSDS.Typography.listTitle)
            content.secondaryText = row.field.value
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.lineBreakMode = row.field.isCompactValue ? .byTruncatingMiddle : .byTruncatingTail
            content.secondaryTextProperties.font = row.field.isMonospaced
                ? .design(row.field.isCompactValue ? IOSDS.Typography.captionMono : IOSDS.Typography.bodyMono)
                : .design(IOSDS.Typography.body)
            content.prefersSideBySideTextAndSecondaryText = true
            cell.contentConfiguration = content
            var background = UIBackgroundConfiguration.listGroupedCell()
            background.backgroundColor = .secondarySystemGroupedBackground
            cell.backgroundConfiguration = background
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self, indexPath.section < sections.count else { return }
            var content = UIListContentConfiguration.plainHeader()
            content.text = sections[indexPath.section].title
            content.textProperties.font = .design(IOSDS.Typography.captionEmphasized)
            content.textProperties.color = .inkTertiary
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: 0,
                leading: IOSDS.Layout.groupHeaderInset - IOSDS.Layout.cardMargin,
                bottom: IOSDS.Layout.groupHeaderGap,
                trailing: 0
            )
            view.contentConfiguration = content
        }
        let dataSource = UICollectionViewDiffableDataSource<String, Row>(collectionView: collectionView) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: row)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        return dataSource
    }
}

private extension SessionSummaryFieldPresentation {
    /// Long mono values (the Session ID) render one step smaller so they fit.
    var isCompactValue: Bool { isMonospaced && value.count > 20 }
}
