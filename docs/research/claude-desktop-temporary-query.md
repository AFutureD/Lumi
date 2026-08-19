# Claude 桌面 App 的临时 CLI 探测进程（temporary query）

> 用途：解释 agent-status 里成批出现的 `Claude Session · completed` 空会话从哪来，以及为什么用「第一个 Turn」而不是环境变量来判定会话有效。调查日期 2026-08-19，Claude Desktop（含 claude-code 2.1.234）。

## 现象

daemon DB 里成对出现的空会话：`agent=claude`、`lifecycle=completed`、0 turn、timeline 只有 `session_started(startup)` + `session_ended(other)` 两条 marker，`startedAt`/`lastActivityAt` 相差 2 s，`~/.claude/projects/` 下没有对应 transcript。`workspace` 常为 `/Users/<me>`（home），偶尔是项目目录。

## 它是什么

Claude 桌面 App 用 `withTemporaryQuery(cwd, fn)` 拉起一次性 CLI 进程加载「斜杠命令 / agent 列表」（`getCommandsFromTemporaryQuery` / `getAgentsFromTemporaryQuery`）。app.asar 里的关键片段：

```js
async withTemporaryQuery(e, n) {
  let a = resolve(e),
      [{sessionEnv: o}, {path: s}, c] = await Promise.all([
        this.getBaseQueryConfig(), this.resolveBinaryPathFresh(), this.getRemotePluginPathsForHost()]);
  let {trusted: u} = await this.workspaceTrustMemo.get(a, ...),
      f = await this.prepareSpawnCwd(u ? a : this.homePath),        // 未信任目录 → 回落到 home
      h = query({prompt: m, options: {
        cwd: f, settingSources: u ? ['user','project','local'] : ['user'],   // 会加载 ~/.claude/settings.json → hook 照常触发
        env: o,
        canUseTool: async () => ({behavior: 'deny', message: 'Config loading only'}),
        mcpServers: {}, strictMcpConfig: true }});
  try { return m.done(), await n(h) } finally { h.return() }               // prompt 流建好即结束 → CLI 起来吐完 init 就退出 ≈ 2 s
}
```

进程 argv：`claude --output-format stream-json --verbose --input-format stream-json --permission-prompt-tool stdio …`，**没有** `--model` / `--effort`（真会话有）。每个进程照样分配新的 `session_id` 并触发 `SessionStart` / `SessionEnd`。

## 何时触发

- `main.log`：`[CCD] Resolved CLI identity changed (… → required_version:2.1.234)` 之后 1 s 内三连（`invalidateCommandsMemoOnCliVersionChange()` 让 commands/agents memo 失效，几个 cwd 并发重新探测）。
- App 启动时同样三连；之后每次 `setFocusedSession` 零星各 1 个。

## 复现

```sh
claude --output-format stream-json --verbose --input-format stream-json --permission-prompt-tool stdio < /dev/null
```

立刻多出一个 `~/.claude/session-env/<uuid>/`（空目录）和一条空会话。

## 环境变量：不能作为判据

一开始的推断是"探测进程没有 `CLAUDE_CODE_ENTRYPOINT=claude-desktop`"。**读 app.asar 后修正**：

- `getBaseQueryConfig().sessionEnv = {...await Qs({oauthToken, apiHost, shellPath, …}), DISABLE_MICROCOMPACT: '1', NODE_USE_SYSTEM_CA: '1'}`；
- `Qs`（内部名 `tln`）里 `Object.assign(env, WH(e))`，而 `WH` 固定写入 `CLAUDE_CODE_ENTRYPOINT: type === '3p' ? 'claude-desktop-3p' : 'claude-desktop'`；
- 所以探测进程**同样**带 `CLAUDE_CODE_ENTRYPOINT=claude-desktop`。
- 真会话走 `buildSessionEnv(sessionId, baseSessionEnv, …)`，多写 `CLAUDE_CODE_HOST_SESSION_ID=<local_…>`（以及 org/account/email 等）；temporary query 直接用 base env，没有这一步。

运行时验证（`ps -Eww` 轮询抓到 4 个探测进程，14:18–14:37）：环境里有 `CLAUDE_CODE_ENTRYPOINT=claude-desktop`、`CLAUDE_AGENT_SDK_VERSION=0.3.234`，**没有** `CLAUDE_CODE_HOST_SESSION_ID`；argv 为 `--output-format stream-json --verbose --input-format stream-json --permission-prompt-tool stdio --setting-sources … --strict-mcp-config --permission-mode default`，无 `--model`。真会话（例如本调查所在的会话）两者都有。

差异只剩 `CLAUDE_CODE_HOST_SESSION_ID` 是否存在，这是桌面 App 内部实现细节，且不覆盖其他来源的空会话（终端 `claude` 启动后直接退出）。因此 agent-status 不用 env 判定。

## agent-status 的处理（见 docs/design/agent-hook.md「临时会话」）

- **有效性边界 = 第一个 Turn**。第一个 Turn 之前的会话是临时会话（`SessionSummary.isProvisional`），UI 不显示。
- **判定时机 = SessionEnd**（SessionStart 时真会话同样还没有 transcript）：Claude `SessionEnd` 且 transcript 未落盘且 daemon 仍记为临时 → helper 产出 `disposition: .discard`，删除 + 墓碑。
- 历史空会话由 migration `agent-status-v3-sweep-empty-claude-sessions` 一次性清掉。
