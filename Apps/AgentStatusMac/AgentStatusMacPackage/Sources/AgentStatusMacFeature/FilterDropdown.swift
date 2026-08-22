import AgentStatusDesignSystem
import AppKit
import SwiftUI

// L3 §3.4 Dropdown 多选过滤 FilterDropdown — macOS tier. One trigger per
// filter dimension drops a panel of checkbox rows, optionally cut into
// sub-groups whose header carries a tri-state "select all". Multi-select
// inside a dimension; dimensions intersect; a dimension never empties (the
// owner's model enforces that — see `SessionActivityFilter`).
//
// The panel is a borderless child window under the trigger (the handoff's
// chrome: radius 10, `.94` white over blur, `.5px` outline, `0 12 30` shadow,
// right-aligned to its trigger, no arrow) — `NSPopover` cannot drop the arrow,
// change its corner radius or take the design's alignment. Outside click,
// Esc, app deactivation, host resize and the trigger leaving the window all
// dismiss it.

// MARK: - Model

/// What one checkbox shows: all / none / some of its group.
enum FilterCheckboxState: Hashable, Sendable {
    case on
    case off
    case mixed
}

/// The leading visual of an option row: a category tag pill (72 wide) or a
/// level chip (26 wide).
enum FilterPanelLeading: Hashable, Sendable {
    case tag(label: String, style: DesignTagStyle)
    case chip(label: String, style: DesignTagStyle)
}

/// One option row. `count` is the pre-filter count of the current session;
/// a 0 stays in the list, dimmed.
struct FilterPanelOption: Hashable, Sendable, Identifiable {
    let id: String
    let leading: FilterPanelLeading
    let name: String
    var description: String?
    let count: Int
    let isSelected: Bool

    init(id: String, leading: FilterPanelLeading, name: String, description: String? = nil, count: Int, isSelected: Bool) {
        self.id = id
        self.leading = leading
        self.name = name
        self.description = description
        self.count = count
        self.isSelected = isSelected
    }
}

/// A sub-group of options. `title == nil` is the panel's only group: no
/// sub-group header is drawn (§3.4 "只有一个子分组时不画子分组头").
struct FilterPanelSection: Hashable, Sendable, Identifiable {
    let id: String
    let title: String?
    let options: [FilterPanelOption]

    init(id: String, title: String?, options: [FilterPanelOption]) {
        self.id = id
        self.title = title
        self.options = options
    }

    var count: Int { options.reduce(0) { $0 + $1.count } }

    /// Tri-state of the header checkbox: on when every option is selected,
    /// off when none is, mixed otherwise.
    var selection: FilterCheckboxState {
        let selected = options.count(where: \.isSelected)
        if selected == options.count { return .on }
        return selected == 0 ? .off : .mixed
    }
}

/// Everything the panel draws: the dimension's title (the group title row,
/// uppercase) and its sections. Pure data, so the open panel is refreshed by
/// value whenever counts or selection change.
struct FilterPanelModel: Hashable, Sendable {
    let title: String
    let sections: [FilterPanelSection]

    init(title: String, sections: [FilterPanelSection]) {
        self.title = title
        self.sections = sections
    }

    var options: [FilterPanelOption] { sections.flatMap(\.options) }
    var selectedCount: Int { options.count(where: \.isSelected) }
    /// Filtered = not every option selected (all selected is "unfiltered").
    var isFiltered: Bool { selectedCount < options.count }

    /// Rows with a description line are the taller 34pt variant.
    var rowHeight: Double {
        options.contains { $0.description != nil }
            ? DesignSystem.FilterDropdown.Panel.describedRowHeight
            : DesignSystem.FilterDropdown.Panel.rowHeight
    }

    /// Natural height of the whole panel (before the 420 cap).
    var contentHeight: Double {
        let panel = DesignSystem.FilterDropdown.Panel.self
        return sections.reduce(panel.headerHeight) { height, section in
            height + (section.title == nil ? 0 : panel.subgroupHeight) + Double(section.options.count) * rowHeight
        }
    }

    var panelHeight: Double {
        min(contentHeight, DesignSystem.FilterDropdown.Panel.maximumHeight)
    }
}

// MARK: - Trigger

/// Trigger button: 22 tall, radius 6, 11 / Regular title, count badge while
/// filtered, chevron that turns while the panel is open. Opening does not
/// change the fill — only the filtered state does.
struct FilterTriggerButton: View {
    let title: String
    let selectedCount: Int
    let isFiltered: Bool
    let isOpen: Bool
    let action: () -> Void

    private typealias T = DesignSystem.FilterDropdown.Trigger
    private typealias F = DesignSystem.FilterDropdown

    var body: some View {
        Button(action: action) {
            HStack(spacing: T.gap) {
                Text(title)
                    .designText(DesignSystem.Typography.subheadline)
                    .lineLimit(1)
                if isFiltered {
                    Text("\(selectedCount)")
                        .designText(DesignSystem.Typography.filterBadge)
                        .monospacedDigit()
                        .foregroundStyle(Color(F.badgeText))
                        .padding(.horizontal, T.badgeHorizontalPadding)
                        .frame(minWidth: T.badgeMinimumWidth)
                        .frame(height: T.badgeHeight)
                        .background(Color(F.badgeFill), in: Capsule())
                }
                Image(systemName: "chevron.down")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .fontWeight(.semibold)
                    .frame(width: T.chevronWidth, height: T.chevronHeight)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .animation(.easeInOut(duration: T.animationDuration), value: isOpen)
            }
            .foregroundStyle(isFiltered ? Color(F.filteredTrigger.text) : Color(F.triggerText))
            .padding(.horizontal, T.horizontalPadding)
            .frame(height: T.height)
            .background(
                isFiltered ? Color(F.filteredTrigger.fill) : Color(F.triggerFill),
                in: RoundedRectangle(cornerRadius: DesignSystem.Radius.filterTrigger, style: .continuous)
            )
            .overlay {
                if isFiltered {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.filterTrigger, style: .continuous)
                        .strokeBorder(Color(F.filteredTrigger.ring), lineWidth: T.ring)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.filterTrigger, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isFiltered ? "\(selectedCount) selected" : "All")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}

// MARK: - Panel content

/// The panel's rows: group title, then per section an optional tri-state
/// header and its option rows. The whole row toggles, not only the box.
struct FilterDropdownPanel: View {
    let model: FilterPanelModel
    let onToggleOption: (String) -> Void
    let onToggleSection: (String) -> Void

    private typealias P = DesignSystem.FilterDropdown.Panel
    private typealias F = DesignSystem.FilterDropdown

    var body: some View {
        VStack(spacing: 0) {
            Text(model.title.uppercased())
                .designText(DesignSystem.Typography.filterPanelHeader)
                .foregroundStyle(Color(F.headerText))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, P.horizontalPadding)
                .frame(height: P.headerHeight)
                .overlay(alignment: .bottom) {
                    Color(F.separator).frame(height: DesignSystem.Stroke.hairline)
                }
            // No indicator: a legacy scroller would reserve 17pt of the 232
            // and squeeze the name column; the cut-off last row shows there is more.
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(model.sections) { section in
                        if let title = section.title {
                            FilterSectionHeaderRow(title: title, count: section.count, state: section.selection) {
                                onToggleSection(section.id)
                            }
                        }
                        ForEach(section.options) { option in
                            FilterOptionRow(option: option, height: model.rowHeight) {
                                onToggleOption(option.id)
                            }
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: P.width, height: model.panelHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.title) filter")
    }
}

/// Sub-group header: 26 tall, `padding 0 10`, gap 8, grey fill, top hairline;
/// tri-state box · 11 / Semibold title · count.
private struct FilterSectionHeaderRow: View {
    let title: String
    let count: Int
    let state: FilterCheckboxState
    let action: () -> Void

    private typealias P = DesignSystem.FilterDropdown.Panel
    private typealias F = DesignSystem.FilterDropdown

    var body: some View {
        Button(action: action) {
            HStack(spacing: P.gap) {
                FilterCheckbox(state: state)
                Text(title)
                    .designText(DesignSystem.Typography.subheadlineEmphasized)
                    .foregroundStyle(Color(F.optionName))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(count)")
                    .designText(DesignSystem.Typography.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Color(F.countText))
            }
            .padding(.horizontal, P.horizontalPadding)
            .frame(height: P.subgroupHeight)
            .background(Color(F.subgroupFill))
            .overlay(alignment: .top) {
                Color(F.separator).frame(height: DesignSystem.Stroke.hairline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(state == .on ? "All selected" : state == .mixed ? "Partly selected" : "None selected")
    }
}

/// Option row: 28 tall (34 with a description), `padding 0 10`, gap 8, top
/// hairline, hover wash; box · tag pill / level chip · name (+ description) ·
/// count.
private struct FilterOptionRow: View {
    let option: FilterPanelOption
    let height: Double
    let action: () -> Void

    @State private var isHovered = false

    private typealias P = DesignSystem.FilterDropdown.Panel
    private typealias F = DesignSystem.FilterDropdown

    var body: some View {
        Button(action: action) {
            HStack(spacing: P.gap) {
                FilterCheckbox(state: option.isSelected ? .on : .off)
                leading
                VStack(alignment: .leading, spacing: 0) {
                    Text(option.name)
                        .designText(DesignSystem.Typography.filterOptionName)
                        .foregroundStyle(Color(F.optionName))
                        .lineLimit(1)
                    if let description = option.description {
                        Text(description)
                            .designText(DesignSystem.Typography.filterOptionDescription)
                            .foregroundStyle(Color(F.optionDescription))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(option.count)")
                    .designText(DesignSystem.Typography.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Color(F.countText))
            }
            .padding(.horizontal, P.horizontalPadding)
            .frame(height: height)
            .background(isHovered ? Color(F.rowHover) : .clear)
            .overlay(alignment: .top) {
                Color(F.separator).frame(height: DesignSystem.Stroke.hairline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(option.name)
        .accessibilityValue("\(option.count)")
        .accessibilityAddTraits(option.isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var leading: some View {
        switch option.leading {
        case let .tag(label, style):
            FilterLeadingPill(label: label, style: style, width: P.tagWidth)
        case let .chip(label, style):
            FilterLeadingPill(label: label, style: style, width: P.levelChipWidth)
        }
    }
}

/// The 72pt tag pill / 26pt level chip: radius 4, `padding 2 0`, the tag
/// typography, centred; `.5px` ring from the style.
private struct FilterLeadingPill: View {
    let label: String
    let style: DesignTagStyle
    let width: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignSystem.FilterDropdown.Panel.tagRadius, style: .continuous)
        Text(label)
            .designText(DesignSystem.Typography.tag)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(style.textColor)
            .padding(.vertical, DesignSystem.FilterDropdown.Panel.tagVerticalPadding)
            .frame(width: width)
            .background(style.fillColor, in: shape)
            .overlay { shape.strokeBorder(style.ringColor, lineWidth: DesignSystem.Tag.ring) }
    }
}

/// 14 × 14, radius 4. On: accent fill + white check. Mixed: accent fill +
/// white dash. Off: clear with a 1.2 inset ring.
struct FilterCheckbox: View {
    let state: FilterCheckboxState

    private typealias P = DesignSystem.FilterDropdown.Panel
    private typealias F = DesignSystem.FilterDropdown

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignSystem.Radius.checkbox, style: .continuous)
        ZStack {
            shape.fill(state == .off ? Color.clear : Color(F.checkboxOn))
            if state == .off {
                shape.strokeBorder(Color(F.checkboxRing), lineWidth: P.checkboxRing)
            }
            switch state {
            case .on:
                CheckMarkShape()
                    .stroke(Color(F.checkMark), style: StrokeStyle(lineWidth: P.checkStroke, lineCap: .round, lineJoin: .round))
                    .frame(width: P.checkWidth, height: P.checkHeight)
            case .mixed:
                Capsule()
                    .fill(Color(F.checkMark))
                    .frame(width: P.dashWidth, height: P.dashHeight)
            case .off:
                EmptyView()
            }
        }
        .frame(width: P.checkbox, height: P.checkbox)
    }
}

/// The handoff's check: `M1.6 6.4l4 4 8.8-8.8` in a 16 × 12 box.
private struct CheckMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 16, sy = rect.height / 12
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 1.6 * sx, y: rect.minY + 6.4 * sy))
        path.addLine(to: CGPoint(x: rect.minX + 5.6 * sx, y: rect.minY + 10.4 * sy))
        path.addLine(to: CGPoint(x: rect.minX + 14.4 * sx, y: rect.minY + 1.6 * sy))
        return path
    }
}

// MARK: - Anchor

/// Lets a SwiftUI trigger hand its AppKit geometry to the presenter: the
/// window it lives in and its frame, so the panel can drop under it. Also
/// reports when the trigger leaves the window / is hidden, which closes the
/// panel (a session switch, a sidebar change). Inert to the mouse.
@MainActor
final class FilterAnchorBox {
    fileprivate(set) weak var view: NSView?
    var onDetach: (() -> Void)?
}

struct FilterAnchor: NSViewRepresentable {
    let box: FilterAnchorBox

    func makeNSView(context: Context) -> FilterAnchorNSView {
        let view = FilterAnchorNSView()
        view.onDetach = { [box] in box.onDetach?() }
        box.view = view
        return view
    }

    func updateNSView(_ view: FilterAnchorNSView, context: Context) {
        box.view = view
    }
}

final class FilterAnchorNSView: NSView {
    var onDetach: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { onDetach?() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        onDetach?()
    }
}

// MARK: - Presenter

/// Owns the one open panel window. `present` replaces whatever is open
/// (opening the other dimension closes the first), `update` refreshes the
/// open panel's rows by value, `dismiss(id:)` closes it if that dimension is
/// the one showing. User-driven dismissals (outside click, Esc, deactivation,
/// host resize) call `onDismiss` so the owner's open-panel state follows;
/// programmatic ones do not — the owner already knows.
@MainActor
final class FilterDropdownPresenter {
    private(set) var presentedID: String?
    private var window: FilterDropdownWindow?
    private var hosting: NSHostingView<FilterDropdownChrome>?
    private weak var hostWindow: NSWindow?
    private var anchorRect: CGRect = .zero
    private var onDismiss: (() -> Void)?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    /// Margin around the panel inside its (transparent) window, holding the shadow.
    private static let shadowInset: CGFloat = 48

    func isPresenting(_ id: String) -> Bool { presentedID == id }

    func present(id: String, content: FilterDropdownPanel, anchor: FilterAnchorBox, onDismiss: @escaping () -> Void) {
        guard let anchorView = anchor.view, let host = anchorView.window else { return }
        if presentedID != nil { tearDown() }

        presentedID = id
        self.onDismiss = onDismiss
        hostWindow = host
        anchorRect = anchorView.convert(anchorView.bounds, to: nil)

        let chrome = FilterDropdownChrome(content: content, inset: Self.shadowInset)
        let hosting = NSHostingView(rootView: chrome)
        hosting.sizingOptions = []
        let window = FilterDropdownWindow(contentRect: frame(for: content.model), host: host)
        window.contentView = hosting
        window.appearance = NSAppearance(named: .aqua)
        self.window = window
        self.hosting = hosting

        host.addChildWindow(window, ordered: .above)
        window.alphaValue = 0
        window.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = 1
        }
        installMonitors(host: host)
    }

    func update(id: String, content: FilterDropdownPanel) {
        guard presentedID == id, let window, let hosting else { return }
        hosting.rootView = FilterDropdownChrome(content: content, inset: Self.shadowInset)
        let target = frame(for: content.model)
        if target != window.frame {
            window.setFrame(target, display: true)
        }
    }

    func dismiss(id: String) {
        guard presentedID == id else { return }
        tearDown()
    }

    func dismissAll() {
        guard presentedID != nil else { return }
        tearDown()
    }

    // MARK: Geometry

    /// Panel (+ shadow margin) in screen coordinates: top edge 8 under the
    /// trigger, right edge on the trigger's right edge, kept inside the host.
    private func frame(for model: FilterPanelModel) -> CGRect {
        guard let host = hostWindow else { return .zero }
        let panel = DesignSystem.FilterDropdown.Panel.self
        let anchor = host.convertToScreen(anchorRect)
        let size = CGSize(width: panel.width, height: model.panelHeight)
        var x = anchor.maxX - size.width
        x = max(host.frame.minX + panel.offset, min(x, host.frame.maxX - panel.offset - size.width))
        let y = anchor.minY - panel.offset - size.height
        return CGRect(x: x, y: y, width: size.width, height: size.height)
            .insetBy(dx: -Self.shadowInset, dy: -Self.shadowInset)
    }

    // MARK: Dismissal

    private func installMonitors(host: NSWindow) {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, let window = self.window else { return event }
            if event.window === window { return event }
            // A click on the trigger itself toggles through the button; do not
            // close first or the button would reopen what it meant to close.
            if event.window === self.hostWindow, self.anchorRect.contains(event.locationInWindow) { return event }
            self.dismissFromUser()
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window != nil, event.keyCode == 53 else { return event }
            self.dismissFromUser()
            return nil
        } as Any)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissFromUser() }
        })
        for name in [NSWindow.didResizeNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: host, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissFromUser() }
            })
        }
    }

    private func dismissFromUser() {
        guard presentedID != nil else { return }
        let callback = onDismiss
        tearDown()
        callback?()
    }

    private func tearDown() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let window {
            hostWindow?.removeChildWindow(window)
            window.orderOut(nil)
        }
        window = nil
        hosting = nil
        hostWindow = nil
        presentedID = nil
        onDismiss = nil
    }
}

/// Borderless, transparent, never key: the host window keeps focus, the
/// panel only takes clicks and hover.
private final class FilterDropdownWindow: NSPanel {
    init(contentRect: CGRect, host: NSWindow) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = host.level
        collectionBehavior = [.fullScreenAuxiliary, .transient]
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The panel chrome: radius 10, `.94` white over the system popover blur,
/// `.5px` outline, `0 12 30 .18` shadow; the content clipped inside. Padded
/// by `inset` so the shadow fits in the window.
private struct FilterDropdownChrome: View {
    let content: FilterDropdownPanel
    let inset: CGFloat

    private typealias F = DesignSystem.FilterDropdown

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignSystem.Radius.filterPanel, style: .continuous)
        content
            .background {
                ZStack {
                    FilterPanelBlur()
                    Color(F.panelFill)
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color(F.panelOutline), lineWidth: F.Panel.outline) }
            .shadow(color: Color(F.panelShadow), radius: F.Panel.shadowBlur / 2, x: 0, y: F.Panel.shadowOffsetY)
            .padding(inset)
            .environment(\.colorScheme, .light)
    }
}

private struct FilterPanelBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
