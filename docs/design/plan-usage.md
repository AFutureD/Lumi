# 套餐用量设计

> 基线：2026-09-08 当前仓库实现。套餐用量（Plan usage）是与 Usage（token 花费）平行的第三条链路：daemon 用 Agent 自己的登录去问服务商「各个时间窗口的额度用了多少」，Mac 把百分比放进 Settings 与 Notch 顶栏，iPhone 的 Usage › Plan 经 Relay 看每台 Mac 的同一份快照。开关与「已用 / 剩余」的显示方式存在 daemon 的 settings 表里，两端读同一份。参考实现 [OpenUsage](https://github.com/robinebers/openusage)（MIT，归属见根目录 `NOTICE.md`），只移植了解析与请求，不移植 token 换发。

## 目标与边界

- 回答「这台 Mac 上的 Claude Code / Codex 订阅，Session（5 小时）、Weekly（7 天）、Fable（7 天、单模型）窗口用了百分之几，什么时候重置」。
- 只读 Agent 自己保存的登录；不换发 token、不写回。Claude 先读 `~/.claude/.credentials.json`，没有文件再读 Claude Code 的 Keychain 项（`Claude Code-credentials`）；Claude Desktop 的 `Claude Safe Storage` 不读。登录过期就停在「已过期」，由用户在 Agent 里重新登录。
- 数据模型按多账号设计（`PlanUsageAccountID`），现在每家一个：`claude`、`codex`。
- 消费者：Mac 的 Settings 两处 + Notch 顶栏；iPhone 的 Usage › Plan（只读，不落盘）。daemon 是唯一数据源。

## 数据来源

| Agent | 登录文件 | 身份 | 接口 |
| --- | --- | --- | --- |
| Claude Code | `~/.claude/.credentials.json`（`CLAUDE_CONFIG_DIR` 覆盖根目录），没有文件则用 `/usr/bin/security find-generic-password -w` 读 Keychain 通用密码 `Claude Code-credentials`（设了 `CLAUDE_CONFIG_DIR` 时先试带其 SHA-256 前 8 位后缀的服务名；账户 = 用户名，再试无账户的旧项；值是同一份 JSON，`security` 不肯打印时给的是 hex）。走 `security` 子进程而不是 `SecItemCopyMatching`：Claude Code 就是用这个工具写入的，所以它在该项的 ACL 里，读取永不弹提示、不依赖 Lumen 被授权：`claudeAiOauth.{accessToken, expiresAt(毫秒), subscriptionType, rateLimitTier, scopes}`。macOS 上的 Claude Code 只写 Keychain，所以本机走的是这条 | `~/.claude.json`（或 `$CLAUDE_CONFIG_DIR/.claude.json`）的 `oauthAccount.emailAddress`；套餐 = `subscriptionType` 首字母大写 + `rateLimitTier` 里的 `Nx`（`Max 20x`） | `GET https://api.anthropic.com/api/oauth/usage`，头 `Authorization: Bearer`、`anthropic-beta: oauth-2025-04-20`、`User-Agent: claude-code/2.1.69`（伪装 Claude Code，版本会漂移）；需要 `user:profile` scope |
| Codex | `$CODEX_HOME/auth.json`（默认 `~/.codex/auth.json`）：`tokens.{access_token, account_id, id_token}`；只有 `OPENAI_API_KEY` 的文件没有套餐用量 | `id_token` 的 JWT claims：`email`、`https://api.openai.com/auth.chatgpt_account_id`（`account_id` 缺时用）；过期看 access token 的 `exp`；套餐 = 响应 `plan_type`（`prolite` → `Pro 5x`、`pro` → `Pro 20x`） | `GET https://chatgpt.com/backend-api/wham/usage`，头 `Authorization: Bearer`、`User-Agent: OpenUsage`、`ChatGPT-Account-Id` |

响应到窗口的映射（`Core/PlanUsage`，纯函数）：

- Claude：`five_hour.utilization` → session；`seven_day.utilization` → weekly；`limits[]` 里 `kind == "weekly_scoped"` 的行按 `scope.model.display_name` 成为单模型周窗（`Fable`），取 `percent`；旧字段 `seven_day_sonnet` 非 null 时也成一行（`Sonnet`）。`resets_at` 是 RFC 3339 或数字（<1e10 秒，否则毫秒）。
- Codex：`rate_limit.primary_window` / `secondary_window` 按 `limit_window_seconds` 归类（18000 → session、604800 → weekly），没写时长才按槽位兜底；`used_percent` 缺时读响应头 `x-codex-primary-used-percent` / `x-codex-secondary-used-percent`；`reset_at`（秒）或 `reset_after_seconds`。
- 百分比一律是服务商的「已用」，夹到 0…100；「剩余」由 Mac 算。
- 不解析：extra usage、credits、reset credits、Spark 限额、Claude Desktop 的加密凭据。

## daemon

`PlanUsageService`（`Service`，`Lumen` 里排在 `ModelPriceRefresher` 之后）：

1. 启动时 `Lumen` 从 settings 表读 `plan_usage.enabled.*`（见 [数据、通信与保存设计 › 设置](data-communication-storage.md#设置)；表里还没有开关而 `Lumen/plan-usage-settings.json` 还在时，导入一次再删文件，日志 `settings_imported`），把开关集合交给 `PlanUsageService`，之后每 5 分钟 `refreshAll`。
2. 每个账号每次都重读登录（文件，Claude 再退到 Keychain），先取身份（邮箱、套餐）；都没有或没有 token → `credentialsMissing`，清空 limits；`security` 出错 → `failed` 带它的 stderr，5 分钟内不重试。`plan_usage` 每次被问都做这一步（不联网），所以刚登录立刻可见；刚出现登录的账号顺带拉一次。
3. 未打开开关 → 到此为止（状态回 `ok`）。
4. token 过期（提前 5 分钟）→ `signInExpired`，不发请求。
5. 429 冷却期内 → 跳过。
6. 发请求（10 秒超时）：2xx → `ok` + limits + `fetchedAt`；401 / 403 → `signInRejected`；429 → `rateLimited`，`retryAt = now + retry-after`（缺省 5 分钟）；其他 → `failed` + `statusDetail`。失败一律保留上一次的 limits。

开关改动只走 `set_settings`：daemon 先写表，再 `PlanUsageService.apply` 按集合差异处理——新打开的账号立刻拉一次（回答里已有 limits），新关掉的清空 limits 并把状态回到 `ok`（`credentialsMissing` 除外），没变的不动；每个变化的账号记 `plan_usage_account_switched`。`LUMI_PLAN_USAGE=0` 关掉联网（测试、smoke）。日志 `lifecycle`：`plan_usage_refreshed account= limits= windows=`、`plan_usage_fetch_failed account= http=`、`plan_usage_account_switched`；token、邮箱、响应体永不进日志。

## IPC 与 Relay

- IPC `plan_usage` → `PlanUsageState { accounts: [PlanUsageAccount], generatedAt }`（只读；每次被问都重读登录文件，不联网）。
- IPC `get_settings` / `set_settings { settings }` → `DaemonSettings { planUsage: PlanUsageSettings { enabledAccounts, percentStyle } }`。`set_settings` 整体替换、daemon 只写变化的叶子；`enabledAccounts` 里出现不认识的账号 id → `invalid_settings`。旧的 `set_plan_usage` 已删除。
- Relay `fetch_plan_usage` → `plan_usage { planUsage, settings, requestID }`：与 IPC 同一条路径（先重读登录），并带上 settings，iPhone 只从中取 `percentStyle`。
- `PlanUsageAccount { id, provider, email?, plan?, enabled, status, statusDetail?, retryAt?, limits: [PlanUsageLimit], fetchedAt? }`；`enabled` 是 `settings.planUsage.enabledAccounts` 的显示投影，改它要走 `set_settings`。`PlanUsageLimit { window: session | weekly, model?, usedPercent, resetsAt? }`；`status ∈ ok · credentialsMissing · signInExpired · signInRejected · rateLimited · failed`。
- `PlanUsagePercentStyle ∈ used · remaining`：只影响数字怎么读，条永远画已用。

## Mac

- `PlanUsageModel`（`ApplicationCoordinator` 持有一份）：App 运行期间每 60 秒发 `plan_usage` + `get_settings`（快照相同不重发布），daemon 从不可达变可达时立即重拉；开关与 Percent 都经 `set_settings` 写回并用返回值覆盖，第一次 `get_settings` 成功之前不写（否则会用默认值盖掉 daemon 的开关）。旧的 UserDefaults 键 `Lumi.Notch.PlanUsage.PercentStyle` 在首次成功读取后导入一次并删除。它同时持有 Notch 自己的显示偏好 `HaloPlanUsagePreferences`（UserDefaults `Lumi.Notch.PlanUsage.*`：`AgentsMode`、`Items`（空集 = 关闭）、`SelectedProvider`——只与 Notch 相关，留在 Mac），三处界面共用。
- **Settings › Usage › Plan**（handoff `design_handoff_plan_usage` 第 9 页）：一账号一张卡（`PlanSettingsPanel`）。卡头：22pt 标记（不可用 .55）、名字 13/590、`邮箱 · 套餐` 11、读取来源 11 等宽（`Keychain · ~/.claude/.credentials.json` / `~/.codex/auth.json`）、`updated 1m ago`（开关开着才显示）、开关（`credentialsMissing` 禁用 .4）。卡身：状态 `ok`/`rateLimited` 且有 limits 时一列一个窗口（`SESSION · 5 HOURS` 10/510/.04em、`42%` 17/590 + `used`、6pt 条——条永远画已用，75–89% Orange 500、≥90% Orange 600 且数字 Orange 700、`resets in 2h 10m`）；否则一行 12px 文案（关着 / Fetching / 状态文案 + 说明），不放按钮。刷新时间与倒计时用 `TimelineView` 每 30 秒重算。值在 `DesignSystem.PlanUsage`。
- **Settings › Notch › Usage**（第 7b 页）：顺序 Preview（黑底 32pt 条 + 一句提示，渲染与顶栏同一个视图；没有可显示账号时用样例并标 `sample`；点击切换模式下整条可点）→ `Agents`（Switch on click · Show both）→ `Percent`（Used · Remaining，存 daemon）→ `Show`：一行一家，20pt 标记 + 名字（104 宽）+ 多选药丸（`5-hour` / `Weekly` / `Fable`；只列服务商报了的窗口；选中 = 蓝底 .12 + 勾），账号不可用时整行 .5、名字下写原因。**没有总开关**：`items` 为空即关闭。药丸不用 segmented（多选与上面两行的单选区分开）。
- **Notch 顶栏**（Notch 第 6 页）：`HaloPlanUsagePresentation.cluster(state:choices:now:)` 纯函数决定画什么——只列打开了开关、勾了窗口且服务商报了的账号；一格 = 标签（`5h` / `7d` / `Fable`，10/510 White 42%）+ 数字（11 SF Mono tabular 纯白，最小宽 16），标签↔数字 3、格↔格 6、标记↔首格 6、两家 8；`switchOnClick` 只出选中的那家（不可用时换另一家），整簇是按钮；没报的窗口不占位，某家没有可画的格就整组消失；已用 ≥ 90% 数字用 `InkDark.warning`（Orange D400），没有第二档；tooltip 列每个窗口的「已用/剩余 + 重置倒计时」。返回 `nil`（含一颗都没选）时顶栏保持品牌簇。
- 图标：`AgentIcons.mark`——两家 SVG 标记（`codex.svg`、`claude.svg`，都是透明背景）直接画在黑底上，15pt；浅色界面（Settings 行、Usage 表、Session 列表）用 `AgentIcons.image`，同一标记加白色圆角底块。

## iPhone

Usage Tab 的 Plan 段（设计交接 `design_handoff_ios_usage` 第 8 / 8b 页）：进入 Tab、下拉刷新、可见时每 60 秒向每台配对的 Mac 发 `fetch_plan_usage`，答复只在内存（`PlanUsageSnapshot`）。一台 Mac 一张卡，卡内按账号分小节（Claude Code 在前），每个窗口一行：`SESSION · 5 HOURS` / `WEEKLY · 7 DAYS` / `FABLE · 7 DAYS` → 百分比 → 6pt 条 → `resets in …`。与 Mac 的有意差异：条统一 tint，只有数字在 ≥ 90% 换警示色；没报的窗口不占位。文案（窗口标题、重置倒计时、`updated 2m ago`、状态原因）与 Mac 共用 Core 的 `PlanUsagePresentation`。

Percent 跟随**各台 Mac 自己**的 settings：两台 Mac 设置不同就各显各的，iPhone 不提供这个设置。状态：开关关着 → 卡头 `off` + 一行灰说明；登录过期 / 未登录 / 被拒 / 失败 → 无窗口、标记与名字变淡、一行警示文案；限流 → 保留上一次数字 + 警示文案；Mac 离线 → 数字不撤，注明是多久前的快照；首次加载 → 卡头 + `Loading plan limits…`；没有配对 Mac → `Pair a Mac`。

## 当前限制

- Claude 的 Keychain 读取依赖 `/usr/bin/security` 在该项 ACL 里（Claude Code 用它写入，现状如此）；若 Claude Code 改用别的方式写钥匙串，这条会变成 `failed`。
- 每家一个账号；第二个登录需要再定 id 规则（`claude@xxxx`）。
- 不显示 extra usage / credits；不推送、不告警，只有颜色。
- `User-Agent: claude-code/2.1.69` 是常量，接口开始拒绝时要跟着 Claude Code 版本改。

## 相关文档

- [Usage 设计](usage.md)（token 花费，另一条链路）
- [日志设计](logging.md)
- [Mac 套餐用量（产品文档）](../feat/modules/mac-plan-usage.md)
