import AgentStatusDesignSystem
import UIKit

/// Activity detail: a medium-detent sheet with the row's tag + title, then
/// its sections (Command / Output for tools, the text otherwise). Failed
/// rows open expanded so the output is in view.
@MainActor
final class ActivityDetailSheetViewController: UIViewController {
    private let presentation: ActivityDetailPresentation

    init(presentation: ActivityDetailPresentation) {
        self.presentation = presentation
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = presentation.isFailed ? .large : .medium
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = IOSDS.Sheet.topRadius
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let s = IOSDS.Sheet.self

        let tag = TagView()
        tag.configure(
            tag: presentation.tag,
            label: presentation.label,
            verticalPadding: s.tagVerticalPadding,
            horizontalPadding: s.tagHorizontalPadding,
            radius: s.tagRadius
        )
        let titleLabel = UILabel()
        titleLabel.setText(presentation.title, style: IOSDS.Typography.sheetTitle, color: .inkPrimary)
        titleLabel.numberOfLines = 1
        let done = UIButton(type: .system)
        done.setTitle("Done", for: .normal)
        done.titleLabel?.font = .design(IOSDS.Typography.action)
        done.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        done.setContentHuggingPriority(.required, for: .horizontal)
        done.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleRow = UIStackView(arrangedSubviews: [tag, titleLabel, done])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = s.titleGap
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        let titleLine = UIView.hairline(color: .blockSeparator)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        let body = UIStackView()
        body.axis = .vertical
        body.spacing = s.sectionGap
        body.translatesAutoresizingMaskIntoConstraints = false
        for section in presentation.sections {
            body.addArrangedSubview(makeSection(section))
        }
        scroll.addSubview(body)

        view.addSubview(titleRow)
        view.addSubview(titleLine)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: view.topAnchor, constant: 22 + s.titleTop),
            titleRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: IOSDS.Layout.sideInset),
            titleRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -IOSDS.Layout.sideInset),
            titleLine.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: s.titleBottom),
            titleLine.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titleLine.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: titleLine.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            body.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: s.bodyTop),
            body.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: IOSDS.Layout.sideInset),
            body.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -IOSDS.Layout.sideInset),
            body.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -s.sectionGap),
            body.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -IOSDS.Layout.sideInset * 2),
        ])
    }

    private func makeSection(_ section: ActivityDetailSection) -> UIView {
        let s = IOSDS.Sheet.self
        let title = UILabel()
        title.font = .design(IOSDS.Typography.captionEmphasized)
        title.textColor = .inkTertiary
        title.text = section.title

        let text = UILabel()
        text.numberOfLines = 0
        if section.isMonospaced {
            text.setText(section.text, style: section.title == "Output" ? IOSDS.Typography.output : IOSDS.Typography.code,
                         color: section.title == "Output" ? UIColor(IOSDS.Color.output) : .inkPrimary)
            text.lineBreakMode = .byCharWrapping
        } else {
            text.setText(section.text, style: IOSDS.Typography.body, color: .inkPrimary)
            text.lineBreakMode = .byWordWrapping
        }
        let block = UIView()
        block.backgroundColor = .tertiarySystemFill
        block.layer.cornerRadius = s.codeRadius
        block.layer.cornerCurve = .continuous
        text.translatesAutoresizingMaskIntoConstraints = false
        block.addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: block.topAnchor, constant: s.codeVerticalPadding),
            text.bottomAnchor.constraint(equalTo: block.bottomAnchor, constant: -s.codeVerticalPadding),
            text.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: s.codeHorizontalPadding),
            text.trailingAnchor.constraint(equalTo: block.trailingAnchor, constant: -s.codeHorizontalPadding),
        ])
        let stack = UIStackView(arrangedSubviews: [title, block])
        stack.axis = .vertical
        stack.spacing = s.sectionTitleGap
        return stack
    }
}
