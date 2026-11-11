import AppKit
import Core
import DesignSystem
import SwiftUI
import Transport

/// State of the sheet an Activity row opens: the row's records read for a
/// person (`ActivityPreview`), and the same records as stored (Raw). A row
/// the cache holds trimmed opens at once from its trimmed copies and takes
/// the whole ones when the daemon answers.
@MainActor
final class ActivityPreviewModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case preview = "Preview"
        case raw = "Raw"

        var id: String { rawValue }
    }

    /// What the sheet says while (or instead of) showing the whole records.
    enum Note: Equatable {
        case loading
        case failed(String)

        var text: String {
            switch self {
            case .loading: "Loading full content…"
            case let .failed(reason): "Couldn't load full content: \(reason)"
            }
        }
    }

    let label: String
    let tag: TimelineTag
    let occurredAt: String

    @Published var mode: Mode = .preview
    @Published private(set) var preview: ActivityPreview
    @Published private(set) var raw: String
    @Published private(set) var note: Note?

    init(activity: SessionActivityPresentation, preview: ActivityPreview) {
        label = activity.label
        tag = activity.tag
        occurredAt = activity.occurredAt
        self.preview = preview
        // The trimmed copy is never passed off as the stored record: Raw
        // waits for the whole one.
        let waits = !preview.truncatedItemIDs.isEmpty
        note = waits ? .loading : nil
        raw = waits ? Note.loading.text : SessionPagePresentationBuilder.rawData(for: preview.items)
    }

    func install(whole items: [TimelineItem]) {
        preview = ActivityPreviewBuilder.make(tag: preview.tag, title: preview.title, items: items)
        raw = SessionPagePresentationBuilder.rawData(for: items)
        note = nil
    }

    func fail(_ error: Error) {
        let failure = Note.failed("\(error)")
        note = failure
        raw = failure.text + "\n\n" + SessionPagePresentationBuilder.rawData(for: preview.items)
    }
}

/// `[tag] …………… [Preview | Raw]`, the sections (or the stored record), then
/// the time and Done. No title: the row that was clicked already says it.
@MainActor
struct ActivityPreviewSheet: View {
    @ObservedObject var model: ActivityPreviewModel
    let onDone: () -> Void

    static let size = CGSize(width: 760, height: 560)

    var body: some View {
        VStack(spacing: 0) {
            header
            Design.Color.UI.activityHairline.frame(height: 1)
            Group {
                switch model.mode {
                case .preview: previewBody
                case .raw: TextBlock(text: model.raw, style: .code, fillsHeight: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Design.Color.UI.activityHairline.frame(height: 1)
            footer
        }
        // One size for both views: switching to Raw must not move the sheet.
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Design.Layout.activityColumnGap) {
            DesignTag(model.label, style: model.tag.tagStyle(.light))
                .frame(width: Design.Layout.activityTagWidth)
            Spacer(minLength: 0)
            Picker("View", selection: $model.mode) {
                ForEach(ActivityPreviewModel.Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.vertical, DesignSystem.Spacing.l)
    }

    private var previewBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                if let note = model.note {
                    Text(note.text)
                        .font(Design.Font.UI.caption)
                        .foregroundStyle(note == .loading ? Design.Color.UI.inkTertiary : Design.Color.UI.destructiveText)
                        .textSelection(.enabled)
                }
                if !model.preview.facts.isEmpty { FactsGrid(facts: model.preview.facts) }
                ForEach(Array(model.preview.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.s) {
                        Text(section.title)
                            .font(Design.Font.UI.group)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        SectionBody(content: section.body)
                    }
                }
                if model.preview.sections.isEmpty, model.preview.facts.isEmpty {
                    Text("No content")
                        .font(Design.Font.UI.body)
                        .foregroundStyle(Design.Color.UI.inkTertiary)
                }
            }
            .padding(DesignSystem.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var footer: some View {
        HStack {
            Text(model.occurredAt)
                .font(Design.Font.UI.monoSmall)
                .foregroundStyle(Design.Color.UI.inkQuaternary)
            Spacer()
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.vertical, DesignSystem.Spacing.l)
    }
}

// MARK: - Sections

private struct SectionBody: View {
    let content: ActivityPreview.Body

    /// Text past this length goes to a text view: it scrolls on its own and
    /// lays out lazily, where a SwiftUI `Text` would lay out every glyph.
    private static let inlineTextLimit = 4_000

    var body: some View {
        switch content {
        case let .prose(text):
            if text.count > Self.inlineTextLimit {
                TextBlock(text: text, style: .prose)
            } else {
                Text(text).modifier(Prose())
            }
        case let .markdown(text):
            if text.count > Self.inlineTextLimit {
                TextBlock(text: text, style: .prose)
            } else {
                Text(Self.markdown(text)).modifier(Prose())
            }
        case let .code(text):
            TextBlock(text: text, style: .code)
        case let .diff(text):
            TextBlock(text: text, style: .diff)
        case let .image(image):
            PreviewImage(image: image)
        case let .facts(facts):
            FactsGrid(facts: facts)
        case let .links(links):
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.m) {
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    VStack(alignment: .leading, spacing: 2) {
                        if let url = link.url.flatMap(URL.init(string:)) {
                            Link(link.title, destination: url).font(Design.Font.UI.body)
                        } else {
                            Text(link.title).font(Design.Font.UI.body).textSelection(.enabled)
                        }
                        if let url = link.url, url != link.title {
                            Text(url)
                                .font(Design.Font.UI.monoSmall)
                                .foregroundStyle(Design.Color.UI.inkTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        if let detail = link.detail {
                            Text(detail)
                                .font(Design.Font.UI.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    /// Inline Markdown only, line breaks kept: a message is shown as it was
    /// written, with its emphasis, code spans and links read.
    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct Prose: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Design.Font.UI.body)
            .foregroundStyle(Design.Color.UI.inkPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `label  value` rows; a value with line breaks or of some length gets a
/// block of its own under its label.
private struct FactsGrid: View {
    let facts: [ActivityPreview.Fact]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.s) {
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                if fact.value.count > 120 || fact.value.contains(where: \.isNewline) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        label(fact.label)
                        TextBlock(text: fact.value, style: .code, maximumHeight: 200)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.l) {
                        label(fact.label).frame(width: 132, alignment: .leading)
                        Text(fact.value)
                            .font(Design.Font.UI.mono)
                            .foregroundStyle(Design.Color.UI.inkPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Design.Font.UI.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

private struct PreviewImage: View {
    let image: ActivityPreview.Image

    var body: some View {
        if let picture = Self.load(image) {
            Image(nsImage: picture)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: min(picture.size.width, 680), maxHeight: 420, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.card, style: .continuous)
                        .strokeBorder(Design.Color.UI.cardStroke)
                )
        } else {
            Text(Self.unavailable(image))
                .font(Design.Font.UI.caption)
                .foregroundStyle(Design.Color.UI.inkTertiary)
                .textSelection(.enabled)
        }
    }

    private static func load(_ image: ActivityPreview.Image) -> NSImage? {
        switch image {
        case let .base64(text):
            // A trimmed copy holds the first bytes only: not an image yet.
            Data(base64Encoded: text, options: .ignoreUnknownCharacters).flatMap(NSImage.init(data:))
        case let .file(path):
            NSImage(contentsOfFile: path)
        }
    }

    private static func unavailable(_ image: ActivityPreview.Image) -> String {
        switch image {
        case .base64: "The image could not be read."
        case let .file(path): "The image is no longer at \(path)."
        }
    }
}

// MARK: - Text block

/// Read-only, selectable text in a card: as tall as its text up to
/// `maximumHeight`, scrolling past it — or the whole space offered
/// (`fillsHeight`, the Raw view).
private struct TextBlock: View {
    enum Style {
        case prose
        case code
        case diff
    }

    let text: String
    let style: Style
    var maximumHeight: CGFloat = 320
    var fillsHeight = false

    var body: some View {
        let block = TextBlockView(text: text, style: style, maximumHeight: fillsHeight ? nil : maximumHeight)
        if fillsHeight {
            block
        } else {
            block
                .background(Design.Color.UI.zebra)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.card, style: .continuous)
                        .strokeBorder(Design.Color.UI.cardStroke)
                )
        }
    }
}

private struct TextBlockView: NSViewRepresentable {
    let text: String
    let style: TextBlock.Style
    /// `nil` takes whatever height is offered.
    let maximumHeight: CGFloat?

    private static let inset = NSSize(width: 10, height: 8)
    /// Past this the text is not measured: it gets the full height at once.
    private static let measuredCharacterLimit = 200_000

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = Self.inset
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        let attributed = Self.attributed(text, style: style)
        if textView.textStorage?.isEqual(to: attributed) != true {
            textView.textStorage?.setAttributedString(attributed)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        // Filling: exactly the space offered, whatever the text would like.
        guard let maximumHeight else { return proposal.replacingUnspecifiedDimensions(by: CGSize(width: 640, height: 400)) }
        let width = proposal.width ?? 640
        guard text.count <= Self.measuredCharacterLimit else { return CGSize(width: width, height: maximumHeight) }
        let bounds = Self.attributed(text, style: style).boundingRect(
            with: NSSize(width: max(1, width - Self.inset.width * 2 - 10), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let height = ceil(bounds.height) + Self.inset.height * 2
        return CGSize(width: width, height: min(max(height, 28), maximumHeight))
    }

    private static func attributed(_ text: String, style: TextBlock.Style) -> NSAttributedString {
        let font = style == .prose ? Design.Font.body : Design.Font.mono
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Design.Color.inkPrimary]
        guard style == .diff else { return NSAttributedString(string: text, attributes: base) }
        // Added lines green, removed lines red, hunk headers quiet.
        let result = NSMutableAttributedString()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            var attributes = base
            if line.hasPrefix("@@") || line.hasPrefix("+++") || line.hasPrefix("---") {
                attributes[.foregroundColor] = Design.Color.inkTertiary
            } else if line.hasPrefix("+") {
                attributes[.foregroundColor] = NSColor.systemGreen.blended(withFraction: 0.35, of: .black) ?? .systemGreen
            } else if line.hasPrefix("-") {
                attributes[.foregroundColor] = Design.Color.destructiveText
            }
            result.append(NSAttributedString(string: String(line) + (index < lines.count - 1 ? "\n" : ""), attributes: attributes))
        }
        return result
    }
}
