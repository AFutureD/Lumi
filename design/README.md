# Handoff: Agent Status — macOS App + Notch (current design)

## Overview
Agent Status is a macOS app that monitors coding-agent sessions (Codex, Claude) on the local machine. It has two surfaces:

- **macOS app window** — session list, per-session Activity timeline, Inspector, iPhone pairing, Settings.
- **Notch panel** — a dark glass panel that drops out of the display notch: collapsed status pill, session list, turn-start / turn-end summaries, session detail.

This bundle is the current state of both surfaces plus the design system that all values come from.

## About the design files
The files in this bundle are **design references created in HTML** — prototypes showing intended look, structure and behavior. They are **not production code to copy**. The task is to **recreate these designs in the target codebase's existing environment** (for this product: AppKit / SwiftUI in the existing Swift packages) using its established patterns, native controls and libraries. If no environment exists yet, pick the appropriate framework for a macOS menu-bar/notch app and implement there.

Two kinds of file:

- **`.html` (single-file)** — for viewing. Everything is inlined; double-click to open in a browser, no other file needed. These are compiled output — do not edit them.
- **`.dc.html` + `support.js`** — the editable source of the two app design files. Keep `support.js` next to them; without it the pages will not render.

**`DESIGN SYSTEM.html` is the single source of truth for every value.** The two `完整设计` files are the current state of each screen. If a value in a screen file disagrees with the design system, the design system wins. The design system ships as a single-file HTML only.

## Fidelity
**High-fidelity (hifi).** Final colors, typography, spacing, control sizes and states. Recreate pixel-accurately, but always with **native AppKit / SwiftUI controls** — buttons, switches, sliders, segmented controls, pop-up buttons, checkboxes, table/outline rows. The HTML control samples exist only to pin down sizes, colors and usage; do not hand-roll a control set.

---

## Design system structure (`DESIGN SYSTEM.html`)
Five layers; lower layers only reference values from higher ones. New values must be added to L1 first.

- **L1 基础规范** — colors (neutral / semantic / category ramps), typography, spacing & grid, materials, elevation & hairlines, icons
- **L2 原子组件** — Button, Input, Tag, Checkbox/Radio/Switch, Segmented/Dropdown, Slider, status dot
- **L3 分子组件** — status pill, sidebar row, session row, Activity row, lane cell, Notch row
- **L4 组织与模式** — session lifecycle, turn phase, three attention tiers, message category table, escalation rules, three-lane Activity list
- **L5 准则** — cross-layer do / don't

The page has three tweak props (`focusLayer`, `showSpecs`, `showDarkMode`) used for browsing only — not product features.

---

## Design tokens

### Neutral ink (light)
| Token | Value | Use |
|---|---|---|
| Primary | `rgb(26,26,26)` | titles, body, list titles |
| Secondary | `rgb(64,64,64)` | secondary body, unselected segment |
| Tertiary | `rgb(114,114,114)` | section headers, labels, captions |
| Quaternary | `rgb(138,138,138)` | timestamps, weakest info |
| Accent | `rgb(0,120,240)` | icons, selection, prominent button |
| Separator | `rgba(0,0,0,.05)` | row separators, header bottom edge |
| Hairline | `rgb(226,226,226)` | card .5px outline |
| Selection | `rgb(242,242,242)` | sidebar / list / settings selected fill |

### Neutral ink (dark, Notch)
Four tiers mirroring the light ladder: `#fff` (active title) → `rgba(255,255,255,.72)` (subagent child rows, completed sessions) → `rgba(255,255,255,.4)` (group labels) → `rgba(255,255,255,.32~.38)` (timestamps). Panel fills: `rgba(255,255,255,.06~.09)` with `inset 0 0 0 .5px rgba(255,255,255,.09~.12)`.

### Semantic
| Meaning | Light | Dark |
|---|---|---|
| Agent blue / accent | `rgb(0,120,240)` | `#4C9BFF` (pill text `#9DC7FF`) |
| User green / success | `#1DA84C` (deep text `#157A38`) | `#34C759` |
| Error red | `#E5352F` (destructive text `#B3261E`) | `#EE4038` |
| PLAN purple | `#8E3FE8` (text `#6A2FD1`) | `#C9AEFB` |
| SUBAGENT orange | `#ED6A0C` (text `#8A3E05`) | `#FFB27A` |
| TOOL·RESULT yellow | `#F0B400` (text `#6E5417`) | `#F5C862` |
| Neutral (L1) | `#E7E8EC` | `rgba(255,255,255,.38)` |
| Completed gray | `rgb(110,113,120)` | `rgba(255,255,255,.34)` |

### Category ramps (three attention tiers)
Same hue, three saturations. L1 = no saturation `#E7E8EC`; L2 = pale tint (lane cell `#DBECFD` blue / `#EFE4FC` purple / `#FCE7D8` orange / `#FDF3D6` yellow, tag fill = category at 14–16%); L3 = full-saturation solid + `#fff` text.

**Every tag carries a `.5px` inset border, in all three tiers**: L1 neutral `rgba(0,0,0,.16)` · L2 same-hue category at 24–32% · L3 same-hue dark tone at 38% (`USER rgba(0,78,32,.38)` / `TURN END rgba(0,72,160,.38)` / `FAILED rgba(140,18,14,.38)`).

### Typography
SF Pro (`-apple-system, BlinkMacSystemFont, 'SF Pro Text'`); numbers, IDs, paths and timestamps in SF Mono (`ui-monospace, 'SF Mono', Menlo, monospace`, `font-variant-numeric: tabular-nums`). Only five sizes and three weights (510 / 590 / 700):

| Spec | Use |
|---|---|
| 22 / 700 / -.01em / 26 | detail page title |
| 15 / 700 / 18 | section title |
| 13 / 700 / 16 | sidebar section header, inspector group |
| 13 / 590 / 16 | list title, emphasis |
| 13 / 510 / 16 | body, sidebar label, Activity content |
| 11 / 590 / 14 | status pill, counts |
| 11 / 510 / 14~16 | subtitle, caption, field value, Notch body |
| 10 / 590 / .04em / 13 | metric label, lane name |
| SF Mono 10 | timestamps |
| SF Mono 11 | IDs, paths, numbers |
| 9 / 700 / .04em | category tag text |

### Spacing (4pt base — not 8pt)
`2` control inner gap · `4` lane-cell gap, sidebar icon↔text, selection outset · `6` tag padding, dot↔text · `8` control↔label, in-card gaps · `10` pill padding, in-card group gap · `12` Activity column gap, card grid gap · `14` sidebar side padding, card padding · `16` table row padding · `18` large card padding · `24` detail area padding, Activity row side padding · `28` detail right padding · `48` page section gap.

### Key metrics
window radius `16` · toolbar/header height `52` · sidebar width `224`, padding `0 14`, row `32`, selected capsule radius `8` outset ±4 · section header `34` (first) / `43`, padding `0 4 9` · session list `324` · Inspector `288` · Settings category column `260`, row `44` · Activity rows item/header/marker `40 / 36 / 32`, row padding `0 24` · columns time `56` / tag `82` / status dot `10` · lane cell `13×13 r3 gap4` · detail padding `24 28 28` · card radius `14` + `.5px rgb(226,226,226)` · controls: button `28`, switch track `38×22` knob `18`, slider track `4` knob `20`, dropdown `28` · radii: control/segment `1000`, tag `5`, checkbox `4`.

### Materials
- Thick (sidebar): `background rgba(246,246,246,.72); backdrop-filter blur(60px) saturate(180%)`
- Thin (Inspector): `rgba(246,246,246,.48)` + same filter
- Scroll edge effect (sticky headers): `rgba(255,255,255,.85); backdrop-filter blur(6px); border-bottom 1px solid rgba(0,0,0,.05)`
- Content panel: `rgba(255,255,255,.9~.94)`, **no** backdrop-filter (opaque panels with a filter can drop internal scroll content)
- Liquid Glass Large (window shell, metric cards): `linear-gradient(rgba(191,191,191,.1)…),linear-gradient(rgba(255,255,255,.7)…)` + `1.25px 0 0 -.75px rgb(219,219,219), -1.25px 0 0 -.75px rgb(219,219,219), 0 0 0 .5px rgb(219,219,219), 0 18px 48px rgba(0,0,0,.25)`
- Liquid Glass Small (round / capsule controls): `linear-gradient(rgba(248,248,248,.2)…),linear-gradient(rgba(255,255,255,.25)…)` + `1.25px 0 0 -.75px rgb(208,208,208), -1.25px 0 0 -.75px rgb(208,208,208), 0 0 0 .5px rgb(232,232,232), 0 8px 15px rgba(0,0,0,.02), inset 0 24px 6px -24px rgba(40,40,40,.5), inset 0 -24px 6px -24px rgba(40,40,40,.3)`

### Elevation
hairline card `0 0 0 .5px rgb(226,226,226)` · selection: flat `rgb(242,242,242)`, no shadow · glass small rim (above) · popover `0 0 0 .5px rgba(0,0,0,.08), 0 12px 32px rgba(0,0,0,.18)` · glass large (above) · knob `0 1px 3px rgba(0,0,0,.18~.22)`.

### Icons
SF Symbols, line style only, two sizes: `16` at stroke `1.4` (sidebar, accent-tinted) and `14` at stroke `1.3` (toolbar, primary-tinted). Row-end chevron `7×11` stroke `1.4` `rgba(60,60,67,.3)`; disclosure `11×7` stroke `1.6` tertiary. Icon slot is 24px centered. State and category are never expressed with icons — use the status dot and the tag.

---

## Semantic model (implement this, not just the pixels)

### Session lifecycle — three tiers
| Tier | Color | Rule |
|---|---|---|
| Running | `rgb(0,120,240)`, halo `rgba(0,120,240,.18)` | agent is working: thinking / responding / toolRunning / subagentRunning / compacting all collapse here; subtitle shows the current phase; dot breathes |
| Waiting for input | `#1DA84C` | needs a human: awaiting input, awaiting permission decision. **The only tier that sorts the session to the top of the list and pushes the notch.** |
| Completed / Idle | `rgb(110,113,120)` | turn wrapped, session ended, or long idle. Title keeps its color; only dot and subtitle go gray. |
| Failed / Aborted | `#E5352F` | after turnFailed / turnAborted; drops back to Completed once seen. Sorting still follows Completed. |

### Turn phase
`submitted` (hollow gray dot) · `thinking` / `responding` / `toolRunning` (blue) · `waitingPermission` (green) · `subagentRunning` (`#ED6A0C`) · `compacting` / `stopped` (gray 110) · `failed` (red) · `aborted` (gray 138). Phase only changes the status dot and the header subtitle — never the lifecycle tier color.

### Attention tiers for Activity messages
Tier is decided by "does a human need to act", not by category. A category can move between adjacent tiers.

- **L1 一般消息 (low)** — session context, per-turn injected context, reasoning, all session markers. No fill, text `rgb(138,138,138)`, 9/700/.04em, no category color, `inset 0 0 0 .5px rgba(0,0,0,.16)` border; lane cell `#E7E8EC`.
- **L2 消息过程 (medium)** — tool calls & results, assistant replies, plan updates, subagents. Fill = category at 14–16%, text = category deep tone, `inset 0 0 0 .5px` category at 24–32%; lane cell = the pale tint.
- **L3 阶段消息 (high)** — user input, turn end, failure/abort. Solid category fill + `#fff` text + `inset 0 0 0 .5px` same-hue dark tone at 38%; +6% lightness in dark. **Only L3 can expand the notch or fire haptics.**

### Message categories
| Tag | Tier | Lane | Status | Note |
|---|---|---|---|---|
| SESSION | L1 | spans | info | SessionStarted / Ended, one row across all lanes |
| COMPACT | L1 | spans | running→succeeded | CompactionBegan → Ended, updates in place |
| CONTEXT ×N | L1 | User | info | instruction files / config / model config / cwd; adjacent rows merge, expandable — occupies the User lane only, not spanning |
| USER | L3 | User | info | hand-written user input, always top tier |
| CONTEXT | L1 | User | info | this turn's injections: attachments, system-reminder, hook output, skill expansion, compaction summary |
| REASONING | L1 | Model | info | highest volume; never escalates |
| ASSISTANT | L2 | Model | info · last succeeded | assistant text split per block; last row gets the deep blue dot |
| TURN END | L3 | Model | succeeded / failed / cancelled | turnStopped closes a turn, carries duration + tool count |
| PLAN | L2 | Model | running→succeeded | appears on plan create/rewrite, updates in place |
| SUBAGENT | L2 | Model | started→succeeded/failed | same agentId updates in place; lane is Model, not Exec |
| ABORTED | L3 | Model | failed / cancelled | turnFailed / turnAborted; drops a tier only after being seen |
| TOOL | L2 | Exec | started | assistant `tool_use` goes to Exec — the **block type** decides the lane |
| RESULT | L2 | Exec | succeeded / failed | paired with TOOL by `toolUseId`, hover highlights both, never merged; `isError` escalates to FAILED |

Item status dots: `info` blank · `started` hollow `inset 0 0 0 1.5px rgb(0,120,240)` · `running` solid blue + `0 0 0 2.5px rgba(0,120,240,.18)` breathing · `succeeded` `#0A5FBF` · `failed` `#E5352F` · `cancelled` `rgb(138,138,138)`.

### Escalation / in-place update
- `toolResult.isError` → RESULT becomes red FAILED (L3), pushes the notch, status `failed`; the paired TOOL row highlights until seen.
- `subagentReturned` → no new row; same agentId flips dot `started → succeeded/failed` and swaps the text for `lastMessage`.
- `turnStopped` → append a TURN END row; the turn's last assistant row gets the deep blue dot.

### Rules that are easy to miss
- Lane is decided by block type, not message role: assistant `tool_use` and user `tool_result` both land in Exec. Lane content = what the LLM has to encode.
- Permission requests/decisions and usage never enter the timeline — they show up in the header session state and the turn phase.
- Ordinary messages carry no category color; body text stays 13/510 `rgb(26,26,26)`. Hierarchy comes only from tag style.
- Max 3 L3 messages on screen; beyond that, demote the ones already seen.
- Empty lane cells stay empty — never fill them.
- **Subagents are only listed while their turn is running. Once the turn ends, subagent child rows disappear from the list.**

---

## Screens — macOS (`Agent Status macOS - 完整设计.dc.html`)

Window shell: `1440×860` (screen 1) / `1440×760` (2, 3), radius `16`, Liquid Glass Large fill and shadow, `overflow: hidden`. Traffic lights `12px` circles `#FF5F57 / #FEBC2E / #28C840`, 8px apart, in a `52px` toolbar with padding `0 8 0 19`.

### 1 主窗口 · Sessions + Activity (`data-screen-label="1 Sessions"`)
Three columns: sidebar `224` (Thick material) · session list `324` · detail (Activity + Inspector `288`).
- Sidebar: `52` toolbar with a `28` round glass refresh button; section headers 13/700 tertiary, height `34` first / `43` after, padding `0 4 9`; rows `32` with a `24` icon slot (16px accent icon) + 13/510 label + trailing count; selected row = `rgb(242,242,242)` radius `8`, outset 4px each side; the iPhone row carries a `7px` `#1DA84C` connected dot.
- Session list: rows show a `16` agent glyph, 13/590 title, and a status line (7px dot + 11/510 tier-colored text). Subagent children indent `32` so the title aligns with the parent, with a 1px `rgba(60,60,67,.24)` elbow.
- Activity: header "Activity" 15/700 + count pill (11/590 on `rgba(120,120,128,.12)`, radius 1000). Lane strip: 44px right-aligned lane names (10/590 tertiary) + `13×13` r3 cells, gap 4. Rows: time `56` (SF Mono 10, `rgb(138,138,138)`) + tag `82` centered (9/700/.04em, radius 5, `.5px` inset border in every tier) + single-line content 13/510 ellipsized + `7×11` chevron. Item rows `40`, marker rows `32` (no tag fill but the same L1 border, gray text; SESSION / COMPACT span all lanes, merged `CONTEXT ×N` occupies the User lane only), separators `1px rgba(0,0,0,.05)`.

### 2 Pair iPhone (`data-screen-label="2 Pair iPhone"`)
Header: 22/700 title + Prominent button; status row = green pill (`Relay connected`, dot `#1DA84C` + halo, text `#157A38`) plus 11/510 explanation. Body: `320` glass card holding a `280×280` white QR placeholder (radius 14, `inset 0 0 0 .5px rgb(226,226,226)`) with 13/590 + 11/510 captions below; right side lists paired devices — each row has name, state (11/510 tertiary, 52px column) and a `24` Revoke capsule with `#B3261E` text.

### 3 Settings · Daemon (`data-screen-label="3 Settings"`)
Sidebar + `260` category column (rows `44`, selected `rgb(242,242,242)` r8) + detail. Header 22/700 with a green Running pill and 11/510 explanation. Rows `52` min-height, padding `12 16`, separators `rgba(0,0,0,.05)`; secondary actions are Bordered glass buttons `28`, destructive ones only recolor the label `#B3261E`.

### 4 Settings · remaining panels (`4 General` / `4 Agents` / `4 About` / `4 Notch`)
`956` wide cards (400 tall, Notch panel 840). Each has a sticky header (scroll edge effect material, padding `14 28`) with a 22/700 title, then rows: 13/510 label + 11/510 caption + a native control on the right — switch `38×22` (knob 18, on = accent + `inset 0 0 0 .5px rgba(0,90,190,.35)`), pop-up button `28` capsule with a `16` accent chevron badge, slider (track 4, knob 20) with a value capsule, checkboxes `14` r4. Agents rows carry a `20` agent glyph and a `~/.codex/config.toml · agent-status-helper` mono caption.

## Screens — Notch (`Agent Status Notch - 完整设计.dc.html`)

Panel is `520pt` wide dark glass hanging from the notch; the top black band keeps the camera area clear (app glyph left, session count right, `32` tall, radius `0 0 12 12`, `background #000`).

### 1 收起态 (collapsed)
`64pt` wide: an `8px` status dot (tier color + `0 0 0 3px` halo) and the session count 11/590. Idle state uses `rgba(255,255,255,.34)` with no halo.

### 2 Session 列表 (`data-screen-label="2 Notch List"`)
Rows are a 3-column grid `8px | 1fr | auto`, padding `10 16 11`, column gap 10: status dot `8` (+3px halo) · title 13/590/16 (`#fff` active, `rgba(255,255,255,.72)` completed) · right group = agent chip (height 20, r6, `rgba(255,255,255,.09)`, 10/590 `rgba(255,255,255,.6)`; completed uses `.07` / `.45`) + a `20px` trailing cell holding the relative time (SF Mono 10, `rgba(255,255,255,.38)`, right-aligned) which swaps to a `20×20` r6 archive button on hover. Gap chip→trailing cell is `10`, and the cell is exactly button-width so the trailing inset equals the row's `16` right padding. Separators `1px rgba(255,255,255,.08)` inset 16. Subagent child rows: indent `34`, `6px` dot, 11/510/14 `.72` text, mono `10` `.32` time, 1px `.16` elbow — **only while the turn runs**. Footer: `9 16 12`, top border `.08`, "N of M sessions" 10/590 `.4`.

### 3 Turn 刚启动 (`data-screen-label="3 Notch Turn Start"`)
Header row: 13/590 title + `Turn started` 10/590 `#9DC7FF` + elapsed mono 10 `.4`; second line 11/510/14 `.52` with `agent · model · cwd`. Below, the echoed user input in a card (padding `9 11`, r10, `rgba(255,255,255,.06)`, `inset 0 0 0 .5px rgba(255,255,255,.09)`): a 9/700/.06em `USER` label `.4` plus 11/510/16 `.86` body clamped to 6 lines. Body copy stays at weight 510 — 11/590 is reserved for status pills and counts; at 11px, hierarchy comes from opacity, not weight.

### 4 Turn 结束 (`data-screen-label="4 Notch Turn End"`)
Same header with `Turn complete`; three metric chips (padding `4 9`, r8, `rgba(255,255,255,.07)`, value 11/590 tabular-nums); summary body 11/510/16 `.78` clamped to 6 lines; action row of `30` tall r9 buttons — primary `#fff` on `#111` text 13/590, secondary `rgba(255,255,255,.1)` + `inset 0 0 0 .5px rgba(255,255,255,.1)`.

### 5 Session 详情 (`data-screen-label="5 Notch Detail"`)
Back chevron `11×11` + 15/700/18 title; a running pill (h20, r1000, `rgba(76,155,255,.18)` + `inset 0 0 0 .5px rgba(76,155,255,.32)`, dot `#4C9BFF`, text 10/590 `#9DC7FF`); three metric cards (tokens / context / elapsed — value 13/590 tabular-nums, label 9/590/.04em uppercase `.42`); the RECENT ACTIVITY list; then `Show in App` / secondary actions.

**RECENT ACTIVITY** — section label 10/700/.05em `.4` + item count 10/590 `.3`. One row per message category, in timeline order: SESSION · CTX ×3 · USER · CONTEXT · REASON · PLAN · TOOL · RESULT · SUBAG · ASSIST · TURN END · FAILED · COMPACT. Each row is `22` tall, column gap `12`: a `60px` centered tag (padding `2 0`, r5, 9/700/.03em, dark-mode fill + `.5px` inset border per tier — L1 rows have no fill, `rgba(255,255,255,.38)` text and a `rgba(255,255,255,.2)` border) + single-line content 11/510/14 `rgba(255,255,255,.8)` ellipsized. Labels are abbreviated to fit the 60px column (`CTX ×N`, `REASON`, `SUBAG`, `ASSIST`). The whole panel is `580` tall on this screen; screens 2–4 stay `404`.

---

## Interactions & behavior
- **Hover** — session rows lighten their fill; the Notch row's time swaps for the archive button; TOOL and RESULT rows highlight each other via `toolUseId`.
- **Selection** — light surfaces: `rgb(242,242,242)` r8 fill, text color unchanged. Notch light list: `rgba(0,120,240,.09)` fill, `rgb(0,120,240)` stripe, title `#0A5FBF`.
- **Status dot** — `running` breathes (opacity/halo pulse, ~1.6s ease-in-out); other states are static.
- **Notch expansion** — only L3 messages and the `Waiting for input` tier expand the panel and fire haptics; expansion collapses on pointer-out unless "Stay expanded" is on.
- **Sorting** — sessions needing a human first, then running, then completed by recency.
- **In-place updates** — COMPACT, PLAN and SUBAGENT rows update in place; no duplicate rows.

## State
Per session: `lifecycleTier` (running / waiting / completed / failed), `turnPhase`, `agentKind`, `model`, `cwd`, `lastActivityAt`, `tokens`, `contextPercent`, `elapsed`, `subagents[]` (visible only while the turn runs), `timelineItems[]` (each with category, attention tier, lane, `status`, `toolUseId`, timestamp, single-line content). App level: `pairedDevices[]`, `relayConnected`, `daemonRunning`, settings values, `notchExpanded`, `unseenL3Count`. Data source is the local daemon's SQLite store; the timeline is append-only with in-place updates keyed by `toolUseId` / `agentId`.

## Assets
No bitmap assets. Agent glyphs (Codex, Claude) are inline SVGs in the HTML — replace with the real vendor marks available in the app bundle. All other icons are SF Symbols. QR code is a placeholder.

## Files
View (single-file HTML, double-click to open — compiled output, don't edit):
- `DESIGN SYSTEM.html` — design system, **the only source of values** (L1–L5)
- `Agent Status macOS - 完整设计（单文件）.html` — current state of macOS screens 1–4
- `Agent Status Notch - 完整设计（单文件）.html` — current state of Notch screens 1–5

Editable source:
- `Agent Status macOS - 完整设计.dc.html`
- `Agent Status Notch - 完整设计.dc.html`
- `support.js` — runtime required by the two `.dc.html` files
