#if canImport(SwiftUI)
import SwiftUI

// MARK: - Adapters

public extension DesignFontWeight {
    var swiftUI: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
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

public extension DesignStatusDotStyle {
    var swiftUIColor: Color { Color(color) }
    var haloColor: Color { Color(halo) }
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

// MARK: - 2.7 Status dot

/// The status dot in its three forms. Hollow draws a 1.5px ring; solid
/// fills; breathing fills and pulses a halo (`haloWidth` each side) between
/// full and `DesignSystem.Opacity.breathingHalo` every 0.8s.
public struct DesignStatusDot: View {
    public let style: DesignStatusDotStyle
    public var size: Double = DesignSystem.StatusDot.size
    public var haloWidth: Double = DesignSystem.StatusDot.halo
    @State private var breathing = false

    public init(
        _ style: DesignStatusDotStyle,
        size: Double = DesignSystem.StatusDot.size,
        haloWidth: Double = DesignSystem.StatusDot.halo
    ) {
        self.style = style
        self.size = size
        self.haloWidth = haloWidth
    }

    public var body: some View {
        ZStack {
            if style.breathes {
                Circle()
                    .fill(style.haloColor)
                    .frame(width: size + haloWidth * 2, height: size + haloWidth * 2)
                    .opacity(breathing ? DesignSystem.Opacity.breathingHalo : 1)
            }
            if style.isHollow {
                Circle()
                    .strokeBorder(style.swiftUIColor, lineWidth: DesignSystem.StatusDot.hollowRing)
                    .frame(width: size, height: size)
            } else {
                Circle()
                    .fill(style.swiftUIColor)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .onAppear { breathing = style.breathes }
        .onChange(of: style.form) { _, _ in breathing = style.breathes }
        .animation(
            style.breathes ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
            value: breathing
        )
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
