# Agent Status 设计文档

从[整体架构设计](system-architecture.md)开始；需要改数据链路时，再读[数据、通信与保存设计](data-communication-storage.md)。

> 基线：2026-08-17 当前仓库实现。本文档描述已经接线的行为，并单独标出预留能力和未完成验收；不把早期计划当作现状。

## 10 分钟阅读路径

1. [整体架构设计](system-architecture.md)：进程、Target、Package、设备关系和权威边界。
2. [数据、通信与保存设计](data-communication-storage.md)：Session 模型、本地 IPC、远程同步、SQLite 和删除语义。
3. [Agent Hook 设计](agent-hook.md)：Hook 安装、helper、rollout watcher、事件归一化和敏感数据边界。
4. [Relay、配对与安全设计](relay-pairing-security.md)：Cloudflare Durable Object、配对、E2EE、序号和撤销。
5. [App 与运行时设计](application-runtime.md)：macOS、Notch、iOS、缓存、刷新和并发边界。
6. [构建、发布与测试设计](build-release-testing.md)：SwiftPM、Xcode、Universal 2、Relay 部署和 CI。

## 设计状态

| 范围 | 当前状态 | 关键边界 |
| --- | --- | --- |
| Agent | v1 仅实现 Codex | `AgentAdapter` 允许以后增加其他 Agent |
| 本地服务 | 已实现 | 每台 Mac 一个 daemon、一个 Unix socket、一个 NIO event loop |
| macOS | 已实现开发预览 | AppKit 主界面；OpenNook/SwiftUI 只负责 Notch 和 Notch 设置内容 |
| iOS | 已实现开发预览 | UIKit，只读；每台 Mac 一个独立通道和 SQLite 文件 |
| Relay | 已部署开发版本 | TypeScript Worker + 每台 Mac 一个 Durable Object |
| 推送 | 未实现 | APNs 不在当前范围 |
| 发布 | 部分验证 | Developer ID、公证和干净机器安装仍待验收 |

## 核心约束

- 一台 Mac 有一个 daemon、一个 macOS App、多个 Agent 和多个 Session。
- Session 不是连接单位。本地事件流和远程通道都复用连接。
- daemon SQLite 是该 Mac 的本地权威数据；Mac 和 iOS 保存同步副本。
- Session 不按时间自动过期，只能由用户删除单条或清空全部。
- Relay 不保存 Session 正文；会保存授权、配对、限流和单调序号等运行元数据。
- 远程业务 payload 在 Mac 端按设备加密，在 iPhone 端解密。
- iPhone 离线时保留 SQLite 副本，但只有收到当前在线快照后才显示。
- 跨进程、跨设备 DTO 只在 `Common/AgentStatusTransport` 声明。

## 术语

| 术语 | 含义 |
| --- | --- |
| Agent | 产生 Session 事件的工具；v1 为 Codex |
| Session | 一次可持续多个 Turn 的 Agent 会话 |
| Turn | Session 内的一轮用户请求与 Agent 响应 |
| Timeline | 用户活动以及保留的模型配置、内部上下文和消耗指标的有序集合；Mac 详情分模块展示，iPhone 主界面只展示用户活动 |
| daemon | 本地后台服务和 Session 权威存储 |
| helper | Codex Hook 调用的无状态命令行程序 |
| channel | 一台 Mac 与一台 iPhone 的逻辑授权、密钥和序号域 |
| index | Relay 一次发布的收尾帧：当前可见 Session id 全集，设备据此裁剪与校验完整性 |
| Relay | 只负责授权、在线状态和密文路由的 Cloudflare 服务 |

## 代码入口

- daemon/helper：`CLI/`
- 公共状态与存储：`Common/`
- 唯一传输模型：`Common/AgentStatusTransport/`
- 共享设计系统 token：`Common/Sources/AgentStatusDesignSystem/`；设计交接原件：`design/`
- macOS/iOS：`Apps/`
- Cloudflare Relay：`Relay/`
- 产品行为文档：`docs/feat/`
- 当前实施任务：`docs/developer/tasks/260816T1953-agent-status-v1/TASK.md`
