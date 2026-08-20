import Foundation

/// Namespace of every design token. Source of truth: `design/DESIGN SYSTEM.html`
/// — L1 基础规范 (palette, roles, type, spacing), L2 原子组件 (tag, status
/// dot), L3 分子组件 (status pill, rows, lanes). Views never write a colour,
/// size or weight literal; they read it from here.
public enum DesignSystem {}

/// The seven hues of the palette. Every saturated colour on any surface is
/// one of these at some step; `neutral` is the grey ladder.
public enum DesignHue: Hashable, Sendable, CaseIterable {
    case neutral
    case blue
    case green
    case red
    case yellow
    case purple
    case orange
}

/// One light ramp: eight steps `700 → 50`, `600` is the default (`P`) step.
/// `500 → 50` mix the base with white at 21 / 44 / 66 / 86 / 93 / 97 %.
public struct DesignRamp: Hashable, Sendable {
    public var s700: DesignColor
    public var s600: DesignColor
    public var s500: DesignColor
    public var s400: DesignColor
    public var s300: DesignColor
    public var s200: DesignColor
    public var s100: DesignColor
    public var s50: DesignColor

    public init(_ s700: UInt32, _ s600: UInt32, _ s500: UInt32, _ s400: UInt32,
                _ s300: UInt32, _ s200: UInt32, _ s100: UInt32, _ s50: UInt32) {
        self.s700 = DesignColor(hex: s700)
        self.s600 = DesignColor(hex: s600)
        self.s500 = DesignColor(hex: s500)
        self.s400 = DesignColor(hex: s400)
        self.s300 = DesignColor(hex: s300)
        self.s200 = DesignColor(hex: s200)
        self.s100 = DesignColor(hex: s100)
        self.s50 = DesignColor(hex: s50)
    }

    /// The default step (`600`).
    public var base: DesignColor { s600 }
}

/// One dark ramp — **its own curve, not derived from the light ramp**. Light
/// steps desaturate as they mix with white; dark needs lift with saturation
/// kept. Five steps `D700 → D300`, `D500` is the default (`P`) step.
public struct DesignDarkRamp: Hashable, Sendable {
    public var d700: DesignColor
    public var d600: DesignColor
    public var d500: DesignColor
    public var d400: DesignColor
    public var d300: DesignColor

    public init(_ d700: UInt32, _ d600: UInt32, _ d500: UInt32, _ d400: UInt32, _ d300: UInt32) {
        self.d700 = DesignColor(hex: d700)
        self.d600 = DesignColor(hex: d600)
        self.d500 = DesignColor(hex: d500)
        self.d400 = DesignColor(hex: d400)
        self.d300 = DesignColor(hex: d300)
    }

    /// The default step (`D500`).
    public var base: DesignColor { d500 }
}

public extension DesignSystem {
    /// 1.1 色板. Raw ramps; roles (`Ink`, `Surface`, `Semantic`) pick from here.
    enum Palette {
        public static let black = DesignColor.black
        public static let white = DesignColor.white

        // MARK: Light ramps (700 → 50)

        public static let neutral = DesignRamp(0x1A1A1A, 0x404040, 0x727272, 0x8A8A8A, 0xCACACA, 0xE2E2E2, 0xF2F2F2, 0xFAFAFA)
        public static let blue = DesignRamp(0x0069D7, 0x0078F0, 0x3694F3, 0x70B3F7, 0xA8D1FA, 0xDBECFD, 0xEDF6FE, 0xF7FBFE)
        public static let green = DesignRamp(0x199242, 0x1DA84C, 0x4CBA72, 0x80CE9B, 0xB2E1C2, 0xDFF3E6, 0xEFF9F1, 0xF8FDF9)
        public static let red = DesignRamp(0xB3261E, 0xE5352F, 0xEA5F5B, 0xF08E8A, 0xF6BAB8, 0xFBE3E2, 0xFDF1F0, 0xFEF9F9)
        public static let yellow = DesignRamp(0xD19D00, 0xF0B400, 0xF3C436, 0xF7D570, 0xFAE6A8, 0xFDF3D6, 0xFEFAED, 0xFEFDF7)
        public static let purple = DesignRamp(0x7C37CA, 0x8E3FE8, 0xA667ED, 0xC093F2, 0xD9BEF7, 0xEFE4FC, 0xF7F1FE, 0xFCF9FE)
        public static let orange = DesignRamp(0xCE5C0A, 0xED6A0C, 0xF1893F, 0xF5AC77, 0xF9CCAC, 0xFCE7D8, 0xFEF5EF, 0xFEFBF8)

        // MARK: Dark ramps (D700 → D300). The only dark surface is `#000`.

        /// The one dark panel colour — solid, no material, no stroke, no shadow.
        public static let surfaceDark = DesignColor.black
        public static let blueDark = DesignDarkRamp(0x0069D7, 0x2A8CFF, 0x4C9BFF, 0x9DC7FF, 0xC8E0FF)
        public static let greenDark = DesignDarkRamp(0x1DA84C, 0x22B856, 0x34C759, 0x5EE07E, 0x96EFAF)
        public static let redDark = DesignDarkRamp(0xC42B24, 0xE5352F, 0xEE4038, 0xFF8A83, 0xFFBAB6)
        public static let yellowDark = DesignDarkRamp(0xD19D00, 0xF0B400, 0xF5C862, 0xF9DC9A, 0xFCEBC7)
        public static let purpleDark = DesignDarkRamp(0x8E3FE8, 0xA97BF0, 0xC9AEFB, 0xDCC8FC, 0xEBE0FE)
        public static let orangeDark = DesignDarkRamp(0xED6A0C, 0xF58F42, 0xFFB27A, 0xFFCBA3, 0xFFE0C9)

        /// Neutral "no saturation" marker colour for L1 lane cells and bars.
        public static let neutralMarker = DesignColor(hex: 0xE7E8EC)
        /// Completed / Idle dot on light surfaces (between Neutral 500 and 400).
        public static let neutralDot = DesignColor(rgb: 110, 113, 120)
    }
}

public extension DesignHue {
    /// Light ramp of the hue.
    var ramp: DesignRamp {
        switch self {
        case .neutral: DesignSystem.Palette.neutral
        case .blue: DesignSystem.Palette.blue
        case .green: DesignSystem.Palette.green
        case .red: DesignSystem.Palette.red
        case .yellow: DesignSystem.Palette.yellow
        case .purple: DesignSystem.Palette.purple
        case .orange: DesignSystem.Palette.orange
        }
    }

    /// Dark ramp of the hue; `neutral` has none (it is white at an opacity).
    var darkRamp: DesignDarkRamp? {
        switch self {
        case .neutral: nil
        case .blue: DesignSystem.Palette.blueDark
        case .green: DesignSystem.Palette.greenDark
        case .red: DesignSystem.Palette.redDark
        case .yellow: DesignSystem.Palette.yellowDark
        case .purple: DesignSystem.Palette.purpleDark
        case .orange: DesignSystem.Palette.orangeDark
        }
    }

    /// Saturated base on light surfaces: step `600` (`neutral` → the
    /// Completed dot grey `rgb(110,113,120)`).
    var base: DesignColor {
        self == .neutral ? DesignSystem.Palette.neutralDot : ramp.s600
    }

    /// Saturated base on the dark panel: step `D500` (`neutral` → white 42 %).
    var darkBase: DesignColor {
        darkRamp?.d500 ?? DesignColor(white: 1, alpha: 0.42)
    }

    /// Base of the hue for an appearance.
    func base(_ appearance: DesignAppearance) -> DesignColor {
        appearance == .dark ? darkBase : base
    }
}
