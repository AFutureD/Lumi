import Core
import DesignSystem
import SwiftUI
import UIKit

/// The chart card: `COST PER DAY[ · BY MODEL]` with the agent menu at the
/// right, then the hosted Swift Charts view (plot + axis row + legend). The
/// hosting controller belongs to the History controller (child view
/// controller); this view only lays its view out and sizes it to fit.
final class UsageChartCardView: UIView {
    private typealias U = IOSDS.Usage

    let agentButton = UsageMenuButton(style: IOSDS.Typography.caption)
    private let titleLabel = UILabel()
    private let chartSlot = UIView()
    private var chartHeight: NSLayoutConstraint?
    private var hosting: UIHostingController<UsageHistoryChart>?
    private var lastFittedWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = IOSDS.Layout.cardRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titleRow = UsageMenuRow(arrangedSubviews: [titleLabel, agentButton])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.heightAnchor.constraint(equalToConstant: U.chartTitleRowHeight).isActive = true

        chartSlot.translatesAutoresizingMaskIntoConstraints = false
        chartHeight = chartSlot.heightAnchor.constraint(equalToConstant: U.chartHeight + U.chartAxisRowHeight)
        chartHeight?.isActive = true

        let stack = UIStackView(arrangedSubviews: [titleRow, chartSlot])
        stack.axis = .vertical
        stack.spacing = U.chartTitleGap
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: U.chartTopPadding, leading: U.cardHorizontalPadding, bottom: U.chartBottomPadding, trailing: U.cardHorizontalPadding)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func setTitle(_ title: String) {
        titleLabel.setText(title, style: IOSDS.Typography.usageLabel, color: UIColor(U.secondaryText))
    }

    /// Puts the hosting controller's view in the slot (the controller has
    /// already been added as a child).
    func install(_ hosting: UIHostingController<UsageHistoryChart>) {
        self.hosting = hosting
        let view = hosting.view!
        view.backgroundColor = .clear
        view.translatesAutoresizingMaskIntoConstraints = false
        chartSlot.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: chartSlot.topAnchor),
            view.leadingAnchor.constraint(equalTo: chartSlot.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: chartSlot.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: chartSlot.bottomAnchor),
        ])
    }

    /// The legend wraps by width, so the slot's height is measured from the
    /// SwiftUI content at the current width whenever either changes.
    func refit() {
        lastFittedWidth = 0
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = chartSlot.bounds.width
        guard let hosting, width > 0, width != lastFittedWidth else { return }
        lastFittedWidth = width
        let fitted = hosting.sizeThatFits(in: CGSize(width: width, height: UIView.layoutFittingExpandedSize.height))
        let height: CGFloat = max(CGFloat(U.chartHeight + U.chartAxisRowHeight), fitted.height.rounded(.up))
        if chartHeight?.constant != height {
            chartHeight?.constant = height
            superview?.setNeedsLayout()
        }
    }
}
