import Combine
import Core
import Transport
import AppKit
import SwiftUI

/// The Usage page shell: a subheader with the range control (Today ·
/// This week · This month · Custom, plus two date pickers when Custom) and
/// the price-table status on the right, above the hosted SwiftUI report.
/// Polling runs only while the page is on screen.
@MainActor
final class UsageViewController: NSViewController {
    let subheaderAccessory = DetailSubheaderAccessoryController(horizontalInset: DetailLayout.horizontalInset)
    private var subheader: DetailSubheaderView { subheaderAccessory.subheader }

    private let model: UsageModel
    private let calendar: Calendar
    private let segmented = NSSegmentedControl(
        labels: UsageRangeKind.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let sincePicker = NSDatePicker()
    private let untilPicker = NSDatePicker()
    private let rangeSeparator = NSTextField(labelWithString: "to")
    private let hosting: NSHostingController<UsageReportView>
    private var modelObservation: AnyCancellable?

    init(model: UsageModel, calendar: Calendar = .current) {
        self.model = model
        self.calendar = calendar
        hosting = NSHostingController(rootView: UsageReportView(model: model))
        super.init(nibName: nil, bundle: nil)
        // `objectWillChange` fires before the value lands; read it on the next turn.
        modelObservation = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateSubheader() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        addChild(hosting)
        hosting.sizingOptions = []
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        configureSubheaderControls()
        updateSubheader()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        model.setVisible(true)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        model.setVisible(false)
    }

    /// Toolbar Refresh.
    func refresh() {
        model.refresh()
    }

    private func configureSubheaderControls() {
        segmented.controlSize = .small
        segmented.segmentStyle = .rounded
        segmented.segmentDistribution = .fit
        // The subheader stack hands spare width to its last view; the
        // control keeps its natural width so the pickers sit right beside it.
        segmented.setContentHuggingPriority(.required, for: .horizontal)
        segmented.target = self
        segmented.action = #selector(rangeKindChanged(_:))
        for picker in [sincePicker, untilPicker] {
            picker.datePickerStyle = .textField
            picker.datePickerElements = .yearMonthDay
            picker.controlSize = .small
            picker.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            picker.calendar = calendar
            picker.timeZone = calendar.timeZone
            picker.isBezeled = true
            picker.target = self
            picker.action = #selector(customDatesChanged(_:))
        }
        rangeSeparator.font = Design.Font.caption
        rangeSeparator.textColor = .secondaryLabelColor
    }

    @objc private func rangeKindChanged(_ sender: NSSegmentedControl) {
        guard UsageRangeKind.allCases.indices.contains(sender.selectedSegment) else { return }
        model.select(UsageRangeKind.allCases[sender.selectedSegment])
    }

    @objc private func customDatesChanged(_ sender: NSDatePicker) {
        model.setCustom(
            since: UsageDay(sincePicker.dateValue, calendar: calendar),
            until: UsageDay(untilPicker.dateValue, calendar: calendar)
        )
    }

    private func updateSubheader() {
        guard isViewLoaded else { return }
        let range = model.range
        if let index = UsageRangeKind.allCases.firstIndex(of: range.kind), segmented.selectedSegment != index {
            segmented.selectedSegment = index
        }
        var leading: [NSView] = [segmented]
        if range.kind == .custom {
            let today = model.today.start(in: calendar) ?? Date()
            for picker in [sincePicker, untilPicker] { picker.maxDate = today }
            if let since = range.since.start(in: calendar), sincePicker.dateValue != since { sincePicker.dateValue = since }
            if let until = range.until.start(in: calendar), untilPicker.dateValue != until { untilPicker.dateValue = until }
            sincePicker.maxDate = untilPicker.dateValue
            leading += [sincePicker, rangeSeparator, untilPicker]
        }
        subheader.setLeadingViews(leading, trailingText: Self.pricingText(model.report?.pricing, now: model.today.start(in: calendar) ?? Date()))
    }

    /// `Prices · models.dev · updated 3h ago` / `Prices · built-in snapshot`.
    static func pricingText(_ pricing: UsagePricingStatus?, now: Date = Date()) -> String {
        guard let pricing else { return "Usage from this Mac's Claude Code and Codex transcripts" }
        switch pricing.source {
        case .builtin:
            return "Prices · built-in snapshot"
        case .cached, .fresh:
            guard let fetchedAt = pricing.fetchedAt else { return "Prices · models.dev" }
            return "Prices · models.dev · updated \(SessionRelativeTimeFormatter.string(from: fetchedAt, now: now)) ago"
        }
    }
}
