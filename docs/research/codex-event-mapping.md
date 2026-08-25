# Codex 事件 → Lumi 映射（hooks + rollout JSONL）

> 来源：实测本机 `~/.codex/sessions/`（621 个 rollout 文件，CLI 0.45 → 0.149.0-alpha）
> 与 hooks 文档 https://learn.chatgpt.com/docs/hooks 。
> 第 1、2 章是对 Codex 数据本身的观察，不含 Lumi 代码逻辑；
> 第 3 章起才是 Lumi 的映射与状态规则。
> 更新：2026-08-25——三项决定：`subagent_running` 阶段退役并入 `executing`（§4）；
> 消息类 `response_item` 全部丢弃（§3.2）；新增 `item_completed` 映射与
> 通道优先级仲裁（§3.3）。

---

## 0. 一句话结论

Codex 对外有两条数据面：hook 事件（11 个生命周期钩子，实时、轻量）和
rollout JSONL（`~/.codex/sessions/`，全量、含消息正文）。Lumi 以 rollout
为消息正文的唯一来源，hook 只负责"何时读"与状态断言；两者共同驱动
session lifecycle 与 turn phase。

---

## 1. Hook 事件（文档面）

`~/.codex/hooks.json` 注册的命令会在下列时机被调用，事件 JSON 从 stdin 传入。
公共字段：`session_id`、`cwd`、`hook_event_name`、`transcript_path`，turn 级事件带 `turn_id`。

| 事件 | 时机 | 专有字段 |
|---|---|---|
| SessionStart | 会话开始（startup / resume / clear / compact） | `source`、`model`、`permission_mode` |
| UserPromptSubmit | 用户提交 prompt | `prompt` |
| PreToolUse | 工具执行前 | `tool_name`、`tool_use_id`、`tool_input` |
| PermissionRequest | 需要人工批准时 | `tool_name`、`tool_input(.description)` |
| PostToolUse | 工具执行后 | 同上 + `tool_response` |
| SubagentStart / SubagentStop | 子代理启动 / 结束 | `agent_id`、`agent_type`、`permission_mode` |
| PreCompact / PostCompact | 压缩前 / 后 | `trigger`（manual / auto） |
| Stop | 一个 turn 完成 | `last_assistant_message`、`stop_hook_active` |
| SessionEnd | 会话关闭或闲置 30 分钟以上 | `reason` |

---

## 2. Rollout JSONL 格式（数据面，实测）

### 2.1 文件与行结构

- 路径：`~/.codex/sessions/YYYY/MM/DD/rollout-<本地时间戳>-<会话UUID>.jsonl`。
- 每行恒为三个键：`{"timestamp": ISO8601, "type": <记录类型>, "payload": {...}}`。
  这一外壳从 2025-10（0.87 前）到 0.149 从未变过；变的是记录类型的集合和 payload 字段。
- 子代理（0.146+ 多代理版本）拥有自己独立的 rollout 文件，靠 `session_meta` 里的
  `thread_source: "subagent"`、`parent_thread_id`、`agent_path`（如
  `/root/docs_review/verify_links`，可多级嵌套）识别归属。

### 2.2 顶层记录类型（7 种）

| type | 含义 | 出现版本 |
|---|---|---|
| `session_meta` | 首行，会话元数据 | 全部 |
| `turn_context` | 每个 turn 开头的运行环境快照 | 全部 |
| `event_msg` | 面向 UI 的状态事件流（见 2.3） | 全部 |
| `response_item` | 模型请求/响应的原始条目（见 2.4） | 全部 |
| `compacted` | 压缩后的替换历史（`replacement_history`） | 0.117+ |
| `world_state` | 环境快照（AGENTS.md、collaboration_mode、environments…） | 0.142+ |
| `inter_agent_communication_metadata` | 代理间通信标记，`{trigger_turn: bool}` | 0.146+ |

### 2.3 `event_msg` 家族（payload.type）

状态与 UI 事件。同一事实往往同时以 `event_msg` 和 `response_item` 两种形态落盘。

Turn 生命周期：

| payload.type | 字段要点 |
|---|---|
| `task_started` | `turn_id`、`model_context_window`、`collaboration_mode_kind` |
| `task_complete` | `turn_id`、`last_agent_message`；0.146+ 增 `started_at`、`completed_at`、`duration_ms`、`time_to_first_token_ms`、偶见 `error` |
| `turn_aborted` | `turn_id`、`reason`（实测只见 `"interrupted"`） |

消息与推理：

| payload.type | 字段要点 |
|---|---|
| `user_message` | `message`、`kind`（实测全部为 null）、可带 `images` |
| `agent_message` | `message`（助手正文全文） |
| `agent_reasoning` | `text`；≤0.115 与 0.146+ 存在，0.117–0.137 缺席（只有 `response_item/reasoning`） |
| `token_count` | `info` + `rate_limits`；每个模型响应后写一条，量最大 |

工具结果（只有 end 落盘，begin 不写入 rollout）：

| payload.type | 字段要点 | 出现版本 |
|---|---|---|
| `exec_command_end` | exit code、输出 | 0.117–0.137（之后执行结果走 `response_item` 输出；0.149 另有 `item_completed(CommandExecution)` 副本） |
| `patch_apply_end` | `call_id`、`changes`、`success`、stdout/stderr | 0.117+ |
| `mcp_tool_call_end` | `call_id`、`invocation`、`duration`、`result`、`read_only_hint` | 0.117+ |
| `view_image_tool_call` | 图片路径 | 0.117–0.137 |
| `web_search_end` / `image_generation_end` | query / 结果 | 0.117+ |
| `dynamic_tool_call_request` / `_response` | 动态工具 | 偶见 |

会话级杂项：

| payload.type | 说明 |
|---|---|
| `context_compacted` | 与顶层 `compacted` 记录成对出现 |
| `thread_settings_applied` | 0.142+，完整 thread 设置（模型、approval_policy、collaboration_mode 及其整段 developer_instructions） |
| `thread_rolled_back` / `thread_name_updated` / `thread_goal_updated` | 线程回滚 / 改名 / 改目标 |
| `item_completed` | 0.147+ 的统一"条目完成"信封（0.147/0.148 只装 Plan，0.149 起承载全部内容），`item.type` ∈ AgentMessage、UserMessage、Reasoning、CommandExecution（含 exit_code、duration、aggregated_output）、FileChange、McpToolCall、DynamicToolCall、Plan、SubAgentActivity、CollabAgentToolCall、Extension、ImageView、ContextCompaction |
| `sub_agent_activity` | 0.146+，`agent_thread_id`、`agent_path`、`kind`（实测只有三个值：`started`、`interacted`、`interrupted`） |

### 2.4 `response_item` 家族（payload.type）

模型 API 层的原始条目，字段贴近 OpenAI Responses API：

| payload.type | 字段要点 |
|---|---|
| `message` | `role`（user / assistant / developer）+ `content[]`（input_text / output_text）。developer 是注入指令；user 里混有环境上下文（`<...>` 标签、`# AGENTS.md` 前缀） |
| `reasoning` | `summary[]` + `encrypted_content`（正文加密，读不到；明文靠 `agent_reasoning`） |
| `function_call` / `function_call_output` | `name`（实测主要是 `exec_command`、`write_stdin`）、`arguments`、`call_id` / `output` |
| `custom_tool_call` / `custom_tool_call_output` | `name`（实测主要是 `exec`、`apply_patch`） |
| `web_search_call` / `tool_search_call` / `image_generation_call` | 内置工具调用 |
| `agent_message` | 0.146+ 多代理：带 `author`、`recipient` 的代理间消息 |

### 2.5 版本演进速查

| 版本带 | 特征 |
|---|---|
| ≤ 0.115 | 只有基础集：session_meta / turn_context / event_msg（消息+task+token）/ response_item |
| 0.117 – 0.137 | 增工具 end 事件（exec/patch/mcp/view_image/web_search）、`compacted`、`tool_search`；`agent_reasoning` 消失 |
| 0.142 – 0.145 | 增 `world_state`、`thread_settings_applied`；session_meta 扩容（git、context_window、model_provider…） |
| 0.146 – 0.148（多代理过渡） | 增 `sub_agent_activity`、`inter_agent_communication_metadata`、带 author/recipient 的 `response_item/agent_message`、`item_completed`（此阶段只装 Plan）；`agent_reasoning` 回归；子代理独立 rollout 文件 |
| 0.149+（通道切换） | 内容类 `event_msg`（消息、推理、子代理、mcp/patch/web/compaction 结果）全部消失，并入 `item_completed`；`event_msg` 只剩 5 种：`task_started` / `task_complete` / `turn_aborted` / `token_count` / `thread_settings_applied`；顶层记录与 `response_item` 工具通道保留 |

同一事实常有多通道副本，且组合随版本变化：0.148 及以前，助手消息 =
`event_msg/agent_message` + `response_item/message`；0.149 起 =
`item_completed(AgentMessage)` + `response_item/message`；命令执行在 0.149
同时落 `response_item` 调用/输出对与 `item_completed(CommandExecution)`，
且两者 id 体系不同（`call_…` vs `exec-<uuid>`），无法配对。消费方必须按
事实家族选定通道，见 §3.3 的优先级仲裁。

---

## 3. Lumi 侧：通道与消费规则

- hook 通道：`hooks.json` → `Spark --agent codex`（stdin 收 JSON）→ Unix socket → daemon。
- rollout 通道：每次 hook 触发时，helper 先按 `session_id` 定位 rollout 文件、
  从上次 cursor 增量读到文件尾，再 reduce hook 本身，一批发给 daemon。
- 抑制规则：rollout 可读时（`richSourceAvailable`），hook 不再产生任何消息/工具
  Timeline 行——只产生生命周期断言与 marker。消息正文的唯一来源是 rollout。
- 消息分类：adapter 产出 `TimelinePayload`（message / reasoning / tool / plan /
  subagent / context / config / sessionMarker / turnEnd / modelConfiguration /
  usageMetrics…），`TimelineProjection` 再投影成带 lane 的行标签
  （USER、ASSISTANT、REASONING、TOOL、RESULT、FAILED、SUBAGENT、PLAN、
  CONTEXT、TURN END、ABORTED…）。`modelConfiguration` 与 `usageMetrics`
  不成行，只喂页头元数据。

### 3.1 Hook 事件映射

| hook | lifecycle | phase | timeline（无 rollout 时才产消息行） |
|---|---|---|---|
| SessionStart | starting | idle | sessionMarker(started) |
| UserPromptSubmit | running | thinking | message(user) |
| PreToolUse | running | executing | tool(started) |
| PostToolUse | running | thinking | tool(succeeded / failed) |
| PermissionRequest | waitingForInput | waitingForApproval | 无（只标记等人） |
| SubagentStart | running | executing | subagent(started) |
| SubagentStop | running | thinking | subagent(completed) |
| Stop | waitingForInput | idle | turnEnd(completed) |
| SessionEnd | completed | idle | sessionMarker(ended) |
| PreCompact | compacting | compacting | sessionMarker(compaction started) |
| PostCompact | running | thinking | sessionMarker(compaction ended) |

### 3.2 Rollout 记录映射

顶层记录：

| 记录 | lifecycle / phase | timeline |
|---|---|---|
| session_meta | starting / idle | sessionMarker + modelConfiguration + context(base_instructions) |
| turn_context | — | modelConfiguration + config |
| world_state、compacted | — | context |
| inter_agent_communication_metadata（trigger_turn=true） | running / thinking | 无 |

`event_msg`：

| payload | lifecycle / phase | timeline 行 |
|---|---|---|
| task_started | running / thinking | 无（开 turn） |
| user_message | running / thinking | USER |
| agent_message | running / responding | ASSISTANT |
| agent_reasoning | running / thinking | REASONING |
| task_complete（无 error） | waitingForInput / idle | TURN END |
| task_complete（有 error） | failed / idle | TURN FAILED |
| turn_aborted | interrupted / idle | ABORTED |
| `*_begin` 类 | running / executing | TOOL（实际 rollout 只落 end，此分支主要为防御） |
| `*_end` 类、view_image | running / thinking | RESULT / FAILED |
| sub_agent_activity | running / executing（kind=started 及未知值）；其余 kind → thinking | SUBAGENT |
| context_compacted | — | CONTEXT |
| thread_settings_applied | — | modelConfiguration + config |
| token_count | — | usageMetrics（不成行） |
| item_completed | 按 §3.3 展开 | 见 §3.3 |
| thread_rolled_back、thread_name_updated 等 | — | 丢弃 |

`response_item`：

| payload | lifecycle / phase | timeline 行 |
|---|---|---|
| custom_tool_call / function_call | running / executing | TOOL；`update_plan` 特判为 PLAN（phase=thinking） |
| 对应 output | running / thinking | RESULT / FAILED（从输出内容判失败） |
| message / reasoning / agent_message | — | 丢弃（2026-08-25 决定，见下） |

消息类 response_item 全部丢弃的决定（2026-08-25）：正文一律以 `event_msg`
通道为准（`user_message` / `agent_message` / `agent_reasoning`）。这意味着
有意放弃三类只存在于 response_item 的内容：developer 注入指令（权限说明、
plan 模式指令、子代理团队角色说明）、带标签的注入上下文
（`<user_instructions>`、`<skill>`、AGENTS.md…），以及多代理通信帧
（NEW_TASK / MESSAGE / FINAL_ANSWER，带 author/recipient）——后者是子代理
任务提示与回报正文的唯一载体，Codex app 也不把它们放进父时间线，而是收进
Subagents 面板。

### 3.3 item_completed 映射与通道优先级仲裁（2026-08-25）

原则：每类"事实"（一条助手消息、一次 MCP 调用…）定义一条候选源优先级链；
同一家族内，一旦更高优先级的源产出过行，更低优先级源的记录整条丢弃
（不产行、也不做状态断言）。仲裁状态（家族 → 已见最高优先级）挂在单次
解析批的 `RolloutReadState` 上；因为每个文件内每个家族实际只有一条通道
在场（见 §2.5），批级状态即足够正确，仲裁只是对假想混合流的防护。

仲裁家族（item 源优先于 event 源，两者从不在同一文件共存）：

| 家族 | 高优先级源 | 低优先级源 |
|---|---|---|
| 助手消息 | item_completed(AgentMessage) | event_msg/agent_message |
| 用户消息 | item_completed(UserMessage) | event_msg/user_message |
| 推理 | item_completed(Reasoning) | event_msg/agent_reasoning |
| 子代理活动 | item_completed(SubAgentActivity) | event_msg/sub_agent_activity |
| MCP 调用 | item_completed(McpToolCall) | event_msg/mcp_tool_call_begin/_end |
| 文件改动 | item_completed(FileChange) | event_msg/patch_apply_begin/_end |
| Web 搜索 | item_completed(Extension) | event_msg/web_search_begin/_end |
| 图片查看 | item_completed(ImageView) | event_msg/view_image_tool_call |

静态丢弃（不进仲裁）的 item 类型：CommandExecution、DynamicToolCall、
CollabAgentToolCall（`response_item` 调用/输出对是唯一执行行来源，
在包括 0.149 的所有版本都在场；两套 id 无法配对，而增量批可能恰好切在
调用与 item 之间，仲裁会产生重复行）；ContextCompaction（顶层 `compacted`
与 `event_msg/context_compacted` 继续负责压缩标记）。若未来版本砍掉
`response_item` 工具通道，再为 CommandExecution 补映射，不预先兜底。

item_completed 各类型的行映射：

| item.type | 行 | lifecycle / phase |
|---|---|---|
| AgentMessage | ASSISTANT（content 文本；phase 字段 commentary/final_answer 不区分） | running / responding |
| UserMessage | USER（并写入 turn prompt） | running / thinking |
| Reasoning | REASONING（取 summary_text，raw_content 常为空） | running / thinking |
| SubAgentActivity | SUBAGENT（与 event 版同逻辑） | started → executing，其余 → thinking |
| McpToolCall | 工具结果行（server/tool 名，status 判成败，duration 为 {secs,nanos}） | running / thinking |
| Extension | 工具结果行（名取 kind，如 web.search） | running / thinking |
| FileChange | 工具结果行（Apply patch 语义，status 判成败） | running / thinking |
| ImageView | 工具结果行 | running / thinking |
| Plan | PLAN 行（完整 markdown 存 explanation） | running / thinking |
| CommandExecution、DynamicToolCall、CollabAgentToolCall、ContextCompaction | 丢弃（理由见上） | — |

行 id 使用 `payload.item.id`（`msg_…` / `rs_…` / `exec-…`），保证增量重读幂等。

### 3.4 状态怎么落到 session / turn 上

- 事件只有在自带 lifecycle/phase 断言、且 `occurredAt ≥ lastActivityAt`
  （状态钟）时才改变 session 的 lifecycle 与 phase；被动 backfill 不动状态。
- turn 的 phase 取事件断言；turnEnd 强制 phase=idle；已关闭的 turn 不再回退。
- 列表颜色由 `SessionStatusTone` 折叠：running 系（含所有进行中 phase）→ 蓝；
  waitingForInput + 非 idle phase（等批准）→ 橙；failed/interrupted → 红。
- 子代理会话身份不靠这些事件，而靠 Codex 自己的 `state_5.sqlite` threads 表
  与 rollout `session_meta`（thread_source=subagent / parent_thread_id）。

---

## 4. 2026-08-25 调整：`subagent_running` 退役

turn phase 枚举去掉 `subagentRunning`，子代理执行视为一种执行中状态：

- SubagentStart（hook，Codex 与 Claude）→ phase `executing`（原 subagentRunning）。
- `sub_agent_activity` kind=started → `executing`；其余 kind → `thinking`。
- SUBAGENT 消息行、橙色 SUBAGENT 标签、`subagentCount` 均不变——变的只是
  turn 阶段（状态点从橙色呼吸变为蓝色呼吸）。
- 持久化迁移：`lumi-v6-retire-subagent-running` 把 sessions / turns 存量
  summary 里的 `"subagent_running"` 重写为 `"executing"`（daemon、Mac 缓存、
  iPhone 缓存共用同一 SQLite 仓库实现，一次迁移覆盖三端）。

---

## 5. 对照：Codex app 自己怎么展示（2026-08-25 实机观察）

ChatGPT 桌面 app（bundle id 就叫 `com.openai.codex`）的 Codex 会话视图：

- 一个 turn 折叠成一行 "Worked for 13m 2s"，展开后按序排：助手叙述段落、
  聚合活动行（"Loaded tools, read files, ran commands, searched the web,
  renamed chat"）、"Ran commands" / "Read files" 行、Plan 卡片。
  对应 rollout 里 `task_started` → `task_complete` 的区间。
- 子代理在父会话里只有两行：`<名字> · started working` 和 `<名字> · finished`
  （对应 `sub_agent_activity` 的 started / 结束），正文放在右侧 Subagents
  面板：列表只分两组 Active · N 与 Done · N，点进去是子代理自己的完整
  会话（对应其独立 rollout 文件）。
- 也就是说 Codex 官方 UI 同样没有"子代理运行中"这一独立 turn 阶段——
  子代理是并行的兄弟会话 + 父会话里的两行标记。与本次
  `subagent_running` → `executing` 的退役方向一致。

## 6. 数据与代码的已知差距（待议）

1. `sub_agent_activity.kind` 实测只有 `started` / `interacted` / `interrupted`，
   而映射表按 `completed` / `stopped` / `failed` / `waiting` 写——后四个从未出现，
   `interacted`、`interrupted` 都掉进 default 被当作 `started`：子代理被打断后
   仍显示"进行中"。建议 `interacted` 维持进行中、`interrupted` 记为结束。
2. `exec_command_begin` 等 begin 分支在 rollout 里不会出现（只有 end 落盘），
   TOOL "started" 行实际由 `response_item/{custom_tool,function}_call` 承担。
3. `thread_rolled_back`（回滚会话历史）、`thread_name_updated`、
   `thread_goal_updated` 未映射；回滚意味着已展示的 Timeline 段可能失效。
4. 压缩信息双通道（顶层 `compacted` + `event_msg/context_compacted`）都映射成
   CONTEXT，0.148 及以前会出两行（`ContextCompaction` item 已静态丢弃，
   0.149 起只剩顶层 `compacted` 一行）。
5. 丢弃 CommandExecution 意味着继续用输出文本启发式判失败，放弃了
   exit_code / duration / aggregated_output 这份更规整的数据。
6. 存量已入库的 0.149 会话不自动补历史行（cursor 在文件尾）；需要时用
   SessionReingester 重建。
