import Foundation

/// A platform-neutral sRGB colour from the design system.
///
/// Values are stored as 0…1 components so every client (AppKit, UIKit,
/// SwiftUI) converts without rounding surprises. Each platform adds its own
/// adapter (`NSColor(design)`, `UIColor(design)`, `Color(design)`).
public struct DesignColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#RRGGBB` as written in the design system (`hex: 0x0078F0`).
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// `rgb(r,g,b)` / `rgba(r,g,b,a)` as written in the design system.
    public init(rgb red: Int, _ green: Int, _ blue: Int, alpha: Double = 1) {
        self.init(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, alpha: alpha)
    }

    /// Neutral grey (`white: 1, alpha: .38` ⇢ `rgba(255,255,255,.38)`).
    public init(white: Double, alpha: Double = 1) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    public static let clear = DesignColor(white: 0, alpha: 0)
    public static let white = DesignColor(white: 1)
    public static let black = DesignColor(white: 0)

    /// Same hue at a different opacity (`rgba(0,120,240,.16)`).
    public func opacity(_ alpha: Double) -> DesignColor {
        var copy = self
        copy.alpha = alpha
        return copy
    }

    /// Source-over composite of `self` above `background`, folded into one
    /// opaque-ish colour. Used where the handoff stacks two translucent layers
    /// (e.g. a white veil above a tinted pill fill).
    public func composited(over background: DesignColor) -> DesignColor {
        let outAlpha = alpha + background.alpha * (1 - alpha)
        guard outAlpha > 0 else { return .clear }
        func channel(_ top: Double, _ bottom: Double) -> Double {
            (top * alpha + bottom * background.alpha * (1 - alpha)) / outAlpha
        }
        return DesignColor(
            red: channel(red, background.red),
            green: channel(green, background.green),
            blue: channel(blue, background.blue),
            alpha: outAlpha
        )
    }
}

/// Light / dark pair. `Light` is the macOS app (light surfaces); `dark` is
/// the Notch's dark glass and the iOS dark appearance.
public struct AdaptiveDesignColor: Hashable, Sendable {
    public var light: DesignColor
    public var dark: DesignColor

    public init(light: DesignColor, dark: DesignColor) {
        self.light = light
        self.dark = dark
    }

    /// Same value in both appearances.
    public init(_ color: DesignColor) {
        self.init(light: color, dark: color)
    }

    public func resolve(_ appearance: DesignAppearance) -> DesignColor {
        appearance == .dark ? dark : light
    }
}

public enum DesignAppearance: Hashable, Sendable {
    case light
    case dark
}
