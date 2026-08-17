import AppKit

@MainActor
enum AgentStatusDetailLayout {
    static let horizontalInset: CGFloat = 32
    static let topInset: CGFloat = 26
    static let bottomInset: CGFloat = 30
    static let headerToContentSpacing: CGFloat = 18
    static let minimumContentWidth: CGFloat = 376
    static let maximumContentWidth: CGFloat = 720
    static let minimumColumnWidth = minimumContentWidth + (horizontalInset * 2)

    static func adaptiveWidthConstraints(
        for content: NSView,
        in container: NSView
    ) -> [NSLayoutConstraint] {
        let adaptiveWidth = content.widthAnchor.constraint(
            equalTo: container.widthAnchor,
            constant: -(horizontalInset * 2)
        )
        adaptiveWidth.priority = .defaultHigh

        let preferredMaximumWidth = content.widthAnchor.constraint(
            equalToConstant: maximumContentWidth
        )
        preferredMaximumWidth.priority = .defaultLow

        return [
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontalInset),
            content.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -horizontalInset),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumContentWidth),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: maximumContentWidth),
            adaptiveWidth,
            preferredMaximumWidth,
        ]
    }
}
