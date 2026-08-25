# Session Timeline 重构方案（Helper 领域化 + 消息分级 + Notch 调整）

## Context

现状：`Spark` 只做 hook JSON → `AgentIngressEvent` 薄转换；rollout 由 daemon 内 `CodexRolloutWatcher` 另起一路；`TimelineItem` 扁平事件流，UI 只按 `category` 着色，无 Turn 概念、无每行状态、无消息分级。

目标：
1. **边界前移**：Helper 内完成 Agent 领域抽象（hook stdin + transcript/rollout + sqlite）→ 完备的 Session/Turn 领域数据；daemon 只做去重、持久化、订阅分发。
2. **两个层级**：**A. Agent 通讯领域**（Session/Turn 消息与生命周期，对齐 `docs/research/hooks-session-turn-model.md`）；**B. Timeline 领域**（UI 行、Tag 分级、泳道、状态）；**A→B 映射**是唯一桥梁。
3. UI 按设计交接稿 `~/Downloads/design_handoff_notch_and_activity/`（README + 两份 .dc.html）高保真复刻：主窗口 5A Activity 列表 + Notch 5B–5E；Tag 三级 L1/L2/L3；新增 `TURN END`；Claude 图标 `~/Downloads/claude-ai-icon.svg`。

---

## A. Agent 通讯领域（Helper 产出，daemon 持久化）

### A.1 Session
```
Session {
  id, provider(claude|codex), model?, cwd, permissionMode, transcriptPath?, title?
  startSource: startup|resume|clear|compact|fork
  endReason?:  clear|resume|logout|prompt_input_exit|other
  parent?: { sessionId, agentId, agentType }
  lifecycle: starting | idle | running | compacting | ended
  firstTurnAt?                  // 第一个 Turn 的时间；nil 且 lifecycle == starting ⇒ 临时会话（不显示）
  context: [SessionContext]     // 指令文件 / 配置 / 模型配置 / 工作目录
  turns: [Turn]
}
```
| Session 消息 | 来源 | 转换 |
|---|---|---|
| SessionStarted(source, model) | SessionStart | → idle |
| CompactionBegan / Ended(trigger) | PreCompact / PostCompact | → compacting / 恢复 |
| SessionEnded(reason) | SessionEnd | → ended；Claude 且会话仍临时（无 Turn、无 transcript）→ **SessionDiscarded**：不保留该 Session |
| SubagentSpawned / Finished(agentId, agentType, lastMessage) | SubagentStart/Stop | 建/结子 Session |
| SessionContext(kind, source, content/path) | InstructionsLoaded / ConfigChange / model_configuration / CwdChanged / DirectoryAdded / rollout `session_meta` | 追加 `Session.context[]` |

### A.2 Turn
```
Turn {
  id (claude prompt_id | codex turn_id), index, sessionId, prompt, startedAt, endedAt?
  phase: submitted | thinking | responding | toolRunning | waitingPermission
       | compacting | stopped | failed | aborted
       // subagentRunning 已于 2026-08-25 退役：子代理执行归入 toolRunning/executing
  context: [TurnContext]
  messages: [TurnMessage]
  usage?, permissionEvents[]        // 元数据，不进 Timeline
}
```
| TurnMessage | hook 来源 | transcript / rollout 来源 |
|---|---|---|
| `userPrompt(text)` | UserPromptSubmit | `user`+string / `user_message` |
| `turnContext(kind, content)` | UserPromptSubmit/Expansion additionalContext、hook systemMessage、Elicitation | `attachment` / `system` / `<system-reminder>` 块 / rollout `internal_context` / 压缩摘要 / skill 展开 |
| `assistantThinking(text)` | — | `assistant`.`thinking` / reasoning |
| `assistantText(text)` | Stop.last_assistant_message（兜底） | `assistant`.`text` / `agent_message` |
| `assistantPlan(steps)` | — | plan 更新 |
| `toolCall(toolUseId, name, input)` | PreToolUse | `assistant`.`tool_use` / `exec_command_begin` / `mcp_tool_call_begin` |
| `toolResult(toolUseId, output, isError, duration)` | PostToolUse | `user`.`tool_result`(+`toolUseResult`) / `*_end` |
| `subagentDelegated(agentId, agentType)` / `subagentReturned(lastMessage, ok)` | SubagentStart/Stop | `isSidechain` 记录 / `sub_agent_activity` |
| `turnStopped(lastMessage)` | Stop | — |
| `turnFailed(errorType, msg)` / `turnAborted` | StopFailure(Claude) | `turn_aborted` |
| `permissionRequested/Decided`、`usage` | PermissionRequest / — | — / `token_count`（**元数据**） |

Turn phase 转换集中在 Helper 的 `TurnStateMachine`：`submitted →thinking→ toolRunning ⇄ thinking → responding → stopped`；`permissionRequested→waitingPermission`；`subagentDelegated→executing`（原 `subagentRunning`，已退役）；`turnFailed/aborted→failed/aborted`。

### A.3 传输
`AgentIngressEvent` 携带 `sessionLifecycle? / turnPhase? / sessionMessage? / turnMessage?`（替代直接塞 `timelineItem`）。daemon 存 `sessions / turns / turn_messages / session_messages`。**Timeline 行由 `TimelineProjection`（Common，纯函数）按 §C 投影，不落库。**

---

## B. Timeline 领域（UI 消费）

```
TimelineRow { id, sessionId, occurredAt, tag: Tag, level: L1|L2|L3, lane: Lane?, content, status: ItemStatus,
              toolUseId?, agentId?, seen: Bool, expandable: Bool }
enum Lane { user, model, exec }        // nil = 横跨（SESSION / COMPACT / CONFIG；CONTEXT 在 User 泳道）
enum ItemStatus { info, started, running, succeeded, failed, cancelled }
```

### B.1 Tag 分类表（设计稿 taxonomy，最终版）

| Tag | Level | Lane | 说明 |
|---|---|---|---|
| `SESSION` | L1 | 横跨 | 会话开始 / 会话结束 |
| `COMPACT` | L1 | 横跨 | 上下文压缩 |
| `CONFIG` | L1 | 横跨 | 配置：Agent 怎么跑（设置文件、工作目录、每轮的 model / effort / sandbox）。2026-08-24 起替代原 `CONTEXT ×N`：配置不是喂给模型的输入，横跨三泳道与 SESSION / COMPACT 同组 |
| `USER` | **L3** | User | 用户输入 —— **Turn 起点** |
| `CONTEXT` | L1 | User | 注入上下文（指令文件、附件、system reminder、压缩摘要——模型读到的、非用户键入的内容）。2026-08-24 起不再分 session / turn 两档，也不再相邻合并成 ×N；同文本 REASONING 去重、同 agentId SUBAGENT 原地更新保持不变 |
| `REASONING` | L1 | Model | 思考（蓝色系 L1：透明底、蓝字 `#0069D7`，不再紫色；交接稿 README 写的"统一灰字"以设计系统 §4.3 为准）。Codex 每个新的 reasoning item 会把本 turn 已有的 summary 标题再发一遍（`event_msg.agent_reasoning` A、B，然后 A、B、C…），投影按 turn 去重：同一 turn 内同文本只保留首行，后续记录并入该行的 items。空文本（Claude 只写 signature 的 `thinking` block）显示为 `Empty`，每条自成一行、不参与去重 |
| `ASSISTANT` | L2 | Model | 助手回复（Agent 蓝的 L2 淡色） |
| `PLAN` | L2 | Model | 计划（PLAN 紫的 L2 淡色） |
| `SUBAGENT` | L2 | Model | 子代理（同 agentId 原地更新，不加行） |
| `TURN END` | **L3** | Model | Turn 结束 —— **Turn 终点**（Agent 蓝实底） |
| `TOOL` | L1 | Exec | 工具调用（≡ PreToolUse / assistant `tool_use`），黄色 L1（设计系统 §4.3；本稿早先写 L2，已按代码改正） |
| `RESULT` | L2 | Exec | 工具结果（≡ PostToolUse / user `tool_result`），与 TOOL 用 toolUseId 配对高亮，**不合并** |
| `FAILED`（`.failed`） | **L2** | Exec | 工具调用失败（`toolResult.isError`），留在 Exec 与它的 TOOL 相邻。2026-08-24 起从 L3 降为 L2：单个工具失败是回合内的过程噪音，红色淡底即可，不该和 USER / TURN END 同档 |
| `FAILED`（`.turnFailed`） | **L3** | Model | 轮次 / Agent 失败（`turnFailed`、`.error` payload），同一个 FAILED chip，落在 Model 与 TURN END 相邻。泳道跟来源走：工具失败归 Exec，轮次失败归 Model |
| `ABORTED` | **L3** | Model | 中断（`turnAborted`、含 interrupt / abort / cancel 字样的 `.error`） |

**无 Turn 头行、无 phase pill**：Turn 边界由 `USER` → `TURN END` 读出。**不进 Timeline**：权限、usage。

### B.2 视觉（设计稿 5A + 设计系统）
- 行高 40，hairline `rgba(0,0,0,.05)`；列 time 56 + tag 82 + content，gap 12；无 status-dot 列；行尾 chevron 7×11。
- L1：无底无环，灰字 `rgb(138,138,138)`（dark `.38`）。L2：类目色 14–16% 底 + 深色字 + `.5px` 环。L3：实底 + 白字。色相：Agent 蓝 `#0078F0`（ASSISTANT L2 / TURN END L3）、User 绿 `#1DA84C`、PLAN 紫 `#8E3FE8`、SUBAGENT 橙 `#ED6A0C`、TOOL·RESULT 黄 `#F0B400`、失败红 `#E5352F`。
- Session 标记行（SESSION / COMPACT）：横跨三泳道、行高 32、L1 样式；CONTEXT（含 ×N）不横跨，落在 User 泳道。
- **Lane strip**（列表上方）：三行 User / Model / Exec（`TimelineLane.allCases` 顺序，Mac 与 iPhone 同名同序），每个 item 一个 13×13 r3 单元，gap 4，只在所属泳道填色；格子颜色走同色相三档：L1 中性 `#E7E8EC`、L2 淡色（`#DBECFD` / `#EFE4FC` / `#FCE7D8` / `#FDF3D6`）、L3 满饱和实色。空格留白。**列表每一行都有一格**（行 ↔ 格按下标一一对应）：TOOL 与 RESULT 在 Exec 各占一格，Claude 的 `total_tokens_reminder` 上下文也占格（2026-08-22 起；之前两者只进列表不进 strip）。
- 升级规则：`RESULT.isError` → `FAILED`（同为 L2，只换红色相，**不推 Notch**——单个工具失败是回合内常规噪音，只有轮次失败 / 中断推）；`turnStopped` → 追加 `TURN END`，末条 ASSISTANT 状态点标深蓝 `#0A5FBF`；同屏最多 3 条 L3（先降级已 seen）；L1 不升级；仅 L3 触发 Notch。
- **Session 状态五档**（`SessionStatusTone.resolve`，唯一解析器，三端同源；设计系统 §4.1）：Running 蓝 `rgb(0,120,240)`（starting / running / compacting；带 halo 并呼吸）、Waiting 橙（waitingForInput 且 phase 不是 idle：等输入或等审批，人不处理就不会继续）、Completed · unreviewed 绿 `#1DA84C`（Turn 已结束且 `needsReview`，任一端打开即降灰）、Completed 灰 `rgb(110,113,120)`（含 waitingForInput · idle，显示为 Completed）、Failed / Aborted 红 `#E5352F`（failed / interrupted）。设计稿写“等待排到列表最前”，实现保持纯活动时间倒序，不按档位分层。phase 只换状态点与副标题，不换这一档颜色。深色（Notch）对应 `#4C9BFF` / 橙 / `#34C759` / `.34` / `#EE4038`。（原稿写三档、Waiting 绿；2026-08-22 修订为与代码一致的五档。）

---

## C. A → B 映射

| Agent 领域 | TimelineRow |
|---|---|
| SessionStarted / SessionEnded | `SESSION`(横跨, info) |
| CompactionBegan+Ended | `COMPACT`(横跨, running→succeeded) |
| sessionConfig（ConfigChange / CwdChanged / turn_context / thread_settings） | `CONFIG`(横跨, L1) |
| userPrompt | `USER`(User, L3) |
| context（instructions / attachment / reminder / world_state …） | `CONTEXT`(User, L1) |
| assistantThinking | `REASONING`(Model, L1) |
| assistantText | `ASSISTANT`(Model, L2)；turnStopped 后末条 status=succeeded |
| assistantPlan | `PLAN`(Model, L2) |
| subagentDelegated / Returned | `SUBAGENT`(Model, L2) 同 agentId 原地更新 |
| toolCall | `TOOL`(Exec, L1, started) |
| toolResult ok / isError | `RESULT`(Exec, L2, succeeded) / `FAILED`(`.failed`, Exec, L2) |
| turnStopped | 追加 `TURN END`(Model, L3) |
| turnFailed / `.error` | `FAILED`(`.turnFailed`, Model, L3) |
| turnAborted / 含中断字样的 `.error` | `ABORTED`(Model, L3) |
| permission* / usage | 不映射（页头 / Notch 指标） |

规则：block 类型决定泳道，不是消息角色；失败按来源分泳道（工具失败 Exec、轮次失败 Model），两者共用 FAILED chip。

---

## D. Notch（设计稿 5B–5E，OpenNook）

- **5B 列表**：520pt；行 grid `8px 1fr auto`，padding `10 16 11`（下挂子代理时底 4）；状态点 8px + 3px halo（running `#4C9BFF` / waiting `#34C759` / failed `#EE4038` / idle `.34` 无 halo）；标题 `#fff`，turn 结束后 `.72`；右侧 agent chip（h20 r6 `.09`/`.6`，结束后 `.07`/`.45`）+ 20px 时间/归档共用槽（chip→槽 gap 10），hover 时间原地换成归档按钮（仅 `turnEnded` 行）；子代理行 6px 点 + 11/510 `.72` + 肘形导线，**只在父 Turn 运行时列出**；子代理按 running → waiting → failed → done、再按活动时间排序（`SubagentGroupSummary.precedes`，Mac 主窗口、Notch、iPhone 同一顺序；分组用 `SessionHierarchy`，子代理的子代理并入同一组）；页脚 `9 16 12` 顶部 hairline "N of M sessions"。
- **5C Turn 结束卡**：标题 + "Turn complete" `#9DC7FF`（失败 `#EE4038`）+ 耗时；指标 pill（tokens / context / still running）；摘要 11/510 6 行；"Jump to Agent" 白底 13/590 按钮。
- **5D Turn 开始卡**：`Turn started` `#9DC7FF` + 计时；副标题 `Codex · model · cwd`；USER 消息块。
- **5E 会话详情**：返回 pill + 15/700 标题、生命周期 pill（档位色 `.18` 底 + `.32` 环，文字 `#9DC7FF` 等）、胶囊 agent chip、三指标 tile、**Recent activity**（22 高行，60px compact tag chip 用 dark 色值与短标签 ASSIST / SUBAG）、"Show in App"/"Jump to Agent"。
- Notch 通知：仅 L3 入 `NookActivityQueue`，dwell ≈2.8s，失败红高优先。
- 折叠条 64pt：状态点 + 会话数。

Notch 模型补充：`HaloSession` 增 `turnEnded`、`agentKind`；面板内 list ⇄ detail 导航栈；per-session timeline items `{id, time, tag, lane, content, toolUseId?, agentId?, seen}`；Turn 聚合（elapsed / tokens / context% / still-running / summary / lastUserMessage）。

---

## E. 落地改动

### E.1 Helper（`CLI/Sources/Helper/`, `Common/Sources/Adapters/CodexAdapter.swift`）
- 新增 `AgentDomainReducer` + `SessionStateMachine` / `TurnStateMachine`；输入 hook JSON + transcript/rollout 增量（+ sqlite 元数据），输出 A 层事件；`tool_use_id` 双源去重。
- rollout/transcript 读取从 daemon 搬入 Helper（复用 `CodexRolloutWatcher` 路径解析与 cursor，抽成 Common 库）；cursor 经 IPC 存 daemon（新增 `getCursor/setCursor`）。

### E.2 Daemon（`Common/Sources/Core/SQLiteSessionRepository.swift`, `SessionRepository.swift`, `DaemonRuntime/`）
- schema：`turns(session_id, turn_id, idx, phase, started_at, ended_at, prompt)`、`turn_messages(id, session_id, turn_id, occurred_at, tool_use_id?, agent_id?, kind, payload)`、`session_messages(...)`。
- `SessionReduction` 直接接收 lifecycle/phase；`SessionDetail` 返回 turns + messages；`CodexRolloutWatcher` 退役（feature flag 保留一版）。
- `TimelineProjection`（Common）：A → `[TimelineRow]`，含 SUBAGENT 原地更新、TURN END 追加、FAILED 升级。

### E.3 Mac 主窗口（`SessionDetailPresentation.swift`, `SessionActivityView.swift`, `Design.swift`, `SessionListViewController.swift`）
- 行模型换 `TimelineRow`；Tag chip 三级样式 + 类目色 token 进 `Design.swift`；去掉 status-dot 列；lane strip 三行改读 `lane`。
- 行点击展开详情（复用现有 chevron/折叠机制）；TOOL↔RESULT hover 互相高亮。
- Session 列表：agent 图标支持 Claude —— `claude-ai-icon.svg` 放入 `Resources/`（与 `codex.svg` 同法，参考 commit a314292 / 6c7c1ef 的白底圆角 tile 处理）；`SessionDisplayNames` / agent chip 增加 Claude。

### E.4 Notch（`HaloController.swift`, `HaloModel.swift`, `HaloSettingsView.swift`）
- 按 §D 重做 5B–5E 四态 + 折叠条；复用 `SettingsComponents.swift` / `AppKitComponents.swift` 模式；OpenNook 面板 chrome 不动，只匹配内容 inset。
- 与设计冲突时以现有组件 metric 为准并标注差异（README 要求）。

### E.5 顺序
1. A 层模型 + `TimelineProjection` + 测试 → 2. Helper reducer + rollout 迁入 → 3. daemon schema/IPC → 4. 主窗口 Activity + Tag 分级 + Claude 图标 → 5. Notch 5B–5E → 6. 退役 watcher。

## F. 验证
- Fixture：Codex rollout + hook JSON 序列；Claude transcript（`~/.claude/projects/.../cd28f4d0…jsonl`）→ Helper 输出 A 层消息与 phase 序列符合 A.2；`TimelineProjection` 输出符合 C 表（TOOL/RESULT 各一行同 toolUseId、CONTEXT 合并、TURN END 追加、isError→FAILED）。
- 真实跑一段 Codex 会话：主窗口 5A 几何/色值对照设计稿；USER→TURN END 边界清晰；lane strip 只填所属泳道；权限不出现在列表。
- Notch：5B hover 时间↔归档无位移；5C/5D 卡片随 Turn 开始/结束切换；5E Recent activity 用 dark tag 色；仅 L3 触发展开。

---

## G. 实现记录（2026-08-19）

与上文方案的对应关系及有意偏离：

| 方案 | 实现 | 说明 |
|---|---|---|
| A 层 Session / Turn 模型 | `Transport`：`SessionLifecycle` +`compacting`；`TurnPhase` +`compacting`（`subagentRunning` 曾短暂存在，2026-08-25 并入 `executing`）；新增 `TurnSummary`/`TurnOutcome`；`SessionDetail.turns`；`AgentKind` +`claude`/`claudeSubagent` | 增量式扩展，旧数据可解码 |
| A 层消息 | `TimelinePayload` 新增 `.reasoning` `.context(scope: session|turn)` `.sessionMarker` `.turnEnd`；`ToolTimelinePayload.toolUseID` | 保留 `.modelConfiguration`/`.usageMetrics`/`.internalContext` 作为元数据或历史数据 |
| daemon 表 `turns / turn_messages / session_messages` | 只新增 `turns` 表；消息仍存 `timeline`（Session 级消息 `turnID == nil`） | 语义相同、迁移更小 |
| A→B `TimelineProjection` | `Transport/TimelineProjection.swift`（`TimelineTag`/`TimelineLane`/`TimelineAttentionLevel`/`TimelineRow`） | 含 SUBAGENT 原地更新、TURN END 追加并把末条 ASSISTANT 标为 succeeded、RESULT 从配对 TOOL 补名、同时间戳排序 marker→context→user→其他 |
| `.modelConfiguration` → 行 | **不显示为行**（页头 Model 区仍读取）；行级配置另走 `.config` | Claude transcript 每条 assistant 都会重发模型配置，作为行会落在 Turn 中间 |
| Helper `AgentDomainReducer` | `HelperIngestPipeline` + `CodexAdapter`/`ClaudeAdapter`（`Common/Adapters`），`HelperDaemonPort` 抽象 | 状态机体现在两个 Adapter 的映射表 + daemon `SessionReduction`/`TurnReduction` |
| rollout 迁入 Helper、cursor 走 IPC | 已实现；`ingest_batch`、`get/save_rollout_cursor` | daemon `CodexRolloutWatcher` 保留，`LUMI_ROLLOUT_WATCHER=1` 开启，默认关 |
| 权限不进 Timeline | `PermissionRequest` 只置 lifecycle/phase | — |
| 删除 Session 后的行为 | 被动事件仍被拒绝；新 prompt / SessionStart 使其复活 | 原来永久隐藏会吞掉恢复会话的 hook |
| 主窗口 5A | `SessionActivityPresentation` 包裹 `TimelineRow`；`TimelineTagChip`（L1/L2/L3）；lane strip 三行 User/Model/Exec；无状态点列；无 Turn 头行；TOOL↔RESULT hover 配对高亮；Claude 图标 `Resources/claude.svg` 白底圆角 tile | 行文案为英文（"Session started · resume"），与 App 其余文案一致 |
| helper 退出码 | 永远 0 | exit 2 会阻断 Agent 的工具调用 |
| Notch 5B–5E | `HaloModel`：`HaloSession`（agent、turn 聚合、tokens/context、recentRows）+ `route`（list / detail / turnStarted / turnEnded）；`HaloController`：5B 列表（halo 状态点、agent chip、hover 时间↔归档、子代理肘线、页脚 N of M）、5C/5D 卡片（自动 6s 回列表）、5E 详情（返回、状态 pill、三 tile、Recent activity 用 dark tag chip、Show in App / Jump to Agent）；折叠条不变 | 通知只来自新增 L3 行：USER→5D、TURN END→5C、FAILED/ABORTED→高优先 toast；Notch 与主窗口共用 `TimelineProjection` |
| Claude hook 安装器 | `AgentHookConfigInstaller`（通用 merge/uninstall/命令刷新）+ `CodexHookInstaller`（`~/.codex/hooks.json`, `--agent codex`）+ `ClaudeHookInstaller`（`~/.claude/settings.json` 的 `hooks` 键，`--agent claude`，19 个事件，timeout 5s）；Settings > Agents 增加 Claude Code 卡片 | 只移除含 `Spark` 的 handler；其他 settings 键与他人 hook 保留 |
| daemon watcher | 保留代码，`LUMI_ROLLOUT_WATCHER=1` 开启，默认关 | 未安装 hook 的 Agent 不再被自动发现 |
| 临时会话（2026-08-19 追加） | `SessionSummary.firstTurnAt` / `isProvisional`；Mac 列表、Relay 快照、daemon health 过滤临时会话；Claude `SessionEnd` 时 helper 判定 `never used` → `AgentIngressEvent.disposition = .discard`，仓库删除 + 墓碑并照常发布 | 有效性边界 = 第一个 Turn。桌面 App 的 `withTemporaryQuery` 探测进程（SessionStart→SessionEnd 2 s、无 turn/transcript）从不可见、结束即丢弃；env 签名不作判据（探测进程同样带 `CLAUDE_CODE_ENTRYPOINT=claude-desktop`，见 research）。同时：`apply` 先去重再判墓碑复活（重放的 SessionStart 不再解除墓碑）；客户端 `replaceSnapshot` 清空本地墓碑；Mac 事件队列有序；migration v3 清掉历史空会话 |
| 三端一致性修订（2026-08-22 追加） | `SessionHierarchy`（Core）统一父子分组：任意深度的子 Agent 并入最上层被列出的祖先，Mac 主窗口 / Notch / iPhone 子项都按 running → waiting → failed → done；`TransportCoding` 日期带毫秒；删除 `AgentKind` / `SessionLifecycle` / `TurnPhase` / `IPCOperation` / `RelayFrameKind` / `RemotePayloadKind` / `TimelinePayload` 的 `.unknown` 兜底（未知值 = 解码错误）；daemon 本地流新增 `summary` 帧，iPhone 的已查看经它到达 Mac 窗口与 Notch；`reingest_session` 跳过已删除子 Agent并把重建结果推给 iPhone；iOS 隐藏会话规则统一为“daemon 的副本更新（`updatedAt` 更新）才回来”，并继续写入缓存；iOS `cache.apply` 进入写队列 | 之前 iOS / Notch 丢孙级子 Agent、同秒记录按 id 排序、iPhone 已查看不回 Mac、隐藏会话三条路径规则不一 |
| 列表 ↔ 泳道分类对齐（2026-08-22 追加） | `TimelineTag` 新增 `.turnFailed`（FAILED chip、Model 泳道、L3）：`turnEnd(.failed)` 与非中断 `.error` 映射到它，`.failed` 只剩工具失败（Exec）；删除 `SessionActivityPresentation.appearsInLaneStrip`——每行一格，Mac `ActivityScrollMap` 行列按下标配对，TOOL / `total_tokens_reminder` 进 strip；iPhone lane strip 改读 `TimelineLane.allCases`（User / Model / Exec，与 Mac 同名同序，不再是 Input / Tools / Model）；Mac Category 过滤 Model 组加 "Turn failure"，Exec 组 "Failure" 改名 "Tool failure"；Notch 只对 `.turnFailed` / `.aborted` 推失败 toast | 之前 Turn 级失败画在 Exec 泳道、列表有行而 strip 无格、两端泳道中间一行含义相反；SUBAGENT 维持 Model（iOS 交接稿的 tools 泳道不采用）；TOOL 维持 L1（本稿 B.1 原写 L2，以设计系统 §4.3 与代码为准）|
| 工具失败降为 L2（2026-08-24 追加） | `TimelineTag.failed.level` L3 → L2：chip 变红色淡底（`DesignHue.red` L2 tint）、泳道格变 `red.s200`，Importance 面板里归入 Process 档；`.turnFailed` / `.aborted` 维持 L3 | 失败与中断的区分：工具失败是过程（回合还在继续），回合失败 / 中断是阶段终点；设计档案 `DESIGN SYSTEM.html` 未改（只在同步设计文件时更新），下次同步时把工具 FAILED 行改为 L2 淡底 |
| CONTEXT 合并为单档 + 新增 CONFIG（2026-08-24 追加） | `ContextTimelinePayload` 去掉 `scope`（上下文一律 turn 级、不再合并 ×N，`CONTEXT ×N` chip 退役）；新增 `.config`/`ConfigTimelinePayload` → `CONFIG` tag（L1、横跨，Category 面板 Session 组）：Claude `ConfigChange`/`CwdChanged` 与 transcript attachment 里的运行模式（`auto_mode`/`plan_mode`/`plan_mode_exit`/`command_permissions`）、Codex `turn_context`/`thread_settings_applied` 归它；`InstructionsLoaded`、`base_instructions`、attachment、reminder 等仍是 `CONTEXT`（User 泳道）；同时 Claude 停装 `UserPromptExpansion` hook（18 个事件） | 配置是"Agent 怎么跑"，上下文是"模型读什么"；`internalContext` 不再按 kind 提升为会话级 |
| 泳道跟随过滤（2026-08-24 追加） | Mac `SessionActivityView` 把过滤后的行同时喂给列表和 `SessionActivityTimeline`，`ActivityScrollMap` 只按可见行建（不再有 0 高度行），`ActivityScrollLink.rowsDidRefilter()` 让下一次列表几何报告把 strip 对齐到顶部行；iPhone 无 Activity 过滤，strip 本就每行一格 | 之前 Mac strip 始终画全量、被过滤掉的行保留格子但 0 高度，点格子落到“最近可见行”；现在列表有几行 strip 就有几格，两端一致 |

验证：Transport 16 / Common 25 / CLI 10 / Mac 21 项测试通过；`xcodebuild` LumiMac 与 IOSFeature 构建成功；用真实 Claude transcript 走 daemon+helper 端到端得到 2 个 Turn、11 对 TOOL/RESULT、标题来自 `custom-title`。
