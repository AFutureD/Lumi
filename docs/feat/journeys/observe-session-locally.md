# 在 Mac 上跟进一次 Codex Session

> 验证状态：开发预览。合成 Agent 事件已走通从 Hook 采集到 Mac 列表与详情的完整链路；真实 Codex Hook 长期运行仍待验收。

最短路径：Settings > Daemon > Agents > 在 Codex 里提交一次任务 > 在主窗口或 Notch 查看。

## 用户目标

- 同时运行多个 Agent Session 时，不必逐个切换终端。
- 快速判断哪个 Session 正在执行、等着自己审批、已结束但还没看过、看过了，或者出错。
- 需要时查看消息与执行时间线，但不从 Lumi 控制 Agent。

## 前置条件

- Apple silicon Mac，macOS 26 或更高版本；Mac App 已安装并启动。
- daemon 可在当前用户下运行。
- 本机安装了 Codex 或 Claude Code（Codex 需要它在场完成 Hook 信任）。

## 主路径

1. 在侧边栏选择“Settings”，再在中栏选择“Daemon”并点击“Install & Start daemon”。
   - 系统反馈：Daemon 面板显示 Running 与运行信息。
   - 规则引用：[MAC-R-001](../modules/mac-session-view.md#mac-r-001-daemon-决定实时可用性)。
2. 在中栏选择“Agents”，在 Integrations 列表里你使用的 Agent 行（Codex / Claude Code）点击“Install”。
   - 系统反馈：卡片显示 integration installed；Codex 卡片随后显示“Trusted by Codex”。
   - 数据变化：只增加 Lumi Hook，其他集成保留，写入前留有备份；Codex 的信任记录只针对 Lumi 自己的处理项写入。
   - 规则引用：[MAC-R-002](../modules/mac-session-view.md#mac-r-002-安装不替换现有-hooks)、[MAC-R-021](../modules/mac-session-view.md#mac-r-021-自动向-codex-申请-hook-信任)。
3. 回到侧边栏“Sessions”，在 Codex 里提交一次任务（新 Session 或旧 Session 都可以）。
   - 系统反馈：Main Session 以标题、Agent 图标和状态出现在主窗口中栏；Subagent 作为可折叠子项显示在所属 Main Session 下，并使用自己的名称或任务身份。Notch 紧凑态计数加一，展开后能看到这条 Session。
   - 数据变化：Session 首次进入时连同已有对话记录一起导入；从未再使用的旧 Session 不会出现。
   - 规则引用：[MAC-R-024](../modules/mac-session-view.md#mac-r-024-session-随-agent-活动进入-lumi)、[MAC-R-014](../modules/mac-session-view.md#mac-r-014-notch-显示-session-当前状态)、[MAC-R-016](../modules/mac-session-view.md#mac-r-016-session-列表与详情按信息层级展示)、[MAC-R-018](../modules/mac-session-view.md#mac-r-018-subagent-使用自己的标题与活动)。
4. 在中栏选择目标 Session。
   - 系统反馈：右栏显示该 Session 的完整 Activity（带可定位的时间轴与类别 / 重要性过滤）和 Inspector 指标，标题与工作目录出现在工具栏下方。
   - 数据变化：改变查看对象；这条 Session 若是绿色待查看，会被标记为已查看（绿降灰）并同步到所有端。
   - 规则引用：[MAC-R-004](../modules/mac-session-view.md#mac-r-004-查看不控制-agent)、[MAC-R-016](../modules/mac-session-view.md#mac-r-016-session-列表与详情按信息层级展示)、[MAC-R-017](../modules/mac-session-view.md#mac-r-017-activity-全量显示并支持时间轴定位)、[MAC-R-019](../modules/mac-session-view.md#mac-r-019-打开-session-即视为已查看)。
5. 继续使用 Codex。
   - 系统反馈：收到 Agent 事件时，列表状态、Inspector 和 Activity 自动更新；停在 Activity 底部时新记录会跟随显示，否则保持当前滚动位置。Turn 结束时 Notch 自动展开并短暂显示完成卡片。
   - 数据变化：新活动同步到本地保存内容。
   - 规则引用：[MAC-R-003](../modules/mac-session-view.md#mac-r-003-展示活动并保留-session-诊断数据)、[MAC-R-014](../modules/mac-session-view.md#mac-r-014-notch-显示-session-当前状态)。

完成信号：目标 Main Session 以 Agent 上报的标题、Agent 图标和状态出现在列表中；Subagent 以自己的名称或任务身份显示并可展开/折叠，Inspector 与 Activity 随 Agent 活动变化。之后如需调整 Notch 的表面、屏幕、宽度或动画，在 Notch 点设置按钮或打开“Settings > Notch”，见 [MAC-R-015](../modules/mac-session-view.md#mac-r-015-notch-设置集中在主-app)。

## 刷新与删除

### 手动刷新

点击工具栏右侧的刷新图标（Refresh）。daemon 先从对话记录重算当前选中的 Session，再同步全部 Session 的当前数据；列表、数量或详情变化代表结果已显示，数据无变化时没有单独的完成提示。

### 删除单个 Session

选择 Session，点击工具栏右侧的删除图标（Delete Session），再在确认框点击“Delete”。该 Session 从 daemon、Mac 与在线 iPhone 中移除；删除 Main Session 时其下的全部 Subagent 一并移除。随后选择会转到剩余列表中的 Session，删除最后一条时中栏显示 No Sessions、右栏显示 Select a Session。点击“Cancel”则不改变数据。

### 清空全部历史

在“Settings > Daemon”的 Session history 卡片点击“Clear history…”并确认。Mac 与在线 iPhone 的列表清空；之后 Agent 的新活动仍会让 Session 重新进入列表。

## 失败路径

### daemon 不可用

- 用户看到：“Settings > Daemon”显示 Not connected；刷新和删除不生效。
- 可执行动作：点击“Install & Start daemon”，恢复后点击刷新图标（Refresh）。
- 数据影响：Mac 已同步内容仍可查看，不会因断线自动删除。

### Codex 未信任 Hook

- 用户看到：Hook 已安装但 Codex Session 不再更新；“Settings > Agents”的 Codex 卡片提示还有处理项未被信任，或提示无法确认信任状态。
- 可执行动作：点击 Codex 行的“Trust”；仍不成功再到 Codex `/hooks` 手动信任。
- 数据影响：现有其他 Hooks 不变，只为 Lumi 自己的处理项写入信任记录。

### 列表为空

- 可能原因：Hook 未安装，或启用后还没有 Agent 产生新活动，或用户已删除全部历史。
- 可执行动作：在任一 Agent Session 里提交一次任务。
- 完成信号：首个事件到达后出现 Session。

## 持久化结果

- Session 不按时间自动过期，由用户决定何时删除。
- 单条删除和清空历史都只影响 Lumi。
- 外部 Session 内容只通过 App 启动、手动刷新和 Agent 事件同步；删除和清空会立即同步操作结果。规则见 [MAC-R-009](../modules/mac-session-view.md#mac-r-009-mac-界面只有三种同步入口)。

## 下一目标

[在 iPhone 上查看多台 Mac](check-session-away.md)。

## 涉及模块与数据

- [Mac 会话查看](../modules/mac-session-view.md)
- [Session 状态与时间线](../data-flows.md#session-状态与时间线)
- [用户摩擦点](../friction-points.md)
