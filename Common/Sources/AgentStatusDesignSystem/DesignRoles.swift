import Foundation

// 1.1 使用场景 · Light / Dark. The two role tables every surface reads from.
// Light is the macOS window and iOS light; dark is the Notch panel (and iOS
// dark). **Dark values are their own table — never derived from light**: low
// opacity white on `#000` has no ambient lightness under it and falls off far
// faster than on grey.

public extension DesignSystem {
    /// Light · 前景 (text & icons). Neutral ladder 700 → 400, accent, destructive.
    enum Ink {
        /// 主文字 — titles, list titles (Neutral 700).
        public static let primary = Palette.neutral.s700
        /// 正文 — Activity content, field values (same value as primary).
        public static let body = Palette.neutral.s700
        /// 次级 — secondary body, unselected segment (Neutral 600).
        public static let secondary = Palette.neutral.s600
        /// 三级 — section headers, labels, captions (Neutral 500).
        public static let tertiary = Palette.neutral.s500
        /// 四级 — timestamps, the weakest information (Neutral 400).
        public static let quaternary = Palette.neutral.s400
        /// 强调 — icons, selection, the Running dot and text (Blue 600).
        public static let accent = Palette.blue.s600
        /// 破坏性 — destructive button label (Red 700); the button stays Bordered.
        public static let destructive = Palette.red.s700

        // macOS screen file (`Agent Status macOS - 完整设计`) extras.

        /// Subagent child-row title in the Sessions list.
        public static let childTitle = DesignColor(rgb: 60, 60, 67)
        /// Text of the collapsed-children count badge.
        public static let countBadge = DesignColor(rgb: 90, 90, 90)
        /// Row-end chevron `7×11`; 1px ring around a hovered lane cell.
        public static let chevron = DesignColor(rgb: 60, 60, 67, alpha: 0.3)
        public static let hoverRing = DesignColor(rgb: 60, 60, 67, alpha: 0.3)
    }

    /// Light · 背景与描边.
    enum Surface {
        /// 面板底 — window, Inspector.
        public static let panel = Palette.white
        /// 卡片底 — info blocks; distinguished from the panel by the hairline.
        public static let card = Palette.white
        /// 选中底 — sidebar / list / settings selection, radius 8 (Neutral 100).
        public static let selection = Palette.neutral.s100
        /// 控件底 — search field, agent chip, segmented track.
        public static let control = DesignColor(rgb: 120, 120, 128, alpha: 0.1)
        /// 强调填充 — the Prominent button, at most one per screen (Blue 600).
        public static let accentFill = Palette.blue.s600
        /// 次级按钮底 — secondary buttons, icon keys (archive); one step above `control`.
        public static let secondaryButton = DesignColor(rgb: 120, 120, 128, alpha: 0.16)
        /// 分隔线 1px — row separators, header bottom edge.
        public static let separator = DesignColor(white: 0, alpha: 0.05)
        /// 描边 .5px — card outline (Neutral 200).
        public static let hairline = Palette.neutral.s200
        /// 结构连接线 1px — subagent elbow; one step above the separator.
        public static let connector = DesignColor(rgb: 60, 60, 67, alpha: 0.24)

        /// Neutral chip / count-pill fill and its `.5px` ring.
        public static let chipFill = DesignColor(rgb: 120, 120, 128, alpha: 0.12)
        public static let chipRing = DesignColor(white: 0, alpha: 0.06)

        // macOS screen file extras.

        /// Alternating row wash.
        public static let zebra = DesignColor(rgb: 120, 120, 128, alpha: 0.045)
        /// Liquid-glass card fill above the window shell.
        public static let cardGlass = DesignColor(white: 1, alpha: 0.7)
    }

    /// Dark · 前景. Five white opacities; the panel is `#000` so these are
    /// read as-is, never converted from the light ladder.
    enum InkDark {
        /// 主文字 — titles, list titles.
        public static let primary = Palette.white
        /// 正文 — summaries, Activity content (White 78 %).
        public static let body = DesignColor(white: 1, alpha: 0.78)
        /// 次级 — subtitles, paths, agent-label text (White 58 %).
        public static let secondary = DesignColor(white: 1, alpha: 0.58)
        /// 三级 — metric labels, counts (White 50 %).
        public static let tertiary = DesignColor(white: 1, alpha: 0.50)
        /// 四级 — timestamps (White 46 %).
        public static let quaternary = DesignColor(white: 1, alpha: 0.46)
        /// 强调 — icons, selection, the Running dot and text (Blue D500).
        public static let accent = Palette.blueDark.d500
        /// Accent text above a blue tint (`Turn started`, running pill) (Blue D400).
        public static let accentText = Palette.blueDark.d400
        /// 破坏性 — failed dot and FAILED tag (Red D500).
        public static let destructive = Palette.redDark.d500
        /// Ink on the white primary button.
        public static let onAccentFill = DesignColor(hex: 0x111111)

        // Notch screen file (`Agent Status Notch - 完整设计`) extras.

        /// Top-bar line icons (gear, lock) stroke.
        public static let icon = DesignColor(white: 1, alpha: 0.62)
        /// Top-bar app glyph stroke.
        public static let brandIcon = DesignColor(white: 1, alpha: 0.72)
        /// List archive glyph stroke (White 72 %).
        public static let archiveGlyph = DesignColor(white: 1, alpha: 0.72)
        /// List agent tag text (White 52 %).
        public static let agentTagText = DesignColor(white: 1, alpha: 0.52)
        /// Subagent pill name (White 82 %).
        public static let pillName = DesignColor(white: 1, alpha: 0.82)
        /// Subagent pill duration (White 44 %).
        public static let pillTime = DesignColor(white: 1, alpha: 0.44)
        /// Subagent count-strip chevron (White 42 %, the idle-dot grey).
        public static let subagentChevron = DesignColor(white: 1, alpha: 0.42)
    }

    /// Dark · 背景与描边. Fills are white at `.10 / .12 / .14 / .16`, one step
    /// apart, lowest first.
    enum SurfaceDark {
        /// 面板底 — the Notch panel: solid black, no material, stroke or shadow.
        public static let panel = Palette.surfaceDark
        /// 卡片底 — info blocks, metric cards (White 10 %).
        public static let card = DesignColor(white: 1, alpha: 0.10)
        /// 选中底 — back button, status pill fill (White 12 %).
        public static let selection = DesignColor(white: 1, alpha: 0.12)
        /// 控件底 — agent label, metric capsules, segmented control (White 14 %).
        public static let control = DesignColor(white: 1, alpha: 0.14)
        /// 强调填充 — primary button (with `onAccentFill` text), at most one per screen.
        public static let accentFill = Palette.white
        /// 次级按钮底 — secondary buttons, archive key (White 16 %).
        public static let secondaryButton = DesignColor(white: 1, alpha: 0.16)
        /// 分隔线 1px — row separators, footer top edge (White 8 %; the mock's
        /// 12 % reads too bright over the translucent backdrop).
        public static let separator = DesignColor(white: 1, alpha: 0.08)
        /// 描边 .5px — card outline, secondary-button ring (White 18 %).
        public static let hairline = DesignColor(white: 1, alpha: 0.18)

        // Notch list (`Agent Status Notch - 完整设计` Screen 2) extras.

        /// Agent tag fill — translucent white, not the mock's opaque
        /// `rgb(40,40,40)`: the panel backdrop is only pure black in the
        /// Solid chrome style, and over the frosted / glass materials an
        /// opaque near-black fill disappears. White alpha composites above
        /// whatever backdrop the user picked.
        public static let agentTag = DesignColor(white: 1, alpha: 0.14)
        /// Hovered subagent-row card fill (White 7 %).
        public static let listCard = DesignColor(white: 1, alpha: 0.07)
        /// Subagent pill fill (White 13 %).
        public static let subagentPill = DesignColor(white: 1, alpha: 0.13)
    }

    /// Semantic hues: which hue each meaning takes, light / dark.
    enum Semantic {
        /// Agent 蓝 · Accent — agent running, selection, Prominent button, icons.
        public static let accent = AdaptiveDesignColor(light: Palette.blue.s600, dark: Palette.blueDark.d500)
        /// User 绿 · Success — needs a human, succeeded dot, USER tag.
        public static let success = AdaptiveDesignColor(light: Palette.green.s600, dark: Palette.greenDark.d500)
        /// 失败红 · Error — failed / aborted.
        public static let error = AdaptiveDesignColor(light: Palette.red.s600, dark: Palette.redDark.d500)
        /// PLAN 紫.
        public static let plan = AdaptiveDesignColor(light: Palette.purple.s600, dark: Palette.purpleDark.d500)
        /// SUBAGENT 橙 — subagent messages, `subagentRunning` phase.
        public static let subagent = AdaptiveDesignColor(light: Palette.orange.s600, dark: Palette.orangeDark.d500)
        /// TOOL · RESULT 黄 — Exec lane tool calls and results.
        public static let tool = AdaptiveDesignColor(light: Palette.yellow.s600, dark: Palette.yellowDark.d500)
        /// 中性灰 · Neutral — L1 messages and markers, no saturation.
        public static let neutral = AdaptiveDesignColor(light: Palette.neutralMarker, dark: DesignColor(white: 1, alpha: 0.38))
        /// Completed / Idle dot.
        public static let completed = AdaptiveDesignColor(light: Palette.neutralDot, dark: DesignColor(white: 1, alpha: 0.42))
        /// Relay / iPhone "connected" dot.
        public static let connected = Palette.green.s600
    }
}
