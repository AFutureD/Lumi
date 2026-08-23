import AppKit

/// Content insets shared by the detail column (Pairing, Settings): `24 28 28`.
@MainActor
enum DetailLayout {
    static let horizontalInset: CGFloat = 28
    static let topInset: CGFloat = 24
    static let bottomInset: CGFloat = 28
    static let headerToContentSpacing: CGFloat = 18
    static let minimumContentWidth: CGFloat = 344
    static let maximumContentWidth: CGFloat = 900
    static let minimumColumnWidth = Design.Layout.detailMinimumWidth

    /// `content.width == min(container − insets, maximumContentWidth)`.
    ///
    /// Only inequalities are required; the "grow to the maximum" preference sits
    /// below every split-view holding priority (250+) and far below the window's
    /// stay-put priority (500), so content can never resize a column or the window.
    static func adaptiveWidthConstraints(
        for content: NSView,
        in container: NSView
    ) -> [NSLayoutConstraint] {
        let preferredWidth = content.widthAnchor.constraint(equalToConstant: maximumContentWidth)
        preferredWidth.priority = NSLayoutConstraint.Priority(rawValue: 240)

        let minimumWidth = content.widthAnchor.constraint(
            greaterThanOrEqualToConstant: minimumContentWidth
        )
        minimumWidth.priority = NSLayoutConstraint.Priority(rawValue: 241)

        return [
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontalInset),
            content.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -horizontalInset),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: maximumContentWidth),
            minimumWidth,
            preferredWidth,
        ]
    }
}
