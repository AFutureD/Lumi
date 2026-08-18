# 在 Mac 上跟进一次 Codex Session

> 验证状态：开发预览。合成 Agent 事件已完成 helper、daemon、Mac 列表与详情的真实进程验证；真实 Codex Hook 仍待验收。

最短路径：Settings > Daemon > Agents > 新建 Codex Session > 在主窗口或 Notch 查看。

## 用户目标

- 同时运行多个 Codex Session 时，不必逐个切换终端。
- 快速判断哪个 Session 正在执行、等待输入、完成或出错。
- 需要时查看消息与执行时间线，但不从 Agent Status 控制 Agent。

## 前置条件

- Mac App 已安装并启动。
- daemon 可在当前用户下运行。
- 如需低延迟事件，Agent Status Hook 已在 Codex 中信任。

## 主路径

1. 在侧边栏选择“Settings”，再在中栏选择“Daemon”并点击“Install & Start daemon”。
   - 系统反馈：daemon 区域显示已安装、运行和连接状态。
   - 规则引用：[MAC-R-001](../modules/mac-session-view.md#mac-r-001-daemon-决定实时可用性)。
2. 在中栏选择“Agents”，点击“Install Hook”，必要时在 Codex /hooks 中信任。
   - 系统反馈：安装成功或显示具体错误。
   - 数据变化：只增加 Agent Status Hook，其他集成保留。
   - 规则引用：[MAC-R-002](../modules/mac-session-view.md#mac-r-002-安装不替换现有-hooks)。
3. 回到侧边栏“Sessions”，再新建一个 Codex Session 并提交任务。
   - 系统反馈：Main Session 以标题、Agent 类型和状态出现在主窗口中栏；Subagent 作为可折叠子项显示在所属 Main Session 下，并使用自己的名称或任务身份，不复用父 Session 请求作为标题。Notch 展开后显示标题、状态和当前 Turn 用户消息。
   - 数据变化：启用前已经存在的旧 Session 不会自动导入。
   - 规则引用：[MAC-R-011](../modules/mac-session-view.md#mac-r-011-只记录启用后的新-session)、[MAC-R-014](../modules/mac-session-view.md#mac-r-014-notch-显示-session-当前状态)、[MAC-R-016](../modules/mac-session-view.md#mac-r-016-session-列表与详情按信息层级展示)、[MAC-R-018](../modules/mac-session-view.md#mac-r-018-subagent-使用自己的标题与活动)。
4. 在中栏选择目标 Session。
   - 系统反馈：工具栏显示 Session 标题，subheader 显示 Agent、状态药丸和工作目录；右栏 Activity 展示属于当前 Session 的全部记录，粘顶 header 提供 All / Input / Tools / Model 分段筛选和 Input、Tools、Model 三行时间轴，点击方格可跳到对应记录并短暂高亮；右侧 Inspector 显示 Token / Context / Elapsed 指标与 Overview、Model、Usage 字段。Subagent 为执行任务获得的父 Session 历史不会重复出现在其 Activity。
   - 数据变化：只改变查看对象。
   - 规则引用：[MAC-R-004](../modules/mac-session-view.md#mac-r-004-查看不控制-agent)、[MAC-R-016](../modules/mac-session-view.md#mac-r-016-session-列表与详情按信息层级展示)、[MAC-R-017](../modules/mac-session-view.md#mac-r-017-activity-全量显示并支持时间轴定位)、[MAC-R-018](../modules/mac-session-view.md#mac-r-018-subagent-使用自己的标题与活动)。
5. 继续使用 Codex。
   - 系统反馈：收到 Agent 事件时，列表状态、Inspector 和 Activity 自动更新；Inspector 中的字段值可以选择；停在 Activity 底部时新记录会跟随显示，否则保持当前滚动位置。
   - 数据变化：新活动同步到本地保存内容。
   - 规则引用：[MAC-R-003](../modules/mac-session-view.md#mac-r-003-展示活动并保留-session-诊断数据)。

完成信号：目标 Main Session 以权威标题、Agent 图标和状态出现在列表中；Subagent 以自己的名称或任务身份显示并可展开/折叠，右栏 Inspector 与属于所选 Session 的全量 Activity 随 Agent 活动变化。

用户需要调整 Notch 时，在 Notch 点击设置按钮，或在主 App 选择“Settings > Notch”。第三栏的 Appearance section 不显示固定的 Theme 和 Layout 控件；页面提供 Surface、显示屏幕、可恢复的紧凑宽度、展开宽度、展开动画、保持展开、触觉反馈和 Show Notch。完整取值规则见 [MAC-R-015](../modules/mac-session-view.md#mac-r-015-notch-设置集中在主-app)。

## 刷新与删除

### 手动刷新

点击工具栏右侧的刷新图标（Refresh Sessions）。系统从 daemon 取得完整当前数据；列表、数量或详情变化代表结果已显示，数据无变化时没有单独的完成提示。

### 删除单个 Session

选择 Session，点击工具栏右侧的删除图标（Delete Session），再在确认框点击“Delete”。该 Session 从 daemon、Mac 与在线 iPhone 中移除；随后选择会转到剩余列表中的 Session，删除最后一条时中栏显示 No Sessions、右栏显示 Select a Session。点击“Cancel”则不改变数据。

### 清空全部历史

在“Settings > Daemon”点击“Clear Session history…”并确认。Mac 与在线 iPhone 的列表清空；之后新建的 Codex Session 仍可重新进入列表。

## 失败路径

### daemon unavailable

- 用户看到：设置显示 Not connected，工具栏状态不可用。
- 可执行动作：点击“Install & Start daemon”，恢复后点击刷新图标（Refresh Sessions）。
- 数据影响：Mac 已同步内容仍可查看，不会因断线自动删除。

### Hook 尚未信任

- 用户看到：Codex 将 Hook 标为待审核，实时更新缺失。
- 可执行动作：在 Codex /hooks 检查并信任 Agent Status 命令。
- 数据影响：现有其他 Hooks 不变。

### 列表为空

- 可能原因：启用后尚未新建 Session，或用户已删除全部历史。
- 可执行动作：新建 Codex Session 并触发一次受支持活动。
- 完成信号：首个事件到达后出现 Session。

## 持久化结果

- Session 不按时间自动过期，由用户决定何时删除。
- 单条删除和清空历史都只影响 Agent Status。
- 外部 Session 内容只通过 App 启动、手动刷新和 Agent 事件同步；删除和清空会立即同步操作结果。规则见 [MAC-R-009](../modules/mac-session-view.md#mac-r-009-外部内容只有三种同步入口)。

## 下一目标

[在 iPhone 上查看多台 Mac](check-session-away.md)。

## 涉及模块与数据

- [Mac 会话查看](../modules/mac-session-view.md)
- [Session 状态与时间线](../data-flows.md#session-状态与时间线)
- [用户摩擦点](../friction-points.md)
