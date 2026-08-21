import AgentStatusDesignSystem
import UIKit

/// The Sessions list header under the navigation bar (Large Title and
/// `UISearchController` are the system's): the L3 §3.4 filter row, then the
/// list's top hairline.
final class SessionsHeaderView: UIView {
    let filterBar = FilterBarView()
    private let bottomLine = UIView.hairline(color: .blockSeparator)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        let h = IOSDS.SessionsHeader.self
        filterBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filterBar)
        addSubview(bottomLine)
        NSLayoutConstraint.activate([
            filterBar.topAnchor.constraint(equalTo: topAnchor, constant: h.gap),
            filterBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: IOSDS.Layout.titleInset),
            filterBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -IOSDS.Layout.titleInset),
            bottomLine.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: h.bottom),
            bottomLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }
}

/// L3 §3.4 Dropdown multi-select filters: one trigger per group (`Macs`,
/// `Status`), each opening a multi-select `UIMenu`; `Reset` appears at the
/// right end while any group is filtered.
final class FilterBarView: UIView {
    /// Menu for a group, rebuilt on every open so counts and checks are current.
    var macsMenuProvider: (() -> UIMenu)?
    var statusMenuProvider: (() -> UIMenu)?
    var onReset: (() -> Void)?

    let macsTrigger = FilterTriggerButton(title: "Macs")
    let statusTrigger = FilterTriggerButton(title: "Status")
    private let reset = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        let t = IOSDS.FilterTrigger.self
        macsTrigger.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.macsMenuProvider?().children ?? [])
        }])
        statusTrigger.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.statusMenuProvider?().children ?? [])
        }])
        reset.setTitle("Reset", for: .normal)
        reset.titleLabel?.font = .design(IOSDS.Typography.action)
        reset.addAction(UIAction { [weak self] _ in self?.onReset?() }, for: .touchUpInside)
        reset.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = UIView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [macsTrigger, statusTrigger, spacer, reset])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = t.gap
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.heightAnchor.constraint(equalToConstant: t.height),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// `selected`/`total` per group drive the filtered look and the badge.
    func configure(macsSelected: Int, macsTotal: Int, statusSelected: Int, statusTotal: Int) {
        macsTrigger.configure(selected: macsSelected, total: macsTotal)
        statusTrigger.configure(selected: statusSelected, total: statusTotal)
        reset.isHidden = macsSelected == macsTotal && statusSelected == statusTotal
    }
}

/// Trigger: 30 tall, radius 9, `padding 0 10`; label 14 / Regular; a 16pt
/// count badge when the group is filtered; a 10 × 6 chevron that flips
/// while the menu is open.
final class FilterTriggerButton: UIButton {
    private let label = UILabel()
    private let badge = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)))
    private let stack = UIStackView()
    private var isFiltered = false

    init(title: String) {
        super.init(frame: .zero)
        let t = IOSDS.FilterTrigger.self
        showsMenuAsPrimaryAction = true
        layer.cornerRadius = t.radius
        layer.cornerCurve = .continuous
        layer.borderWidth = t.ring
        label.font = .design(IOSDS.Typography.filterTrigger)
        label.text = title
        badge.font = .design(IOSDS.Typography.filterBadge, tabular: true)
        badge.textColor = .white
        badge.textAlignment = .center
        badge.backgroundColor = UIColor(IOSDS.Color.filterBadge)
        badge.layer.cornerRadius = t.badgeHeight / 2
        badge.clipsToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.heightAnchor.constraint(equalToConstant: t.badgeHeight),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: t.badgeHeight),
        ])
        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        for view in [label, badge, chevron] { stack.addArrangedSubview(view) }
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = t.innerGap
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: t.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: t.horizontalPadding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -t.horizontalPadding),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: t.chevronWidth),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: FilterTriggerButton, _) in
            self.applyColors()
        }
        configure(selected: 0, total: 0)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func configure(selected: Int, total: Int) {
        isFiltered = total > 0 && selected < total
        badge.isHidden = !isFiltered
        badge.text = " \(selected) "
        applyColors()
        invalidateIntrinsicContentSize()
    }

    /// UIButton sizes itself from its own title; ours comes from the stack.
    override var intrinsicContentSize: CGSize {
        let content = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return CGSize(width: content.width + IOSDS.FilterTrigger.horizontalPadding * 2, height: IOSDS.FilterTrigger.height)
    }

    private func applyColors() {
        if isFiltered {
            let pill = DesignHue.blue.pillStyle(designAppearance)
            backgroundColor = pill.fillColor
            layer.borderColor = pill.ringColor.resolvedColor(with: traitCollection).cgColor
            label.textColor = pill.textColor
            chevron.tintColor = pill.textColor
        } else {
            backgroundColor = .tertiarySystemFill
            layer.borderColor = UIColor.clear.cgColor
            label.textColor = .label
            chevron.tintColor = .label
        }
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        UIView.animate(withDuration: 0.18) { self.chevron.transform = CGAffineTransform(rotationAngle: .pi) }
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        UIView.animate(withDuration: 0.18) { self.chevron.transform = .identity }
    }
}
