# Mac 套餐用量

> 验证状态：开发预览。daemon 轮询、Settings 开关、Notch 用量簇与设置预览已在本机核对，Claude（Keychain 登录）与 Codex 都拿到过真实答复。

Lumi for Mac 能把 Claude Code 与 Codex 的订阅额度用了多少放进 Notch：展开顶栏左侧一眼看到 Session / Weekly / Fable 限额的百分比。数据由 daemon 用 Agent 自己的登录去问服务商，Lumi 不换发、不写回任何登录。

## 模块概览

- **入口**：“Settings > Plan”开账号开关；“Settings > Notch”的 Usage 段决定 Notch 显示什么。
- **前置条件**：daemon 运行中；对应 Agent 在这台 Mac 上登录过（Claude Code 的 Keychain 项或 `~/.claude/.credentials.json`，Codex 的 `~/.codex/auth.json`）。
- **主要结果**：Notch 展开态顶栏左侧出现用量簇；Settings 行里有邮箱、套餐与状态。
- **只读边界**：只读 Agent 保存的登录，不换发 token、不写回；不进 iPhone。
- **相关文档**：[Mac 会话查看](mac-session-view.md)（Notch）、[数据流](../data-flows.md#套餐用量)。

## 主流程

1. 打开“Settings > Plan”，找到 Claude Code 或 Codex 行，打开行尾开关。
   - 系统反馈：开关短暂禁用，daemon 立刻问一次；行的副标题变成 `邮箱 · 套餐`（如 `dev@example.com · Pro 20x`）。没登录的行开关不可用，副标题写 `Not signed in · …`；在 Agent 里登录后回到这一页即可用，不会弹任何系统提示。
   - 规则引用：[PLN-R-001](#pln-r-001-只读-agent-的登录文件不换发不写回)、[PLN-R-002](#pln-r-002-每-5-分钟刷新失败保留上一次)。
2. 打开“Settings > Notch”，在 Usage 段打开 `Show plan usage`。
   - 系统反馈：下方 Preview 黑条立即显示将出现在 Notch 里的那一串；没有账号打开开关时显示样例数字并标 `sample`。
   - 规则引用：[PLN-R-003](#pln-r-003-notch-顶栏按设置显示可显示的账号)。
3. 在同一段里选 `Agents`（Switch on click / Show both）、`Percent`（Used / Remaining），逐个开关五个数字。
   - 系统反馈：预览随每次改动即时变化。
4. 展开 Notch。
   - 系统反馈：顶栏左侧的 Lumi 标记换成用量簇：Claude 图标 · Session % · Weekly % · Fable % · Codex 图标 · Weekly %。悬停看每个窗口多久后重置；`Switch on click` 时点一下簇换另一家。
   - 规则引用：[PLN-R-003](#pln-r-003-notch-顶栏按设置显示可显示的账号)、[PLN-R-004](#pln-r-004-90-以上用警示色)。

完成信号：Notch 顶栏的数字与“Settings > Notch”预览一致；“Settings > Plan”的行没有告警文案。

## 页面结构

- **Settings > Plan · Usage 段**：一张卡两行——20pt Agent 图标、名字（`Claude Code` / `Codex`）、登录来源（`Keychain · ~/.claude/.credentials.json`、`~/.codex/auth.json`）、副标题（`邮箱 · 套餐`，或状态文案）、行尾开关；脚注说明只读保存的登录、每 5 分钟刷新。daemon 不可达时下方多一段 Daemon 错误。
- **Settings > Notch · Usage 段**：`Show plan usage` 开关；`Agents` 分段（Switch on click · Show both）；`Percent` 分段（Used · Remaining）；五行开关——Claude Code · Session limit、Claude Code · Weekly limit、Claude Code · Fable limit、Codex · Weekly limit、Codex · Session limit（默认只有最后一个关）；`Preview` 黑条。
- **Notch 顶栏左侧**：每家一组「图标 + 百分比串」，组内 4pt 间距、组间 10pt；没有当前数字的账号图标变暗、数字显示 `–`。

## 规则

### PLN-R-001 只读 Agent 的登录文件，不换发不写回

- 条件：daemon 每次刷新，以及用户打开开关时。
- 行为：重读 `~/.claude/.credentials.json`，没有文件就读 Claude Code 的钥匙串项（邮箱来自 `~/.claude.json`），以及 `~/.codex/auth.json`（邮箱来自其中的登录信息）；用里面的 access token 问服务商，Claude 以 Claude Code 的身份、Codex 以 OpenUsage 的身份。
- 结果：在 Agent 里重新登录后，下一次刷新自动用新登录；Lumi 从不换发 token、从不改这些文件。
- 限制或例外：Claude Desktop 自己的钥匙串项不读；文件和钥匙串都没有就是 `Not signed in`；钥匙串读不出来时显示 `Unavailable · …`。保存的 token 已过期时停在 `Saved sign-in expired`，直到用户在 Agent 里重新登录；只有 API key 的 Codex 登录没有套餐用量。

### PLN-R-002 每 5 分钟刷新，失败保留上一次

- 条件：账号开关打开。
- 行为：daemon 每 5 分钟问一次；打开开关时立即问；Mac 每分钟取一次 daemon 的快照。
- 结果：数字最多滞后 5 分钟；服务商答 429 时按它给的等待时间暂停并显示 `Rate limited · retry in …`，答 401 / 403 显示 `Sign-in rejected by the service`，其他失败显示 `Unavailable · 原因`。
- 限制或例外：失败时上一次的百分比留在 Notch 里，只有登录文件消失才清空；关掉开关立即清空。

### PLN-R-003 Notch 顶栏按设置显示可显示的账号

- 条件：“Settings > Notch”的 `Show plan usage` 打开。
- 行为：只列打开了开关且勾选了至少一个数字的账号；`Show both` 两家并排（Claude 在前），`Switch on click` 一次一家、点击换另一家并记住；`Remaining` 显示 100 减已用；未勾选的数字不占位，服务商没报的窗口显示 `–`。
- 结果：没有任何可显示的账号时顶栏保持原来的 Lumi 标记。
- 限制或例外：设置只在这台 Mac 上；预览在没有可显示账号时用样例数字。

### PLN-R-004 90% 以上用警示色

- 条件：某个窗口已用 ≥ 90%（剩余 ≤ 10%）。
- 行为：该数字换成警示色，其余不变。
- 结果：快用完的窗口一眼可见。
- 限制或例外：阈值固定，不可配置；不弹通知。

## 空状态与故障

- **Not signed in · …**：这台 Mac 上没有该 Agent 的登录；在 Agent 里登录一次、回到这一页，开关就可用。
- **Saved sign-in expired**：登录文件里的 token 过期了；在 Agent 里重新登录。
- **Sign-in rejected by the service**：服务商不认这份登录；重新登录。
- **Rate limited · retry in …**：服务商限流；等倒计时结束自动重试。
- **Unavailable · …**：网络或服务商故障；上一次的数字仍在。
- **Daemon 不可达**：Plan 页开关禁用并显示错误；参照[恢复路径](../friction-points.md)。

## 相关文档

- [功能全景](../index.md)
- [数据流](../data-flows.md)
- [套餐用量设计](../../design/plan-usage.md)
