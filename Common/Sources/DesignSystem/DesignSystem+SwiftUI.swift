#if canImport(SwiftUI)
import SwiftUI

// MARK: - Adapters

public extension DesignFontWeight {
    var swiftUI: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

public extension Color {
    init(_ design: DesignColor) {
        self.init(.sRGB, red: design.red, green: design.green, blue: design.blue, opacity: design.alpha)
    }

    init(_ design: AdaptiveDesignColor, appearance: DesignAppearance) {
        self.init(design.resolve(appearance))
    }
}

public extension ShapeStyle where Self == Color {
    /// `.foregroundStyle(.design(DesignSystem.Ink.primary))`.
    static func design(_ color: DesignColor) -> Color { Color(color) }
}

public extension Font {
    /// System font for a design text style. Mono styles use the monospaced
    /// design with tabular numerals.
    init(_ style: DesignTextStyle) {
        switch style.family {
        case .sans:
            self = .system(size: style.size, weight: style.weight.swiftUI)
        case .mono:
            self = .system(size: style.size, weight: style.weight.swiftUI, design: .monospaced).monospacedDigit()
        }
    }
}

public extension View {
    /// Font, tracking and line spacing of a design text style in one call.
    func designText(_ style: DesignTextStyle) -> some View {
        font(Font(style))
            .kerning(style.tracking)
            .lineSpacing(style.lineSpacing)
    }
}

public extension DesignTagStyle {
    var fillColor: Color { Color(fill) }
    var textColor: Color { Color(text) }
    var ringColor: Color { Color(ring) }
}

public extension DesignStatusPillStyle {
    var fillColor: Color { Color(fill) }
    var ringColor: Color { Color(ring) }
    var dotColor: Color { Color(dot) }
    var textColor: Color { Color(text) }
}

// MARK: - 2.6 Tag

/// The category tag: 5pt-radius rectangle, height 17, `padding 0 6`,
/// 9 / Medium / .04em, `.5px` inset ring in every tier. Give it the column
/// width from outside (`.frame(width: DesignSystem.Tag.width)`); `compact` is
/// the Notch's 60pt variant (`.03em`).
public struct DesignTag: View {
    public let label: String
    public let style: DesignTagStyle
    public var compact = false

    public init(_ label: String, style: DesignTagStyle, compact: Bool = false) {
        self.label = label
        self.style = style
        self.compact = compact
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignSystem.Tag.radius, style: .continuous)
        Text(label)
            .designText(compact ? DesignSystem.Typography.tagCompact : DesignSystem.Typography.tag)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(style.textColor)
            .padding(.horizontal, DesignSystem.Tag.horizontalPadding)
            .frame(maxWidth: .infinity)
            .frame(height: DesignSystem.Tag.height)
            .background(style.fillColor, in: shape)
            .overlay { shape.strokeBorder(style.ringColor, lineWidth: DesignSystem.Tag.ring) }
    }
}

// MARK: - 3.1 Status pill

/// Solid dot + label in a capsule: height 22, `padding 0 10`, 6px slot after
/// the 7px dot, 11 / Semibold, `.5px` ring. `compact` is the Notch header
/// variant (20 tall, `padding 0 8`, 6px dot, 10 / Medium).
public struct DesignStatusPill: View {
    public let text: String
    public let style: DesignStatusPillStyle
    public var compact = false

    public init(_ text: String, style: DesignStatusPillStyle, compact: Bool = false) {
        self.text = text
        self.style = style
        self.compact = compact
    }

    private typealias M = DesignSystem.StatusPill

    public var body: some View {
        HStack(spacing: M.dotGap) {
            Circle()
                .fill(style.dotColor)
                .frame(width: compact ? M.notchDot : M.dot, height: compact ? M.notchDot : M.dot)
            Text(text)
                .designText(compact ? DesignSystem.Typography.notchLabel : DesignSystem.Typography.pill)
                .foregroundStyle(style.textColor)
                .lineLimit(1)
        }
        .padding(.horizontal, compact ? M.notchHorizontalPadding : M.horizontalPadding)
        .frame(height: compact ? M.notchHeight : M.height)
        .background(style.fillColor, in: Capsule())
        .overlay { Capsule().strokeBorder(style.ringColor, lineWidth: M.ring) }
    }
}
#endif
