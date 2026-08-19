# Session Timeline 重构方案（Helper 领域化 + 消息分级 + Notch 调整）

## Context

现状：`agent-status-helper` 只做 hook JSON → `AgentIngressEvent` 薄转换；rollout 由 daemon 内 `CodexRolloutWatcher` 另起一路；`TimelineItem` 扁平事件流，UI 只按 `category` 着色，无 Turn 概念、无每行状态、无消息分级。

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
       | subagentRunning | compacting | stopped | failed | aborted
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

Turn phase 转换集中在 Helper 的 `TurnStateMachine`：`submitted →thinking→ toolRunning ⇄ thinking → responding → stopped`；`permissionRequested→waitingPermission`；`subagentDelegated→subagentRunning`；`turnFailed/aborted→failed/aborted`。

### A.3 传输
`AgentIngressEvent` 携带 `sessionLifecycle? / turnPhase? / sessionMessage? / turnMessage?`（替代直接塞 `timelineItem`）。daemon 存 `sessions / turns / turn_messages / session_messages`。**Timeline 行由 `TimelineProjection`（Common，纯函数）按 §C 投影，不落库。**

---

## B. Timeline 领域（UI 消费）

```
TimelineRow { id, sessionId, occurredAt, tag: Tag, level: L1|L2|L3, lane: Lane?, content, status: ItemStatus,
              toolUseId?, agentId?, seen: Bool, expandable: Bool }
enum Lane { user, model, exec }        // nil = 横跨（SESSION / COMPACT / CONTEXT ×N）
enum ItemStatus { info, started, running, succeeded, failed, cancelled }
```

### B.1 Tag 分类表（设计稿 taxonomy，最终版）

| Tag | Level | Lane | 说明 |
|---|---|---|---|
| `SESSION` | L1 | 横跨 | 会话开始 / 会话结束 |
| `COMPACT` | L1 | 横跨 | 上下文压缩 |
| `CONTEXT ×N` | L1 | 横跨 | 会话上下文（相邻多条合并，可展开） |
| `USER` | **L3** | User | 用户输入 —— **Turn 起点** |
| `CONTEXT` | L1 | User | 本轮注入上下文 |
| `REASONING` | L1 | Model | 思考（灰色，不再紫色） |
| `ASSISTANT` | L2 | Model | 助手回复 |
| `PLAN` | L2 | Model | 计划 |
| `SUBAGENT` | L2 | Model | 子代理（同 agentId 原地更新，不加行） |
| `TURN END` | **L3** | Model | Turn 结束 —— **Turn 终点**（新增） |
| `TOOL` | L2 | Exec | 工具调用（≡ PreToolUse / assistant `tool_use`） |
| `RESULT` | L2 | Exec | 工具结果（≡ PostToolUse / user `tool_result`），与 TOOL 用 toolUseId 配对高亮，**不合并** |
| `FAILED` / `ABORTED` | **L3** | Exec / Model | 失败 / 中断 |

**无 Turn 头行、无 phase pill**：Turn 边界由 `USER` → `TURN END` 读出。**不进 Timeline**：权限、usage。

### B.2 视觉（设计稿 5A + 设计系统）
- 行高 40，hairline `rgba(0,0,0,.05)`；列 time 56 + tag 82 + content，gap 12；无 status-dot 列；行尾 chevron 7×11。
- L1：无底无环，灰字 `rgb(138,138,138)`（dark `.38`）。L2：类目色 14–16% 底 + 深色字 + `.5px` 环。L3：实底 + 白字。色值见 README 类目表。
- Session 标记行：同几何，无灰底，L1 样式；详情在展开态。
- **Lane strip**（列表上方）：三行 User/Model/Exec，每个 item 一个 13×13 r3 单元，gap 4，只在所属泳道填色（横跨类不填/灰 `#C9CDD6`）。
- 升级规则：`RESULT.isError` → `FAILED`（L2→L3，推 Notch）；`turnStopped` → 追加 `TURN END`，末条 ASSISTANT 标绿；同屏最多 3 条 L3（先降级已 seen）；L1 不升级；仅 L3 触发 Notch。

---

## C. A → B 映射

| Agent 领域 | TimelineRow |
|---|---|
| SessionStarted / SessionEnded | `SESSION`(横跨, info) |
| CompactionBegan+Ended | `COMPACT`(横跨, running→succeeded) |
| SessionContext ×N | `CONTEXT ×N`(横跨, 合并) |
| userPrompt | `USER`(User, L3) |
| turnContext | `CONTEXT`(User, L1) |
| assistantThinking | `REASONING`(Model, L1) |
| assistantText | `ASSISTANT`(Model, L2)；turnStopped 后末条 status=succeeded |
| assistantPlan | `PLAN`(Model, L2) |
| subagentDelegated / Returned | `SUBAGENT`(Model, L2) 同 agentId 原地更新 |
| toolCall | `TOOL`(Exec, L2, started) |
| toolResult ok / isError | `RESULT`(Exec, L2, succeeded) / `FAILED`(Exec, L3) |
| turnStopped | 追加 `TURN END`(Model, L3) |
| turnFailed / turnAborted | `FAILED` / `ABORTED`(Model, L3) |
| permission* / usage | 不映射（页头 / Notch 指标） |

规则：block 类型决定泳道，不是消息角色。

---

## D. Notch（设计稿 5B–5E，OpenNook）

- **5B 列表**：520pt；行 grid `8px 1fr auto`；状态点 8px + 3px halo（running `#4C9BFF` / waiting `#F0A030` / idle `.34`）；右侧 agent chip（Codex / Claude）+ 28px 时间/归档共用槽，hover 时间原地换成归档按钮（仅 `turnEnded` 行）；子代理行 6px 点 + 肘形导线；页脚 "N of M sessions"。
- **5C Turn 结束卡**：标题 + "Turn complete" `#4ED96C` + 耗时；指标 pill（tokens / context / still running）；摘要 6 行；"Jump to Agent" 白底按钮。
- **5D Turn 开始卡**：`Turn started` `#9DC7FF` + 计时；副标题 `Codex · model · cwd`；USER 消息块。
- **5E 会话详情**：返回 pill、状态 pill、三指标 tile、**Recent activity**（22 高行，60px tag chip 用 dark 色值）、"Show in App"/"Jump to Agent"。
- Notch 通知：仅 L3 入 `NookActivityQueue`，dwell ≈2.8s，orange 高优先。
- 折叠条 64pt：状态点 + 会话数。

Notch 模型补充：`AgentStatusNookSession` 增 `turnEnded`、`agentKind`；面板内 list ⇄ detail 导航栈；per-session timeline items `{id, time, tag, lane, content, toolUseId?, agentId?, seen}`；Turn 聚合（elapsed / tokens / context% / still-running / summary / lastUserMessage）。

---

## E. 落地改动

### E.1 Helper（`CLI/Sources/AgentStatusHelper/`, `Common/Sources/AgentStatusCodex/CodexAdapter.swift`）
- 新增 `AgentDomainReducer` + `SessionStateMachine` / `TurnStateMachine`；输入 hook JSON + transcript/rollout 增量（+ sqlite 元数据），输出 A 层事件；`tool_use_id` 双源去重。
- rollout/transcript 读取从 daemon 搬入 Helper（复用 `CodexRolloutWatcher` 路径解析与 cursor，抽成 Common 库）；cursor 经 IPC 存 daemon（新增 `getCursor/setCursor`）。

### E.2 Daemon（`Common/Sources/AgentStatusCore/SQLiteSessionRepository.swift`, `SessionRepository.swift`, `DaemonRuntime/`）
- schema：`turns(session_id, turn_id, idx, phase, started_at, ended_at, prompt)`、`turn_messages(id, session_id, turn_id, occurred_at, tool_use_id?, agent_id?, kind, payload)`、`session_messages(...)`。
- `SessionReduction` 直接接收 lifecycle/phase；`SessionDetail` 返回 turns + messages；`CodexRolloutWatcher` 退役（feature flag 保留一版）。
- `TimelineProjection`（Common）：A → `[TimelineRow]`，含合并 CONTEXT ×N、SUBAGENT 原地更新、TURN END 追加、FAILED 升级。

### E.3 Mac 主窗口（`SessionDetailPresentation.swift`, `SessionActivityView.swift`, `AgentStatusDesign.swift`, `SessionListViewController.swift`）
- 行模型换 `TimelineRow`；Tag chip 三级样式 + 类目色 token 进 `AgentStatusDesign.swift`；去掉 status-dot 列；lane strip 三行改读 `lane`。
- 行点击展开详情（复用现有 chevron/折叠机制）；TOOL↔RESULT hover 互相高亮。
- Session 列表：agent 图标支持 Claude —— `claude-ai-icon.svg` 放入 `Resources/`（与 `codex.svg` 同法，参考 commit a314292 / 6c7c1ef 的白底圆角 tile 处理）；`SessionDisplayNames` / agent chip 增加 Claude。

### E.4 Notch（`AgentStatusNookController.swift`, `AgentStatusNookModel.swift`, `AgentStatusNookSettingsView.swift`）
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
| A 层 Session / Turn 模型 | `AgentStatusTransport`：`SessionLifecycle` +`compacting`；`TurnPhase` +`subagentRunning`/`compacting`；新增 `TurnSummary`/`TurnOutcome`；`SessionDetail.turns`；`AgentKind` +`claude`/`claudeSubagent` | 增量式扩展，旧数据可解码 |
| A 层消息 | `TimelinePayload` 新增 `.reasoning` `.context(scope: session|turn)` `.sessionMarker` `.turnEnd`；`ToolTimelinePayload.toolUseID` | 保留 `.modelConfiguration`/`.usageMetrics`/`.internalContext` 作为元数据或历史数据 |
| daemon 表 `turns / turn_messages / session_messages` | 只新增 `turns` 表；消息仍存 `timeline`（Session 级消息 `turnID == nil`） | 语义相同、迁移更小 |
| A→B `TimelineProjection` | `Transport/TimelineProjection.swift`（`TimelineTag`/`TimelineLane`/`TimelineAttentionLevel`/`TimelineRow`） | 含 CONTEXT ×N 合并、SUBAGENT 原地更新、TURN END 追加并标绿末条 ASSISTANT、RESULT 从配对 TOOL 补名、同时间戳排序 marker→context→user→其他 |
| `.modelConfiguration` → CONTEXT ×N | **不显示为行**（页头 Model 区仍读取） | Claude transcript 每条 assistant 都会重发模型配置，作为行会落在 Turn 中间 |
| Helper `AgentDomainReducer` | `HelperIngestPipeline` + `CodexAdapter`/`ClaudeAdapter`（`Common/AgentStatusCodex`），`HelperDaemonPort` 抽象 | 状态机体现在两个 Adapter 的映射表 + daemon `SessionReduction`/`TurnReduction` |
| rollout 迁入 Helper、cursor 走 IPC | 已实现；`ingest_batch`、`get/save_rollout_cursor` | daemon `CodexRolloutWatcher` 保留，`AGENT_STATUS_ROLLOUT_WATCHER=1` 开启，默认关 |
| 权限不进 Timeline | `PermissionRequest` 只置 lifecycle/phase | — |
| 删除 Session 后的行为 | 被动事件仍被拒绝；新 prompt / SessionStart 使其复活 | 原来永久隐藏会吞掉恢复会话的 hook |
| 主窗口 5A | `SessionActivityPresentation` 包裹 `TimelineRow`；`TimelineTagChip`（L1/L2/L3）；lane strip 三行 User/Model/Exec；无状态点列；无 Turn 头行；TOOL↔RESULT hover 配对高亮；Claude 图标 `Resources/claude.svg` 白底圆角 tile | 行文案为英文（"Session started · resume"），与 App 其余文案一致 |
| helper 退出码 | 永远 0 | exit 2 会阻断 Agent 的工具调用 |
| Notch 5B–5E | `AgentStatusNookModel`：`AgentStatusNookSession`（agent、turn 聚合、tokens/context、recentRows）+ `route`（list / detail / turnStarted / turnEnded）；`AgentStatusNookController`：5B 列表（halo 状态点、agent chip、hover 时间↔归档、子代理肘线、页脚 N of M）、5C/5D 卡片（自动 6s 回列表）、5E 详情（返回、状态 pill、三 tile、Recent activity 用 dark tag chip、Show in App / Jump to Agent）；折叠条不变 | 通知只来自新增 L3 行：USER→5D、TURN END→5C、FAILED/ABORTED→高优先 toast；Notch 与主窗口共用 `TimelineProjection` |
| Claude hook 安装器 | `AgentHookConfigInstaller`（通用 merge/uninstall/命令刷新）+ `CodexHookInstaller`（`~/.codex/hooks.json`, `--agent codex`）+ `ClaudeHookInstaller`（`~/.claude/settings.json` 的 `hooks` 键，`--agent claude`，19 个事件，timeout 5s）；Settings > Agents 增加 Claude Code 卡片 | 只移除含 `agent-status-helper` 的 handler；其他 settings 键与他人 hook 保留 |
| daemon watcher | 保留代码，`AGENT_STATUS_ROLLOUT_WATCHER=1` 开启，默认关 | 未安装 hook 的 Agent 不再被自动发现 |
| 临时会话（2026-08-19 追加） | `SessionSummary.firstTurnAt` / `isProvisional`；Mac 列表、Relay 快照、daemon health 过滤临时会话；Claude `SessionEnd` 时 helper 判定 `never used` → `AgentIngressEvent.disposition = .discard`，仓库删除 + 墓碑并照常发布 | 有效性边界 = 第一个 Turn。桌面 App 的 `withTemporaryQuery` 探测进程（SessionStart→SessionEnd 2 s、无 turn/transcript）从不可见、结束即丢弃；env 签名不作判据（探测进程同样带 `CLAUDE_CODE_ENTRYPOINT=claude-desktop`，见 research）。同时：`apply` 先去重再判墓碑复活（重放的 SessionStart 不再解除墓碑）；客户端 `replaceSnapshot` 清空本地墓碑；Mac 事件队列有序；migration v3 清掉历史空会话 |

验证：Transport 16 / Common 25 / CLI 10 / Mac 21 项测试通过；`xcodebuild` AgentStatusMac 与 AgentStatusIOSFeature 构建成功；用真实 Claude transcript 走 daemon+helper 端到端得到 2 个 Turn、11 对 TOOL/RESULT、标题来自 `custom-title`。
