import AgentStatusCore
import AgentStatusTransport
import AppKit
import SwiftUI

/// Detail column: a subheader strip (agent chip · status pill · workspace) above a
/// nested split of Activity (main) and Inspector (288, collapsible).
@MainActor
final class SessionDetailViewController: NSViewController {
    private let store: MacSessionStore
    private let renderer = SessionPagePresentationRenderer()

    let subheaderAccessory = DetailSubheaderAccessoryController(
        horizontalInset: AgentStatusDesign.Layout.activityHorizontalInset
    )
    private var subheader: DetailSubheaderView { subheaderAccessory.subheader }
    private let agentChip = CapsuleChipView()
    private let statusPill = StatusPillView()
    private let split = SessionDetailSplitViewController()
    private let activityState = SessionActivityState()
    private let emptyLabel = NSTextField(labelWithString: "Select a Session")

    private var presentationTask: Task<Void, Never>?
    private var renderGeneration = 0
    private var displayedSessionID: SessionID?
    private var presentation: SessionPagePresentation?

    init(store: MacSessionStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        store.observe { [weak self] in self?.reload() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        view.appearance = NSAppearance(named: .aqua)

        addChild(split)
        split.activity.rootView = makeActivityView()
        split.inspector.rootView = makeInspectorView()

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor

        [split.view, emptyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        NSLayoutConstraint.activate([
            split.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            split.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        reload()
    }

    /// Toolbar action. Persisted; nothing else ever changes the inspector state.
    func toggleInspector() {
        split.toggleInspector()
    }

    private func reload() {
        guard isViewLoaded else { return }
        let detail = store.selectedSession
        let sessionChanged = displayedSessionID != detail?.summary.id
        displayedSessionID = detail?.summary.id

        guard let detail else {
            presentationTask?.cancel()
            renderGeneration &+= 1
            presentation = nil
            activityState.reset()
            subheaderAccessory.isHidden = true
            split.view.isHidden = true
            emptyLabel.isHidden = false
            split.activity.rootView = makeActivityView()
            split.inspector.rootView = makeInspectorView()
            return
        }

        subheaderAccessory.isHidden = false
        split.view.isHidden = false
        emptyLabel.isHidden = true
        applySubheader(detail.summary)

        if sessionChanged {
            presentation = nil
            activityState.reset()
            split.activity.rootView = makeActivityView()
            split.inspector.rootView = makeInspectorView()
        }

        presentationTask?.cancel()
        renderGeneration &+= 1
        let generation = renderGeneration
        let renderer = renderer
        presentationTask = Task { @MainActor [weak self] in
            if !sessionChanged {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
            }
            guard let rendered = await renderer.presentation(for: detail),
                  !Task.isCancelled else { return }
            self?.apply(rendered, generation: generation)
        }
    }

    private func apply(_ rendered: SessionPagePresentation, generation: Int) {
        guard generation == renderGeneration,
              displayedSessionID == rendered.sessionID else { return }
        presentation = rendered
        split.activity.rootView = makeActivityView()
        split.inspector.rootView = makeInspectorView()
    }

    private func applySubheader(_ summary: SessionSummary) {
        agentChip.text = summary.agent.displayName
        statusPill.configure(
            tone: summary.statusTone,
            text: SessionListRowPresentation(session: summary).status
        )
        subheader.setLeadingViews(
            [agentChip, statusPill],
            trailingText: SessionPagePresentationBuilder.abbreviatedWorkspace(summary.workspace),
            trailingMonospaced: true
        )
    }

    private func makeActivityView() -> SessionActivityView {
        SessionActivityView(
            presentation: presentation,
            state: activityState,
            onPreview: { [weak self] activity in
                self?.showRawData(for: activity)
            }
        )
    }

    private func makeInspectorView() -> SessionInspectorView {
        SessionInspectorView(presentation: presentation)
    }

    private func showRawData(for activity: SessionActivityPresentation) {
        guard let hostWindow = view.window else { return }

        let textScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 680, height: 420))
        let textView = NSTextView(frame: textScroll.contentView.bounds)
        textView.autoresizingMask = [.width, .height]
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.string = SessionPagePresentationBuilder.rawData(for: activity.rawItems)
        textView.textContainer?.widthTracksTextView = true

        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.borderType = .bezelBorder

        let alert = NSAlert()
        alert.messageText = "\(activity.label) Raw Data"
        alert.informativeText = activity.occurredAt
        alert.accessoryView = textScroll
        alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: hostWindow)
    }
}

/// Activity | Inspector. The inspector is fixed at 288 and only the toolbar toggles it.
@MainActor
final class SessionDetailSplitViewController: NSSplitViewController {
    private static let inspectorVisibleKey = "AgentStatus.Layout.InspectorVisible"

    let activity = NSHostingView(rootView: SessionActivityView(
        presentation: nil,
        state: SessionActivityState(),
        onPreview: { _ in }
    ))
    let inspector = NSHostingView(rootView: SessionInspectorView(presentation: nil))
    private let inspectorItem: NSSplitViewItem
    private var inspectorObservation: NSKeyValueObservation?
    private var didRestore = false

    init() {
        let activityController = NSViewController()
        activityController.view = activity
        let inspectorController = NSViewController()
        // Lighter than `.underWindowBackground`: a within-window sheet material.
        let effect = NSVisualEffectView()
        effect.material = .sheet
        effect.blendingMode = .withinWindow
        effect.state = .active
        inspector.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(inspector)
        NSLayoutConstraint.activate([
            inspector.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            inspector.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            inspector.topAnchor.constraint(equalTo: effect.topAnchor),
            inspector.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        inspectorController.view = effect
        // A plain item (not `inspectorWith…`): the system inspector style adds a
        // titlebar-height inset that is wrong below our own session header.
        inspectorItem = NSSplitViewItem(viewController: inspectorController)
        super.init(nibName: nil, bundle: nil)

        // Hosting views must not size the split from their content.
        activity.sizingOptions = []
        inspector.sizingOptions = []

        splitView.dividerStyle = .thin
        splitView.isVertical = true

        let activityItem = NSSplitViewItem(viewController: activityController)
        activityItem.minimumThickness = AgentStatusDesign.Layout.detailMinimumWidth - 40
        activityItem.holdingPriority = .defaultLow

        inspectorItem.minimumThickness = AgentStatusDesign.Layout.inspectorWidth
        inspectorItem.maximumThickness = AgentStatusDesign.Layout.inspectorWidth
        inspectorItem.canCollapse = true
        inspectorItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        inspectorItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)

        addSplitViewItem(activityItem)
        addSplitViewItem(inspectorItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        let defaults = UserDefaults.standard
        let visible = defaults.object(forKey: Self.inspectorVisibleKey) == nil
            ? true
            : defaults.bool(forKey: Self.inspectorVisibleKey)
        inspectorItem.isCollapsed = !visible
        didRestore = true
        inspectorObservation = inspectorItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.didRestore else { return }
                UserDefaults.standard.set(!self.inspectorItem.isCollapsed, forKey: Self.inspectorVisibleKey)
            }
        }
    }

    func toggleInspector() {
        inspectorItem.animator().isCollapsed.toggle()
    }
}
