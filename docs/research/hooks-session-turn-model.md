# Session / Turn 抽象整理（Claude Code Hooks vs Codex Hooks）

> 来源：https://code.claude.com/docs/en/hooks 、 https://learn.chatgpt.com/docs/hooks
> 用途：Lumi 的数据模型/状态机设计参考。不涉及代码。

---

## 0. 一句话结论

- 两端都是三层结构：**Session（会话）→ Turn（一次对话）→ ToolCall（工具调用）**，外加可嵌套的 **Subagent**。
- Codex 是 Claude 的**子集**：Codex 的 11 个事件在 Claude 里全部存在且字段同名（`session_id / cwd / hook_event_name / permission_mode / tool_name / tool_input / tool_use_id / agent_id / agent_type / last_assistant_message / trigger / source / reason`）。
- 关键差异：Codex 每个 turn 级事件带显式 **`turn_id`**；Claude 用 **`prompt_id`**（UUID）+ `turn_number` 表达同一概念。两端只是命名不同。
- Claude 独有大量"环境/异步"事件（配置变化、目录变化、worktree、通知、任务、compaction 后、错误终止…），Codex 只覆盖核心主线。

---

## 1. Session 有哪些数据

### 1.1 两端一致（公共抽象）

| 抽象字段 | Claude 字段 | Codex 字段 | 说明 |
|---|---|---|---|
| sessionId | `session_id` | `session_id` | 主键 |
| transcriptPath | `transcript_path` | `transcript_path` (可 null) | 对话记录 JSONL |
| cwd | `cwd` | `cwd` | 工作目录（Claude 可中途变，见 CwdChanged） |
| permissionMode | `permission_mode` | `permission_mode` | Claude: default/plan/acceptEdits/auto/dontAsk/bypassPermissions；Codex 少 `auto` |
| model | `model`（仅 SessionStart，可能缺） | `model`（每个 payload 都有） | 模型 slug |
| startSource | SessionStart `source` | SessionStart `source` | startup / resume / clear / compact；Claude 多一个 `fork` |
| endReason | SessionEnd `reason` | SessionEnd `reason` | Claude: clear/resume/logout/prompt_input_exit/other；Codex 目前只有 `other` |
| 所属 agent | `agent_id` + `agent_type`（子代理时才有） | `agent_id` + `agent_type` | 用于区分主 session 与 subagent |

### 1.2 Claude 独有的 Session 级数据

- `effort.level`（low/medium/high/xhigh/max）— 每个 payload 都带
- `Setup.trigger`（init / maintenance）— 会话前置阶段
- 配置来源：`ConfigChange.source`（user_settings/project_settings/local_settings/policy_settings/skills）+ `file_path`
- 指令加载：`InstructionsLoaded.load_reason`（session_start/nested_traversal/path_glob_match/include/compact）+ `file_path`
- 目录集合：`CwdChanged.old_cwd/new_cwd`、`DirectoryAdded.directory_path/how_added`
- Worktree：`WorktreeCreate.worktree_path/reason`、`WorktreeRemove.worktree_path`
- 监听文件：`FileChanged.file_path/change_type`
- Task 列表：`TaskCreated.task_id/task_title/task_description`、`TaskCompleted.task_id/task_title`
- Team：`TeammateIdle.teammate_name/reason`

### 1.3 Codex 独有的 Session 级数据

- 无（`turn_id` 属于 Turn 级）。

---

## 2. Session 有哪些阶段

### 2.1 两端一致的状态机

```
[Setup*] → SessionStart(source) → { Turn ×N } → SessionEnd(reason)
                                       ↑
                        Compaction (PreCompact→PostCompact) 可在 turn 间/turn 中插入
                        Subagent 生命周期嵌套在 Turn 内
```

| 阶段 | Claude 事件 | Codex 事件 | 是否可阻断 |
|---|---|---|---|
| 启动/恢复 | `SessionStart` | `SessionStart` | 否（Codex 可注入 additionalContext；Claude 忽略输出） |
| 活跃（循环 Turn） | 见 §4 | 见 §4 | — |
| 压缩 | `PreCompact` → `PostCompact` | `PreCompact` → `PostCompact` | Claude PreCompact 可阻断 |
| 结束 | `SessionEnd` | `SessionEnd` | 否（advisory） |

建议 Session 状态枚举：`starting → idle ⇄ running(turn) → compacting → ended`；另有 `subagent` 作为父子关系而不是状态。

### 2.2 Claude 独有阶段/事件

- 前置：`Setup`（--init / --maintenance）
- 异步任意时刻：`Notification`、`ConfigChange`、`InstructionsLoaded`、`CwdChanged`、`DirectoryAdded`、`FileChanged`、`WorktreeCreate/Remove`
- 团队：`TeammateIdle`
- 显示流：`MessageDisplay`（文本流式展示时）

### 2.3 Codex 独有阶段

- 无。

---

## 3. 一次 Turn 有哪些数据

### 3.1 两端一致

| 抽象字段 | Claude | Codex |
|---|---|---|
| turnId | `prompt_id`（UUID，v2.1.196+） | `turn_id` |
| turnNumber | `UserPromptSubmit.turn_number` | —（无序号，只有 id） |
| prompt | `UserPromptSubmit.prompt` | `UserPromptSubmit.prompt` |
| toolCalls[] | `tool_name / tool_input / tool_use_id / tool_result` | `tool_name / tool_input / tool_use_id / tool_response` |
| permissionRequests[] | `PermissionRequest.tool_name/tool_input/permission_reason` | `PermissionRequest.tool_name/tool_input(.description)` |
| subagents[] | `SubagentStart/Stop.agent_id/agent_type/last_assistant_message` | 同 + `agent_transcript_path` + `stop_hook_active` |
| finalMessage | `Stop.last_assistant_message` | `Stop.last_assistant_message` |
| compaction | `PreCompact/PostCompact.trigger`(manual/auto) | 同 |

### 3.2 Claude 独有

- 失败终止：`StopFailure.error_type`（rate_limit/overloaded/authentication_failed/oauth_org_not_allowed/billing_error/invalid_request/model_not_found/server_error/max_output_tokens/unknown）+ `error_message`
- 工具失败：`PostToolUseFailure.error`
- 权限拒绝：`PermissionDenied.denial_reason`
- 命令展开：`UserPromptExpansion.command_name/command_input/expanded_prompt`
- 批次：`PostToolBatch`（并行工具批次结束）
- MCP 交互：`Elicitation.server_name/elicitation_id/prompt`、`ElicitationResult.user_response`
- 通知类型：`Notification.notification_type`（permission_prompt/idle_prompt/agent_needs_input/agent_completed/…）+ `message`
- 每 payload：`effort.level`

### 3.3 Codex 独有

- `stop_hook_active`（Stop / SubagentStop：表示当前正处于 stop-hook 触发的续跑中，防死循环）
- `agent_transcript_path`（SubagentStop）
- `PreToolUse` 输出 `updatedInput`（可改写工具入参）

---

## 4. 一次 Turn 有哪些阶段

### 4.1 两端一致的状态机

```
UserPromptSubmit(prompt)
   │
   ▼
┌─ Agentic Loop ─────────────────────────────────────┐
│  model 思考/输出                                    │
│  ├─ PreToolUse(tool) ──► [PermissionRequest] ──► 执行 ──► PostToolUse
│  ├─ SubagentStart ──► (子代理自己的 loop) ──► SubagentStop
│  └─ (可穿插) PreCompact → PostCompact
└────────────────────────────────────────────────────┘
   │
   ▼
Stop(last_assistant_message)   ← 可被 hook 阻断 → 回到 loop 继续
```

| 阶段 | Claude | Codex | 可阻断/改写 |
|---|---|---|---|
| 提交 | `UserPromptSubmit` | `UserPromptSubmit` | 两端都可 block + 注入 context |
| 工具前 | `PreToolUse` | `PreToolUse` | 两端 allow/deny；Codex 可 `updatedInput`；Claude 多 `escalate` |
| 授权 | `PermissionRequest` | `PermissionRequest` | 两端 allow/deny（Claude 多 escalate） |
| 工具后 | `PostToolUse` | `PostToolUse` | Claude 不可阻断；Codex 可 `decision: block` |
| 子代理 | `SubagentStart/Stop` | `SubagentStart/Stop` | Stop 两端可阻断 |
| 结束 | `Stop` | `Stop` | 两端可阻断（强制继续） |

建议 Turn 状态枚举：`submitted → thinking ⇄ tool_running ⇄ waiting_permission → (compacting) → stopped | failed`（子代理执行归入 tool_running/executing，不再单列状态）

### 4.2 Claude 独有阶段

- `UserPromptExpansion`（slash command 展开，位于 Submit 之后、loop 之前）
- `PermissionDenied`（auto 模式自动拒绝）
- `PostToolUseFailure`（与 PostToolUse 二选一）
- `PostToolBatch`（一批并行工具结束、下一次 model 调用前，可中断 loop）
- `Elicitation` / `ElicitationResult`（MCP 请求用户输入，嵌在工具调用内）
- `StopFailure`（与 Stop 二选一：API 错误终止）
- `TaskCreated` / `TaskCompleted`（Turn 内的 TaskCreate 工具副作用）
- `Notification`（`agent_needs_input` / `agent_completed` / `idle_prompt` 等——**对 Lumi 最有价值的"需要人介入"信号**）
- `MessageDisplay`（文本流式中）

### 4.3 Codex 独有阶段

- 无新增阶段；只是 Stop/SubagentStop 多了 `stop_hook_active` 标记。

---

## 5. 统一抽象（给 Lumi 用的模型草案）

```
Session {
  id, provider(claude|codex), model?, cwd, permissionMode,
  transcriptPath?, startSource, endReason?,
  parent?: {sessionId, agentId, agentType}   // subagent 归属
  state: starting | idle | running | compacting | ended
  turns: Turn[]
}

Turn {
  id (claude.prompt_id | codex.turn_id), number?, prompt,
  state: submitted | thinking | tool_running | waiting_permission
       | waiting_user_input(elicitation, claude)
       | compacting | stopped | failed(claude StopFailure)
       // 子代理执行不单列状态：SubagentStart 视作一次 tool_running/executing
  toolCalls: ToolCall[]        // tool_use_id 主键
  subagents: Session[]         // agent_id
  finalMessage?, error?
}

ToolCall {
  id(tool_use_id), name, input, result|error?,
  permission?: {requested, decision: allow|deny|escalate, reason}
}
```

### 事件 → 状态映射（两端通用）

| 事件 | 更新 |
|---|---|
| SessionStart | 建 Session，state=idle |
| UserPromptSubmit | 建 Turn，state=submitted→thinking |
| PreToolUse | Turn.state=tool_running，新增 ToolCall |
| PermissionRequest | Turn.state=waiting_permission |
| PostToolUse / PostToolUseFailure | ToolCall 完成，Turn.state=thinking |
| SubagentStart / SubagentStop | 子 Session 建/结，Turn.state=executing/thinking |
| PreCompact / PostCompact | state=compacting / 恢复 |
| Stop | Turn.state=stopped，Session.state=idle |
| StopFailure (Claude) | Turn.state=failed |
| Notification(agent_needs_input) (Claude) | 高亮"需要人" |
| SessionEnd | Session.state=ended |

---

## 6. 备注 / 差异速查

- **ID 命名**：Claude `prompt_id` ≈ Codex `turn_id`；两端 `tool_use_id`、`agent_id` 同名。
- **model 位置**：Codex 每条 payload 都有；Claude 只在 SessionStart 且非保证——需要缓存到 Session。
- **permission_mode 集合**：Claude 多 `auto`；相应多 `PermissionDenied` 事件。
- **PostToolUse 可否阻断**：Claude 否 / Codex 可 block。
- **PreToolUse 改参**：仅 Codex（`updatedInput`）。
- **失败/异常**：Claude 有 `StopFailure`、`PostToolUseFailure`；Codex 无对应事件（失败只能从 tool_response 内容推断）。
- **hook 类型**：Claude 支持 command/http/mcp_tool/prompt；Codex 文档只列 command（支持 `async`, `additionalContextLimit`）。
- **配置位置**：Claude `~/.claude/settings.json`, `.claude/settings.json`, `.claude/settings.local.json`；Codex `~/.codex/hooks.json|config.toml`, `<repo>/.codex/hooks.json|config.toml`。
