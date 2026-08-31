# Changelog

功能全景见 [FEAT.md](docs/FEAT.md)。  

## [Unreleased]

## [0.1.5] - 2026-08-31

### 数据存储

- 本机数据按归属分目录：daemon 数据移入 `Application Support/Lumi/Lumen/`，Mac App 缓存移至 `Lumi/Storage/`；升级后首次启动自动迁移，无需重新同步。

### 会话过滤

- [Lumi for Mac] - “Settings > Agents”新增 Filters：按 Agent、Application、User message、Folder 组合规则过滤幽灵 Session（测试、一次性调用等）——命中的 Session 照常入库，但不进列表、Notch、iPhone 与推送。判定在首条用户消息到达时一次冻结，改规则不追溯已有 Session。
- [Lumi for Mac] - 修复所有文本输入框无法粘贴的问题：主菜单补上标准 Edit 菜单，编辑快捷键全应用生效。
- [Lumi for Mac] - “Settings > Agents”的 Hook 卡片合并为 Integrations 列表：一行一个 Agent，行尾单个按钮表示动作（Install / Remove / Trust）。

### 会话查看

- [Lumi for Mac] - Session 列表支持多选（Shift 连选、⌘ 点选、⌘A 全选）与更多删除入口（右键菜单、⌘⌫）；确认框多选时写明条数，删除后选中落到相邻一条。
- 由 AaaS 应用（Paseo、Raft 等）启动的 Session 改用该应用自己的标题，不再停留在默认的“Claude Session / Codex Session”，会话结束后也不再被换回。
- Session 详情 Inspector 的 Overview 新增 Application 项，显示承载该会话的 AaaS 应用。
- Activity 中用户键入的斜杠命令保持为用户消息，按记录原文显示；命令的本地输出仍是上下文。
- Raft daemon 自动发起的工具型会话（如用量轮询）现在也归属 Raft，不再被归为 Claude Code。

### 会话采集

- 修复中断的 Codex 会话永久卡在 Running 的问题：daemon 常驻的 watcher 在数秒内把会话收口为 Interrupted。
- 回合信息改为从时间线推导，时间线成为唯一事实源；对用户可见的行为不变。
- Hook 采集链路重构为「helper 只转发、daemon 全量归并」，对版本偏差与超大断档更皮实：未知 hook 事件不再整帧丢弃，大断档整段补读、不再只吃尾部或整本重放。
- daemon 迁移到结构化并发，收到退出信号时按序优雅关停，期间入队的补读不再丢失。
- [Lumi for Mac] - 修复 Codex hook 授权链路的线程优先级反转；codex 进程意外退出时授权立即失败返回，不再干等超时。

### 配对与同步

- [Lumi for Mac] - 配对码到期后停在 Expired，不再自动换新；点 New code 或重新进入“iPhone”页才出新码。

### 官网

- Download 按钮改为直接下载最新版 dmg，解析失败时退回 releases 页面。

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

[Unreleased]: https://github.com/AFutureD/Lumi/compare/v0.1.5...HEAD
[0.1.5]: https://github.com/AFutureD/Lumi/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/AFutureD/Lumi/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/AFutureD/Lumi/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/AFutureD/Lumi/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/AFutureD/Lumi/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/AFutureD/Lumi/releases/tag/v0.1.0