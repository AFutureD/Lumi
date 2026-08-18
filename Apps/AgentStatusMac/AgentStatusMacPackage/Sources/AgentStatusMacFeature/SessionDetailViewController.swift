import AgentStatusCore
import AgentStatusTransport
import AppKit
import SwiftUI

@MainActor
final class SessionDetailViewController: NSViewController {
    private let store: MacSessionStore
    private let renderer = SessionPagePresentationRenderer()

    private let headerView = NSView()
    private let titleLabel = NSTextField(labelWithString: "Select a Session")
    private let headerSeparator = NSBox()
    private var hostingView: NSHostingView<SessionDetailScrollableView>!
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

        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        headerSeparator.boxType = .separator

        [titleLabel, headerSeparator].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            headerView.addSubview($0)
        }

        hostingView = NSHostingView(rootView: makeScrollableView())
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        [headerView, hostingView, emptyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 72),
            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 32),
            titleLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -32),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            headerSeparator.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 32),
            headerSeparator.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -32),
            headerSeparator.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),

            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: hostingView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: hostingView.centerYAnchor),
        ])

        reload()
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
            titleLabel.stringValue = "Select a Session"
            hostingView.rootView = makeScrollableView()
            emptyLabel.isHidden = false
            return
        }

        titleLabel.stringValue = SessionListRowPresentation(session: detail.summary).title
        titleLabel.toolTip = detail.summary.title
        emptyLabel.isHidden = true

        if sessionChanged {
            presentation = nil
            hostingView.rootView = makeScrollableView()
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
        titleLabel.stringValue = rendered.title
        hostingView.rootView = makeScrollableView()
    }

    private func makeScrollableView() -> SessionDetailScrollableView {
        return SessionDetailScrollableView(
            presentation: presentation,
            onPreview: { [weak self] activity in
                self?.showRawData(for: activity)
            }
        )
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
        textView.string = SessionPagePresentationBuilder.rawData(for: activity.rawItem)
        textView.textContainer?.widthTracksTextView = true

        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.borderType = .bezelBorder

        let alert = NSAlert()
        alert.messageText = "\(activity.category.tag) Raw Data"
        alert.informativeText = activity.occurredAt
        alert.accessoryView = textScroll
        alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: hostWindow)
    }
}
