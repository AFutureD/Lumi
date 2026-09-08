import DesignSystem
import Transport
import os
import UIKit

private let log = os.Logger(subsystem: "app.huanan.lumi", category: "usage")

/// Usage tab (handoff `design_handoff_ios_usage`): a `Plan` / `History`
/// segmented control under the inline title, two child screens toggled by
/// `isHidden`. The tab asks every paired Mac on appearance, polls while it
/// is on screen (Plan every 60 s, History every 30 s — the Mac's cadence),
/// and stops the moment it leaves. Nothing is persisted: the snapshots live
/// in `RelayDeviceController` memory only.
@MainActor
final class UsageViewController: UIViewController {
    private enum Segment: Int { case plan, history }

    private let relay: RelayDeviceController
    private let segments = UISegmentedControl(items: ["Plan", "History"])
    private let container = UIView()
    private lazy var plan = PlanUsageViewController(
        relay: relay,
        onRefresh: { [weak self] in self?.requestPlan() },
        onPairMac: onPairMac
    )
    private lazy var history = UsageHistoryViewController(
        relay: relay,
        onRefresh: { [weak self] in self?.requestHistory() },
        onPairMac: onPairMac
    )
    private let onPairMac: () -> Void
    private var planTimer: Timer?
    private var historyTimer: Timer?

    static let planPollInterval: TimeInterval = 60
    static let historyPollInterval: TimeInterval = 30

    init(relay: RelayDeviceController, onPairMac: @escaping () -> Void) {
        self.relay = relay
        self.onPairMac = onPairMac
        super.init(nibName: nil, bundle: nil)
        title = "Usage"
        tabBarItem = UITabBarItem(title: "Usage", image: UIImage(systemName: "chart.bar"), tag: 1)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .inline

        segments.selectedSegmentIndex = Segment.plan.rawValue
        segments.setTitleTextAttributes([.font: UIFont.design(IOSDS.Typography.captionEmphasized)], for: .selected)
        segments.setTitleTextAttributes([.font: UIFont.design(IOSDS.Typography.captionMedium)], for: .normal)
        segments.translatesAutoresizingMaskIntoConstraints = false
        segments.addAction(UIAction { [weak self] _ in self?.showSelectedSegment() }, for: .valueChanged)
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(segments)
        view.addSubview(container)
        NSLayoutConstraint.activate([
            segments.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: IOSDS.Usage.segmentTop),
            segments.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: IOSDS.Layout.titleInset),
            segments.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -IOSDS.Layout.titleInset),
            segments.heightAnchor.constraint(equalToConstant: IOSDS.Header.segmentHeight),
            container.topAnchor.constraint(equalTo: segments.bottomAnchor, constant: IOSDS.Usage.segmentBottom),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        for child in [plan, history] as [UIViewController] {
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
        showSelectedSegment()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        log.info("usage_tab_appear")
        requestPlan()
        requestHistory()
        planTimer?.invalidate()
        planTimer = Timer.scheduledTimer(withTimeInterval: Self.planPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestPlan() }
        }
        historyTimer?.invalidate()
        historyTimer = Timer.scheduledTimer(withTimeInterval: Self.historyPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestHistory() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        log.info("usage_tab_disappear")
        planTimer?.invalidate()
        planTimer = nil
        historyTimer?.invalidate()
        historyTimer = nil
    }

    private func showSelectedSegment() {
        let selected = Segment(rawValue: segments.selectedSegmentIndex) ?? .plan
        plan.view.isHidden = selected != .plan
        history.view.isHidden = selected != .history
        log.debug("usage_segment segment=\(selected == .plan ? "plan" : "history", privacy: .public)")
    }

    private func requestPlan() {
        relay.requestPlanUsage()
    }

    private func requestHistory() {
        relay.requestUsage(history.preset)
    }
}
