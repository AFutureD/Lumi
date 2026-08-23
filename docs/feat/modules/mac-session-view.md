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
2. 中栏是 Session 列表，按最后更新时间倒序，不分组、不按状态分档；工具栏中栏段是“Filter sessions”搜索框，按标题、Agent 名或工作目录过滤，命中 Subagent 时保留其父级。每行是固定网格：`[Agent 图标][标题][相对时间]` 加第二行 `[状态色点 + 生命周期 · Turn 阶段][折叠数量]`，状态色点与标题左对齐。Codex 使用 OpenAI 标记的圆角图标；Subagent 不缩进、不显示图标，标题与父级共用同一左边线，层级只画成沿图标轴的引导线（折角 + 竖线）。Subagent 默认收起；点击有 Subagent 的 Main Session 行任意位置即可展开/收起，收起时第二行右侧显示子项数量的圆角标记，点击它也可展开。展开后的 Subagent 按 running → waiting → failed → done、同档内最新活动在前排列，与 Notch 和 iPhone 的顺序一致。右侧相对时间只用单一单位（now / 12s / 4m / 1h / 3d，不出现 yesterday 之类文字）每 30 秒刷新。选中行使用中性灰底、文字颜色不变。标题固定一行，原始换行和连续空白会归一为空格，超出可用宽度时尾部省略；工具栏标题遵循相同规则。Main Session 使用 Codex 标题；Subagent 使用自己的名称，未单独命名时显示昵称与任务路径摘要，不复用父 Session 的请求作为标题。首次还没有标题时使用“Codex Session”；已同步过的 Subagent 在标题暂时不可用时继续保留原类型和关系。没有可用 parent 的旧格式或孤立 Subagent 保留在顶层，避免无法访问。中栏宽度只在用户拖动分隔线时改变，窗口缩放和数据刷新都不会改变它；Sessions 与 Settings 各自记住上次宽度。
3. 右栏顶部是工具栏中的 Session 标题和三个动作按钮（Refresh Sessions、Delete Session、Toggle Inspector），标题下方一条 subheader 显示 Agent 胶囊、状态药丸和工作目录。其下 Activity 独占主区，右侧是 288 pt 的 Inspector：顶部三张指标卡（TOKENS、CONTEXT、ELAPSED，运行中的 Session 每秒更新 Elapsed），下方 Overview、可选的 Lineage、Model、Usage 四组字段。Inspector 由 Toggle Inspector 显隐，状态在重启后保留。Activity 按时间显示当前 Session 自己的全部消息、系统与上下文、模型回复与 reasoning、工具、计划、子 Agent、错误和可识别的未知记录；Subagent 为执行任务获得的父 Session 历史不会重复显示为该 Subagent 的活动。Activity 粘顶 header 包含标题、数量、两枚过滤按钮（Category / Importance）和一个密度切换按钮：默认 User、Model、Exec 三行横向时间轴（Session 开始/结束与压缩横跨三行），切换后压成一行“Timeline”，每条记录一个按类别着色的方格；点击任一方格会跳到对应记录并短暂高亮；点击记录行查看原始 JSON。密度偏好在重启后保留；过滤只对当前 Session 有效，见[过滤 Activity](#过滤-activity)。
4. 窗口缩放只改变右栏宽度；侧栏、中栏和 Inspector 保持各自宽度。

“iPhone”页面收起中栏：页头是标题“Pair an iPhone”、右侧的 Relay 状态药丸和一行提示。内容区左列是配对码卡片（二维码、6 位配对码、Relay 地址、5 分钟倒计时、New code），iPhone 提交后它下方出现待确认卡片（“<iPhone 名> wants to pair”、6 位数字、Don't match / Match）；右列是 Paired iPhones 列表。Relay 连接、配对过程和配对记录都由 daemon 持有，这一页只是它的控制台：退出 Mac App 后已配对 iPhone 照常同步，只有配对时需要打开 App；离开这一页，配对码即作废。“Settings”继续保持三栏：中栏列出 General、Notch、Daemon、Agents 和 About（44 pt 两行行、灰底选中），右栏是工具栏标题 + 副标题 subheader + 卡片式内容；Daemon 面板的 subheader 额外显示 Running / Not connected 药丸。

### Notch：活动摘要

Notch 紧凑时显示列表中的 Session 数量和最近一个 Session 的状态色；展开后按最近更新时间列出最近七天内活动过的全部主 Session（包括已关闭的会话），视口一次最多显示六条，更多内容向下滚动，底部一行显示列表中的 Session 总数。正在工作的 Session 在标题下多一行最近活动（类别标签 + 摘要）。带 Subagent 的 Session 在标题下多一条计数条（子 Agent 的子 Agent 也算在同一条里）：叠在一起的状态点（running → waiting → failed → done）+ `3 subagents · 2 running · 1 done`（只写非零档）+ 箭头；Session 运行中时默认展开成“状态点 + 名称 + 已运行时长”的胶囊，等待输入 / 已完成 / 失败时默认折叠只留计数条；点整条展开或收起，该行记住你的选择直到它的状态档变化；点击胶囊直接打开该 Subagent。鼠标悬停在带 Subagent 的行上时，这一行显示为一张卡片。Notch 顶部的设置按钮打开主 App 的 Notch 设置，不在 Notch 内维护第二套设置页。完整展示规则和可用选项见 [MAC-R-014](#mac-r-014-notch-显示-session-当前状态) 和 [MAC-R-015](#mac-r-015-notch-设置集中在主-app)。

### Session 状态颜色

Mac Session 列表、详情、Notch 和 iPhone 用同一套五档状态颜色回答“该先看哪条”：

- **蓝 · Running**：Agent 正在工作（含启动和上下文压缩）。
- **橙 · Waiting for input**：Turn 停在等待你审批或回答，人不处理就不会继续。
- **绿 · 待查看**：Turn 已结束，但你还没打开过这条 Session——它就是下一条该看的。
- **灰 · Completed**：Turn 已结束且你看过了，或 Session 处于空闲。
- **红 · Failed / Interrupted**：失败或被中断。

在 Mac 列表点击某行，或从 Notch 打开详情，都算“看过”，绿色随即降为灰色并同步到所有端；见 [MAC-R-019](#mac-r-019-打开-session-即视为已查看)。

Mac 主窗口在列表中用 7 pt 状态色点 + 同色状态文字（Completed 档的文字转为三级灰），在 subheader 中用同档色系、带描边的状态药丸；状态变化时颜色 0.2 秒过渡。蓝、橙、绿三档的色点带光晕并缓慢呼吸（约 1.6 秒一次）；灰与红的点为实心静止。选中行使用中性灰底，文字颜色不变。完整映射见 [MAC-R-013](#mac-r-013-session-状态颜色跨端一致)。

## 首次配置

1. 在侧边栏选择“Settings”，再在中栏选择“Daemon”。
2. 点击“Install & Start daemon”。
   - 系统反馈：daemon 区域显示连接和运行状态。
   - 规则引用：[MAC-R-001](#mac-r-001-daemon-决定实时可用性)。
3. 在中栏选择“Agents”，点击“Install Hook”。
   - 系统反馈：成功或显示安装错误；随后 Codex 卡片显示“Trusted by Codex”和处理项数量。
   - 数据结果：只追加 Agent Status Hook，不覆盖其他集成；Codex 的信任记录只针对 Agent Status 自己的处理项写入。
   - 规则引用：[MAC-R-002](#mac-r-002-安装不替换现有-hooks)、[MAC-R-021](#mac-r-021-自动向-codex-申请-hook-信任)。
4. 新建一个 Codex Session。
   - 系统反馈：首个受支持 Agent 事件到达后，Session 出现在中栏。
   - 规则引用：[MAC-R-011](#mac-r-011-只记录启用后的新-session)。

完成信号：daemon 显示已连接；新 Session 以“标题、Agent、状态”出现在列表中，Summary 与 Activity 随 Agent 事件更新。

## 日常操作

### 刷新 Session

点击工具栏右侧的刷新图标（Refresh Sessions）：当前选中的 Session 会先由 daemon 从它的 transcript / rollout 整个重建（Claude 父 Session 连同子 Agent 一起；你已删除的子 Agent 不会被重建回来），已同步的 iPhone 同时拿到重建结果，然后再从 daemon 取得全部 Session 的完整当前数据；没有选中时只做后一步。解析规则更新后，用它回填旧 Session 新增的记录（例如 `Empty` 的 REASONING 行）。列表、数量或详情变化代表同步结果已显示；数据没有变化时，当前版本没有单独的完成提示。外部产生的 Session 内容除此之外只会在 App 启动和收到 Agent 事件时更新，不进行定时轮询。

### 删除单个 Session

选择 Session，点击工具栏右侧的删除图标（Delete Session），再在确认框点击“Delete”。该 Session 立即从列表消失，并从 daemon、Mac 和已连接 iPhone 中删除。删除不影响 Codex 自身 Session；之后被动到达的旧活动不会让它重新出现，只有你在同一会话里再次发出请求（或会话重启）它才会回来。

### 从 Notch 归档 Session

在 Notch 展开列表中，把鼠标悬停到一条 Turn 已结束的 Session 行上（等待输入或已关闭都算），行尾的相对时间会原地换成归档按钮，点击后该 Session 立即从 Notch 的列表和计数里消失。归档只影响 Notch：主窗口和已连接 iPhone 照常显示这个 Session，历史也不删除。你在该 Session 里发出新请求（或它重新启动）时，它会自动回到 Notch。不手动归档的话，超过七天没有活动的 Session 也会自动离开 Notch 列表。

- 规则引用：[MAC-R-014](#mac-r-014-notch-显示-session-当前状态)。

### 清空全部历史

在“Settings > Daemon”的 Session history 卡片点击“Clear history…”，确认后清空 Agent Status 保存的全部 Session 与时间线。Codex 自身历史不受影响。同一面板的 Local service 卡片显示状态、运行时长、活跃/已存 Session 数和 socket 路径；已安装时提供“Reinstall daemon”和“Stop & uninstall”（需确认），未安装时提供“Install & Start daemon”。最下方的 Logs 卡片显示日志目录（`~/Library/Logs/Agent Status`，含 daemon.log / helper.log / app.log 和只收错误的 errors.log），“Show in Finder”直接打开；哪些内容会进日志见[恢复路径](../friction-points.md#仍无法恢复先看日志)。升级 App 后不需要手动 Reinstall：启动时发现运行中的 daemon 版本过期会自动重启它（[MAC-R-022](#mac-r-022-启动时自动更新已安装的-daemon)）。

### 过滤 Session 列表

在工具栏中栏段的“Filter sessions”输入文字，列表只保留标题、Agent 名或工作目录包含该文字的 Session；命中的 Subagent 会连同父级一起保留。清空文字恢复完整列表。

### 过滤 Activity

Activity 标题右侧有两枚下拉按钮：**Category**（按消息类别，面板按 Session / User / Model / Exec 四个泳道分组；失败分两项——Model 组的 Turn failure 和 Exec 组的 Tool failure，标签都是 FAILED）和 **Importance**（按 L3 / L2 / L1 三档）。点开面板后点任意一行勾选或取消，列表立即只显示“类别被选中 且 重要性被选中”的记录；分组头可以一键全选 / 全不选整组。过滤中的按钮变蓝并显示仍选中的项数，标题旁的计数变成“命中 / 总数”（如 `11 / 27`）。

- 面板里的计数永远是这个 Session 的全量条数，不随另一枚按钮变化；为 0 的项保留但压灰。
- 一个维度不能全部取消：取消掉最后一项会自动回到全选。
- 两个维度交集为空时列表显示空态和 Reset 按钮，点 Reset 两个维度都回到全选。
- 横向时间轴不受过滤影响，始终画全量；点击被过滤掉的方格会滚到它附近最近的可见记录，不高亮。
- 过滤只在当前 Session 内有效，切到别的 Session 或重新打开就回到全选；新记录到达时保持当前过滤条件。
- 规则引用：[MAC-R-023](#mac-r-023-activity-过滤只收窄列表)。

### 配对一台 iPhone

“iPhone”页面常驻一张配对码卡片：二维码、6 位配对码（如 `7KF 3QP`）、Relay 地址、`Expires in m:ss` 倒计时。码 5 分钟到点自动换新，旧码立刻作废；卡片上的 New code 随时手动换；离开页面码也作废。iPhone 输码或扫码提交后，卡片下方出现 “<iPhone 名> wants to pair”、Relay 地址和时间、一组 6 位数字（如 `482 913`）以及 Don't match / Match 两个按钮：和 iPhone 屏幕上的数字一样才点 Match（默认键盘焦点在 Don't match，Return 不触发任何一个）；60 秒没点自动拒绝。结果（Paired ✓ / Pairing declined ✕）停 2 秒后卡片收起、新码开始；iPhone 那边中途取消则不显示结果，直接换新码。Mac App 退出不影响进行中的配对（过程在 daemon 里）；daemon 重启则重开这一页。规则见 [IOS-R-002](./iphone-live-view.md#ios-r-002-配对码短时且一次性)、[IOS-R-014](./iphone-live-view.md#ios-r-014-配对时两端比对数字mac-点-match-才生效)。

### 管理已配对 iPhone

“iPhone”页面右列的 Paired iPhones 列表每行是一台 iPhone：名称旁一枚状态 tag，下面一行是它所在的 Relay 地址，行尾一个文字动作；标题旁的数量只统计 Active 的设备。

- **Active**：这台 Mac 在 Match 时记住了这台 iPhone 的身份，正在向它同步（[IOS-R-014](./iphone-live-view.md#ios-r-014-配对时两端比对数字mac-点-match-才生效)）。行尾是 “Revoke”：确认后只关闭该设备的通道，其他 iPhone 不受影响，记录保留为 Revoked。
- **Unverified**：这台 iPhone 的身份不是这台 Mac 点 Match 批准过的（此版本之前配对的，或中转服务换过钥匙），不向它发送任何内容，下方提示 `Key not verified · pair this iPhone again`；行尾同样是 “Revoke”。恢复方式见[用户摩擦点](../friction-points.md#iphone-在-mac-上显示-unverified)。
- **Revoked**：已被撤销。行尾是 “Remove”：确认后删掉这条配对记录（这台 iPhone 之后用新码可以重新配对）。

刚配对成功的那一行会短暂高亮一次。

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
- 限制或例外：写入 hooks.json 会让 Codex 已有的信任记录失效，因此安装后立即执行 [MAC-R-021](#mac-r-021-自动向-codex-申请-hook-信任)。

### MAC-R-003 展示活动并保留 Session 诊断数据

- 条件：新 Session 产生受支持的 Agent 事件。
- 行为：Activity 整理消息、系统与上下文、reasoning、工具、计划、子 Agent、错误和可识别的未知记录；Summary 展示 Session 元数据、模型配置和消耗指标。模型每开始一次思考就出现一行 REASONING（思考结束不另起一行）；Claude 只落盘签名、没有正文的思考也占一行，内容显示为 `Empty`。
- 结果：用户能在 Activity 中按发生顺序查看对话与执行上下文，并在 Summary 中查看当前配置和 Token 使用。重复事件不产生重复记录，乱序事件不回退可见状态。
- 限制或例外：每类最新诊断记录会完整保存来源提供的嵌套内容，其中可能出现路径、凭据、环境信息或工具内容；当前没有内容级脱敏保证。只有 Agent Status 能识别为活动的记录会显示，其他来源事件不会另行保留。

### MAC-R-004 查看不控制 Agent

- 条件：用户选择 Session 或时间线项目。
- 行为：改变当前查看对象；选中一条绿色待查看的 Session 会同时把它标记为已查看（[MAC-R-019](#mac-r-019-打开-session-即视为已查看)）。
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

- 条件：App 启动、用户点击刷新图标（Refresh）或收到 Agent 事件。
- 行为：分别执行首次同步、完整手动同步或增量更新。手动刷新时若有选中的 Session，daemon 先用该 Session 的本机对话记录从头重算它（修正卡住的状态、补齐漏掉的内容），再做完整同步。重算保留人为标记：已查看状态（[MAC-R-019](#mac-r-019-打开-session-即视为已查看)）和 Notch 归档（[MAC-R-014](#mac-r-014-notch-显示-session-当前状态)）不因刷新重置。
- 结果：界面不依赖周期轮询；刷新不会让看过的 Session 重新变绿，也不会让归档的 Session 回到 Notch。
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
- 行为：五档映射——Starting、Running、Compacting 使用蓝色（Agent 在工作）；Turn 停在等待审批或回答时使用橙色（人不处理就不会继续）；Turn 已结束但还没被打开过时使用绿色（待查看）；Turn 已结束且已查看，或 Session 空闲时使用灰色；Failed 和 Interrupted 使用红色。命令行回到提示符等待下一条指令的 Session 按“已结束”档显示（绿或灰，状态文字为 Completed），不算等待审批。颜色不影响列表排序。
- 结果：用户在三个界面看到相同的状态颜色语义；绿色专指“已结束但还没看过”，看过即降灰（[MAC-R-019](#mac-r-019-打开-session-即视为已查看)）。
- 限制或例外：三个界面共用同一套设计系统取值：Mac 主窗口使用浅色值（Session 详情列固定浅色外观），Notch 使用独立的深色取值并以纯黑实色面板承载（无材质、描边与投影，便于与刘海无缝衔接），iPhone 随系统外观在浅色 / 深色两组值之间切换。蓝、橙、绿三档的状态点在 Mac 主窗口和 Notch 带光晕呼吸，灰与红为实心；iPhone 的状态标记是实心图标（Failed / Interrupted 显示为感叹号标记），不带呼吸光晕。Mac Inspector Overview 的 Lifecycle 字段显示原始生命周期，停在提示符的 Session 在该字段显示 Waiting For Input 而非 Completed。Notch 列表里 Turn 已结束的行标题降为次级亮度，状态点仍按本档显示（未查看为绿色呼吸、已查看为灰色实心），Agent 标签不变。Activity 与 Notch 里的消息类别标签在三档注意力级别下都带 0.5 pt 描边（L1 灰描边、L2 同色淡描边、L3 同色深描边），只靠标签样式区分层级。Mac 列表选中行使用中性灰底、文字颜色不变。Notch 仍只展示当前纳入活动摘要的 Session，不因颜色规则扩大显示范围。

### MAC-R-014 Notch 显示 Session 当前状态

- 条件：Mac 本地同步数据中存在最近七天内活动过、未被 Notch 归档且状态已知的 Session——正在启动、工作、压缩上下文、等待审批、Turn 已结束停在提示符（待查看与已查看都算）、已关闭（Completed），或以失败 / 中断收尾。
- 行为：紧凑状态显示列表中的主 Session 数量；展开后按最近更新时间全量列出这些主 Session，视口一次最多显示六条（按各行实际高度截到第六条为止），更多内容向下滚动，底部一行显示列表中的 Session 总数。正在工作（蓝色档）的行在标题下显示最近一条活动（类别标签 + 摘要）。带 Subagent 的 Session 不论处于哪一档都在标题下保留一条 Subagent 计数条（叠放的状态点按 running → waiting → failed → done 排列，文案为 `N subagents` 加各非零档的数量，单数写 `1 subagent`）；蓝色档默认展开成胶囊（状态点 + 名称 + 已运行时长，按同样顺序自由换行），其他档默认折叠；点计数条切换展开 / 折叠，这一行的选择在它的状态档变化前一直保留，状态档变化后回到默认；点击胶囊打开该 Subagent 的详情。悬停在带 Subagent 的行上时该行以卡片底色高亮，位置与尺寸不变。Turn 结束时 Notch 自动展开、短暂显示回合完成卡片后自动收回；回合级失败 / 中断时自动展开并短暂显示错误提示后收回。用户正在悬停或自己打开着 Notch 时不会被这些提示抢占或收回。新用户消息（回合开始）不改变 Notch 显示，列表行自然反映新状态；子代理的回合边界属于父级的内部进度，单个工具调用的失败属于常规噪音，都不触发提示。正在查看某条详情时，卡片不会打断当前页面。
- 结果：用户不打开主窗口也能判断 Session 正在做什么以及当前请求是什么；已结束的 Turn 和已关闭的会话留在列表里，直到被归档或超过七天没有新活动。
- 限制或例外：超过七天没有活动的 Session 自动移出列表和计数，没有单独入口找回（主窗口照常显示）；跨过七天边界的移出要等下一次数据变化才生效，不是即时的。用户在 Notch 归档的 Session 不进入列表和计数，直到该 Session 收到新请求或重新启动；归档不影响主窗口和 iPhone 的显示。没有可显示的用户消息时显示等待首条用户消息。Notch 只读取 Mac 已同步内容，不额外刷新 daemon。

### MAC-R-015 Notch 设置集中在主 App

- 条件：用户点击 Notch 顶部设置按钮，或在主 App 选择“Settings > Notch”。
- 行为：第三栏的 Appearance section 不显示 Theme 和 Layout 控件；Notch 始终使用 Dark Theme 与 Notch Layout。用户可以选择 Solid、Translucent 或 Liquid Glass 表面，选择内建屏幕、主屏幕或一台已连接的指定屏幕，并调整紧凑宽度、展开宽度和展开动画时长。紧凑宽度默认 64 pt，可在 32–240 pt 间按 1 pt 调整；展开宽度默认 520 pt，可在 360–720 pt 间按 4 pt 调整；展开动画默认 0.54 秒，可在 0.15–1.20 秒间按 0.01 秒调整。三项调节都能通过数值左侧的恢复按钮回到默认值，滑块不显示步进刻度点。保持展开、触觉反馈和 Show Notch 继续保留；启用触觉反馈时会给出一次确认，并在有意义的活动提示出现时反馈。
- 结果：屏幕、尺寸、动画、表面和行为设置保存在主 App 中并立即应用；Notch 设置按钮打开同一个 Notch 设置页面。
- 限制或例外：物理刘海宽度是紧凑状态的安全下限；指定屏幕断开时，Notch 暂时回到可用的内建屏幕或主屏幕，并在该屏幕重新连接后恢复。触觉反馈仍受 Mac 硬件和系统设置限制。

### MAC-R-016 Session 列表与详情按信息层级展示

- 条件：Sessions 页面存在一个或多个 Session，用户选择其中一条。
- 行为：列表行显示 Agent 图标、Session 标题、相对时间和“状态色点 + 生命周期 · Turn 阶段”；Subagent 不缩进，用左侧引导线挂在父级下。Subagent 默认收起；点击父级行任意位置或子项数量标记切换展开/收起（也支持键盘左右方向键），展开状态在本次 App 运行期间保留。详情固定为 Activity 主区 + Inspector：Inspector 顶部显示 Token 总量、Context 使用比例（最近一次用量 / 上下文窗口）和 Elapsed（运行中的 Session 持续计时，结束的 Session 停在最后活动时间），其下 Overview（Session ID、Agent、Lifecycle、Turn Phase、Needs Attention、Started）、有 lineage 时的 Lineage（Thread Source、Subagent Depth、Agent Nickname、Agent Role）、Model（Model、Provider、Context Window、Reasoning Effort、Client Version）和 Usage。Activity 行可打开对应记录的完整原始内容。Subagent 的标题与活动归属见 [MAC-R-018](#mac-r-018-subagent-使用自己的标题与活动)。
- 结果：用户可以按 Main Session 浏览或收起整组 Subagent，再在右栏查看当前副本保存的活动记录与指标。
- 限制或例外：没有 Activity 时显示明确空状态。父 Session 不在当前列表、父子关系成环，或旧格式 Subagent 没有 parent 时，该 Subagent 作为顶层项显示；父 Session 还没有 Turn（通常不显示）但已有可见 Subagent 时，父级照常显示，选中它点 Refresh 即可从对话记录补全。Activity 的系统与上下文记录可能包含凭据、环境信息或工具内容；App 不做内容级脱敏，只应在受信任的 Mac 上查看。

### MAC-R-017 Activity 全量显示并支持时间轴定位

- 条件：用户选择的 Session 包含一条或多条 Activity。
- 行为：Activity 按发生顺序显示属于当前 Session 的全部记录，不要求分批加载。粘顶 header 包含标题、记录数量、密度切换按钮和横向时间轴：三泳道模式下每条记录占一个 13 pt 方格（列表一行对应时间轴一格，合并成 `CONTEXT ×N` 的记录也只占一格），只填在自己所属的泳道（User：用户输入和所有上下文；Model：Assistant、Reasoning、Plan、Subagent、Turn End、回合级失败与中断；Exec：Tool、Result、工具失败），其余泳道留空；Session 开始/结束与上下文压缩不占泳道，而是在三条泳道各画一条 4 pt 窄条，靠宽度与实格区分；单行模式下所有记录排成一行，方格填类别色。横向时间轴与下方列表同步滚动：滚动列表时时间轴跟着移动，在时间轴上横向滚动或按住鼠标左右拖动时列表也随之滚动，拖动松手后时间轴带惯性滑行一小段（列表继续跟随），再次拖动、滚动或点击即停；只有填了色的方格可以点击（悬停时指针变为手形、方格出现描边），点击后列表滚动到对应记录并短暂高亮，空白泳道格和方格间隙不响应点击。新记录到达时若用户停在列表底部则跟随到底，否则保持当前位置。
- 结果：用户浏览长 Session 时仍能看到时间轴和当前位置入口，可以先识别会话结构，再直接定位任意一条活动记录。
- 限制或例外：时间轴与密度切换只改变当前详情的查看方式和位置，不修改或控制 Codex Session。

### MAC-R-018 Subagent 使用自己的标题与活动

- 条件：Codex 或 Claude Code 为 Main Session 启动一个 Subagent，Agent Status 收到该 Subagent 的身份和任务活动。
- 行为：Subagent 有独立名称时显示该名称；未单独命名时显示昵称与任务路径摘要。Claude 的 Subagent 以启动时的任务描述为标题（没有描述时显示 agent 类型），其 Activity 来自子代理自己的对话记录，生命周期跟随子代理的启动与结束（结束后为 Completed，不会显示为等待输入）。为执行任务提供给 Subagent 的父 Session 历史只作为其工作背景，不作为 Subagent 标题，也不重复进入其 Activity。
- 补录：升级前记录的 Claude Session 没有子行；选中该 Session 点工具栏 Refresh 会从本机对话记录补出它的 Subagent。
- 结果：用户在父子层级中能按任务辨认 Subagent，打开详情时只看到该 Subagent 实际开始工作后的活动。
- 限制或例外：缺少父子关系的旧格式或孤立 Subagent 仍保留在顶层；其可用身份信息不足时显示通用 Subagent 名称。

### MAC-R-019 打开 Session 即视为已查看

- 条件：一条 Session 的 Turn 已结束且还没被打开过（状态为绿色待查看）。
- 行为：在 Mac 列表点击该行（重复点击已选中的行同样生效），或在 Notch 打开它的详情，都把它标记为已查看；Notch 详情开着期间新结束的 Turn 也立即视为已查看。标记写入 daemon 和 Mac 本地副本，并同步到已连接 iPhone。
- 结果：绿色降为灰色，三个界面一致；列表里剩下的绿色就是还没看过的 Session。
- 限制或例外：在 iPhone 上打开 Session 同样清除该标记——iPhone 把「已查看」发回 Mac，Mac 写入后同步到所有端（[IOS-R-013](./iphone-live-view.md#ios-r-013-iphone-打开即视为已查看)）。该 Session 下一个 Turn 结束时会重新变绿。刷新重算不重置此标记（[MAC-R-009](#mac-r-009-外部内容只有三种同步入口)）。

### MAC-R-020 启动时自动更新已安装的 Hook helper

- 条件：Hook 已安装（Codex 或 Claude Code），且 Mac App 启动时自带的 helper 与已安装副本不一致。
- 行为：启动时自动把 helper 更新为当前版本，并在支持的 Hook 事件有新增时补齐配置；两者都一致时不写任何文件。
- 结果：升级 App 后 Hook 立即获得新采集能力（如 Claude Subagent 实时子 Session），无需重新点击“Install Hook”。
- 限制或例外：从未安装过 Hook 时启动不做任何事；配置补齐仍只追加 Agent Status 自己的处理项（[MAC-R-002](#mac-r-002-安装不替换现有-hooks)）。

### MAC-R-021 自动向 Codex 申请 Hook 信任

- 条件：Codex Hook 已安装。发生在点击“Install Hook”之后，以及每次 App 启动时。
- 行为：向 Codex 询问它当前怎么看待各个处理项，为其中未被信任的 Agent Status 处理项写入信任，然后再问一次以确认结果。整个过程只涉及命令为 Agent Status helper 的处理项，其他工具的 Hook 一律不读取也不改写。
- 结果：用户不必手动审核就能继续收到 Session 事件；“Settings > Agents”的 Codex 卡片显示“Trusted by Codex”和处理项数量。
- 限制或例外：Codex 按处理项在 hooks.json 中的位置记录信任，任何工具改写这个文件都会让信任失效，因此每次启动都会重新申请。本机没有 Codex、或 Codex 版本还没有信任机制时不显示这一行。申请失败时卡片改为提示未信任并提供“Authorize”按钮，按钮仍失败则需要用户在 Codex `/hooks` 中手动信任。

### MAC-R-022 启动时自动更新已安装的 daemon

- 条件：daemon 已安装并在运行，且 Mac App 启动后发现它运行的不是当前 App 自带的版本（按可执行文件指纹比对，无需人工维护版本号）。
- 行为：自动重启 daemon 服务，让 launchd 换用 App 内的新版本，然后重新同步数据。
- 结果：升级 App 后 daemon 立即获得新采集能力（如 Codex 标题与 Subagent lineage 同步），无需去 Settings 手动 Reinstall。
- 限制或例外：从未安装过 daemon 时启动不做任何事（不会擅自注册服务）。每次 App 启动最多自动重启一次；重启后仍不一致（例如开发版 App 对着已注册的正式版 daemon）只记录日志，不再重试。手动“Reinstall daemon”仍可用作兜底。

### MAC-R-023 Activity 过滤只收窄列表

- 条件：用户在 Activity 头部的 Category 或 Importance 面板里改变勾选。
- 行为：列表只保留类别与重要性都被选中的记录；两枚按钮之间取交集，一枚按钮内取并集。面板里两级计数都是过滤前的全量条数；取消某维度的最后一项时该维度自动回到全选；交集为空时显示空态与 Reset。同一时间只开一枚面板，点面板外、按 Esc、调整窗口大小或切换 Session 都会关闭它。
- 结果：用户可以只看用户输入与回合结束这类“阶段”消息，或只看某一泳道的记录，而时间轴与计数仍然告诉他藏掉了什么。
- 限制或例外：横向时间轴、Inspector 指标与 Notch 都不受过滤影响；过滤不持久化，切走再回来即复位；过滤不修改或控制 Codex / Claude Session。

## 空状态与故障

- **No Sessions**：daemon 在线，但启用后尚无新 Session，或用户已删除全部记录。
- **No active Sessions**：Notch 没有符合展示条件的 Session（都已被归档，或都超过七天没有活动）；历史仍可在主窗口查看。
- **Daemon unavailable**：保留本地已同步内容供查看；恢复 daemon 后点击刷新图标（Refresh Sessions）。
- **Codex 未信任 Hook**：Codex 不运行未信任的 Hook，也不给提示，表现为 Session 停更；在“Settings > Agents”点击“Authorize”，仍失败则在 Codex `/hooks` 中手动信任。

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
