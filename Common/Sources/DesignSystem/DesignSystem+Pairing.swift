import Foundation

// Pairing v2 (`design_handoff_relay_pairing_v2 2`): the macOS Pair an iPhone
// page (macOS 第 2 页) and the iOS Macs / Add Mac / SAS / failure screens
// (iOS 第 4 / 5 页). Only the product's own pieces are specified — the code
// card, the SAS layout, the six code cells, the status dots; everything else
// is a system control at system metrics.

public extension DesignSystem {
    enum Pairing {
        // MARK: - macOS · Pair an iPhone

        /// Left column (code card + pending card): at least 420 wide, sized by
        /// its content — the Relay host never wraps or truncates, a longer
        /// one widens the card and the devices column yields. Columns 28
        /// apart, cards 20 apart.
        public static let columnMinimumWidth: Double = 420
        /// In-content header: title 22 / 400 with the Relay pill at its right,
        /// subtitle 11 / 400 under it, a 1px `rgba(0,0,0,.05)` rule below.
        public static let headerTop: Double = 20
        public static let headerTitleGap: Double = 4
        public static let headerBottom: Double = 16
        public static let headerRule = DesignColor(white: 0, alpha: 0.05)
        public static let columnGap: Double = 28
        public static let cardGap: Double = 20
        public static let cardRadius: Double = 20
        public static let cardPadding: Double = 20
        /// QR 180 × 180, radius 12, `.5px` hairline, 18 to the code block.
        public static let qrSize: Double = 180
        public static let qrRadius: Double = 12
        public static let qrGap: Double = 18
        /// `CODE` / `RELAY` labels — 11 / Semibold / .06em, uppercase.
        public static let label = DesignTextStyle(size: 11, weight: .semibold, lineHeight: 14, trackingEm: 0.06)
        /// The code — SF Mono 34 / Semibold / 40 / .06em, one run `7KF-3QP`
        /// with the hyphen in `rgb(170,170,170)` (mirrors the iPhone's cells).
        public static let code = DesignTextStyle(size: 34, weight: .semibold, lineHeight: 40, trackingEm: 0.06, family: .mono)
        public static let codeHyphen = DesignColor(rgb: 170, 170, 170)
        /// Relay host under the code — SF Mono 12 / 18.
        public static let relayHost = DesignTextStyle(size: 12, weight: .regular, lineHeight: 18, family: .mono)
        /// `Expires in` 11 grey + mono 13 / Semibold value.
        public static let expiryValue = DesignTextStyle(size: 13, weight: .semibold, lineHeight: 16, family: .mono)
        /// Countdown bar: 3 tall, capsule, track `rgba(120,120,128,.16)`, fill accent.
        public static let countdownHeight: Double = 3
        public static let countdownTrack = DesignColor(rgb: 120, 120, 128, alpha: 0.16)
        /// Code card divider `rgba(0,0,0,.07)`, `margin 10 0 6`.
        public static let divider = DesignColor(white: 0, alpha: 0.07)
        public static let dividerTop: Double = 10
        public static let dividerBottom: Double = 6

        /// Pending card: `padding 22 20 18`, content 16 apart, accent stroke
        /// `0 0 0 1px rgba(0,120,240,.34), 0 0 0 5px rgba(0,120,240,.1)`.
        public static let pendingTopPadding: Double = 22
        public static let pendingBottomPadding: Double = 18
        public static let pendingGap: Double = 16
        public static let pendingRingInner = DesignColor(rgb: 0, 120, 240, alpha: 0.34)
        public static let pendingRingOuter = DesignColor(rgb: 0, 120, 240, alpha: 0.10)
        public static let pendingRingOuterWidth: Double = 5
        /// Title `“<iPhone>” wants to pair` — 15 / Semibold / 20; 15pt iPhone glyph.
        public static let pendingTitle = DesignTextStyle(size: 15, weight: .semibold, lineHeight: 20)
        public static let pendingIcon: Double = 15
        /// SAS on the Mac — SF Mono 64 / Semibold / 68 / .04em, halves 26 apart.
        public static let sas = DesignTextStyle(size: 64, weight: .semibold, lineHeight: 68, trackingEm: 0.04, family: .mono)
        public static let sasGroupGap: Double = 26
        /// Explanation under the SAS — 13 / 18, max width 340.
        public static let sasHint = DesignTextStyle(size: 13, weight: .regular, lineHeight: 18)
        public static let sasHintMaxWidth: Double = 340
        /// Decision buttons: 32 tall capsules, 15pt, 12 apart.
        public static let decisionButtonHeight: Double = 32
        public static let decisionButtonGap: Double = 12
        public static let decisionButton = DesignTextStyle(size: 15, weight: .regular, lineHeight: 20)
        public static let decisionButtonEmphasized = DesignTextStyle(size: 15, weight: .semibold, lineHeight: 20)
        /// Result mark 34 × 34 (green ✓ / grey ✕); result copy 12 / 17.
        public static let resultMark: Double = 34
        public static let resultBody = DesignTextStyle(size: 12, weight: .regular, lineHeight: 17)
        /// How long the result stays before the card collapses.
        public static let resultDwell: Double = 2
        /// Pending card entrance: fade in, 120 ms ease-out.
        public static let entranceDuration: Double = 0.12

        /// Paired iPhones list: rows 60 tall, `padding 0 16`; 16pt iPhone
        /// glyph; name 13 / 590 with the state tag 8 to its right; subtitle is
        /// the Relay host in SF Mono 11 / 14; a plain-text action at the end
        /// (24 tall, 11 / 400, destructive): `Revoke` on Active, `Remove` on
        /// Revoked.
        public static let deviceRowHeight: Double = 60
        public static let deviceRowInset: Double = 16
        public static let deviceIcon: Double = 16
        public static let deviceTagGap: Double = 8
        public static let deviceSubtitle = DesignTextStyle(size: 11, weight: .regular, lineHeight: 14, family: .mono)
        public static let deviceAction = DesignTextStyle(size: 11, weight: .regular, lineHeight: 14)
        public static let deviceActionHeight: Double = 24
        /// State tag: 18 tall capsule, `padding 0 8`, 11 / 590. Active = green
        /// L2 (fill .16 / text #157A38 / ring .5 at .28); Revoked = L1 (clear /
        /// `rgb(138,138,138)` / ring `.5px rgba(0,0,0,.16)`).
        public static let tagHeight: Double = 18
        public static let tagHorizontalPadding: Double = 8
        public static let tag = DesignTextStyle(size: 11, weight: .semibold, lineHeight: 14)
        public static let tagActiveFill = DesignColor(rgb: 29, 168, 76, alpha: 0.16)
        public static let tagActiveText = DesignColor(hex: 0x157A38)
        public static let tagActiveRing = DesignColor(rgb: 29, 168, 76, alpha: 0.28)
        public static let tagMutedText = DesignColor(rgb: 138, 138, 138)
        public static let tagMutedRing = DesignColor(white: 0, alpha: 0.16)
        /// A freshly paired row is tinted `rgba(0,120,240,.06)` once, then fades.
        public static let newRowTint = DesignColor(rgb: 0, 120, 240, alpha: 0.06)

        // MARK: - iOS · Macs / Add Mac

        public enum IOS {
            /// Six code cells 58 tall, radius 10, 8 apart, with a 12 × 2 dash
            /// between the halves; glyphs SF Mono 26 / Semibold.
            public static let cellHeight: Double = 58
            public static let cellRadius: Double = 10
            public static let cellGap: Double = 8
            public static let cellGlyph = DesignTextStyle(size: 26, weight: .semibold, lineHeight: 32, family: .mono)
            public static let cellRing = DesignColor(rgb: 60, 60, 67, alpha: 0.22)
            public static let cellRingActiveWidth: Double = 2
            public static let cellRingErrorWidth: Double = 1.5
            public static let cellRingError = DesignColor(rgb: 229, 53, 47, alpha: 0.55)
            public static let dashWidth: Double = 12
            public static let dashHeight: Double = 2
            public static let dash = DesignColor(rgb: 60, 60, 67, alpha: 0.35)
            /// Primary / secondary buttons 50 tall, radius 12, 17pt.
            public static let buttonHeight: Double = 50
            public static let buttonRadius: Double = 12
            public static let buttonGap: Double = 12
            /// Content `padding 24 20 0`; blocks 20 apart.
            public static let contentTop: Double = 24
            public static let contentInset: Double = 20
            public static let blockGap: Double = 20
            /// Intro copy 15 / 20 at 72 % ink.
            public static let intro = DesignTextStyle(size: 15, weight: .regular, lineHeight: 20)
            public static let introInk = DesignColor(rgb: 60, 60, 67, alpha: 0.72)
            /// `Advanced` row 15 / 20 at 75 %; cell label 12 / 16 at 60 %; value SF Mono 17 / 22.
            public static let advancedInk = DesignColor(rgb: 60, 60, 67, alpha: 0.75)
            public static let fieldLabel = DesignTextStyle(size: 12, weight: .regular, lineHeight: 16)
            public static let fieldLabelInk = DesignColor(rgb: 60, 60, 67, alpha: 0.6)
            public static let fieldValue = DesignTextStyle(size: 17, weight: .regular, lineHeight: 22, family: .mono)
            public static let placeholderInk = DesignColor(rgb: 60, 60, 67, alpha: 0.35)
            public static let fieldCellMinimumHeight: Double = 56
            /// Inline error: 17pt `exclamationmark.circle.fill` + 13 / 18 destructive text.
            public static let errorIcon: Double = 17
            /// SAS screen: blocks 26 apart, 60 under; Mac name 22 / Bold / 28 / −.02em;
            /// SAS SF Mono 56 / Semibold / 60 / .04em, halves 22 apart.
            public static let sasGap: Double = 26
            public static let sasBottom: Double = 60
            public static let macName = DesignTextStyle(size: 22, weight: .semibold, lineHeight: 28, trackingEm: -0.02)
            public static let sas = DesignTextStyle(size: 56, weight: .semibold, lineHeight: 60, trackingEm: 0.04, family: .mono)
            public static let sasGroupGap: Double = 22
            public static let sasHint = DesignTextStyle(size: 15, weight: .regular, lineHeight: 20)
            public static let sasHintInk = DesignColor(rgb: 60, 60, 67, alpha: 0.75)
            /// Relay host under the Mac name — SF Mono 13 / 18 at 60 %.
            public static let relayHost = DesignTextStyle(size: 13, weight: .regular, lineHeight: 18, family: .mono)
            /// Success mark 56 (green); failure marks 52 (grey, red only for a
            /// commitment mismatch); title 20 / Bold / 25; body 15 / 20 at 70 %, max 290.
            public static let successMark: Double = 56
            public static let failureMark: Double = 52
            public static let failureTitle = DesignTextStyle(size: 20, weight: .semibold, lineHeight: 25)
            public static let failureBody = DesignTextStyle(size: 15, weight: .regular, lineHeight: 20)
            public static let failureBodyInk = DesignColor(rgb: 60, 60, 67, alpha: 0.7)
            public static let failureMaxWidth: Double = 290
            /// Success screen dwell before returning to the Macs list.
            public static let successDwell: Double = 1.5
            /// Macs list subtitle — SF Mono 13 / 18 (`Online · relay.lumi.huanan.app`).
            public static let macRowSubtitle = DesignTextStyle(size: 13, weight: .regular, lineHeight: 18, family: .mono)
        }
    }
}
