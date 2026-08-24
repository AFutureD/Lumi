# 整体架构设计

Lumi 使用“daemon 唯一权威、客户端持久缓存、Relay 不透明转发”的结构。daemon 负责采集、归并，并作为 Relay Host 把数据层记录（index / 事件 / 整 Session）同步给 iPhone；macOS App 负责本机 UI 与 Notch；iOS 以每台 Mac 一个 SQLite 缓存只读消费，业务层（状态档、展示文案）在各端用共享代码计算。

## 目标

1. 聚合一台 Mac 上多个 Agent、多个 Session，不让连接数随 Session 数增长。
2. Hook 低延迟事件和 rollout 持久日志互相补充，daemon 重启后可以继续处理新内容。
3. daemon、Mac、iOS 都使用 SQLite，使读取和重启恢复不依赖内存快照。
4. Relay 无法读取 Session payload，也不提供业务历史查询。
5. 传输对象只有一个定义源，避免 daemon、App 和 Relay 协议漂移。

## 非目标

- v1 不支持从 iPhone 审批、输入、终止或控制 Agent。
- v1 不实现 Claude、Pi 或其他 Agent Adapter。
- 当前不实现 APNs。
- Relay 不是 Session 数据库，也不承担长期重放。
- 线上只传数据层记录（`SessionSummary` / `TurnSummary` / `TimelineItem` / `AgentIngressEvent` / `DaemonHealth` / index 条目），不传展示层结果。

## 系统拓扑

```mermaid
flowchart LR
    subgraph Mac["一台 Mac"]
        Codex["Codex"]
        Hook["Codex Hooks"]
        Rollout["rollout JSONL"]
        Helper["Spark<br/>无状态"]
        Daemon["Lumen<br/>本地权威"]
        DaemonDB[("daemon SQLite")]
        MacStore["MacSessionStore"]
        MacDB[("Mac SQLite 缓存")]
        MacUI["AppKit 主界面"]
        Notch["OpenNook"]
        RelayHost["RelayHostService<br/>daemon 内"]

        Codex --> Hook -->|stdin JSON| Helper
        Helper -->|Unix socket 请求| Daemon
        Codex --> Rollout -->|增量扫描| Daemon
        Daemon <--> DaemonDB
        Daemon -->|单一订阅流| MacStore
        Daemon <-->|事件流 + 仓库读取| RelayHost
        MacStore <--> MacDB
        MacStore --> MacUI
        MacStore --> Notch
        MacStore -.->|IPC relay_*| RelayHost
    end

    subgraph Cloudflare["Cloudflare"]
        Worker["Worker 路由"]
        DO["每台 Mac 一个 Durable Object"]
        Meta[("授权与运行元数据")]
        Worker --> DO
        DO <--> Meta
    end

    subgraph IPhoneA["iPhone A"]
        DeviceA["RelayDeviceChannel"]
        IOSDBA[("按 Mac 的 SQLite 缓存")]
        UIA["UIKit"]
        DeviceA <--> IOSDBA
        DeviceA --> UIA
    end

    subgraph IPhoneB["iPhone B"]
        DeviceB["RelayDeviceChannel"]
        IOSDBB[("按 Mac 的 SQLite 缓存")]
        UIB["UIKit"]
        DeviceB <--> IOSDBB
        DeviceB --> UIB
    end

    RelayHost -->|"1 条 Host WSS；按设备加密帧"| Worker
    DO -->|"每个 Mac 通道 1 条 Device WSS"| DeviceA
    DO -->|"每个 Mac 通道 1 条 Device WSS"| DeviceB
```

## 数量关系

| 对象 | 数量关系 | 连接策略 |
| --- | --- | --- |
| Mac | 1 台设备 | 1 daemon + 1 macOS App |
| Agent | 每台 Mac 0..N 个 | 事件统一进入同一个 daemon |
| Session | 每个 Agent 0..N 个 | 不创建独立 socket、event loop 或 WSS |
| 本地 request | 按操作创建 | helper 和普通 IPC 请求使用短连接 |
| 本地事件订阅 | 每个 Mac App 1 条 | 全部 Session 复用持久 Unix socket channel |
| Relay Host WSS | 每个 daemon 1 条 | 一条连接发送所有已配对设备的定向帧，并接收设备的密封请求 |
| Mac—iPhone 逻辑通道 | 每对设备 1 个 | 独立授权、密钥、序号和 iOS SQLite |
| iPhone Device WSS | 每个已配对 Mac 1 条 | 一台 iPhone 可同时连接多台 Mac |
| Durable Object | 每个 `HostID` 1 个 | 隔离授权、连接与序号状态 |

## 组件职责

| 组件 | 负责 | 不负责 |
| --- | --- | --- |
| helper | 读取 Hook stdin、归一化、发送事件、报告失败 | 保存状态、扫描日志、重试队列 |
| daemon | 建立基线、归并事件、SQLite 权威存储、本地查询与事件扇出、Relay Host（注册、配对会话与 SAS / Match 状态机、设备列表与公钥钉住、应答 iPhone 请求、推送增量） | UI、QR 渲染 |
| Mac App | SQLite 客户端缓存、AppKit UI、Notch、daemon 管理、Hook 安装、配对页（经 IPC 驱动 daemon 的 Relay Host） | 解析原始 rollout、成为业务权威、持有 Relay 凭据或连接 |
| iOS App | 多 Mac 配对、每通道 SQLite 缓存、index-first 对账 + 事件流、始终显示缓存 | Agent 控制、Relay 历史查询、成为数据源 |
| Relay | Host/Device 鉴权、配对、撤销、在线状态、密文转发 | 解密 Session、保存业务数据、重放历史 |
| Transport Package | DTO、版本、编码、framing、golden fixture | 网络连接、SQLite、UI、Reducer |

## Swift Package 分层

```mermaid
flowchart TD
    Transport["Transport<br/>Foundation only"]
    Core["Core<br/>Reducer + Repository 协议"]
    Persistence["Persistence<br/>GRDB repository"]
    Codex["Adapters<br/>Adapter"]
    IPC["IPCClient<br/>POSIX socket"]
    Remote["Remote<br/>CryptoKit + URLSession + Keychain"]
    Design["DesignSystem<br/>颜色 / 字号 / 间距 token"]
    CLI["CLI daemon/helper"]
    Mac["macOS Feature"]
    IOS["iOS Feature"]

    Transport --> Core
    Transport --> Codex
    Transport --> IPC
    Transport --> Remote
    Core --> Persistence
    Core --> Codex
    Core --> CLI
    Persistence --> CLI
    Codex --> CLI
    IPC --> CLI
    Transport --> Design
    Core --> Design
    Core --> Mac
    Persistence --> Mac
    IPC --> Mac
    Remote --> Mac
    Design --> Mac
    Core --> IOS
    Persistence --> IOS
    Remote --> IOS
    Design --> IOS
```

边界规则：

- `Transport` 只依赖 Foundation。
- Session、Timeline、IPC 和 Relay routing DTO 不在 Package 外重复声明。
- `Core` 拥有 reducer 与 repository 协议，不依赖 GRDB 与 AppKit/UIKit；GRDB 实现单独放在 `Persistence`，只有真正持久化的进程（daemon、App 缓存）链接它。helper 读取 Codex 状态库走系统 SQLite3，不引入 GRDB。
- `DesignSystem` 承载设计系统 L1 基础规范（颜色、字号、间距、圆角、关键尺寸、消息类别标签与状态色梯度），只依赖 Foundation（SwiftUI 适配放在 `#if canImport(SwiftUI)`）；macOS、Notch、iOS 视图不写颜色 / 字号 literal，只引用这里的 token。设计交接原件归档在仓库根目录 `design/`（`DESIGN SYSTEM.html` 为唯一取值来源）。
- App 创建 ViewModel 或控制器状态，但不重新声明传输层业务对象。
- Relay 通过共享 golden JSON 校验 routing frame，不解析 `RemoteSessionPayload`。

## 权威边界

1. **Agent 原始事实**：Codex Hook JSON 与 rollout JSONL。
2. **本机产品事实**：daemon SQLite；Reducer 决定当前 Session 状态。
3. **Mac 展示副本**：Mac SQLite；启动/手动对账按 Session 替换与裁剪，Agent 事件可增量应用。
4. **iOS 缓存**：每台 Mac 一个 SQLite（与 daemon / Mac 同一 schema）；按 daemon 的 `session_index` 对账（多余裁掉、缺失整取、timeline 变化补尾、仅 summary 变化单独写入），之后用与 daemon 相同的 reducer 应用 `session_message` 事件流。
5. **Relay 元数据**：授权、配对、限流和序号；不是业务事实源。

删除操作先进入 daemon。daemon 记录 ignored Session tombstone 后再删除业务数据，避免之后到达的晚事件让 Session 复活。

## 启动顺序

### daemon

1. 创建权限为 `0700` 的 Application Support 目录。
2. 打开并迁移 daemon SQLite。
3. 第一次运行时把已存在 rollout 文件标为基线，不导入旧 Session。
4. 启动 Unix socket，socket 权限设为 `0600`。
5. 启动 rollout watcher，默认每 2 秒检查文件尺寸变化。
6. 从 Keychain 加载（或创建并注册）Relay host 凭据，建立 Host WSS，订阅自己的事件流；`DaemonHealth.relayConnected` 随连接状态变化（`LUMI_RELAY=0` 可关闭）。

### macOS App

1. 打开 Mac SQLite 缓存并先渲染已保存内容。
2. 与 daemon 对账：索引 diff 后逐 Session 拉取替换、裁剪多余项。
3. 建立一个持久事件订阅 channel。
4. 启动主窗口和 OpenNook；配对页经 IPC（`relay_status` / `relay_pairing_start` / `relay_pairing_state` / `relay_pairing_decide` / `relay_pairing_cancel` / `relay_revoke_device`）读写 daemon 的 Relay Host。

### iOS App

1. 从 Keychain 恢复所有 Mac 通道凭据。
2. 为每台 Mac 打开独立 SQLite 缓存，先把缓存内容显示出来。
3. 建立 Device WSS；Host 在线即发送密封的 `sync_index` 请求，收齐 index 后用 `SyncReconcilePlan` 对账（裁剪 / 整取 / 补尾 / 改 summary）。
4. 之后应用 `session_message` 事件流；序号断档、重连、回到前台、下拉刷新都重新索取 index。

## 当前实现约束

- iOS 与以前一样把每个 Session 的完整 `SessionDetail` 载入内存（与缓存等量）；超大历史的懒加载待做。
- Relay 不缓冲：iPhone 离线期间的变化靠下一次 index 对账补齐，不是逐帧重放。
- Release 签名、公证、干净机器 LaunchAgent 和真实物理 iPhone 仍待最终验收。

## 相关文档

- [数据、通信与保存设计](data-communication-storage.md)
- [Agent Hook 设计](agent-hook.md)
- [Relay、配对与安全设计](relay-pairing-security.md)
- [App 与运行时设计](application-runtime.md)
- [构建、发布与测试设计](build-release-testing.md)
