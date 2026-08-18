# Mac 会话查看

> 验证状态：开发预览。App 已在 macOS 26 上完成编译、启动、Sessions / iPhone / Settings 三种布局的截图核对、Notch 展开、Notch 设置入口、手动刷新、单 Session 删除和本地同步验证；真实 Codex Hook、正式签名、公证与干净机器安装仍待验收。2026-08-18 起主窗口采用 Liquid Glass 重设计（原生工具栏 + Activity 主区 + 右侧 Inspector）。

Agent Status 在一台 Mac 上聚合多个 Agent 的多个 Session。主窗口使用与 Mail.app 相同的“导航—列表—详情”层级，Notch 用于快速查看当前活动。

## 模块概览

- **入口**：启动 Agent Status；侧边栏包含“Sessions”“iPhone”“Settings”。
- **前置条件**：macOS 26 或更高版本；daemon 已安装并运行。
- **主要结果**：用户可从列表查看 Session 标题、Agent 类型和状态，在 Activity 中查看完整活动历史，在右侧 Inspector 中查看 Token / Context / Elapsed 指标、Session 信息、模型配置和消耗；也可按标题过滤列表、手动刷新、删除单个 Session，或清空全部 Agent Status 历史。
- **只读边界**：查看和删除 Agent Status 中的记录不会审批、终止或修改 Codex Session。
- **相关旅程**：[在 Mac 上跟进一次 Codex Session](../journeys/observe-session-locally.md)。

## 主窗口布局

### Sessions：标准三栏

1. 左栏是固定 224 pt 的全高侧边栏，分为 Monitor / Connections / Application 三组：Sessions 行右侧显示会话数量，iPhone 行右侧在 Relay 连接时显示绿点。工具栏侧边栏段右侧的折叠按钮可隐藏或显示整栏；折叠状态在重启后保留。
2. 中栏是 Session 列表，按最后更新时间倒序，不分组；工具栏中栏段是“Filter sessions”搜索框，按标题、Agent 名或工作目录过滤，命中 Subagent 时保留其父级。每行是固定网格：`[Agent 图标][标题][相对时间]` 加第二行 `[状态色点 + 生命周期 · Turn 阶段][折叠数量]`，状态色点与标题左对齐。Codex 使用 OpenAI 标记的圆角图标；Subagent 不缩进、不显示图标，标题与父级共用同一左边线，层级只画成沿图标轴的引导线（折角 + 竖线）。点击有 Subagent 的 Main Session 行任意位置即可折叠/展开；折叠后第二行右侧显示子项数量胶囊，点击也可展开。右侧相对时间（now / 12s / 4m / 1h / yesterday / 3d）每 30 秒刷新。选中行使用中性灰底、文字颜色不变。标题固定一行，原始换行和连续空白会归一为空格，超出可用宽度时尾部省略；工具栏标题遵循相同规则。Main Session 使用 Codex 标题；Subagent 使用自己的名称，未单独命名时显示昵称与任务路径摘要，不复用父 Session 的请求作为标题。首次还没有标题时使用“Codex Session”；已同步过的 Subagent 在标题暂时不可用时继续保留原类型和关系。没有可用 parent 的旧格式或孤立 Subagent 保留在顶层，避免无法访问。中栏宽度只在用户拖动分隔线时改变，窗口缩放和数据刷新都不会改变它；Sessions 与 Settings 各自记住上次宽度。
3. 右栏顶部是工具栏中的 Session 标题和三个动作按钮（Refresh Sessions、Delete Session、Toggle Inspector），标题下方一条 subheader 显示 Agent 胶囊、状态药丸和工作目录。其下 Activity 独占主区，右侧是 288 pt 的 Inspector：顶部三张指标卡（TOKENS、CONTEXT、ELAPSED，运行中的 Session 每秒更新 Elapsed），下方 Overview、可选的 Lineage、Model、Usage 四组字段。Inspector 由 Toggle Inspector 显隐，状态在重启后保留。Activity 按时间显示当前 Session 自己的全部消息、系统与上下文、模型回复与 reasoning、工具、计划、子 Agent、错误和可识别的未知记录；Subagent 为执行任务获得的父 Session 历史不会重复显示为该 Subagent 的活动。Activity 粘顶 header 包含标题、数量和一个密度切换按钮：默认 Input、Tools、Model 三行横向时间轴，切换后压成一行“Timeline”，每条记录一个按类别着色的方格；点击任一方格会跳到对应记录并短暂高亮；点击记录行查看原始 JSON。密度偏好在重启后保留。
4. 窗口缩放只改变右栏宽度；侧栏、中栏和 Inspector 保持各自宽度。

“iPhone”页面收起中栏：工具栏显示“Pair iPhone”和 Generate new code 按钮，subheader 显示 Relay 状态药丸，内容区左侧是二维码卡片、右侧是 Paired devices 列表。“Settings”继续保持三栏：中栏列出 General、Notch、Daemon、Agents 和 About（44 pt 两行行、灰底选中），右栏是工具栏标题 + 副标题 subheader + 卡片式内容；Daemon 面板的 subheader 额外显示 Running / Not connected 药丸。

### Notch：活动摘要

Notch 紧凑时显示全部符合展示条件的 Session 数量和最近一个 Session 的状态色；展开后列出其中最近更新的最多四个，帮助用户快速判断各 Session 正在做什么。Notch 顶部的设置按钮打开主 App 的 Notch 设置，不在 Notch 内维护第二套设置页。完整展示规则和可用选项见 [MAC-R-014](#mac-r-014-notch-显示-session-当前状态) 和 [MAC-R-015](#mac-r-015-notch-设置集中在主-app)。

### Session 状态颜色

Mac Session 列表、详情、Notch 和 iPhone 使用相同颜色语义区分进行中、等待下一轮、等待用户处理、完成和异常状态。Mac 主窗口在列表中用 7 pt 状态色点 + 同色状态文字，在 subheader 中用带描边的状态药丸（Running 蓝、Waiting 橙、Completed 灰、Connected 绿）；状态变化时颜色 0.2 秒过渡，不闪烁。选中行使用中性灰底，文字颜色不变。完整映射见 [MAC-R-013](#mac-r-013-session-状态颜色跨端一致)。

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

完成信号：daemon 显示已连接；新 Session 以“标题、Agent、状态”出现在列表中，Summary 与 Activity 随 Agent 事件更新。

## 日常操作

### 刷新 Session

点击工具栏右侧的刷新图标（Refresh Sessions），从 daemon 取得完整当前数据。列表、数量或详情变化代表同步结果已显示；数据没有变化时，当前版本没有单独的完成提示。外部产生的 Session 内容除此之外只会在 App 启动和收到 Agent 事件时更新，不进行定时轮询。

### 删除单个 Session

选择 Session，点击工具栏右侧的删除图标（Delete Session），再在确认框点击“Delete”。该 Session 会从 daemon、Mac 和已连接 iPhone 中删除。删除不影响 Codex 自身 Session；之后到达的同一 Session 活动也不会让它重新出现在 Agent Status 中。

### 清空全部历史

在“Settings > Daemon”的 Session history 卡片点击“Clear history…”，确认后清空 Agent Status 保存的全部 Session 与时间线。Codex 自身历史不受影响。同一面板的 Local service 卡片显示状态、运行时长、活跃/已存 Session 数和 socket 路径；已安装时提供“Reinstall daemon”和“Stop & uninstall”（需确认），未安装时提供“Install & Start daemon”。

### 过滤 Session 列表

在工具栏中栏段的“Filter sessions”输入文字，列表只保留标题、Agent 名或工作目录包含该文字的 Session；命中的 Subagent 会连同父级一起保留。清空文字恢复完整列表。

### 撤销 iPhone 配对

在“iPhone”页面的 Paired devices 卡片点击某台设备的“Revoke”，确认后只关闭该设备的通道，其他 iPhone 不受影响。

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

### MAC-R-003 展示活动并保留 Session 诊断数据

- 条件：新 Session 产生受支持的 Agent 事件。
- 行为：Activity 整理消息、系统与上下文、reasoning、工具、计划、子 Agent、错误和可识别的未知记录；Summary 展示 Session 元数据、模型配置和消耗指标。
- 结果：用户能在 Activity 中按发生顺序查看对话与执行上下文，并在 Summary 中查看当前配置和 Token 使用。重复事件不产生重复记录，乱序事件不回退可见状态。
- 限制或例外：每类最新诊断记录会完整保存来源提供的嵌套内容，其中可能出现路径、凭据、环境信息或工具内容；当前没有内容级脱敏保证。只有 Agent Status 能识别为活动的记录会显示，其他来源事件不会另行保留。

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
- 限制或例外：Mac 主窗口的状态色和类别色取自设计稿的浅色值（Session 详情列固定浅色外观），其余界面使用系统动态色；Mac 列表选中行使用中性灰底、文字颜色不变。Notch 仍只展示当前纳入活动摘要的 Session，不因颜色规则扩大显示范围。

### MAC-R-014 Notch 显示 Session 当前状态

- 条件：Mac 本地同步数据中存在 Starting、Running、Waiting For Input、Failed 或 Interrupted 的 Session。
- 行为：紧凑状态统计全部符合条件的 Session；展开后按最近更新时间列出最多四个，每行显示标题、状态和当前 Turn 最近一条用户消息。新 Session、生命周期变化、当前用户消息变化，以及进入或离开等待审批时会短暂显示活动卡片。
- 结果：用户不打开主窗口也能判断 Session 正在做什么以及当前请求是什么。
- 限制或例外：Completed 和未知状态不持续留在展开列表；Session 刚进入 Completed 时仍可短暂显示完成卡片。没有可显示的用户消息时显示等待首条用户消息。Notch 只读取 Mac 已同步内容，不额外刷新 daemon。

### MAC-R-015 Notch 设置集中在主 App

- 条件：用户点击 Notch 顶部设置按钮，或在主 App 选择“Settings > Notch”。
- 行为：第三栏的 Appearance section 不显示 Theme 和 Layout 控件；Notch 始终使用 Dark Theme 与 Notch Layout。用户可以选择 Solid、Translucent 或 Liquid Glass 表面，选择内建屏幕、主屏幕或一台已连接的指定屏幕，并调整紧凑宽度、展开宽度和展开动画时长。紧凑宽度默认 64 pt，可在 32–240 pt 间按 1 pt 调整；展开宽度默认 520 pt，可在 360–720 pt 间按 4 pt 调整；展开动画默认 0.54 秒，可在 0.15–1.20 秒间按 0.01 秒调整。三项调节都能通过数值左侧的恢复按钮回到默认值，滑块不显示步进刻度点。保持展开、触觉反馈和 Show Notch 继续保留；启用触觉反馈时会给出一次确认，并在有意义的活动提示出现时反馈。
- 结果：屏幕、尺寸、动画、表面和行为设置保存在主 App 中并立即应用；Notch 设置按钮打开同一个 Notch 设置页面。
- 限制或例外：物理刘海宽度是紧凑状态的安全下限；指定屏幕断开时，Notch 暂时回到可用的内建屏幕或主屏幕，并在该屏幕重新连接后恢复。触觉反馈仍受 Mac 硬件和系统设置限制。

### MAC-R-016 Session 列表与详情按信息层级展示

- 条件：Sessions 页面存在一个或多个 Session，用户选择其中一条。
- 行为：列表行显示 Agent 图标、Session 标题、相对时间和“状态色点 + 生命周期 · Turn 阶段”；Subagent 不缩进，用左侧引导线挂在父级下。点击父级行任意位置或折叠数量胶囊切换展开/收起（也支持键盘左右方向键），折叠状态在本次 App 运行期间保留。详情固定为 Activity 主区 + Inspector：Inspector 顶部显示 Token 总量、Context 使用比例（最近一次用量 / 上下文窗口）和 Elapsed（运行中的 Session 持续计时，结束的 Session 停在最后活动时间），其下 Overview（Session ID、Agent、Lifecycle、Turn Phase、Needs Attention、Started）、有 lineage 时的 Lineage（Thread Source、Subagent Depth、Agent Nickname、Agent Role）、Model（Model、Provider、Context Window、Reasoning Effort、Client Version）和 Usage。Activity 行可打开对应记录的完整原始内容。Subagent 的标题与活动归属见 [MAC-R-018](#mac-r-018-subagent-使用自己的标题与活动)。
- 结果：用户可以按 Main Session 浏览或收起整组 Subagent，再在右栏查看当前副本保存的活动记录与指标。
- 限制或例外：没有 Activity 时显示明确空状态。父 Session 不在当前列表、父子关系成环，或旧格式 Subagent 没有 parent 时，该 Subagent 作为顶层项显示。Activity 的系统与上下文记录可能包含凭据、环境信息或工具内容；App 不做内容级脱敏，只应在受信任的 Mac 上查看。

### MAC-R-017 Activity 全量显示并支持时间轴定位

- 条件：用户选择的 Session 包含一条或多条 Activity。
- 行为：Activity 按发生顺序显示属于当前 Session 的全部记录，不要求分批加载。粘顶 header 包含标题、记录数量、密度切换按钮和横向时间轴：三泳道模式下每条记录占一个 13 pt 方格，只填在自己所属的泳道（Input：System、Context、User；Tools：Tool、Subagent、其他；Model：Assistant、Reasoning），其余泳道留空；单行模式下所有记录排成一行，方格填类别色。用户点击方格后，列表滚动到对应记录并短暂高亮。新记录到达时若用户停在列表底部则跟随到底，否则保持当前位置。
- 结果：用户浏览长 Session 时仍能看到时间轴和当前位置入口，可以先识别会话结构，再直接定位任意一条活动记录。
- 限制或例外：时间轴与密度切换只改变当前详情的查看方式和位置，不修改或控制 Codex Session。

### MAC-R-018 Subagent 使用自己的标题与活动

- 条件：Codex 为 Main Session 启动一个 Subagent，Agent Status 收到该 Subagent 的身份和任务活动。
- 行为：Subagent 有独立名称时显示该名称；未单独命名时显示昵称与任务路径摘要。为执行任务提供给 Subagent 的父 Session 历史只作为其工作背景，不作为 Subagent 标题，也不重复进入其 Activity。
- 结果：用户在父子层级中能按任务辨认 Subagent，打开详情时只看到该 Subagent 实际开始工作后的活动。
- 限制或例外：缺少父子关系的旧格式或孤立 Subagent 仍保留在顶层；其可用身份信息不足时显示通用 Subagent 名称。

## 空状态与故障

- **No Sessions**：daemon 在线，但启用后尚无新 Session，或用户已删除全部记录。
- **No active Sessions**：Notch 没有 Starting、Running、Waiting For Input、Failed 或 Interrupted 的 Session；历史仍可在主窗口查看。
- **Daemon unavailable**：保留本地已同步内容供查看；恢复 daemon 后点击刷新图标（Refresh Sessions）。
- **Hook 未信任**：新活动可能不能即时到达；在 Codex /hooks 完成审核。

更多恢复步骤见[用户摩擦点](../friction-points.md)。

## 业务数据

Session 状态、活动时间线、模型配置、内部上下文和消耗指标在 daemon 和 Mac 上分别保存同步副本，不自动过期。Mac 的副本支持快速启动、列表浏览、分模块详情和离线查看；daemon 恢复后，以 daemon 当前数据为准重新同步。

Notch 消费 Mac 已同步的 Session 与时间线，不创建额外 Session 副本，也不增加新的刷新入口；详细筛选与展示规则见 [MAC-R-014](#mac-r-014-notch-显示-session-当前状态)。

删除单个 Session 或清空历史只影响 Agent Status。完整生命周期见[数据流](../data-flows.md#session-状态与时间线)。

## 相关文档

- [功能全景](../index.md)
- [本地查看旅程](../journeys/observe-session-locally.md)
- [数据流](../data-flows.md)
- [摩擦点](../friction-points.md)
