import AgentStatusDesignSystem
import UIKit

/// An 8pt round dot used as a trailing list-cell accessory (Macs online
/// state, notification permission). Stays round whatever size the accessory
/// system lays it out at.
final class DotAccessoryView: UIView {
    init(color: UIColor, size: Double = IOSDS.MacRow.dot) {
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        backgroundColor = color
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
    }
}

extension UICellAccessory {
    static func dot(_ color: UIColor) -> UICellAccessory {
        .customView(configuration: .init(
            customView: DotAccessoryView(color: color),
            placement: .trailing(),
            reservedLayoutWidth: .custom(IOSDS.MacRow.dot),
            maintainsFixedSize: true
        ))
    }
}
