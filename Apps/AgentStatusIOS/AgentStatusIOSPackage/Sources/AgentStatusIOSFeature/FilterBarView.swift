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
/// `Status`); tapping a trigger asks the owner to drop (or fold) that
/// group's `FilterDropdownPanel`. `Reset` appears at the right end while any
/// group is filtered.
final class FilterBarView: UIView {
    var onToggleGroup: ((FilterGroup) -> Void)?
    var onReset: (() -> Void)?

    /// The group whose panel is open: its chevron points up.
    var openGroup: FilterGroup? {
        didSet {
            guard openGroup != oldValue else { return }
            for (group, trigger) in triggers {
                trigger.setOpen(group == openGroup, animated: window != nil)
            }
        }
    }

    private let triggers: [FilterGroup: FilterTriggerButton] = Dictionary(
        uniqueKeysWithValues: FilterGroup.allCases.map { ($0, FilterTriggerButton(title: $0.title)) }
    )
    private let reset = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        let t = IOSDS.FilterTrigger.self
        for group in FilterGroup.allCases {
            triggers[group]!.addAction(UIAction { [weak self] _ in self?.onToggleGroup?(group) }, for: .touchUpInside)
        }
        reset.setTitle("Reset", for: .normal)
        reset.titleLabel?.font = .design(IOSDS.Typography.action)
        reset.addAction(UIAction { [weak self] _ in self?.onReset?() }, for: .touchUpInside)
        reset.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = UIView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = UIStackView(arrangedSubviews: FilterGroup.allCases.map { triggers[$0]! } + [spacer, reset])
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

    /// The trigger of a group — the panel drops under it.
    func trigger(for group: FilterGroup) -> UIView {
        triggers[group]!
    }

    /// `selected`/`total` per group drive the filtered look and the badge.
    func configure(counts: [FilterGroup: FilterGroupCount]) {
        for (group, trigger) in triggers {
            let count = counts[group] ?? FilterGroupCount(selected: 0, total: 0)
            trigger.configure(selected: count.selected, total: count.total)
        }
        reset.isHidden = counts.values.allSatisfy { $0.selected == $0.total }
    }
}

/// How many options of a group are selected, out of how many.
struct FilterGroupCount: Hashable {
    let selected: Int
    let total: Int
}

/// Trigger: 30 tall, radius 9, `padding 0 10`; label 14 / Regular; a 16pt
/// count badge when the group is filtered; a 10 × 6 chevron that flips
/// while the panel is open.
final class FilterTriggerButton: UIButton {
    private let label = UILabel()
    private let badge = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)))
    private let stack = UIStackView()
    /// `min-width 16`, else the count plus `4` each side.
    private lazy var badgeWidth = badge.widthAnchor.constraint(equalToConstant: IOSDS.FilterTrigger.badgeHeight)
    private var isFiltered = false

    init(title: String) {
        super.init(frame: .zero)
        let t = IOSDS.FilterTrigger.self
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
            badgeWidth,
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
        accessibilityLabel = title
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: FilterTriggerButton, _) in
            self.applyColors()
        }
        configure(selected: 0, total: 0)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func configure(selected: Int, total: Int) {
        isFiltered = total > 0 && selected < total
        badge.isHidden = !isFiltered
        badge.text = "\(selected)"
        let t = IOSDS.FilterTrigger.self
        badgeWidth.constant = max(t.badgeHeight, ceil(badge.intrinsicContentSize.width) + t.badgeHorizontalPadding * 2)
        accessibilityValue = isFiltered ? "\(selected) of \(total)" : "All"
        applyColors()
        invalidateIntrinsicContentSize()
    }

    /// Flips the chevron (`rotate(180deg)`, `.18s ease`) while the panel is open.
    func setOpen(_ isOpen: Bool, animated: Bool) {
        let transform = isOpen ? CGAffineTransform(rotationAngle: .pi) : .identity
        accessibilityTraits = isOpen ? [.button, .selected] : .button
        guard animated else {
            chevron.transform = transform
            return
        }
        UIView.animate(withDuration: IOSDS.FilterTrigger.animationDuration, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.chevron.transform = transform
        }
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
}
