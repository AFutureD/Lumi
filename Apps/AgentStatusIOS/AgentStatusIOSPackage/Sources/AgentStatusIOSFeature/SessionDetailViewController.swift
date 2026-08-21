import AgentStatusCore
import AgentStatusDesignSystem
import AgentStatusTransport
import UIKit

/// Session detail: a fixed header (status + agent pills, path, Activity /
/// Info segments, lane strip or metric cards) over the selected tab.
@MainActor
final class SessionDetailViewController: UIViewController {
    private let relay: RelayDeviceController
    private let hostID: HostID
    private let sessionID: SessionID
    private var observer: UUID?
    private var presentation: SessionDetailPresentation?
    private var syncingScroll = false
    nonisolated(unsafe) private var ticker: Timer?

    private let header = SessionHeaderView()
    private let container = UIView()
    private let activity = ActivityListViewController()
    private let info = SessionInfoViewController()

    init(relay: RelayDeviceController, hostID: HostID, sessionID: SessionID) {
        self.relay = relay
        self.hostID = hostID
        self.sessionID = sessionID
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    deinit {
        ticker?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: [
                UIAction(title: "Refresh session", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                    guard let self else { return }
                    relay.refreshSession(hostID: hostID, id: sessionID)
                },
                UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.confirmDelete()
                },
            ])
        )

        header.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(container)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.topAnchor.constraint(equalTo: header.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        for child in [activity, info] as [UIViewController] {
            addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child.view)
            NSLayoutConstraint.activate([
                child.view.topAnchor.constraint(equalTo: container.topAnchor),
                child.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                child.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            child.didMove(toParent: self)
        }
        header.segments.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
        header.laneStrip.onSelect = { [weak self] index in self?.activity.scroll(toActivityAt: index) }
        // Strip and list scroll in step: the list's top row leads the strip,
        // a pan on the strip leads the list. A guard stops the echo.
        activity.onTopVisibleChange = { [weak self] index in
            guard let self, !syncingScroll else { return }
            syncingScroll = true
            header.laneStrip.scroll(toActivityAt: index)
            syncingScroll = false
        }
        header.laneStrip.onUserScroll = { [weak self] index in
            guard let self, !syncingScroll else { return }
            syncingScroll = true
            activity.scroll(toActivityAt: index, position: .top, animated: false)
            syncingScroll = false
        }
        selectTab(0)

        observer = relay.observe { [weak self] in self?.update() }
        update()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.header.tick(now: Date()) }
        }
    }

    /// Looking at the detail is reviewing it — same as opening it on the Mac.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        relay.markReviewed(hostID: hostID, id: sessionID)
    }

    private func update() {
        guard let detail = relay.session(hostID: hostID, id: sessionID) else {
            if presentation != nil { navigationController?.popViewController(animated: true) }
            return
        }
        let next = SessionDetailPresentationBuilder.make(detail: detail)
        guard next != presentation else { return }
        presentation = next
        title = next.title
        header.configure(next, now: Date())
        activity.update(next.activities)
        info.update(next.sections)
    }

    @objc private func segmentChanged() {
        selectTab(header.segments.selectedSegmentIndex)
    }

    private func selectTab(_ index: Int) {
        let showsActivity = index == 0
        activity.view.isHidden = !showsActivity
        info.view.isHidden = showsActivity
        header.showsLanes = showsActivity
        let background: UIColor = showsActivity ? .systemBackground : .systemGroupedBackground
        view.backgroundColor = background
        header.backgroundColor = background
    }

    private func confirmDelete() {
        let alert = UIAlertController(
            title: "Delete this session from iPhone?",
            message: "The Mac keeps the session. It reappears here if the Mac sends a newer version.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            relay.dismissSession(hostID: hostID, id: sessionID)
            navigationController?.popViewController(animated: true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(alert, animated: true)
    }
}

// MARK: - Header

/// Status pill + agent pill, workspace path, segmented control, and a 44pt
/// slot holding either the lane strip (Activity) or the metric cards (Info).
final class SessionHeaderView: UIView {
    let segments = UISegmentedControl(items: ["Activity", "Info"])
    let laneStrip = LaneStripView()
    private let metrics = MetricCardsView()
    private let statusPill = StatusPillView()
    private let agentPill = UILabel()
    private let pathIcon = UIImageView(image: UIImage(systemName: "folder"))
    private let pathLabel = UILabel()
    private let pathRow = UIStackView()
    private let bottomLine = UIView.hairline(color: .blockSeparator)
    private var metricsPresentation: SessionMetricsPresentation?

    var showsLanes = true {
        didSet {
            laneStrip.isHidden = !showsLanes
            metrics.isHidden = showsLanes
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let h = IOSDS.Header.self
        backgroundColor = .systemBackground

        agentPill.font = .design(IOSDS.Typography.captionEmphasized)
        agentPill.textColor = UIColor(IOSDS.Color.agentPillText)
        let agentWrap = PaddedPill(label: agentPill, horizontalPadding: h.agentPillHorizontalPadding, height: h.pillHeight)
        let pillsRow = UIStackView(arrangedSubviews: [statusPill, agentWrap, UIView()])
        pillsRow.axis = .horizontal
        pillsRow.alignment = .center
        pillsRow.spacing = h.pillGap

        pathIcon.tintColor = UIColor(IOSDS.Color.activityTime)
        pathIcon.contentMode = .scaleAspectFit
        pathIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pathIcon.widthAnchor.constraint(equalToConstant: h.pathIcon),
            pathIcon.heightAnchor.constraint(equalToConstant: h.pathIcon),
        ])
        pathLabel.font = .design(IOSDS.Typography.captionMono)
        pathLabel.textColor = .secondaryLabel
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathRow.axis = .horizontal
        pathRow.alignment = .center
        pathRow.spacing = h.pathGap
        pathRow.addArrangedSubview(pathIcon)
        pathRow.addArrangedSubview(pathLabel)

        let topBlock = UIStackView(arrangedSubviews: [pillsRow, pathRow])
        topBlock.axis = .vertical
        topBlock.spacing = h.pillRowGap

        segments.selectedSegmentIndex = 0
        segments.setTitleTextAttributes([.font: UIFont.design(IOSDS.Typography.captionEmphasized)], for: .selected)
        segments.setTitleTextAttributes([.font: UIFont.design(IOSDS.Typography.captionMedium)], for: .normal)
        segments.heightAnchor.constraint(equalToConstant: h.segmentHeight).isActive = true

        let slot = UIView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        slot.heightAnchor.constraint(equalToConstant: h.slotHeight).isActive = true
        for view in [laneStrip, metrics] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: slot.topAnchor),
                view.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
            ])
        }
        metrics.isHidden = true

        let stack = UIStackView(arrangedSubviews: [topBlock, segments, slot])
        stack.axis = .vertical
        stack.spacing = h.blockGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(bottomLine)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: h.top),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: IOSDS.Layout.sideInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -IOSDS.Layout.sideInset),
            stack.bottomAnchor.constraint(equalTo: bottomLine.topAnchor, constant: -h.bottom),
            bottomLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func configure(_ presentation: SessionDetailPresentation, now: Date) {
        statusPill.configure(text: presentation.header.statusText, tone: presentation.header.tone)
        agentPill.text = presentation.header.agentName
        pathRow.isHidden = presentation.header.workspace == nil
        pathLabel.text = presentation.header.workspace
        laneStrip.configure(activities: presentation.activities)
        metricsPresentation = presentation.metrics
        metrics.configure(presentation.metrics, now: now)
    }

    func tick(now: Date) {
        guard let metricsPresentation, metricsPresentation.endedAt == nil else { return }
        metrics.configure(metricsPresentation, now: now)
    }
}

/// Solid dot + label in a capsule (3.1 on iOS). Header: 26 tall, `padding
/// 0 11`, 7px dot, 13 / Semibold. List row: 20 tall, `padding 0 8`, 6px dot,
/// 11 / Semibold.
final class StatusPillView: UIView {
    private let dot = UIView()
    private let label = UILabel()
    private var tone: SessionStatusTone = .gray

    init(
        height: Double = IOSDS.Header.pillHeight,
        horizontalPadding: Double = IOSDS.Header.pillHorizontalPadding,
        dotSize: Double = IOSDS.Header.pillDot,
        dotGap: Double = IOSDS.Header.pillDotGap,
        textStyle: DesignTextStyle = IOSDS.Typography.captionEmphasized
    ) {
        super.init(frame: .zero)
        layer.cornerRadius = height / 2
        layer.cornerCurve = .continuous
        layer.borderWidth = DS.StatusPill.ring
        dot.layer.cornerRadius = dotSize / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        label.font = .design(textStyle)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            dot.widthAnchor.constraint(equalToConstant: dotSize),
            dot.heightAnchor.constraint(equalToConstant: dotSize),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: dotGap),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: StatusPillView, _) in
            self.applyColors()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func configure(text: String, tone: SessionStatusTone) {
        self.tone = tone
        label.text = text
        applyColors()
    }

    private func applyColors() {
        let pill = tone.style(designAppearance).pill
        backgroundColor = pill.fillColor
        layer.borderColor = pill.ringColor.resolvedColor(with: traitCollection).cgColor
        dot.backgroundColor = pill.dotColor
        label.textColor = pill.textColor
    }
}

/// A label in a neutral capsule (the agent pill).
final class PaddedPill: UIView {
    init(label: UILabel, horizontalPadding: Double, height: Double) {
        super.init(frame: .zero)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = height / 2
        layer.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }
}

/// Three cards — tokens / context / elapsed — each 1/3 wide, 44 tall.
final class MetricCardsView: UIStackView {
    private let tokens = MetricCardView(label: "tokens")
    private let context = MetricCardView(label: "context")
    private let elapsed = MetricCardView(label: "elapsed")

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .horizontal
        distribution = .fillEqually
        spacing = IOSDS.MetricCard.gap
        addArrangedSubview(tokens)
        addArrangedSubview(context)
        addArrangedSubview(elapsed)
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    func configure(_ metrics: SessionMetricsPresentation, now: Date) {
        tokens.value = metrics.totalTokensText
        context.value = metrics.contextText
        elapsed.value = metrics.elapsedText(now: now)
    }
}

final class MetricCardView: UIView {
    private let valueLabel = UILabel()
    private let captionLabel = UILabel()

    var value: String = "" {
        didSet { valueLabel.text = value }
    }

    init(label: String) {
        super.init(frame: .zero)
        let m = IOSDS.MetricCard.self
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = m.radius
        layer.cornerCurve = .continuous
        valueLabel.font = .design(IOSDS.Typography.metricValue, tabular: true)
        valueLabel.textColor = .label
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.7
        captionLabel.attributedText = IOSDS.Typography.metricLabel.attributed(label.uppercased(), color: .secondaryLabel)
        let stack = UIStackView(arrangedSubviews: [valueLabel, captionLabel])
        stack.axis = .vertical
        stack.spacing = m.innerGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: m.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m.horizontalPadding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m.horizontalPadding),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }
}
