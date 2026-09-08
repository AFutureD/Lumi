import Foundation

public extension DesignSystem {
    /// Plan usage (handoff `design_handoff_plan_usage`, 2026-09-07): the
    /// Notch top-bar cluster (Notch page 6), Settings › Notch › Usage (macOS
    /// page 7b) and Settings › Usage › Plan (macOS page 9). The top-bar
    /// metrics sit in `Notch`; the light-surface values are here.
    enum PlanUsage {
        // MARK: Thresholds

        /// Top bar and card value: at or above this the number turns to the
        /// warning colour. The top bar has this one band only.
        public static let warningPercent: Double = 90
        /// Card bar only: the fill warms one step from here.
        public static let bandPercent: Double = 75

        // MARK: Settings › Notch › Usage (page 7b)

        /// Preview strip: the top band's height and radius on the panel black.
        public static let previewHeight: Double = 32
        public static let previewRadius: Double = 10
        public static let previewInset: Double = 14
        /// One agent row under "Show": mark, name column, pills.
        public static let showRowMinimumHeight: Double = 46
        public static let showRowVerticalPadding: Double = 8
        public static let showRowGap: Double = 10
        public static let showMark: Double = 20
        public static let showMarkRadius: Double = 5
        public static let showNameWidth: Double = 104
        public static let pillHeight: Double = 24
        public static let pillHorizontalPadding: Double = 10
        public static let pillInnerGap: Double = 5
        public static let pillGap: Double = 6
        public static let pillCheck: Double = 10
        /// An agent row whose account has nothing to pick from.
        public static let unavailableRowOpacity: Double = 0.5

        public static let pillSelectedFill = Palette.blue.s600.opacity(0.12)
        public static let pillSelectedText = Palette.blue.s700
        public static let pillSelectedRing = Palette.blue.s600.opacity(0.28)
        public static let pillFill = Surface.control
        public static let pillText = DesignColor(rgb: 90, 90, 95)
        public static let pillRing = Surface.separator

        // MARK: Settings › Usage › Plan (page 9)

        public static let cardMaximumWidth: Double = 860
        public static let headerMinimumHeight: Double = 56
        public static let headerVerticalPadding: Double = 12
        public static let headerGap: Double = 12
        public static let headerMark: Double = 22
        public static let headerMarkRadius: Double = 5
        public static let headerTitleGap: Double = 8
        public static let headerLineGap: Double = 2
        public static let bodyVerticalPadding: Double = 14
        public static let bodyHorizontalPadding: Double = 16
        public static let columnGap: Double = 24
        public static let columnLineGap: Double = 5
        public static let valueUnitGap: Double = 5
        public static let barHeight: Double = 6
        public static let barRadius: Double = 3
        public static let noticeVerticalPadding: Double = 12
        /// Mark and switch of an account that cannot be used.
        public static let unavailableMarkOpacity: Double = 0.55
        public static let disabledSwitchOpacity: Double = 0.4

        /// `rgb(150,150,150)` — the read path and the refresh stamp.
        public static let pathText = DesignColor(rgb: 150, 150, 150)
        public static let barTrack = Surface.secondaryButton
        public static let barFill = DesignColor(rgb: 72, 72, 76)
        /// 75–89 %: Orange 500; 90 % and up: Orange 600.
        public static let barFillBand = Palette.orange.s500
        public static let barFillWarning = Palette.orange.s600
        /// The card value at 90 % and up: Orange 700.
        public static let valueWarning = Palette.orange.s700

        // MARK: Notices (iPhone Plan / History cards, handoff `design_handoff_ios_usage`)

        /// Warning wording — `Saved sign-in expired…`, `Rate limited…`,
        /// `<Mac> offline · numbers from 2h ago` — `#8A5A28`.
        public static let noticeWarningText = DesignColor(rgb: 138, 90, 40)
        /// The page-level offline banner's fill `rgba(255,204,153,.22)`.
        public static let noticeWarningFill = DesignColor(rgb: 255, 204, 153).opacity(0.22)
    }
}

public extension DesignSystem.Typography {
    /// Top-bar window label — 10 / Medium / .01em.
    static let planUsageNotchLabel = DesignTextStyle(size: 10, weight: .medium, lineHeight: 13, trackingEm: 0.01)
    /// Top-bar value — 11 / Regular SF Mono / −.01em, tabular.
    static let planUsageNotchValue = DesignTextStyle(size: 11, weight: .regular, lineHeight: 14, trackingEm: -0.01, family: .mono)
    /// Card window title — 10 / Medium / .04em, uppercase.
    static let planUsageWindowTitle = DesignTextStyle(size: 10, weight: .medium, lineHeight: 13, trackingEm: 0.04)
    /// Card value — 17 / Semibold / 20, tabular.
    static let planUsageValue = DesignTextStyle(size: 17, weight: .semibold, lineHeight: 20)
    /// Show pill — 12 / Regular.
    static let planUsagePill = DesignTextStyle(size: 12, weight: .regular, lineHeight: 15)
    /// Card notice — 12 / Regular / 17.
    static let planUsageNotice = DesignTextStyle(size: 12, weight: .regular, lineHeight: 17)
}
