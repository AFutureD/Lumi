# Mac 会话查看

> 验证状态：开发预览。App 已在 macOS 上完成编译、启动、Sessions 与 Settings 三栏交互、Notch 展开、Notch 设置入口、手动刷新、单 Session 删除和本地同步验证；真实 Codex Hook、正式签名、公证与干净机器安装仍待验收。

Agent Status 在一台 Mac 上聚合多个 Agent 的多个 Session。主窗口使用与 Mail.app 相同的“导航—列表—详情”层级，Notch 用于快速查看当前活动。

## 模块概览

- **入口**：启动 Agent Status；侧边栏包含“Sessions”“iPhone”“Settings”。
- **前置条件**：macOS 15 或更高版本；daemon 已安装并运行。
- **主要结果**：用户可查看 Session 状态和时间线，手动刷新、删除单个 Session，或清空全部 Agent Status 历史。
- **只读边界**：查看和删除 Agent Status 中的记录不会审批、终止或修改 Codex Session。
- **相关旅程**：[在 Mac 上跟进一次 Codex Session](../journeys/observe-session-locally.md)。

## 主窗口布局

### Sessions：标准三栏

1. 左栏是全高侧边栏，负责在 Sessions、iPhone 和 Settings 之间导航。
2. 中栏是 Session 列表，按最近更新时间排序；每行显示标题、时间、状态、阶段和工作目录摘要。
3. 右栏是详情，显示 Agent、Session 状态、工作目录、更新时间，以及消息、工具、计划、子 Agent 和错误。
4. 刷新图标（Refresh Sessions）位于 Session 列表上方；删除图标（Delete Session）位于详情上方。

“iPhone”页面收起中栏，让配对内容使用剩余区域。“Settings”继续保持三栏：左栏是产品导航，中栏列出 General、Notch、Daemon、Agents 和 About，右栏显示当前设置详情。

### Notch：活动摘要

Notch 紧凑时显示全部符合展示条件的 Session 数量和最近一个 Session 的状态色；展开后列出其中最近更新的最多四个，帮助用户快速判断各 Session 正在做什么。Notch 顶部的设置按钮打开主 App 的 Notch 设置，不在 Notch 内维护第二套设置页。完整展示规则和可用选项见 [MAC-R-014](#mac-r-014-notch-显示-session-当前状态) 和 [MAC-R-015](#mac-r-015-notch-设置集中在主-app)。

### Session 状态颜色

Mac Session 列表、详情、Notch 和 iPhone 使用相同颜色语义区分进行中、等待下一轮、等待用户处理、完成和异常状态。颜色使用系统动态色，会随浅色、深色和辅助功能显示设置调整。Mac 列表中的选中行使用系统选中文字颜色，以保持与选中背景的对比度。完整映射见 [MAC-R-013](#mac-r-013-session-状态颜色跨端一致)。

## 首次配置

1. 在侧边栏选择“Settings”，再在中栏选择“Daemon”。
2. 点击“Install & Start daemon”。
   - 系统反馈：daemon 区域显示连接和运行状态。
   - 规则引用：[MAC-R-001](#mac-r-001-daemon-决定实时可用性)。
3. 在中栏选择“Agents”，点击“Install Hook”。
   - 系统反馈：成功或显示安装错误。
   - 数据结果：只追加 Agent Status Hook，不覆盖其他集成。
   - 规则引用：[MAC-R-002](#mac-r-002-安装不替换现有-hooks)。
4. 如 Codex 要求审核，在 /hooks 中信任 Agent Status 命令。
5. 新建一个 Codex Session。
   - 系统反馈：首个受支持 Agent 事件到达后，Session 出现在中栏。
   - 规则引用：[MAC-R-011](#mac-r-011-只记录启用后的新-session)。

完成信号：daemon 显示已连接；新 Session 在列表中出现，详情随 Agent 事件更新。

## 日常操作

### 刷新 Session

点击 Session 列表上方的刷新图标（Refresh Sessions），从 daemon 取得完整当前数据。列表、数量或详情变化代表同步结果已显示；数据没有变化时，当前版本没有单独的完成提示。外部产生的 Session 内容除此之外只会在 App 启动和收到 Agent 事件时更新，不进行定时轮询。

### 删除单个 Session

选择 Session，点击详情上方的删除图标（Delete Session），再在确认框点击“Delete”。该 Session 会从 daemon、Mac 和已连接 iPhone 中删除。删除不影响 Codex 自身 Session；之后到达的同一 Session 活动也不会让它重新出现在 Agent Status 中。

### 清空全部历史

在“Settings > Daemon”点击“Clear Session history…”，确认后清空 Agent Status 保存的全部 Session 与时间线。Codex 自身历史不受影响。

## 规则

### MAC-R-001 daemon 决定实时可用性

- 条件：daemon 已安装、获准运行并成功连接。
- 行为：App 在启动时取得完整数据，并订阅后续 Agent 事件。
- 结果：工具栏和设置页显示连接状态，Session 保持同步。
- 限制或例外：daemon 断开时，Mac 仍可查看本地已同步内容，但会显示不可用，刷新和删除无法完成。

### MAC-R-002 安装不替换现有 Hooks

- 条件：用户点击“Install Hook”。
- 行为：只追加尚不存在的 Agent Status Hook。
- 结果：其他集成继续保留。
- 限制或例外：新增 Hook 可能需要在 Codex /hooks 中审核并信任。

### MAC-R-003 只采集用户可见活动

- 条件：新 Session 产生受支持的 Agent 事件。
- 行为：整理消息、工具、计划、子 Agent、状态和错误。
- 结果：重复事件不产生重复时间线，乱序事件不回退可见状态。
- 限制或例外：reasoning、系统指令、环境快照和原始 transcript 不进入产品时间线。

### MAC-R-004 查看不控制 Agent

- 条件：用户选择 Session 或时间线项目。
- 行为：只改变当前查看对象。
- 结果：Codex Session 不会被批准、终止或修改。
- 限制或例外：v1 没有远程控制入口。

### MAC-R-005 已移除：旧 Notch 活动摘要

- 状态：removed。
- 移除日期：2026-08-17。
- 原因：旧 Notch 展示规则已由新的 Session glance 与主 App 设置规则替代。
- 替代规则：[MAC-R-014](#mac-r-014-notch-显示-session-当前状态)、[MAC-R-015](#mac-r-015-notch-设置集中在主-app)。

### MAC-R-006 已移除：自动保留 7 天

- 状态：removed。
- 移除日期：2026-08-17。
- 原因：按时间自动删除不再属于当前产品规则。
- 替代规则：[MAC-R-012](#mac-r-012-历史由用户决定删除)。

### MAC-R-007 移除集成只移除 Agent Status

- 条件：用户点击“Remove Hook”。
- 行为：只删除 Agent Status helper 对应的处理项。
- 结果：其他 Hook 保留。
- 限制或例外：daemon 仍可运行；停止全部采集还需停止并卸载 daemon。

### MAC-R-008 清空历史不修改 Codex

- 条件：用户确认“Clear Session history…”。
- 行为：清空 Agent Status 保存的全部 Session 与时间线。
- 结果：Mac 和已连接 iPhone 不再显示这些 Session。
- 限制或例外：Codex 自身 Session 和日志不受影响。

### MAC-R-009 外部内容只有三种同步入口

- 条件：App 启动、用户点击刷新图标（Refresh Sessions）或收到 Agent 事件。
- 行为：分别执行首次同步、完整手动同步或增量更新。
- 结果：界面不依赖周期轮询。
- 限制或例外：删除和清空会立即同步操作结果；连接恢复会重新建立事件通道，但不会引入定时轮询。

### MAC-R-010 单 Session 删除跨端同步

- 条件：用户选择一个 Session 并确认删除。
- 行为：删除该 Session 及时间线，并把结果同步到当前客户端。
- 结果：daemon、Mac 和已连接 iPhone 保持一致。
- 限制或例外：操作需要 daemon 在线；不删除 Codex 自身内容。

### MAC-R-011 只记录启用后的新 Session

- 条件：daemon 第一次建立 Codex 日志基线。
- 行为：忽略当时已经存在的旧 Session，只接收之后新建的 Session。
- 结果：首次启用不会突然导入整份 Codex 历史。
- 限制或例外：已加入 Agent Status 的 Session 后续活动会继续更新，直到用户删除。

### MAC-R-012 历史由用户决定删除

- 条件：Session 已进入 Agent Status。
- 行为：系统不按时间主动清理。
- 结果：Session 保留到用户删除单条或清空全部历史。
- 限制或例外：删除后，同一 Session 的后续本地活动不会恢复该记录。

### MAC-R-013 Session 状态颜色跨端一致

- 条件：Mac、Notch 或 iPhone 显示一个 Session 的当前状态。
- 行为：Starting 和 Running 使用蓝色；Waiting For Input 在 Idle 阶段使用绿色、在 Waiting For Approval 阶段使用橙色；Completed 使用灰色；Failed 和 Interrupted 使用橙色。
- 结果：用户在三个界面看到相同的状态颜色语义。
- 限制或例外：颜色是系统动态色；Mac 列表选中行优先使用系统选中文字颜色保证可读性。Notch 仍只展示当前纳入活动摘要的 Session，不因颜色规则扩大显示范围。

### MAC-R-014 Notch 显示 Session 当前状态

- 条件：Mac 本地同步数据中存在 Starting、Running、Waiting For Input、Failed 或 Interrupted 的 Session。
- 行为：紧凑状态统计全部符合条件的 Session；展开后按最近更新时间列出最多四个，每行显示标题、状态和当前 Turn 最近一条用户消息。新 Session、生命周期变化、当前用户消息变化，以及进入或离开等待审批时会短暂显示活动卡片。
- 结果：用户不打开主窗口也能判断 Session 正在做什么以及当前请求是什么。
- 限制或例外：Completed 和未知状态不持续留在展开列表；Session 刚进入 Completed 时仍可短暂显示完成卡片。没有可显示的用户消息时显示等待首条用户消息。Notch 只读取 Mac 已同步内容，不额外刷新 daemon。

### MAC-R-015 Notch 设置集中在主 App

- 条件：用户点击 Notch 顶部设置按钮，或在主 App 选择“Settings > Notch”。
- 行为：主 App 显示 Theme（Match Mac、Dark、Light）、Surface（Solid、Translucent、Liquid Glass）、Layout（Auto、Notch、Floating）、保持展开、触觉反馈和 Show Notch；启用触觉反馈时会给出一次确认，并在有意义的活动提示出现时反馈。设置按钮不会在 Notch 内打开独立设置页。
- 结果：Notch 外观与交互设置在主 App 的三栏 Settings 中保存并立即应用。
- 限制或例外：Theme、Surface 和 Layout 为互斥选项；触觉反馈仍受 Mac 硬件和系统设置限制。

## 空状态与故障

- **No Sessions**：daemon 在线，但启用后尚无新 Session，或用户已删除全部记录。
- **No active Sessions**：Notch 没有 Starting、Running、Waiting For Input、Failed 或 Interrupted 的 Session；历史仍可在主窗口查看。
- **Daemon unavailable**：保留本地已同步内容供查看；恢复 daemon 后点击刷新图标（Refresh Sessions）。
- **Hook 未信任**：新活动可能不能即时到达；在 Codex /hooks 完成审核。

更多恢复步骤见[用户摩擦点](../friction-points.md)。

## 业务数据

Session 状态与时间线在 daemon 和 Mac 上分别保存同步副本，不自动过期。Mac 的副本支持快速启动、列表浏览和离线查看；daemon 恢复后，以 daemon 当前数据为准重新同步。

Notch 消费 Mac 已同步的 Session 与时间线，不创建额外 Session 副本，也不增加新的刷新入口；详细筛选与展示规则见 [MAC-R-014](#mac-r-014-notch-显示-session-当前状态)。

删除单个 Session 或清空历史只影响 Agent Status。完整生命周期见[数据流](../data-flows.md#session-状态与时间线)。

## 相关文档

- [功能全景](../index.md)
- [本地查看旅程](../journeys/observe-session-locally.md)
- [数据流](../data-flows.md)
- [摩擦点](../friction-points.md)
