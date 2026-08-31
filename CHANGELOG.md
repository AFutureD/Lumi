# Changelog

功能全景见 [FEAT.md](docs/FEAT.md)。  

## [Unreleased]

### 数据存储

- 本机数据布局按归属分目录：daemon（Lumen）的数据库与 relay state 移入 `Application Support/Lumi/Lumen/`，Mac App 的同步缓存移至 `Lumi/Storage/cache.sqlite`；`daemon.sock` 与 `bin/Spark` 留在根目录不变。升级后首次启动自动完成一次性迁移，无需重新同步。`LUMI_SUPPORT_DIRECTORY` 现在同时移动 socket 默认路径（此前只移数据库与 relay state）。

### 会话过滤

- [Lumi for Mac] - “Settings > Agents”新增 Filters：一组规则把幽灵 Session（测试、`~/tmp` 一次性调用等）挡在所有界面之外——命中的新 Session 照常入库，但不出现在主窗口列表和 Notch，不同步到 iPhone，也不发推送。规则内条件取与、规则间取或；字段有 Agent、Application、User message（首条用户消息）、Folder（含子目录）；规则可就地编辑、拖拽排序、停用与删除。判定在 Session 首条用户消息到达时做一次并永久冻结，改规则不追溯已有 Session；规则存在 daemon，Clear history 不清规则。斜杠命令、Raft 这类从不开回合的会话同样参与判定（User message 规则按记录原文匹配，`<command-name>` 记录用 contains 才能命中命令名）。
- [Lumi for Mac] - “Settings > Agents”的 Hook 卡片合并为一个 Integrations 列表：一行一个 Agent（图标、名称、配置路径、状态副标题），行尾单个按钮表示动作——Install / Remove（红字）/ Trust（仅 Codex 未信任时，蓝色实心，Remove 移入右键菜单）。

### 会话查看

- [Lumi for Mac] - Session 列表支持多选与更多删除入口：Shift 连选、⌘ 点选增减、⌘⇧ 并入范围、⌘A 全选、Shift + 上下方向键扩缩范围（多选只在 Session 级，Subagent 行不参与）；删除可从右键菜单（Delete Session / Delete N Sessions）或 ⌘⌫ 触发，与工具栏按钮共用同一确认框——多选时写明条数，Delete 改为红色破坏性按钮且回车落在 Cancel 上；删除后选中自动落到相邻的下一条，多选时工具栏标题显示“N Sessions Selected”。
- 由 AaaS 应用（Agentic AI as a Service，如 Paseo、Raft）启动的 Session 标题改用该应用自己的标题：Paseo 显示其 agent 标题（含改名跟进），Raft 显示 agent 名（如 Fable）；不再停留在默认的“Claude Session / Codex Session”。
- 每个 Session 现在记住承载它的 AaaS 应用（ChatGPT、Codex、Claude Desktop、Claude Code、Paseo、Raft）与所在终端，标题由该应用决定；修复 Paseo/Raft 的 Session 结束后标题被换回 Agent 原生线程名的问题。
- Session 详情 Inspector（Mac 与 iPhone 的 Info）Overview 新增 Application 项，显示承载该会话的 AaaS 应用；早于归属记录的旧 Session 显示 Not available。
- Activity 中用户键入的斜杠命令（Claude 会话）保持为用户消息，内容按记录原文显示（含 `<command-name>` 等标签，不再解析成键入形式），不作为上下文记录归类；命令的本地输出仍是上下文。
- Raft daemon 自动发起的工具型会话（如它的用量轮询）现在也归属 Raft：环境只带 `SLOCK_HOME` 时即判定为 Raft，无 agent id 与标题；此前这类会话被归为 Claude Code。

### 会话采集

- 回合聚合（Turn）不再单独落库：`turns` 表删除，回合信息改为读取时从时间线推导——时间线成为唯一事实源，三端（daemon / Mac / iPhone）数据库随迁移一并清理。对用户可见的行为不变。
- 修复中断的 Codex 会话永久卡在 Running 的问题：中断把终态写进 rollout 但不触发任何 hook，现在 daemon 内常驻的 rollout watcher 在数秒内补读并把会话正确收口为 Interrupted。Claude 侧的 transcript watcher 同样常驻，两者不再有环境变量开关。
- Hook 采集链路重构为「helper 只转发、daemon 全量归并」：Spark 不再解析 hook 内容，把原始 stdin、agent 类型与白名单环境变量组成一帧 `ingest_hook` 交给 daemon；解析、transcript / rollout 增量读取、归并、AaaS 标题识别全部收进 daemon（游标随之由 daemon 单一持有）。helper.log 新增 `hook_frame` 帧日志（含 payload 的 JSON 渲染、不含原始字节；渲染仅入日志不进帧），摄取详情改记在 daemon.log 的 `hook_ingested`。
- 采集链路更皮实：注册表与二进制版本偏差带来的未知 hook 事件降级为「只读增量」而不再整帧丢弃；daemon 离线期间积累的超大 rollout/transcript 断档交给串行回填整段补读，不再只吃尾部；修复大断档续读时游标越界导致整本重放的偏移计算。
- Helper 环境变量诊断日志保留：`LUMI_LOG_ENV=1`（或 `--verbose`）时每次 hook 记录一行 env 键名列表（只记键名，不记值）。
- Helper 转发的环境白名单新增 `TERM_PROGRAM`、`__CFBundleIdentifier`、`CLAUDE_CODE_ENTRYPOINT`（AaaS 归属判定用，均无敏感信息）；daemon 的 `hook_ingested` 日志键 `wrapper/wrapper_agent` 改为 `aaas/aaas_agent/aaas_term`。
- daemon（Lumen）整体迁移到 swift-service-lifecycle + 结构化并发：收到 SIGTERM/SIGINT（如 Mac App 重装 daemon、launchd unregister）时按序优雅关停——Relay 先断开、watcher 停扫、IPC 连接排空、回填队列最后清空——以退出码 0 干净退出并删除 socket 文件，不再被直接杀死；期间入队的补读不再丢失。
- [Lumi for Mac] - 修复 Codex hook 授权链路的线程优先级反转（Thread Performance Checker 告警）：app-server 应答读取移到专属高优先级线程，等待也不再占用 Swift Concurrency 线程池；codex 进程意外退出时授权立即失败返回，不再干等 15 秒超时。

### 配对与同步

- [Lumi for Mac] - 配对码到期后不再自动换新：卡片停在 Expired（二维码收起、旧码变灰），点 New code 或重新进入“iPhone”页才出新码。配对页开着但没人配对时，不再每 5 分钟向 Relay 申请一次新码。

### 官网

- Download 按钮改为直接下载最新版 dmg：链接统一走 `/download`，由官网现场解析 GitHub 最新 release 后跳转；解析失败时退回 releases 页面。

## [0.1.4] - 2026-08-27

### 官网

- 上线落地页 lumi.huanan.app：单页十节（Hero 推送卡片、三大功能、Privacy boundary、三步上手、FAQ），含移动端单列布局；以 Cloudflare Worker 静态资产部署。

### 会话查看

- [Lumi for Mac] - Session 列表改为两行式：状态点前置 + 标题 + 行尾相对时间，副标题显示 Agent 图标与 CLI 上报的 `model · reasoning effort` 原值。
- [Lumi for Mac] - Session 列表改按创建时间倒序排列，顺序不再随后续活动跳动；行尾仍显示最近更新的相对时间。
- [Lumi for Mac] - Subagent 折叠成副标题右端的叠放状态点（最多五个，数量与分档进悬停提示），展开后一个一行、按启动先后排列、行尾显示各自的持续时间（运行中每秒走动，结束后停在最终用时），且可单独选中查看自己的详情；Running / Waiting / Failed 默认展开、Completed 默认收起。
- [Lumi for Mac] - 列表选中改为满宽中性灰底（Subagent 行为圆角灰底），新增悬停底色；状态词与生命周期文字移入状态点的悬停提示。
- 列表相对时间口径统一为 0s / 12s / 4m / 2h / 12d：不足一秒显示 0s，不再出现 now。
- [Lumi for Mac] - 关闭主窗口后 Dock 图标随之隐藏（App 继续驻留，Notch 与同步照常运行）；从 Notch 打开 Session / 设置或再次启动 App 时，窗口与 Dock 图标一起恢复。
- [Lumi for Mac] - 在 Notch 归档带 Subagent 的 Session 时，整组子 Agent（含更深层）随父级一起从列表和计数消失，不再升格为独立顶层行；父级收到新请求时整组一起回来。

### Daemon

- [Lumi for Mac] - 已注册的 daemon 起不来时（如注册指向的安装包被重编译或删除），App 启动约 10 秒后自动重装一次并恢复连接，不再无限报 Connection refused。

### 推送提醒

- [Lumi for iPhone] - 修复点按推送提醒时 App 立刻闪退、看起来像"没有打开"的问题；现在点提醒会直接落在对应 Session 的详情页，App 未启动、在后台或已打开都一样。
- 推送提醒只发给这台 Mac 点过 Match（身份已核对）的 iPhone；Paired iPhones 里显示 Unverified 的设备不再收到含 Session 标题的提醒，与 Session 内容同一条信任边界。

### 系统要求

- [Lumi for iPhone] - 最低支持版本提升到 iOS 26。

## [0.1.3] - 2026-08-26

### 会话查看

- [Lumi for Mac] - Activity 保留完整的工具调用与工具结果内容，不再截断。
- [Lumi for Mac] - 修复刷新时 Session 内容被截断的问题。

### 会话采集

- 重做 Claude 回合边界判定：以内容驱动（human 输入开启、终态 stop_reason 收束），不再依赖 hook 时序。

### 推送提醒

- Session 回合结束、失败或中断时，通过 APNs 发送系统通知到 iPhone。

## [0.1.2] - 2026-08-25

### 发布流水线

- 发布合并为单一 workflow，包含 macOS、iOS 与 Relay 三个任务。
- TestFlight 上传使用持久化的开发证书，不再每次重新生成。

## [0.1.1] - 2026-08-25

### 会话采集

- Codex：映射 item_completed 事件，完善回合归属。
- Codex 事件通道仲裁重构，移除 subagent phase 机制。

### 应用图标

- Mac 与 iPhone 图标更换为矢量 spark 图案。

## [0.1.0] - 2026-08-25

首个公开版本。

### 会话查看

- [Lumi for Mac] - Session 列表、Activity 时间线（L1/L2/L3 密度切换）、子 Agent 层级、Liquid Glass 界面。
- [Halo] - 常驻状态展示，支持自定义设置与响应式细节。
- [Lumi for iPhone] - 查看 Session 状态与 Activity。

### 会话采集

- 采集并归纳 Claude Code 与 Codex 的会话数据。

### 配对与同步

- Mac 与 iPhone 之间的同步通道，支持配对码与 Numeric Comparison 配对。

### 软件更新

- Sparkle 稳定更新通道，支持自动检查。

### 发布流水线

- 由 tag 驱动的发布流水线。

[Unreleased]: https://github.com/AFutureD/Lumi/compare/v0.1.4...HEAD
[0.1.4]: https://github.com/AFutureD/Lumi/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/AFutureD/Lumi/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/AFutureD/Lumi/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/AFutureD/Lumi/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/AFutureD/Lumi/releases/tag/v0.1.0