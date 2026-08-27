# Changelog

功能全景见 [FEAT.md](docs/FEAT.md)。  

## [Unreleased]

### 会话查看

- [Lumi for Mac] - Session 列表改为两行式：状态点前置 + 标题 + 行尾相对时间，副标题显示 Agent 图标与 CLI 上报的 `model · reasoning effort` 原值。
- [Lumi for Mac] - Subagent 折叠成副标题右端的叠放状态点（最多五个，数量与分档进悬停提示），展开后一个一行、带各自的相对时间，且可单独选中查看自己的详情；Running / Waiting / Failed 默认展开、Completed 默认收起。
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

[Unreleased]: https://github.com/AFutureD/Lumi/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/AFutureD/Lumi/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/AFutureD/Lumi/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/AFutureD/Lumi/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/AFutureD/Lumi/releases/tag/v0.1.0