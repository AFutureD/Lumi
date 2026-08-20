# Handoff: Agent Status — 设计系统 + macOS / Notch 完整设计

## Overview

Agent Status 是一个 macOS 应用，实时显示多个 coding agent（Codex / Claude）会话的运行状态。它有两个界面：

- **主窗口** — Session 列表 + Activity 时间线 + Inspector，浅色。
- **Notch 面板** — 屏幕顶部刘海处的常驻浮层，纯黑，用于扫读与快速跳转。

本包交付这两个界面的全部当前设计，以及作为唯一取值来源的设计系统。

## About the Design Files

**这个包里的 HTML 是设计参考，不是可直接复制的生产代码。** 它们用 HTML 搭出来只是为了精确表达外观和行为。

任务是**在目标代码库的既有环境里重建这些设计**（本项目是 Swift / AppKit + SwiftUI），沿用它已有的模式和控件，而不是把 HTML 搬进去。

已有实现位于：

```
Apps/AgentStatusMac/AgentStatusMacPackage/Sources/AgentStatusMacFeature/
  AgentStatusNookController.swift     Notch 面板全部视图
  AgentStatusDesign.swift             设计常量的 Swift 映射
  SessionListViewController.swift     主窗口 Session 列表
  SessionActivityView.swift           Activity 时间线
Common/Sources/AgentStatusDesignSystem/
  DesignMetrics.swift                 尺寸常量
  DesignPalette.swift                 颜色常量
```

## Fidelity

**High-fidelity。** 颜色、字号、字重、行高、间距、圆角、透明度都是最终值，可以逐条取用。文案是占位内容，不是最终文案。

---

## 文件说明

| 文件 | 用途 |
|---|---|
| `DESIGN SYSTEM.html` | **唯一取值来源。** 颜色、排版、间距、材质、组件构造、语义规则全在这里。 |
| `Agent Status macOS - 完整设计（单文件）.html` | 主窗口全部页面的当前状态 |
| `Agent Status Notch - 完整设计（单文件）.html` | Notch 面板全部页面的当前状态 |
| `Agent Status macOS - 完整设计.dc.html` + `support.js` | 上面那份的**可编辑源文件** |
| `Agent Status Notch - 完整设计.dc.html` + `support.js` | 同上 |

**（单文件）.html 是编译产物，用于查看，不要直接改。** 要改就改 `.dc.html`（需与 `support.js` 放在同一目录才能打开），改完重新打包。

设计系统只以单文件 HTML 交付，没有可编辑源 —— 它是取值来源，不是待改的设计稿。

**取值冲突时以 `DESIGN SYSTEM.html` 为准。** 完整设计文件是它的应用结果；两者不一致说明完整设计漏同步了。

---

## Design Tokens

### 色板 · Light

七条色阶，每条八档（700 → 50），600 为默认档。500→50 由基色混白得到，混白比例 21% / 44% / 66% / 86% / 93% / 97%。

| 色相 | 700 | 600 (P) | 500 | 400 | 300 | 200 | 100 | 50 |
|---|---|---|---|---|---|---|---|---|
| Neutral 中性 | `#1A1A1A` | `#404040` | `#727272` | `#8A8A8A` | `#CACACA` | `#E2E2E2` | `#F2F2F2` | `#FAFAFA` |
| Blue 蓝 | `#0069D7` | `#0078F0` | `#3694F3` | `#70B3F7` | `#A8D1FA` | `#DBECFD` | `#EDF6FE` | `#F7FBFE` |
| Green 绿 | `#199242` | `#1DA84C` | `#4CBA72` | `#80CE9B` | `#B2E1C2` | `#DFF3E6` | `#EFF9F1` | `#F8FDF9` |
| Red 红 | `#B3261E` | `#E5352F` | `#EA5F5B` | `#F08E8A` | `#F6BAB8` | `#FBE3E2` | `#FDF1F0` | `#FEF9F9` |
| Yellow 黄 | `#D19D00` | `#F0B400` | `#F3C436` | `#F7D570` | `#FAE6A8` | `#FDF3D6` | `#FEFAED` | `#FEFDF7` |
| Purple 紫 | `#7C37CA` | `#8E3FE8` | `#A667ED` | `#C093F2` | `#D9BEF7` | `#EFE4FC` | `#F7F1FE` | `#FCF9FE` |
| Orange 橙 | `#CE5C0A` | `#ED6A0C` | `#F1893F` | `#F5AC77` | `#F9CCAC` | `#FCE7D8` | `#FEF5EF` | `#FEFBF8` |

黑白：`#000000` / `#FFFFFF`。

### 色板 · Dark

**独立一套，不从浅色梯度取值。** 浅色梯度是基色混白算出来的，越浅越脱色；深色需要的是提亮但保饱和，两条曲线不重合。D500 为深色基准档。

| 色相 | D700 | D600 | D500 (P) | D400 | D300 |
|---|---|---|---|---|---|
| Blue Dark | `#0069D7` | `#2A8CFF` | `#4C9BFF` | `#9DC7FF` | `#C8E0FF` |
| Green Dark | `#1DA84C` | `#22B856` | `#34C759` | `#5EE07E` | `#96EFAF` |
| Red Dark | `#C42B24` | `#E5352F` | `#EE4038` | `#FF8A83` | `#FFBAB6` |
| Yellow Dark | `#D19D00` | `#F0B400` | `#F5C862` | `#F9DC9A` | `#FCEBC7` |
| Purple Dark | `#8E3FE8` | `#A97BF0` | `#C9AEFB` | `#DCC8FC` | `#EBE0FE` |
| Orange Dark | `#ED6A0C` | `#F58F42` | `#FFB27A` | `#FFCBA3` | `#FFE0C9` |

深色面板底只有一个：`#000000`。

### 使用场景 · Light

**前景**

| 角色 | 取值 | token | 用途 |
|---|---|---|---|
| 主文字 | `rgb(26,26,26)` | Neutral 700 | 标题、列表标题 |
| 正文 | `rgb(26,26,26)` | Neutral 700 | Activity 内容、字段值（与主文字同值） |
| 次级 | `rgb(64,64,64)` | Neutral 600 | 次级正文、分段控件未选中项 |
| 三级 | `rgb(114,114,114)` | Neutral 500 | Section header、label、说明文字 |
| 四级 | `rgb(138,138,138)` | Neutral 400 | 时间戳等最弱信息 |
| 强调 | `rgb(0,120,240)` | Blue 600 | 图标、选中态、运行中状态点与文字 |
| 破坏性 | `#B3261E` | Red 700 | 删除类操作的按钮文字 |

**背景与描边**

| 角色 | 取值 | token |
|---|---|---|
| 面板底 | `#FFFFFF` | White |
| 卡片底 | `#FFFFFF` | White（靠描边与面板区分） |
| 选中底 | `rgb(242,242,242)` | Neutral 100 |
| 控件底 | `rgba(120,120,128,.1)` | — |
| 强调填充 | `rgb(0,120,240)` | Blue 600 |
| 次级按钮底 | `rgba(120,120,128,.16)` | — |
| 分隔线 1px | `rgba(0,0,0,.05)` | — |
| 描边 .5px | `rgb(226,226,226)` | Neutral 200 |
| 结构连接线 1px | `rgba(60,60,67,.24)` | — |

### 使用场景 · Dark

底色只有 `#000`。**纯黑没有环境亮度垫底，低透明度白掉得比在灰底上快得多 —— 一律按下表取值，不要从浅色换算。**

**前景**

| 角色 | 取值 | token |
|---|---|---|
| 主文字 | `#FFFFFF` | White |
| 正文 | `rgba(255,255,255,.78)` | White 78% |
| 次级 | `rgba(255,255,255,.58)` | White 58% |
| 三级 | `rgba(255,255,255,.50)` | White 50% |
| 四级 | `rgba(255,255,255,.46)` | White 46% |
| 强调 | `#4C9BFF` | Blue D500 |
| 破坏性 | `#EE4038` | Red D500 |

**背景与描边**

| 角色 | 取值 | token |
|---|---|---|
| 面板底 | `#000000` | Surface |
| 卡片底 | `rgba(255,255,255,.10)` | White 10% |
| 选中底 | `rgba(255,255,255,.12)` | White 12% |
| 控件底 | `rgba(255,255,255,.14)` | White 14% |
| 强调填充 | `#FFFFFF` | White（配 `#111` 文字） |
| 次级按钮底 | `rgba(255,255,255,.16)` | White 16% |
| 分隔线 1px | `rgba(255,255,255,.14)` | White 14% |
| 描边 .5px | `rgba(255,255,255,.18)` | White 18% |
| 结构连接线 1px | `rgba(255,255,255,.24)` | White 24% |

### 排版

字体：**SF Pro**（`-apple-system`）。数字、时间、路径、ID 用 **SF Mono**。

五个字号直接对应 macOS 系统文本样式，行高跟着样式走：

| 用途 | 样式 | 规格 |
|---|---|---|
| 详情页大标题 | Title 1 | 22 / Regular / 26 |
| 区块标题 | Title 3 Emphasized | 15 / Semibold / 20 |
| 侧栏组头 · 列表标题 | Body Emphasized | 13 / Semibold / 16 |
| 正文 | Body | 13 / Regular / 16 |
| 状态药丸 · 计数 | Subheadline Emphasized | 11 / Semibold / 14 |
| 副标题 · 字段值 | Subheadline | 11 / Regular / 14 |
| 指标 label · 泳道名 | Caption 2 | 10 / Medium / 13 / .04em |
| 时间戳 | Footnote（SF Mono） | 10 / Regular / 13 |
| ID · 路径 | Subheadline（SF Mono） | 11 / Regular / 14 |

字重只有三档，数值实现用 SF 的可变字重刻度：**Regular 400 / Medium 510 / Semibold 590**。

**不要用 Bold。** macOS 只把 Bold 留给 Headline 和 Title 1 Emphasized，这套界面里没有这两个角色；层级靠字号、颜色和位置拉开。

### 间距与网格

**4pt 基准**（macOS 桌面密度，不用 8pt）。行高与列宽都是 4 的倍数。

关键尺寸：

| | |
|---|---|
| 窗口圆角 | 16 |
| 工具栏 / header 高 | 52 |
| 侧栏宽 / 内边距 / 行高 | 224 / `0 14` / 32 |
| 侧栏选中胶囊 | radius 8，左右各外扩 4 |
| Activity 行高 | item 40 / header 36 / marker 32 |
| 泳道格 | 13×13，radius 3，gap 4 |
| Notch 面板宽 | 520 |
| Notch 顶栏 | 高 32，padding `0 14` |
| Notch 列表行 | padding `10 16 11`，列 `8px 1fr auto`，列间距 10 |
| Notch subagent 子行 | padding `3 16 3 34`，末行下 9 |
| Notch 面板下圆角 | 26 |

---

## 组件

### 标签 Tag（自定义组件）

高 17，radius **5（矩形，不是胶囊）**，padding `0 6`，9 / Medium / .04em，列宽固定 82 居中。每档都带 .5px inset 描边。

**注意力三档** —— 档位由「是否需要人处理」决定，不由类别决定：

| 档 | Light 底 / 字 | Dark 底 / 字 |
|---|---|---|
| **L1 无饱和** | 无底色 + `rgba(0,0,0,.16)` 描边 / `rgb(138,138,138)` | 无底色 + `rgba(255,255,255,.28)` 描边 / `rgba(255,255,255,.46)` |
| **L2 淡纯色** | 色相 200 档 / 色相 700 档 | 色相 600 @22–26% / 色相 D500 |
| **L3 满饱和实色** | 色相 600 / `#FFFFFF` | 色相 D600 / `#FFFFFF` |

各色相的具体取值见 `DESIGN SYSTEM.html` §2.6 的两张表。

标签到色相的映射（语义，见 §4.3）：

| 色相 | 档 | 标签 |
|---|---|---|
| Neutral | L1 | SESSION · CONTEXT · CTX · REASON · COMPACT |
| Yellow | L2 | TOOL · RESULT |
| Purple | L2 | PLAN |
| Orange | L2 | SUBAGENT |
| Blue | L2 / L3 | ASSIST（L2）· TURN END（L3） |
| Green | L3 | USER |
| Red | L3 | FAILED · ABORTED |

### 状态点 ItemStatus（自定义组件）

7px 圆点，行内位于标签后 10px 槽。**三种形态**：

- **空心** — 1.5px 描边，无填充
- **实心** — 纯色填充
- **实心 + 呼吸** — 纯色填充 + 2.5px 光晕

不需要状态时整个槽留白，不画点。

呼吸圈透明度两套不同：**Light `.20`，Dark `.32`** —— 纯黑底下 `.20` 的光晕基本看不见。

**只有正在进行的状态才带呼吸。** 结束态（Completed / Failed / Aborted）是实心无光晕。

### 状态药丸 StatusPill

高 22，radius 1000，左右内边距 10，7px 实心点 + 6px 槽 + 11 / Semibold 文案。四个值：底 / 描边 / 点 / 字。各色相取值见 §3.1。

### 系统组件

按钮、输入框、复选框 / 单选 / 开关、分段控件 / 下拉、滑杆 —— **一律用 AppKit / SwiftUI 原生控件。** 设计系统里标的尺寸只是对照，**真机以系统当前样式为准**；系统与文档不一致时跟系统走。

---

## Screens

### macOS 主窗口（1440×860）

**布局** — 三栏：侧栏 224 / 中栏 flex / Inspector 320。工具栏高 52 通栏。

**侧栏** — Section header（13 / Semibold / Neutral 500，高 34 首个 / 43 其余，padding `0 4 9`）+ 行（高 32，图标槽 24 + 文字 + 尾部计数）。选中态：`rgb(242,242,242)` 底 + radius 8，左右各外扩 4，**文字色不变**。

**Session 列表行** — 两行结构：标题行（16px agent 图标 + 13 / Semibold 标题 + 右侧时间）+ 状态行（7px 点 + 11 / Regular 状态文案，缩进 22）。subagent 子行缩进 32，带 L 形连接线 `rgba(60,60,67,.24)`。

运行中的行状态点带 `2.5px` 呼吸光晕；结束态不带。

**Activity 时间线** — 时间 56 + 标签 82 + 单行内容，列间距 12。marker 行横跨、无标签底色。行高 item 40 / marker 32。

**泳道** — 三行，格子 13×13 / radius 3 / gap 4，空格留白不填底色。**跨泳道事件不占泳道**：三行各画一条 13 高 × 4 宽 / radius 2 的小条，列宽也收到 4，靠宽度差与实格区分。

**Inspector** — 指标卡三联（15 / Semibold 数值 + 10 / Medium 全大写 label）+ 字段分组（13 / Semibold 组标题 + 11 / Regular 字段行，label 左值右对齐）。

其余页面：Pair iPhone、Settings（Daemon / Relay / Appearance）。

### Notch 面板（宽 520）

面板 **纯黑实色 `#000`，无材质、无描边、无投影** —— 它必须和摄像头挖孔无缝拼接，任何半透明、模糊或亮边都会让接缝显形。下圆角 26。

> ⚠️ 这不是可选项。Nook chrome 的 `NookStyle` 只暴露 `topCornerRadius` / `bottomCornerRadius` / `expandedContentInsets`，没有 surface color 或 material 参数，面板底色由 chrome 画成不透明黑。

**顶栏** — 高 32，padding `0 14`。左侧应用标识（15px 线图标 + 11 / Regular / 58% 文字），右侧设置与锁图标（15px，描边 62% 白）。这条横带把摄像头区留空。

五个页面：

1. **收起态** — 236×32，下圆角 12，状态点 + 会话数。三种：无会话（42% 白点 / 46% 白数字）、运行中（`#4C9BFF` + 呼吸）、待处理（`#34C759` + 呼吸）。
2. **Session 列表** — 行 `padding:10 16 11`，列 `8px 1fr auto`，列间距 10。8px 状态点 + 13 / Semibold 标题 + agent 标签 + 等宽相对时间。subagent 子行缩进 34、6px 点、11 / Regular / 78% 标题，L 形引导线 24% 白从父行状态点连下来。**archive 图标只在 turn 已结束的行上、hover 时替换时间戳**（同一 20px 槽位交换，不产生位移）。
3. **Turn 刚启动** — 标题 + 「Turn started」+ 计时，下方用户输入原文（11 / Regular / 78%，最多 6 行）。
4. **Turn 结束** — 标题 + 「Turn complete」+ 耗时，指标胶囊三联（tokens / context / still running），总结正文最多 6 行，底部主按钮。
5. **Session 详情** — 返回键 + 15 / Semibold 标题，状态药丸 + agent 标签，指标卡三联，RECENT ACTIVITY 列表（60pt 标签 + 单行内容，行高 22），底部主按钮 + 次级按钮。

**agent 标签在所有行上同色**（`.14` 底 + `.58` 字）。轮次结束只降标题（`#fff` → `.78`）和状态点（饱和色 → `42%` 白无光晕），不降标签。

---

## 语义规则

### Session 生命周期（四档）

| 状态 | 色相 | 点 | 说明 |
|---|---|---|---|
| Running | Blue | 实心 + 呼吸 | agent 在跑：thinking / responding / toolRunning / subagentRunning / compacting 都归这一档，副标题换成当前 phase |
| Waiting for input | Green | 实心 + 呼吸 | 需要人处理。**唯一会把 session 排到列表最前并推 notch 的一档** |
| Completed / Idle | Neutral | 实心 | 轮次收尾或长时间无事件。标题不降色，只有状态点与副标题转灰 |
| Failed / Aborted | Red | 实心 | 失败或中断 |

### Turn phase（十个）

phase 只换状态点与页头副标题，**不换生命周期那一档颜色**。

| phase | 色相 | 形态 |
|---|---|---|
| submitted | Neutral | 空心（唯一不填充的） |
| thinking / responding / toolRunning | Blue | 实心 + 呼吸 |
| waitingPermission | Green | 实心 + 呼吸 |
| subagentRunning | Orange | 实心 + 呼吸 |
| compacting | Neutral | 实心 + 呼吸 |
| stopped / aborted | Neutral | 实心 |
| failed | Red | 实心 |

### 消息类别

泳道由 **block 类型**决定，不是消息角色：assistant 的 `tool_use` 与 user 的 `tool_result` 都进 Exec。完整对照表见 `DESIGN SYSTEM.html` §4.3。

---

## Interactions & Behavior

- **archive 按钮** — 只在 `turnEnded` 的行上、hover 时出现，占用时间戳所在的 20pt 槽位，两者互斥交换，不产生布局位移。
- **呼吸动画** — 运行中状态点的光晕循环缩放。
- **Notch 展开** — 只有 L3 阶段消息（USER / TURN END / FAILED）能触发展开和触感反馈。
- **列表排序** — 需要人处理的 session 排到最前。

---

## 已知的代码与设计差异

这份设计与现有 Swift 实现对比后发现的两处，实现侧需要修：

**1. 状态点降级与标题降级是两套独立开关**

`AgentStatusNookController.swift`：

```swift
.foregroundStyle(session.turnEnded ? Color.nookSecondary : Color.nookTitle)
```

标题用 `session.turnEnded` 降级，圆点用 `session.statusTone` 上色。结果是标题变灰了但点还是满饱和绿，三档注意力塌成一档。两者应该同步。

**2. 时间戳被塞进 20pt 固定槽**

```swift
Text(SessionRelativeTimeFormatter.string(...))
    .fixedSize()
}
.frame(width: NotchMetric.trailingCell, height: ..., alignment: .trailing)
```

`trailingCell = 20`，但 10pt 等宽的 `11m` / `now` 实际宽 22–26pt，`.fixedSize()` 让它溢出这个框，时间戳右边缘与 archive 按钮对不齐。设计里这一列是 `auto 20px`：时间是 auto 宽，只有 archive 槽位固定 20。

---

## Assets

无位图资源。全部图标是内联 SVG 线图标，实现时换成对应的 SF Symbols：

| 设计中的图标 | SF Symbol |
|---|---|
| 终端（应用标识） | `terminal` |
| 齿轮（设置） | `gearshape` |
| 锁 | `lock` |
| 归档 | `archivebox` |
| 返回 chevron | `chevron.left` |

图标只有 14 / 16 两个尺寸，描边宽度随尺寸 1.3 / 1.4 / 1.6，**不用填充图标**。状态与类别不用图标表达，用状态点与标签。
