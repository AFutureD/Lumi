import Core
import DesignSystem
import SwiftUI
import Transport
import os
import UIKit

private let log = os.Logger(subsystem: "app.huanan.lumi", category: "usage.history")

/// Usage › History (handoff pages 9 / 9b / 9c): the range row, the figures
/// card and the chart card. Reads every Mac's `MacChannelState.usage`,
/// merges for `All Macs` (`UsageAggregate`), and keeps what it is looking at
/// in `UsageHistoryState`. The parent tab asks the Macs and polls; the range
/// menu asks straight away.
@MainActor
final class UsageHistoryViewController: UIViewController {
    private typealias U = IOSDS.Usage

    private let relay: RelayDeviceController
    private let onRefresh: () -> Void
    private let onPairMac: () -> Void
    private var observer: UUID?
    private var refreshDeadline: Task<Void, Never>?
    private(set) var state = UsageHistoryState()

    private let scrollView = UIScrollView()
    private let content = UIStackView()
    private let rangeButton = UsageMenuButton(style: IOSDS.Typography.action)
    private let scopeButton = UsageMenuButton(style: IOSDS.Typography.action)
    private let banner = UsageNoticeBannerView()
    private let figuresCard = UsageFiguresCardView()
    private let chartCard = UsageChartCardView()
    private let pairCard = UsagePairCardView()
    private let chartModel: UsageChartModel
    private let hosting: UIHostingController<UsageHistoryChart>

    /// The wire preset the parent polls with.
    var preset: UsageRangePreset { state.preset }

    init(relay: RelayDeviceController, onRefresh: @escaping () -> Void, onPairMac: @escaping () -> Void) {
        self.relay = relay
        self.onRefresh = onRefresh
        self.onPairMac = onPairMac
        let model = UsageChartModel(
            trend: UsageTrend(unit: .day, bars: [], series: []),
            yMaximum: 1,
            barInset: U.barGapDay / 2,
            onTap: { _ in }
        )
        chartModel = model
        hosting = UIHostingController(rootView: UsageHistoryChart(model: model))
        super.init(nibName: nil, bundle: nil)
        model.onTap = { [weak self] bucket in self?.tapped(bucket: bucket) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pulled), for: .valueChanged)
        scrollView.refreshControl = refresh
        view.addSubview(scrollView)

        let rangeRow = UIStackView(arrangedSubviews: [rangeButton, scopeButton, UIView()])
        rangeRow.axis = .horizontal
        rangeRow.alignment = .center
        rangeRow.spacing = U.rangeRowGap
        rangeRow.heightAnchor.constraint(equalToConstant: U.rangeRowHeight).isActive = true

        content.axis = .vertical
        content.spacing = U.cardGap
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [rangeRow, banner, figuresCard, chartCard, pairCard] as [UIView] {
            content.addArrangedSubview(view)
        }
        content.setCustomSpacing(U.rangeRowBottom, after: rangeRow)
        scrollView.addSubview(content)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: IOSDS.Layout.cardMargin),
            content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -IOSDS.Layout.cardMargin),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -IOSDS.Layout.groupGap),
            content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -2 * IOSDS.Layout.cardMargin),
        ])

        addChild(hosting)
        chartCard.install(hosting)
        hosting.didMove(toParent: self)

        figuresCard.onClear = { [weak self] in
            guard let self else { return }
            log.info("history_clear_selection")
            state.clearSelection()
            render()
        }
        pairCard.onPair = { [weak self] in self?.onPairMac() }

        observer = relay.observe { [weak self] in self?.render() }
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        render()
    }

    // MARK: - Actions

    @objc private func pulled() {
        log.info("history_pull_refresh preset=\(self.state.preset.rawValue, privacy: .public)")
        onRefresh()
        refreshDeadline?.cancel()
        refreshDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.endRefreshing(reason: "deadline")
        }
    }

    private func endRefreshing(reason: String) {
        guard scrollView.refreshControl?.isRefreshing == true else { return }
        log.debug("history_refresh_end reason=\(reason, privacy: .public)")
        scrollView.refreshControl?.endRefreshing()
        refreshDeadline?.cancel()
        refreshDeadline = nil
    }

    private func choose(range: UsageRangeKind) {
        guard range != state.range else { return }
        log.info("history_range range=\(range.rawValue, privacy: .public)")
        state.select(range: range)
        relay.requestUsage(state.preset)
        render()
    }

    private func choose(scope: HostID?) {
        log.info("history_scope scope=\(scope?.rawValue ?? "all", privacy: .public)")
        state.select(scope: scope)
        render()
    }

    private func choose(agent: UsageSummaryAgent) {
        guard agent != state.chartAgent else { return }
        log.info("history_agent agent=\(agent.rawValue, privacy: .public)")
        state.select(agent: agent)
        render()
    }

    private func tapped(bucket: String) {
        state.toggle(bucket: bucket)
        log.info("history_bucket bucket=\(self.state.selectedBucket ?? "none", privacy: .public)")
        render()
    }

    // MARK: - Render

    private static let ranges: [UsageRangeKind] = [.today, .thisWeek, .thisMonth]

    private func render() {
        let states = relay.channelStates
        let now = Date()
        state.reconcile(pairedHosts: Set(states.map(\.hostID)))

        rangeButton.setChoices(Self.ranges.map(\.title), selected: Self.ranges.firstIndex(of: state.range) ?? 1) { [weak self] index in
            self?.choose(range: Self.ranges[index])
        }
        let scopes: [HostID?] = [nil] + states.map(\.hostID)
        scopeButton.setChoices(["All Macs"] + states.map(\.displayName), selected: scopes.firstIndex(of: state.scope) ?? 0) { [weak self] index in
            self?.choose(scope: scopes[index])
        }

        guard !states.isEmpty else {
            scopeButton.title = "No Macs"
            scopeButton.isEnabled = false
            banner.isHidden = true
            figuresCard.isHidden = true
            chartCard.isHidden = true
            pairCard.isHidden = false
            endRefreshing(reason: "no_macs")
            return
        }
        scopeButton.isEnabled = true
        pairCard.isHidden = true

        let relevant = state.scope.map { id in states.filter { $0.hostID == id } } ?? states
        var reports: [HostID: UsageReport] = [:]
        for mac in relevant {
            if let snapshot = mac.usage, snapshot.preset == state.preset, let report = snapshot.report {
                reports[mac.hostID] = report
            }
        }
        let anyLoading = relevant.contains { $0.usage?.isLoading == true }
        let allOffline = states.allSatisfy { !$0.isOnline }
        let newest = relevant.compactMap { $0.usage?.fetchedAt }.max()
        let lastSeen = newest ?? relevant.compactMap(\.lastSyncAt).max()

        banner.isHidden = !allOffline
        if allOffline { banner.text = UsageHistoryText.offlineBanner(lastSeen: lastSeen, now: now) }

        let stamp: (String?, Bool)
        if allOffline {
            stamp = (UsageHistoryText.offlineStamp(lastSeen: lastSeen, now: now), false)
        } else if anyLoading {
            stamp = ("updating…", true)
        } else {
            stamp = (PlanUsagePresentation.updatedText(newest, now: now), false)
        }

        let range = UsageRange.preset(state.range, now: now, calendar: .current)
        if scrollView.refreshControl?.isRefreshing == true, !anyLoading {
            endRefreshing(reason: "loaded")
        }

        guard let report = UsageAggregate.report(for: state.scope, in: reports) else {
            let body: UsageFiguresModel.Body
            if anyLoading {
                body = .loading("Loading usage…")
            } else if allOffline {
                let since = lastSeen.map { " · last success \(SessionRelativeTimeFormatter.string(from: $0, now: now)) ago" } ?? ""
                body = .message("Can't reach any Mac\(since)", warning: true)
            } else if let error = relevant.compactMap({ $0.usage?.error }).first {
                log.warning("history_unavailable error=\(error, privacy: .public)")
                body = .message("Can't reach any Mac · \(error)", warning: true)
            } else {
                body = .loading("Loading usage…")
            }
            figuresCard.apply(UsageFiguresModel(
                title: UsageHistoryText.rangeCaption(since: range.since, until: range.until),
                titleEmphasized: false, stamp: stamp.0, stampTint: stamp.1, showsClear: false,
                body: body, notices: []
            ))
            figuresCard.isHidden = false
            chartCard.isHidden = true
            return
        }

        let calendar = Calendar.current
        let allTrend = UsageTrend.build(report: report, range: range, agent: .all, calendar: calendar)
        let chartTrend = state.chartAgent == .all
            ? allTrend
            : UsageAggregate.reducingModels(UsageTrend.build(report: report, range: range, agent: state.chartAgent, calendar: calendar))
        if let selected = state.selectedBucket, !allTrend.bars.contains(where: { $0.id == selected }) {
            log.debug("history_selection_dropped bucket=\(selected, privacy: .public)")
            state.clearSelection()
        }
        let figures = UsageSummaryFigures.build(report: report, agent: .all, comparisonLabel: range.comparisonLabel(calendar: calendar))

        var model = UsageFiguresModel(
            title: UsageHistoryText.rangeCaption(since: report.since, until: report.until),
            titleEmphasized: false, stamp: stamp.0, stampTint: stamp.1, showsClear: false,
            body: .figures(UsageFiguresModel.Figures(
                cost: figures.cost,
                costCaption: (report.totals.costUSD ?? 0) == 0 && !figures.allUnpriced ? "no spend in this range" : figures.costDelta,
                tokens: figures.tokens,
                segments: figures.segments,
                composition: figures.composition,
                sessions: figures.sessions, turns: figures.turns, calls: figures.calls
            )),
            notices: []
        )
        if let selected = state.selectedBucket, let bar = allTrend.bars.first(where: { $0.id == selected }) {
            let slice = UsageAggregate.bucketSlice(bar: bar, agent: state.chartAgent)
            model.title = bar.title
            model.titleEmphasized = true
            model.showsClear = true
            model.body = .figures(UsageFiguresModel.Figures(
                cost: UsageFormatting.cost(slice.costUSD),
                costCaption: UsageHistoryText.bucketCostSplit(bar: bar, agent: state.chartAgent),
                tokens: UsageFormatting.tokens(slice.tokens.total),
                segments: figures.segments,
                composition: "composition for the whole range",
                sessions: figures.sessions, turns: figures.turns, calls: figures.calls
            ))
        }
        let unpriced = report.byModel.filter { $0.costUSD == nil }.count
        if let notice = UsageHistoryText.unpricedNotice(modelCount: unpriced) {
            model.notices.append(.init(text: notice, warning: true))
        }
        if !allOffline {
            for mac in relevant where !mac.isOnline {
                guard let snapshot = mac.usage, snapshot.report != nil else { continue }
                let age = snapshot.fetchedAt.map { SessionRelativeTimeFormatter.string(from: $0, now: now) } ?? "a while"
                model.notices.append(.init(text: "\(mac.displayName) data as of \(age) ago", warning: true))
            }
        }
        figuresCard.apply(model)
        figuresCard.isHidden = false

        chartCard.setTitle(chartTrend.title(.cost) + (state.chartAgent == .all ? "" : " · BY MODEL"))
        let agents = UsageSummaryAgent.allCases
        chartCard.agentButton.setChoices(agents.map(\.title), selected: agents.firstIndex(of: state.chartAgent) ?? 0) { [weak self] index in
            self?.choose(agent: agents[index])
        }
        chartModel.trend = chartTrend
        chartModel.yMaximum = UsageTrend.niceMaximum(allTrend.maximum(.cost))
        chartModel.barInset = (chartTrend.bars.count > 7 ? U.barGapMonth : U.barGapDay) / 2
        chartModel.selected = state.selectedBucket
        chartCard.isHidden = false
        chartCard.refit()
    }
}

/// The page-level warning strip: `Offline · showing numbers from 5m ago`.
final class UsageNoticeBannerView: UIView {
    private let label = UILabel()

    var text: String {
        get { label.text ?? "" }
        set { label.text = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(DS.PlanUsage.noticeWarningFill)
        layer.cornerRadius = IOSDS.Layout.cardRadius
        layer.cornerCurve = .continuous
        label.font = .design(IOSDS.Typography.caption)
        label.textColor = UIColor(DS.PlanUsage.noticeWarningText)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: IOSDS.Usage.bannerVerticalPadding),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: IOSDS.Usage.cardHorizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -IOSDS.Usage.cardHorizontalPadding),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -IOSDS.Usage.bannerVerticalPadding),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }
}

/// No paired Macs: one sentence and a `Pair a Mac` row — no empty card, no `$0.00`.
final class UsagePairCardView: UIView {
    var onPair: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = IOSDS.Layout.cardRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true
        let text = UILabel()
        text.numberOfLines = 0
        text.setText("Cost and tokens come from each paired Mac's daemon. Pair a Mac to see them here.", style: IOSDS.Typography.caption, color: UIColor(IOSDS.Usage.secondaryText))
        let textRow = UIStackView(arrangedSubviews: [text])
        textRow.isLayoutMarginsRelativeArrangement = true
        textRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: IOSDS.Usage.noticeVerticalPadding, leading: IOSDS.Usage.cardHorizontalPadding, bottom: IOSDS.Usage.noticeVerticalPadding, trailing: IOSDS.Usage.cardHorizontalPadding)
        var configuration = UIButton.Configuration.plain()
        configuration.title = "Pair a Mac"
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: IOSDS.Usage.cardHorizontalPadding, bottom: 0, trailing: IOSDS.Usage.cardHorizontalPadding)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.design(IOSDS.Typography.listTitle)
            return outgoing
        }
        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.heightAnchor.constraint(equalToConstant: IOSDS.Layout.fieldRowMinimumHeight).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.onPair() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [textRow, UIView.hairline(color: UIColor(IOSDS.Usage.hairline)), button])
        stack.axis = .vertical
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
}
