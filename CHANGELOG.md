# Changelog

功能全景见 [FEAT.md](docs/FEAT.md)。  

## [Unreleased]

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