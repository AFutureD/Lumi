#if canImport(SwiftUI)
import SwiftUI

public extension DesignFontWeight {
    var swiftUI: Font.Weight {
        switch self {
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

public extension TimelineTagStyle {
    var fillColor: Color { Color(fill) }
    var textColor: Color { Color(text) }
    var ringColor: Color { Color(ring) }
}

public extension SessionStatusToneStyle {
    var swiftUIColor: Color { Color(color) }
    var haloColor: Color? { halo.map(Color.init) }
    var pillFillColor: Color { Color(pillFill) }
    var pillRingColor: Color { Color(pillRing) }
    var pillTextColor: Color { Color(pillText) }
}
#endif
