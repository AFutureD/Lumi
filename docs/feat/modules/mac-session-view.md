# Mac 会话查看

> 验证状态：开发预览。v0.1.0–v0.1.3 已正式发布，本文描述发布后继续演进的工作副本，界面行为已通过本机核对。真实 Codex Hook 长期运行与干净机器安装仍待验收。

Lumi 在一台 Mac 上聚合多个 Agent 的多个 Session。主窗口使用与 Mail.app 相同的“导航—列表—详情”层级，Notch 用于不打开主窗口的快速查看。

## 模块概览

- **入口**：启动 Lumi；侧边栏包含“Sessions”“iPhone”“Settings”。
- **前置条件**：Apple silicon Mac，macOS 26 或更高版本；daemon 已安装并运行。
- **主要结果**：用户可在列表查看 Session 标题、Agent 和状态，在 Activity 中查看完整活动历史，在 Inspector 中查看 Token / Context / Elapsed 指标与 Session 信息；也可按标题过滤列表、手动刷新、删除选中的一条或多条 Session，或清空全部 Lumi 历史。
- **只读边界**：查看和删除 Lumi 中的记录不会审批、终止或修改 Agent 的 Session。
- **相关旅程**：[在 Mac 上跟进一次 Codex Session](../journeys/observe-session-locally.md)。

## 主窗口布局

### Sessions：标准三栏

1. 左栏——固定 224 pt 的全高侧边栏。
   - 分 Monitor / Connections / Application 三组。
   - Sessions 行右侧显示 Lumi 当前保存的 Session 总数（Main Session 与 Subagent 都计入，因此通常大于中栏行数）；iPhone 行右侧在 Relay 连接时显示绿点。
   - 工具栏侧边栏段右侧的折叠按钮可隐藏或显示整栏；折叠状态在重启后保留。
2. 中栏——Session 列表。
   - 排序：按创建时间倒序（新建的排最上）；创建时间不会变，后续活动、改标题都不打乱顺序。不分组、不分档，一行一个 Main Session。
   - 行结构（两行）：第一行是状态色点 + 标题 + 行尾等宽相对时间（悬停提示 Last update）；第二行左端是 13 pt 的 Agent 原色图标（Agent 名进悬停提示），紧跟灰色的 `model · reasoning effort`——直接显示 CLI 上报的原值（如 `claude-sonnet-4-5 · high`）；只有 model 时省掉分隔点，只有 effort 时单独显示 effort，两者都没有则留空。
   - 标题来源（Agent 上报）：Main Session 使用 Agent 上报的标题；Subagent 使用自己的名称，未单独命名时显示昵称与任务路径摘要，不复用父 Session 的请求作为标题。首次还没有标题时显示“`<Agent 名>` Session”（如 Codex Session、Claude Session）。
   - 标题来源（AaaS）：每个 Session 归属一个承载它的 AaaS 应用（Agentic AI as a Service：ChatGPT、Codex、Claude Desktop、Claude Code、Paseo、Raft），标题由该应用决定——Paseo 显示你在 Paseo 里看到（或改过）的 agent 标题，Raft 显示 agent 名（如 Fable），其余应用沿用 Agent 上报的标题；改名后随下一次 Agent 活动更新，Session 结束后 Paseo/Raft 的标题也保持不变。
   - 标题排版：固定一行，原始换行和连续空白归一为空格，超出可用宽度时尾部省略（空间不够先截断 model，相对时间永不被挤压）；工具栏标题遵循相同规则。
   - Subagent 簇：带 Subagent 的行在第二行右端叠放各 Subagent 的状态色圆点（按 running → waiting → failed → done 排列，最多画五个，数量与分档进悬停提示，如 `3 subagents · 2 running · 1 done`）加一枚折叠箭头；点这一簇展开或收起，不改变选中。
   - 展开后：一个 Subagent 一行（子 Agent 的子 Agent 也平铺在同一组里），按启动先后从早到晚排列——读下来就是这次运行的执行顺序；每行是 6 pt 状态点 + 名称 + 行尾持续时间（悬停提示 Duration；运行中每秒走动，结束后停在最终用时）；全部逐行列出、不分页。
   - 展开默认档：Running / Waiting / Failed 默认展开，Completed 默认收起；手动切换后记住你的选择（本次运行期间），直到该行的默认档位变化为止。
   - 键盘：左右方向键展开或收起当前行，上下方向键在 Session 行与已展开的 Subagent 行之间移动选中；Shift + 上下把多选范围扩一行或收一行（只走 Session 行）；⌘⌫ 删除当前选中（见[删除 Session](#删除-session)）。
   - 选中：两级且互斥。点第一二行选中整个 Session——满宽中性灰底、贴到列两边；点 Subagent 行选中该 Subagent——圆角灰底，右栏切到它自己的详情，父级行不再高亮。悬停用更浅的同形灰底。
   - 多选：只在 Session 级。Shift 点选从上一次点的行连选到这次点的行，⌘ 点选逐条加入或移出，⌘⇧ 点选把范围并入已有多选，⌘A 全选；右栏继续显示最后点的那条，工具栏标题改显“N Sessions Selected”标明真实范围。Subagent 行不参与多选——带修饰键点它不改变任何选中。
   - 时间格式：相对时间只用单一单位（0s / 12s / 4m / 1h / 3d，不出现 now 或 yesterday 之类文字）；持续时间最多两段（12s / 3m 43s / 1h 02m / 2d 03h）；两者都每秒刷新。
   - 过滤：工具栏中栏段是“Filter sessions”搜索框，按标题、Agent 名或工作目录过滤，命中 Subagent 时保留其父级；没有命中时显示 No matching Sessions。
   - 孤立 Subagent：没有可用 parent 的旧格式或孤立 Subagent 保留在顶层，避免无法访问。
   - 宽度：只在用户拖动分隔线时改变（240–480 pt），窗口缩放和数据刷新都不会改变它；Sessions 与 Settings 各自记住上次宽度。
3. 右栏——详情。
   - 工具栏：Session 标题 + 三个动作按钮（Refresh、Delete Session、Toggle Inspector）；标题下方一条 subheader 显示 Agent 胶囊、状态药丸和工作目录。
   - Inspector：右侧 288 pt。顶部三张指标卡（TOKENS、CONTEXT、ELAPSED，运行中的 Session 每秒更新 Elapsed），下方 Overview、可选的 Lineage、Model、Usage 四组字段；由 Toggle Inspector 显隐，状态在重启后保留。
   - Activity：独占主区，按时间显示当前 Session 自己的全部消息、系统与上下文、模型回复与 reasoning、工具、计划、子 Agent、错误和可识别的未知记录；用户键入的斜杠命令显示为用户消息（内容为记录原文，含 `<command-name>` 等标签），而不是上下文；Subagent 为执行任务获得的父 Session 历史不会重复显示为该 Subagent 的活动。
   - Activity 粘顶 header：标题、数量、两枚过滤按钮（Category / Importance）和一个密度切换按钮。默认 User、Model、Exec 三行横向时间轴（Session 开始/结束、压缩与配置横跨三行），切换后压成一行“Timeline”，每条记录一个按类别着色的方格；密度偏好在重启后保留。
   - Activity 交互：点击任一时间轴方格跳到对应记录并短暂高亮；点击记录行查看原始 JSON；悬停工具调用或结果行时，同一次调用的两行一起以类别色浅底高亮；过滤只对当前 Session 有效，见[过滤 Activity](#过滤-activity)。
4. 窗口缩放只改变右栏中 Activity 主区的宽度；侧栏、中栏和 Inspector 保持各自宽度。

### iPhone 与 Settings 页面

- “iPhone”页面收起中栏：页头是标题“Pair an iPhone”、右侧的 Relay 状态药丸和一行提示。
- 内容区左列是配对码卡片（二维码、6 位配对码、Relay 地址、5 分钟倒计时与进度条、New code）；iPhone 提交后它下方出现待确认卡片（“<iPhone 名> wants to pair”、6 位数字、Don't match / Match）。右列是 Paired iPhones 列表；窗口较窄时两列改为上下排布。
- Relay 连接、配对过程和配对记录都由 daemon 持有，这一页只是它的控制台；离开这一页，配对码即作废，进行中的配对也随之取消——配对全程需要停在这一页完成。已配对 iPhone 的日常同步不需要打开 Mac App。
- “Settings”继续保持三栏：中栏列出 General、Notch、Daemon、Agents 和 About（44 pt 高的两行式行、灰底选中），右栏是工具栏标题 + 副标题 subheader + 卡片式内容；各面板内容见[设置面板](#设置面板)。

### Notch：活动摘要

- 紧凑时：显示列表中的 Session 数量和最近一个 Session 的状态色。
- 展开后：按最近活动时间列出最近七天内活动过的全部主 Session（包括已关闭的会话）；视口一次最多显示六条，更多内容向下滚动；底部一行显示列表中的 Session 总数。
- 顶栏：品牌图标、“Lumi”标题、一枚锁形“保持展开”开关（与 Notch 设置里的 Stay expanded 同一状态）和设置按钮；设置按钮打开主 App 的“Settings > Notch”，不在 Notch 内维护第二套设置页。
- 正在工作的 Session 在标题下多一行最近活动（类别标签 + 摘要）。
- 带 Subagent 的 Session 在标题下多一条可点开的 Subagent 计数条（子 Agent 的子 Agent 也算在同一条里）：运行中默认展开成胶囊，其他状态默认折叠；点击胶囊直接打开该 Subagent；悬停在带 Subagent 的行上时，这一行显示为一张卡片。
- Session 的 Turn 结束或失败时 Notch 自动展开并短暂提示；回合开始不自动展开。
- 完整展示规则见 [MAC-R-014](#mac-r-014-notch-显示-session-当前状态)，可用选项见 [MAC-R-015](#mac-r-015-notch-设置集中在主-app)。

在 Notch 列表点击一行进入该 Session 的 Notch 详情页：

- 结构：返回按钮、标题、状态药丸 + Agent 胶囊、TOKENS / CONTEXT / ELAPSED 三张指标卡（ELAPSED 每秒跳动）、最近活动列表（最多显示最近 8 条，头部计数即这 8 条以内的条数）。
- 底部按钮：Show in App（在主窗口打开该 Session）和 Jump to Agent（把 Codex / Claude 桌面端或所用终端切到前台）。
- 打开详情即把该 Session 标记为已查看（[MAC-R-019](#mac-r-019-打开-session-即视为已查看)）。

### Session 状态颜色

Mac Session 列表、详情、Notch 和 iPhone 用同一套五档状态颜色回答“该先看哪条”：

- 蓝 · Running：Agent 正在工作（含启动和上下文压缩）。
- 橙 · Waiting for input：Turn 停在等待你审批或回答，人不处理就不会继续。
- 绿 · 待查看：Turn 已结束，但你还没打开过这条 Session——它就是下一条该看的。
- 灰 · Completed：Turn 已结束且你看过了，或 Session 处于空闲。
- 红 · Failed / Interrupted：失败或被中断。

在 Mac 列表点击某行，或从 Notch、iPhone 打开详情，都算“看过”，绿色随即降为灰色并同步到所有端；见 [MAC-R-019](#mac-r-019-打开-session-即视为已查看)。

Mac 主窗口的状态视觉：

- 列表：标题行前置 7 pt 状态色点（状态词进色点的悬停提示，Completed 档的标题转为中灰）；subheader 用同档色系、带描边的状态药丸；状态变化时颜色 0.2 秒过渡。
- 蓝、橙、绿三档的色点带光晕并缓慢呼吸（约 1.6 秒一次）；灰与红的点为实心静止。
- 选中行使用中性灰底，文字颜色与字重不变。
- 完整映射见 [MAC-R-013](#mac-r-013-session-状态颜色跨端一致)。

## 首次配置

1. 在侧边栏选择“Settings”，再在中栏选择“Daemon”。
2. 点击“Install & Start daemon”。
   - 系统反馈：Daemon 面板显示连接和运行状态。
   - 规则引用：[MAC-R-001](#mac-r-001-daemon-决定实时可用性)。
3. 在中栏选择“Agents”。Integrations 列表一行一个 Agent（Codex、Claude Code），给你在用的 Agent 点行尾的“Install”（两个都用就都装）。
   - 系统反馈：该行副标题变为 Installed；Codex 行随后显示已信任的处理项数量（Claude Code 无信任环节）。
   - 数据结果：只追加 Lumi Hook，不覆盖其他集成，写入前在配置文件旁保留一份备份；Codex 的信任记录只针对 Lumi 自己的处理项写入。
   - 规则引用：[MAC-R-002](#mac-r-002-安装不替换现有-hooks)、[MAC-R-021](#mac-r-021-自动向-codex-申请-hook-信任)。
4. 新建一个 Agent Session 并提交任务。
   - 系统反馈：首个 Hook 事件到达后，Session 出现在中栏。
   - 规则引用：[MAC-R-024](#mac-r-024-session-随-agent-活动进入-lumi)。

完成信号：Daemon 面板显示 Running；新 Session 以“标题、Agent、状态”出现在列表中，Inspector 与 Activity 随 Agent 事件更新。

## 日常操作

### 关闭主窗口

关闭主窗口不会退出 Lumi：Notch、daemon 和 iPhone 同步照常运行，Dock 图标随窗口一起隐藏。要找回窗口，从 Notch 打开任意 Session 或 Notch 设置，用菜单栏 Window > Lumi（⌘0），或从 Spotlight / 启动台 / Finder 再次打开 Lumi——窗口回来时 Dock 图标一并恢复。彻底退出用菜单栏的 Quit Lumi（⌘Q）。

### 刷新 Session

点击工具栏右侧的刷新图标（Refresh）：

- 当前选中的 Session 先由 daemon 从它的本机对话记录整个重建（Claude 父 Session 连同子 Agent 一起；你已删除的子 Agent 不会被重建回来），已同步的 iPhone 同时拿到重建结果；然后再从 daemon 取得全部 Session 的完整当前数据。
- 列表非空时总有一条处于选中，所以刷新通常都带重建；解析规则更新后，用它回填旧 Session 新增的记录（例如 `Empty` 的 REASONING 行）。
- 列表、数量或详情变化代表同步结果已显示；数据没有变化时，当前版本没有单独的完成提示。
- 外部产生的 Session 内容除此之外只会在 App 启动和收到 Agent 事件时更新，见 [MAC-R-009](#mac-r-009-mac-界面只有三种同步入口)。

### 删除 Session

三个入口，同一确认框：工具栏右侧的删除图标（Delete Session）、列表右键菜单（一条时是 Delete Session，多选时是 Delete N Sessions）、焦点在列表时按 ⌘⌫（裸 ⌫ 不触发删除）。右键落在未选中的行会先把选中移到那一行；落在已选中的行上则对整组多选生效。

确认框写明会从这台 Mac、daemon 和已连接 iPhone 移除（多选时写明条数）；Delete 是红色破坏性按钮，回车落在 Cancel 上。确认后 Session 立即从列表消失，选中自动落到相邻的下一条（删的是 Subagent 时回到它的父级）。删除不影响 Agent 自身 Session；之后被动到达的旧活动不会让它重新出现，只有你在同一会话里再次发出请求（或会话重启）它才会回来。

### 从 Notch 归档 Session

- 入口：在 Notch 展开列表中，悬停到一条 Turn 已结束的 Session 行上（等待查看、已关闭、失败或中断都算），行尾的相对时间原地换成归档按钮。
- 点击后该 Session 立即从 Notch 的列表和计数里消失；带 Subagent 的 Session 整组一起消失，回来时也整组一起回来。
- 归档只影响 Notch：主窗口和已连接 iPhone 照常显示这个 Session，历史也不删除。
- 回来条件：你在该 Session 里发出新请求（或它重新启动）时，它自动回到 Notch。不手动归档的话，超过七天没有活动的 Session 也会自动离开 Notch 列表。

- 规则引用：[MAC-R-014](#mac-r-014-notch-显示-session-当前状态)。

### 过滤 Session 列表

在工具栏中栏段的“Filter sessions”输入文字，列表只保留标题、Agent 名或工作目录包含该文字的 Session；命中的 Subagent 会连同父级一起保留。清空文字恢复完整列表；没有命中时显示 No matching Sessions。

### 隐藏幽灵 Session（Filters）

测试、`~/tmp` 里的一次性调用这类不想再看到的 Session，可以用“Settings > Agents”的 Filters 规则挡在所有界面之外：命中规则的新 Session 照常记录，但不出现在主窗口列表、Notch，也不同步到 iPhone、不发推送。

- 语义：默认显示所有 Session；命中任一启用规则的被隐藏。一条规则内的条件全部满足才算命中（and），多条规则之间取或。
- 条件字段：Agent（Codex / Claude）、Application（承载会话的应用，如 Paseo）、User message（首条用户消息，contains / starts with，按记录原文匹配——斜杠命令记录含 `<command-name>` 标签，匹配命令名要用 contains）、Folder（工作目录，选中的文件夹及其子目录都算命中）。
- 编辑就地完成：`+ Add Filter…` 追加一条默认规则（Agent is Codex）并立刻展开编辑；已有规则点铅笔展开，一次只有一行可编辑；Cancel 回滚（新建行直接消失），Done 保存。规则行可以拖拽排序、用开关停用（保留但不参与判断）、点 × 删除。
- 生效时机：规则只对新 Session 生效——在它的首条用户消息到达时判一次，之后不再改变；改规则不会隐藏或放出已有 Session。斜杠命令、Raft 这类从不开回合的会话也会被判定。空值条件不命中任何 Session。
- 规则引用：[MAC-R-025](#mac-r-025-filters-在-session-首条用户消息判一次并冻结)。

### 过滤 Activity

Activity 标题右侧有两枚下拉按钮：

- Category：按消息类别，面板按 Session / User / Model / Exec 四个泳道分组。失败分两项——Model 组的 Turn failure 和 Exec 组的 Tool failure，标签都是 FAILED，但前者是实色红、后者是淡红底。
- Importance：按 L3 / L2 / L1 三档。L3 是阶段——用户输入、回合结束、回合失败、中断；L2 是过程——回复、工具结果、工具失败、计划、子 Agent；L1 是细节——思考、上下文、配置、工具调用，以及 Session 开始/结束和上下文压缩。
- 用法：点开面板后点任意一行勾选或取消，列表和上方的横向时间轴立即只显示“类别被选中 且 重要性被选中”的记录——列表少几行，时间轴就少几格，两边始终一行对一格；分组头可以一键全选 / 全不选整组。
- 过滤中的按钮变蓝并显示仍选中的项数，标题旁的计数变成“命中 / 总数”（如 `11 / 27`）。

- 面板里的计数永远是这个 Session 的全量条数，不随另一枚按钮变化。
- 一个维度不能全部取消：取消掉最后一项会自动回到全选。
- 两个维度交集为空时列表显示空态和 Reset 按钮，点 Reset 两个维度都回到全选。
- 横向时间轴跟着过滤走：被过滤掉的记录在时间轴上也没有格子，改完勾选后时间轴自动对齐到列表顶部那一行；点任意方格仍然跳到对应记录并高亮。
- 过滤只在当前 Session 内有效，切到别的 Session 或重新打开就回到全选；新记录到达时保持当前过滤条件。
- 规则引用：[MAC-R-023](#mac-r-023-activity-过滤同时收窄列表与时间轴)。

### 配对一台 iPhone

“iPhone”页面常驻一张配对码卡片：二维码、6 位配对码（显示为 `7KF-3QP` 的三三分组）、Relay 地址、`Expires in m:ss` 倒计时和寿命进度条。

- 码的寿命：5 分钟有效，到点立刻作废，但不会自动换新——卡片停在过期态（倒计时处显示 Expired、二维码收起、旧码变灰），提示点 New code 再出一个。
- 出新码的时机：只在进入这一页、点 New code 或一次配对有了结果之后；New code 在有 iPhone 待确认时暂不可用。离开页面码也作废，回来时重新出码；daemon 重启后这一页自动出新码。
- iPhone 提交后：卡片下方出现 “<iPhone 名> wants to pair”、Relay 地址和时间、一组 6 位数字（如 `482 913`）以及 Don't match / Match 两个按钮。和 iPhone 屏幕上的数字一样才点 Match（默认键盘焦点在 Don't match，Return 不触发任何一个）；60 秒没点自动拒绝。
- 结果（Paired ✓ / Pairing declined ✕）停 2 秒后卡片收起、新码开始；iPhone 那边中途取消则不显示结果，直接换新码。
- 整个确认过程要停在这一页完成——离开页面或退出 Mac App 会取消进行中的配对。
- 规则见 [IOS-R-002](./iphone-live-view.md#ios-r-002-配对码短时且一次性)、[IOS-R-014](./iphone-live-view.md#ios-r-014-配对时两端比对数字mac-点-match-才生效)。

### 管理已配对 iPhone

“iPhone”页面右列的 Paired iPhones 列表每行是一台 iPhone：名称旁一枚状态 tag，行尾一个文字动作；标题旁的数量只统计 Active 的设备。

- Active：这台 Mac 在 Match 时记住了这台 iPhone 的身份，正在向它同步（[IOS-R-014](./iphone-live-view.md#ios-r-014-配对时两端比对数字mac-点-match-才生效)）。行尾是 “Revoke”：确认后只关闭该设备的通道，其他 iPhone 不受影响，记录保留为 Revoked。
- Unverified：这台 iPhone 的身份不是这台 Mac 点 Match 批准过的（此版本之前配对的，或中转服务换过钥匙），不向它发送任何 Session 内容，下方提示 `Key not verified · pair this iPhone again`；行尾同样是 “Revoke”。恢复方式见[用户摩擦点](../friction-points.md#iphone-在-mac-上显示-unverified)。
- Revoked：已被撤销。行尾是 “Remove”：确认后删掉这条配对记录（这台 iPhone 之后用新码可以重新配对）。

刚配对成功的那一行会短暂高亮一次。

## 设置面板

- **General**：Startup 卡片提供“Open Lumi at login”开关（登录自动启动 Lumi；daemon 的常驻另由 Daemon 设置管理，互不影响）；Software Updates 卡片提供“Automatically check for updates”开关，脚注注明下载或安装前 Lumi 都会先询问。完整更新行为见[软件更新](software-updates.md)。
- **Notch**：见 [MAC-R-015](#mac-r-015-notch-设置集中在主-app)。
- **Daemon**：subheader 显示 Running / Not connected 药丸。
  - Local service 卡片：Status、Uptime、Active sessions、Stored sessions 和 Socket 路径；已安装时提供“Reinstall daemon”（立即执行）和“Stop & uninstall”（需确认，确认框注明采集停止但历史保留），未安装时提供“Install & Start daemon”。
  - Session history 卡片：标题显示保存的 Session 条数和磁盘占用；点“Clear history…”并在确认框（Clear Lumi Session history?）点“Clear History”即清空 Lumi 保存的全部 Session 与时间线，Agent 自身历史不受影响。
  - Logs 卡片：显示日志目录（`~/Library/Logs/Lumi`，含 daemon.log / helper.log / app.log 和只收错误的 errors.log），“Show in Finder”直接打开；哪些内容会进日志见[恢复路径](../friction-points.md#仍无法恢复先看日志)。
  - 升级 App 后不需要手动 Reinstall：启动时发现 daemon 版本过期或起不来会自动重装（[MAC-R-022](#mac-r-022-启动时自动更新已安装的-daemon)）。
- **Agents**：两组内容。
  - Integrations：一张卡片列出全部 Agent（Codex、Claude Code），每行是图标、名称、等宽配置文件路径和状态副标题，行尾一个按钮表示当前动作——未安装 Install、已安装 Remove（红字）；Codex 已安装但未被信任时按钮换成蓝色的 Trust（Remove 移进右键菜单），副标题以警示色说明 Session 会停止上报（[MAC-R-021](#mac-r-021-自动向-codex-申请-hook-信任)）。
  - Filters：隐藏幽灵 Session 的规则列表，见[隐藏幽灵 Session](#隐藏幽灵-sessionfilters)与 [MAC-R-025](#mac-r-025-filters-在-session-首条用户消息判一次并冻结)。
- **About**：显示版本与 build、更新通道与自动检查状态（如 `Stable · Automatic checks on`），提供“Check for Updates…”和系统 About 面板入口；完整行为见[软件更新](software-updates.md)。

## 规则

### MAC-R-001 daemon 决定实时可用性

- 条件：daemon 已安装、获准运行并成功连接。
- 行为：App 在启动时取得完整数据，并订阅后续 Agent 事件。
- 结果：连接状态显示在“Settings > Daemon”的药丸与 Status 行；daemon 断开且无数据时，Notch 空态显示 Daemon unavailable。Session 保持同步。
- 限制或例外：daemon 断开时，Mac 仍可查看本地已同步内容，但刷新和删除无法完成；Sessions 页面本身不显示连接状态。

### MAC-R-002 安装不替换现有 Hooks

- 条件：用户在 Integrations 列表的 Codex 或 Claude Code 行点击“Install”。
- 行为：只追加尚不存在的 Lumi Hook；每次写入前在配置文件旁保留一份 `.lumi-backup` 备份。
- 结果：其他集成继续保留。
- 限制或例外：写入 Codex 的 hooks.json 会让它已有的信任记录失效，因此安装后立即执行 [MAC-R-021](#mac-r-021-自动向-codex-申请-hook-信任)。

### MAC-R-003 展示活动并保留 Session 诊断数据

- 条件：Session 产生受支持的 Agent 事件。
- 行为：Activity 整理消息、系统与上下文、reasoning、工具、计划、子 Agent、错误和可识别的未知记录；Inspector 展示 Session 元数据、模型配置和消耗指标。模型每开始一次思考就出现一行 REASONING（思考结束不另起一行）；Claude 只落盘签名、没有正文的思考也占一行，内容显示为 `Empty`。
- 结果：用户能在 Activity 中按发生顺序查看对话与执行上下文，并在 Inspector 中查看当前配置和 Token 使用。重复事件不产生重复记录，乱序事件不回退可见状态。
- 限制或例外：每类最新诊断记录会完整保存来源提供的嵌套内容，其中可能出现路径、凭据、环境信息或工具内容；当前没有内容级脱敏保证。只有 Lumi 能识别为活动的记录会显示，其他来源事件不会另行保留。

### MAC-R-004 查看不控制 Agent

- 条件：用户选择 Session 或时间线项目。
- 行为：改变当前查看对象；选中一条绿色待查看的 Session 会同时把它标记为已查看（[MAC-R-019](#mac-r-019-打开-session-即视为已查看)）。
- 结果：Agent 的 Session 不会被批准、终止或修改。
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

### MAC-R-007 移除集成只移除 Lumi

- 条件：用户在 Integrations 列表的 Codex 或 Claude Code 行点击“Remove”（Codex 未信任时 Remove 在该行的右键菜单里）。
- 行为：只删除该 Agent 配置中 Lumi helper 对应的处理项。
- 结果：其他 Hook 保留；另一个 Agent 的安装不受影响。
- 限制或例外：daemon 仍可运行；停止全部采集还需停止并卸载 daemon。

### MAC-R-008 清空历史不修改 Agent

- 条件：用户确认“Clear history…”。
- 行为：清空 Lumi 保存的全部 Session 与时间线。
- 结果：Mac 和已连接 iPhone 不再显示这些 Session。
- 限制或例外：Agent 自身 Session 和日志不受影响。

### MAC-R-009 Mac 界面只有三种同步入口

- 条件：App 启动、用户点击刷新图标（Refresh）或收到 Agent 事件。
- 行为：
  - 三种入口分别执行首次同步、完整手动同步或增量更新。
  - 手动刷新时若有选中的 Session，daemon 先用该 Session 的本机对话记录从头重算它（修正卡住的状态、补齐漏掉的内容），再做完整同步。
  - 重算保留人为标记：已查看状态（[MAC-R-019](#mac-r-019-打开-session-即视为已查看)）和 Notch 归档（[MAC-R-014](#mac-r-014-notch-显示-session-当前状态)）不因刷新重置。
- 结果：界面不做周期轮询；刷新不会让看过的 Session 重新变绿，也不会让归档的 Session 回到 Notch。
- 限制或例外：删除和清空会立即同步操作结果；连接恢复会重新建立事件通道。daemon 会自行跟进运行中 Claude Session 的对话记录，因此有些变化（如 Esc 中止后数秒内变红）不需要任何 Hook 事件，见[数据流](../data-flows.md#session-状态与时间线)。

### MAC-R-010 Session 删除跨端同步

- 条件：用户选择一个或多个 Session 并确认删除。
- 行为：删除这些 Session 及时间线，并把结果同步到全部已连接客户端。
- 结果：daemon、Mac 和已连接 iPhone 保持一致。
- 限制或例外：操作需要 daemon 在线；不删除 Agent 自身内容。

### MAC-R-011 已移除：只记录启用后的新 Session

- 状态：removed。
- 移除日期：2026-08-27。
- 原因：规则与实际行为不符。
- 替代规则：[MAC-R-024](#mac-r-024-session-随-agent-活动进入-lumi)。

### MAC-R-012 历史由用户决定删除

- 条件：Session 已进入 Lumi。
- 行为：系统不按时间主动清理。
- 结果：Session 保留到用户删除单条或清空全部历史。
- 限制或例外：删除后，同一 Session 的后续被动活动不会恢复该记录（[MAC-R-024](#mac-r-024-session-随-agent-活动进入-lumi) 的进入条件重新满足时才回来）。

### MAC-R-013 Session 状态颜色跨端一致

- 条件：Mac、Notch 或 iPhone 显示一个 Session 的当前状态。
- 行为：
  - 五档映射——Starting、Running、Compacting 使用蓝色（Agent 在工作）；Turn 停在等待审批或回答时使用橙色（人不处理就不会继续）；Turn 已结束但还没被打开过时使用绿色（待查看）；Turn 已结束且已查看，或 Session 空闲时使用灰色；Failed 和 Interrupted 使用红色。
  - 命令行回到提示符等待下一条指令的 Session 按“已结束”档显示（绿或灰，状态文字为 Completed），不算等待审批。
  - 颜色不影响列表排序。
- 结果：用户在三个界面看到相同的状态颜色语义；绿色专指“已结束但还没看过”，看过即降灰（[MAC-R-019](#mac-r-019-打开-session-即视为已查看)）。
- 限制或例外：
  - 三个界面共用同一套设计系统取值：Mac 主窗口使用浅色值（Session 详情列固定浅色外观）；Notch 使用独立的深色取值（默认 Solid 表面为纯黑实色面板，便于与刘海无缝衔接；用户也可在设置中改为 Translucent 或 Liquid Glass 材质，见 [MAC-R-015](#mac-r-015-notch-设置集中在主-app)）；iPhone 随系统外观在浅色 / 深色两组值之间切换。
  - 蓝、橙、绿三档的状态点在 Mac 主窗口和 Notch 带光晕呼吸，灰与红为实心；iPhone 的状态标记是实心图标（Failed / Interrupted 显示为感叹号标记），不带呼吸光晕。
  - Mac Inspector Overview 的 Lifecycle 字段显示原始生命周期，停在提示符的 Session 在该字段显示 Waiting For Input 而非 Completed。
  - Notch 列表里 Turn 已结束的行标题降为次级亮度，状态点仍按本档显示，Agent 标签不变。
  - Activity 与 Notch 里的消息类别标签在三档注意力级别下都带 0.5 pt 描边（L1 灰描边、L2 同色淡描边、L3 同色深描边），只靠标签样式区分层级。
  - Mac 列表选中行使用中性灰底，文字颜色不变。
  - Notch 仍只展示当前纳入活动摘要的 Session，不因颜色规则扩大显示范围。

### MAC-R-014 Notch 显示 Session 当前状态

- 条件：Mac 本地同步数据中存在最近七天内活动过、未被 Notch 归档、已产生过 Turn 且状态已知的主 Session——正在启动、工作、压缩上下文、等待审批、Turn 已结束停在提示符（待查看与已查看都算）、已关闭（Completed），或以失败 / 中断收尾。
- 行为：
  - 紧凑状态显示列表中的主 Session 数量；展开后按最近活动时间全量列出这些主 Session，视口一次最多显示六条（按各行实际高度截到第六条为止），更多内容向下滚动，底部一行显示列表中的 Session 总数。
  - 正在工作（蓝色档）的行在标题下显示最近一条活动（类别标签 + 摘要）。
  - 带 Subagent 的 Session 不论处于哪一档都在标题下保留一条 Subagent 计数条（叠放的状态点按 running → waiting → failed → done 排列，文案为 `N subagents` 加各非零档的数量，单数写 `1 subagent`）；蓝色档默认展开成胶囊（状态点 + 名称 + 已运行时长，按同样顺序自由换行），其他档默认折叠。
  - 点计数条切换展开 / 折叠，这一行的选择在它的状态档变化前一直保留，状态档变化后回到默认；点击胶囊打开该 Subagent 的详情。悬停在带 Subagent 的行上时该行以卡片底色高亮，位置与尺寸不变。
  - Turn 结束时 Notch 自动展开、显示约 6 秒回合完成卡片（标题、Turn complete / failed / aborted 与用时、tokens / context 胶囊、最后一条助手消息摘要、Jump to Agent 按钮；点卡片本身进入该 Session 详情）后自动收回；回合级失败 / 中断时自动展开并短暂显示错误提示（标题 + 错误摘要，约 3 秒）后收回。
  - 面板不会在用户悬停或手动展开期间被自动收回；失败提示会等用户离开后再呈现，但回合完成卡片在面板打开期间仍会临时覆盖列表内容。正在查看某条 Notch 详情时，完成卡片不打断当前页面。
  - 不触发提示的情形：新用户消息（回合开始）不改变 Notch 显示；子代理的回合边界属于父级的内部进度，单个工具调用的失败属于常规噪音；App 启动后约 6 秒内以及首次加载的历史数据同样不触发。
- 结果：用户不打开主窗口也能判断 Session 正在做什么以及当前请求是什么；已结束的 Turn 和已关闭的会话留在列表里，直到被归档或超过七天没有新活动。
- 限制或例外：
  - 超过七天没有活动的 Session 自动移出列表和计数，没有单独入口找回（主窗口照常显示）；跨过七天边界的移出要等下一次数据变化才生效，不是即时的。
  - 用户在 Notch 归档的 Session 不进入列表和计数，直到该 Session 收到新请求或重新启动；归档不影响主窗口和 iPhone 的显示。
  - 归档一条带 Subagent 的 Session 时，整组子 Agent（含子 Agent 的子 Agent）随父级一起从列表和计数消失，不会变成独立的顶层行，父级收到新请求回来时整组一起回来。
  - 还没有产生任何 Turn 的 Session 不进入 Notch。
  - Notch 只读取 Mac 已同步内容，不额外刷新 daemon。

### MAC-R-015 Notch 设置集中在主 App

- 条件：用户点击 Notch 顶部设置按钮，或在主 App 选择“Settings > Notch”。
- 行为：
  - 第三栏的 Appearance section 不显示 Theme 和 Layout 控件；Notch 始终使用 Dark Theme 与 Notch Layout。
  - 用户可以选择 Solid、Translucent 或 Liquid Glass 表面，选择内建屏幕、主屏幕或一台已连接的指定屏幕，并调整紧凑宽度、展开宽度和展开动画时长。
  - 紧凑宽度默认 64 pt，可在 32–240 pt 间按 1 pt 调整；展开宽度默认 520 pt，可在 360–720 pt 间按 4 pt 调整；展开动画默认 0.54 秒，可在 0.15–1.20 秒间按 0.01 秒调整。三项调节都能通过数值左侧的恢复按钮回到默认值（已是默认值时按钮禁用），滑块不显示步进刻度点。
  - 保持展开、触觉反馈和 Show Notch 继续保留；启用触觉反馈时会给出一次确认脉冲，并在完成卡片或错误提示出现时反馈。
- 结果：屏幕、尺寸、动画、表面和行为设置保存在主 App 中、跨 App 重启保留并立即应用；Notch 设置按钮打开同一个 Notch 设置页面。
- 限制或例外：物理刘海宽度是紧凑状态的安全下限；指定屏幕断开时，Notch 暂时回到可用的内建屏幕或主屏幕，屏幕下拉里该屏幕显示为 Saved Display (Not Connected)，重新连接后自动恢复。触觉反馈仍受 Mac 硬件和系统设置限制。

### MAC-R-016 Session 列表与详情按信息层级展示

- 条件：Sessions 页面存在一个或多个 Session，用户选择其中一条。
- 行为：
  - 列表一行一个 Main Session，两行式：状态色点 + 标题 + 相对时间，加 Agent 图标 + `model · reasoning effort` 副标题（只有 effort 时单独显示 effort，都没有则留空）。
  - 带 Subagent 的行在副标题右端显示叠放状态点与折叠箭头，点这一簇（或键盘左右方向键）切换展开；展开后每个 Subagent（含更深层的子 Agent）占一行且本身可选中——选中 Subagent 即在右栏查看它自己的详情，父级行同时取消高亮。
  - Running / Waiting / Failed 默认展开、Completed 默认收起，手动切换在该行默认档位变化前一直保留（本次 App 运行期间）。
  - 详情固定为 Activity 主区 + Inspector。Inspector 顶部显示 Token 总量、Context 使用比例（最近一次用量 / 上下文窗口）和 Elapsed（运行中的 Session 持续计时，结束的 Session 停在最后活动时间）；其下 Overview（Session ID、Agent、Application、Lifecycle、Turn Phase、Needs Attention、Started；Agent 显示引擎与角色——Codex、Codex(subagent)、Claude、Claude(subagent)；Application 是承载会话的 AaaS 应用，如 Paseo、ChatGPT，早于归属记录的旧 Session 显示 Not available）、有 lineage 时的 Lineage（Thread Source、Subagent Depth、Agent Nickname、Agent Role）、Model（Model、Provider、Context Window、Reasoning Effort、Client Version）和 Usage。
  - Activity 行可打开对应记录的完整原始内容。Subagent 的标题与活动归属见 [MAC-R-018](#mac-r-018-subagent-使用自己的标题与活动)。
- 结果：用户可以按 Main Session 浏览或收起整组 Subagent，再在右栏查看当前副本保存的活动记录与指标。
- 限制或例外：
  - 没有 Activity 时显示明确空状态。
  - 父 Session 不在当前列表、父子关系成环，或旧格式 Subagent 没有 parent 时，该 Subagent 作为顶层项显示；父 Session 还没有 Turn（通常不显示）但已有可见 Subagent 时，父级照常显示，选中它点 Refresh 即可从对话记录补全。
  - Activity 记录（含工具的完整输入与输出、系统与上下文内容）可能包含凭据、环境信息；App 不做内容级脱敏，只应在受信任的 Mac 上查看。

### MAC-R-017 Activity 全量显示并支持时间轴定位

- 条件：用户选择的 Session 包含一条或多条 Activity。
- 行为：
  - Activity 按发生顺序显示属于当前 Session 的全部记录，不要求分批加载。粘顶 header 包含标题、记录数量、密度切换按钮和横向时间轴。
  - 三泳道模式：每条记录占一个 13 pt 方格（列表一行对应时间轴一格），只填在自己所属的泳道（User：用户输入和注入的上下文；Model：Assistant、Reasoning、Plan、Subagent、Turn End、回合级失败与中断；Exec：Tool、Result、工具失败），其余泳道留空；Session 开始/结束、上下文压缩与配置变化不占泳道，而是在三条泳道各画一条 4 pt 窄条，靠宽度与实格区分。
  - 单行模式：所有记录排成一行，方格填类别色。
  - 同步滚动：滚动列表时时间轴跟着移动；在时间轴上横向滚动或按住鼠标左右拖动时列表也随之滚动，拖动松手后时间轴带惯性滑行一小段（列表继续跟随），再次拖动、滚动或点击即停。
  - 点击：只有填了色的方格可以点击（悬停时指针变为手形、方格出现描边），点击后列表滚动到对应记录并短暂高亮；空白泳道格和方格间隙不响应点击。
  - 新记录到达时若用户停在列表底部则跟随到底，否则保持当前位置。
- 结果：用户浏览长 Session 时仍能看到时间轴和当前位置入口，可以先识别会话结构，再直接定位任意一条活动记录。
- 限制或例外：时间轴与密度切换只改变当前详情的查看方式和位置，不修改或控制 Agent 的 Session。

### MAC-R-018 Subagent 使用自己的标题与活动

- 条件：Codex 或 Claude Code 为 Main Session 启动一个 Subagent，Lumi 收到该 Subagent 的身份和任务活动。
- 行为：
  - Subagent 有独立名称时显示该名称；未单独命名时显示昵称与任务路径摘要。
  - Claude 的 Subagent 以启动时的任务描述为标题（没有描述时显示 agent 类型），其 Activity 来自子代理自己的对话记录，生命周期跟随子代理的启动与结束（结束后为 Completed，不会显示为等待输入）。
  - 为执行任务提供给 Subagent 的父 Session 历史只作为其工作背景，不作为 Subagent 标题，也不重复进入其 Activity。
- 结果：用户在父子层级中能按任务辨认 Subagent，打开详情时只看到该 Subagent 实际开始工作后的活动。
- 限制或例外：缺少父子关系的旧格式或孤立 Subagent 仍保留在顶层；其可用身份信息不足时显示通用 Subagent 名称。旧版本记录的 Claude Session 没有子行——选中该 Session 点工具栏 Refresh 即可从本机对话记录补出它的 Subagent。

### MAC-R-019 打开 Session 即视为已查看

- 条件：一条 Session 的 Turn 已结束且还没被打开过（状态为绿色待查看）。
- 行为：在 Mac 列表点击该行（重复点击已选中的行同样生效），或在 Notch 打开它的详情，都把它标记为已查看；主窗口详情或 Notch 详情开着期间新结束的 Turn 也立即视为已查看。标记写入 daemon 和 Mac 本地副本，并同步到已连接 iPhone。
- 结果：绿色降为灰色，三个界面一致；列表里剩下的绿色就是还没看过的 Session。
- 限制或例外：在 iPhone 上打开 Session 同样清除该标记——iPhone 把「已查看」发回 Mac，Mac 写入后同步到所有端（[IOS-R-013](./iphone-live-view.md#ios-r-013-iphone-打开即视为已查看)）。该 Session 下一个 Turn 结束时会重新变绿。刷新重算不重置此标记（[MAC-R-009](#mac-r-009-mac-界面只有三种同步入口)）。

### MAC-R-020 启动时自动更新已安装的 Hook helper

- 条件：Hook 已安装（Codex 或 Claude Code），且 Mac App 启动时自带的 helper 与已安装副本不一致（按文件内容逐字节比对）。
- 行为：启动时自动把 helper 更新为当前版本，并把 Hook 配置刷新到当前事件集——补上新增事件、移除 Lumi 不再监听的事件下自己的处理项；配置完全一致时不写任何文件。
- 结果：升级 App 后 Hook 立即获得新采集能力，无需重新点击“Install”。
- 限制或例外：从未安装过 Hook 时启动不做任何事；配置刷新仍只触碰 Lumi 自己的处理项（[MAC-R-002](#mac-r-002-安装不替换现有-hooks)）。

### MAC-R-021 自动向 Codex 申请 Hook 信任

- 条件：Codex Hook 已安装。发生在点击“Install”之后，以及每次 App 启动时。
- 行为：向 Codex 询问它当前怎么看待各个处理项，为其中未被信任的 Lumi 处理项写入信任，然后再问一次以确认结果。整个过程只涉及命令为 Lumi helper 的处理项，其他工具的 Hook 一律不读取也不改写。
- 结果：用户不必手动审核就能继续收到 Session 事件；“Settings > Agents”的 Codex 行副标题显示已信任的处理项数量。
- 限制或例外：
  - Codex 按处理项在 hooks.json 中的位置记录信任，任何工具改写这个文件都会让信任失效，因此每次启动都会重新申请。
  - 本机没有 Codex、或 Codex 版本还没有信任机制时副标题只显示 Installed。
  - 仍有处理项未被信任时，Codex 行的副标题以警示色提示未信任数量与“Session 会停止上报”，行尾按钮换成蓝色的“Trust”（Remove 移进右键菜单）；Codex 没有应答（无法确认信任状态）时副标题提示 trust unverified。仍失败则需要用户在 Codex `/hooks` 中手动信任。

### MAC-R-022 启动时自动更新已安装的 daemon

- 条件：daemon 已安装，且 Mac App 启动后发现它运行的不是当前 App 自带的版本（按可执行文件指纹比对，指纹缺失也按不一致处理），或已注册的 daemon 根本起不来（启动约 10 秒后仍连不上——常见于注册指向的安装包被重编译或删除）。
- 行为：自动重装 daemon 服务，让系统换用 App 内的新版本，然后重新同步数据。
- 结果：升级 App 后 daemon 立即获得新采集能力，无需去 Settings 手动 Reinstall；注册损坏时也能在启动后自行恢复，不再无限报连接失败。
- 限制或例外：从未安装过 daemon 时启动不做任何事（不会擅自注册服务）。每次 App 启动最多自动重装一次；重装后仍不一致（例如开发版 App 对着已注册的正式版 daemon）或仍连不上时只记录日志，不再重试。手动“Reinstall daemon”仍可用作兜底。

### MAC-R-023 Activity 过滤同时收窄列表与时间轴

- 条件：用户在 Activity 头部的 Category 或 Importance 面板里改变勾选。
- 行为：
  - 列表和横向时间轴只保留类别与重要性都被选中的记录——被过滤掉的记录既没有行也没有格子，两边仍然一行对一格、同步滚动，改完勾选后时间轴对齐到列表顶部那一行。
  - 两枚按钮之间取交集，一枚按钮内取并集。
  - 面板里两级计数都是过滤前的全量条数；取消某维度的最后一项时该维度自动回到全选；交集为空时列表与时间轴都空，显示空态与 Reset。
  - 同一时间只开一枚面板，点面板外、按 Esc、调整窗口大小、切换 Session、最小化或关闭窗口、App 失去激活都会关闭它。
- 结果：用户可以只看用户输入与回合结束这类“阶段”消息，或只看某一泳道的记录，时间轴随之变成这些记录的地图，标题旁的“命中 / 总数”计数告诉他藏掉了多少。
- 限制或例外：Inspector 指标与 Notch 不受过滤影响；过滤不持久化，切走再回来即复位；过滤不修改或控制 Agent 的 Session。

### MAC-R-024 Session 随 Agent 活动进入 Lumi

- 条件：对应 Agent 的 Hook 已安装。
- 行为：Session 只在 Agent 产生新活动（Hook 被触发）时进入或更新 Lumi；Lumi 不扫描历史会话目录。一条 Session 首次进入时，它此前已有的完整对话记录会一并导入。
- 结果：启用 Lumi 后从未再使用的旧 Session 不会出现；在一条旧 Session 里再发一条请求，它会带着完整历史出现在列表里。
- 限制或例外：从未产生过任何 Turn 的 Claude Session 会在会话结束时被丢弃，不进入列表；升级迁移也会一次性清掉历史上残留的这类空 Session。已被用户删除的 Session 需重新满足进入条件才会回来（[MAC-R-012](#mac-r-012-历史由用户决定删除)）。

### MAC-R-025 Filters 在 Session 首条用户消息判一次并冻结

- 条件：“Settings > Agents”存在至少一条启用的 Filter 规则，一条新 Session 的首条用户消息到达（斜杠命令这类不开回合的用户消息也算）。
- 行为：按当时的规则判定一次（User message 规则匹配这条消息的记录原文）。命中即隐藏：这条 Session（连同它的整组 Subagent）不出现在主窗口列表和 Notch，不同步到已配对 iPhone，也不发推送；数据照常记录在 daemon。判定结果永久冻结——之后改规则、删规则、Session 复活或刷新重算都不改变它。
- 结果：幽灵 Session 不再打扰任何界面；正常 Session 不会因为后加的规则消失。
- 限制或例外：
  - 停用的规则不参与判定；值为空的条件不命中任何 Session。
  - 规则只在这台 Mac 的 daemon 上判定与存储；Clear history 清掉的是 Session，规则保留。
  - 被隐藏的 Session 目前没有查看入口（计划后续提供显示开关）；daemon 的 Stored sessions 计数包含它们。

## 空状态与故障

- **No Sessions**：daemon 在线，但还没有 Session 进入 Lumi，或用户已删除全部记录。
- **No matching Sessions**：过滤词没有命中任何 Session；清空搜索框恢复。
- **No active Sessions**（Notch）：没有符合展示条件的 Session（都已被归档，或都超过七天没有活动）；历史仍可在主窗口查看。
- **Daemon unavailable**（Notch 空态与 Settings）：保留本地已同步内容供查看；恢复 daemon 后点击刷新图标（Refresh）。
- **Codex 未信任 Hook**：Codex 不运行未信任的 Hook，也不给提示，表现为 Session 停更；在“Settings > Agents”的 Codex 行点击“Trust”，仍失败则在 Codex `/hooks` 中手动信任。

更多恢复步骤见[用户摩擦点](../friction-points.md)。

## 业务数据

Session 状态、活动时间线、模型配置、内部上下文和消耗指标在 daemon 和 Mac 上分别保存同步副本，不自动过期。Mac 的副本支持快速启动、列表浏览、分模块详情和离线查看；daemon 恢复后，以 daemon 当前数据为准重新同步。

Notch 消费 Mac 已同步的 Session 与时间线，不创建额外 Session 副本，也不增加新的刷新入口；详细筛选与展示规则见 [MAC-R-014](#mac-r-014-notch-显示-session-当前状态)。

删除 Session 或清空历史只影响 Lumi。完整生命周期见[数据流](../data-flows.md#session-状态与时间线)。

## 相关文档

- [功能全景](../index.md)
- [本地查看旅程](../journeys/observe-session-locally.md)
- [软件更新](software-updates.md)
- [数据流](../data-flows.md)
- [摩擦点](../friction-points.md)
